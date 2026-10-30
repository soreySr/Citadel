#include "Jak1ModLevelRecipe.h"

#ifdef DEBUG
#undef DEBUG
#endif

#include <compression.h>

#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <stdexcept>

#include "common/custom_data/Tfrag3Data.h"
#include "common/util/Serializer.h"

#include "third-party/json.hpp"
#include "third-party/tiny_gltf/tiny_gltf.h"

namespace jak1 {

ModLevelRecipe ParseModLevelRecipe(const std::string &text) {
    const auto json = nlohmann::json::parse(text);
    if (json.value("format", 0) != 1) throw std::runtime_error("unknown mod level recipe format");
    ModLevelRecipe recipe;
    for (const auto &entry : json.value("images", nlohmann::json::array())) {
        RecipeImage image;
        image.index = entry.at("index").get<int>();
        image.id = entry.at("id").get<u32>();
        image.name = entry.at("name").get<std::string>();
        if (entry.contains("set")) image.set = entry.at("set").get<std::array<int, 4>>();
        if (entry.contains("from")) image.from = entry.at("from").get<std::array<int, 4>>();
        recipe.images.push_back(image);
    }
    for (const auto &entry : json.value("pieces", nlohmann::json::array())) {
        RecipePiece piece;
        piece.level = entry.at("level").get<std::string>();
        piece.kind = entry.at("kind").get<std::string>();
        piece.tree = entry.value("tree", 0);
        piece.tod = entry.value("tod", 0);
        piece.r = entry.at("r").get<std::array<double, 9>>();
        piece.t = entry.at("t").get<std::array<double, 3>>();
        recipe.pieces.push_back(piece);
    }
    for (const auto &entry : json.value("primitives", nlohmann::json::array())) {
        RecipePrimitive primitive;
        primitive.mesh = entry.at("mesh").get<int>();
        primitive.primitive = entry.at("primitive").get<int>();
        primitive.piece = entry.at("piece").get<std::vector<int>>();
        primitive.source = entry.at("source").get<std::vector<u32>>();
        primitive.flags = entry.at("flags").get<std::vector<u32>>();
        if (primitive.piece.size() != primitive.source.size() ||
            primitive.piece.size() != primitive.flags.size()) {
            throw std::runtime_error("mod level recipe: vertex lists differ in length");
        }
        recipe.primitives.push_back(std::move(primitive));
    }
    return recipe;
}

std::string SerializeModLevelRecipe(const ModLevelRecipe &recipe) {
    nlohmann::json json;
    json["format"] = 1;
    json["images"] = nlohmann::json::array();
    for (const auto &image : recipe.images) {
        nlohmann::json entry = {{"index", image.index}, {"id", image.id}, {"name", image.name}};
        if (image.set != std::array<int, 4> {-1, -1, -1, -1}) entry["set"] = image.set;
        if (image.from != std::array<int, 4> {0, 1, 2, 3}) entry["from"] = image.from;
        json["images"].push_back(entry);
    }
    json["pieces"] = nlohmann::json::array();
    for (const auto &piece : recipe.pieces) {
        json["pieces"].push_back({{"level", piece.level}, {"kind", piece.kind}, {"tree", piece.tree},
                                  {"tod", piece.tod}, {"r", piece.r}, {"t", piece.t}});
    }
    json["primitives"] = nlohmann::json::array();
    for (const auto &primitive : recipe.primitives) {
        json["primitives"].push_back({{"mesh", primitive.mesh}, {"primitive", primitive.primitive},
                                      {"piece", primitive.piece}, {"source", primitive.source},
                                      {"flags", primitive.flags}});
    }
    return json.dump();
}

void LoadFr3z(const std::string &path, tfrag3::Level &level) {
    std::ifstream stream(path, std::ios::binary);
    std::vector<u8> file((std::istreambuf_iterator<char>(stream)), {});
    uint32_t magic = 0;
    uint64_t rawSize = 0;
    if (file.size() < 12) throw std::runtime_error("missing " + path);
    memcpy(&magic, file.data(), 4);
    memcpy(&rawSize, file.data() + 4, 8);
    if (magic != 0x5a335246) throw std::runtime_error("not an FR3Z file: " + path);
    std::vector<u8> raw(rawSize);
    if (compression_decode_buffer(raw.data(), raw.size(), file.data() + 12, file.size() - 12, nullptr,
                                  COMPRESSION_LZFSE) != rawSize) {
        throw std::runtime_error("could not decompress " + path);
    }
    file = {};
    Serializer ser(raw.data(), raw.size());
    level.serialize(ser);
}

std::vector<SourceVertex> SourceVertices(const tfrag3::Level &level, const std::string &kind, int tree, int tod) {
    std::vector<SourceVertex> out;
    const auto addPreloaded = [&](const std::vector<tfrag3::PreloadedVertex> &vertices,
                                  const tfrag3::PackedTimeOfDay &colors) {
        out.reserve(vertices.size());
        for (const auto &v : vertices) {
            SourceVertex s {};
            s.pos[0] = v.x / 4096.f;
            s.pos[1] = v.y / 4096.f;
            s.pos[2] = v.z / 4096.f;
            s.st[0] = v.s;
            s.st[1] = v.t;
            for (int c = 0; c < 3; c++) s.color[c] = colors.read(v.color_index, tod, c) / 255.f;
            out.push_back(s);
        }
    };
    if (kind == "merc") {
        out.reserve(level.merc_data.vertices.size());
        for (const auto &v : level.merc_data.vertices) {
            SourceVertex s {};
            for (int c = 0; c < 3; c++) {
                s.pos[c] = v.pos[c] / 4096.f;
                s.color[c] = v.rgba[c] / 255.f;
            }
            s.st[0] = v.st[0];
            s.st[1] = v.st[1];
            const float length = v.normal_vec.length();
            const auto normal = length > 0 ? v.normal_vec / length : math::Vector3f(0, 1, 0);
            for (int c = 0; c < 3; c++) s.normal[c] = normal[c];
            out.push_back(s);
        }
        return out;
    }
    int index = 0;
    if (kind == "tfrag") {
        for (const auto &trees : level.tfrag_trees) {
            for (const auto &t : trees) {
                if (index++ == tree) {
                    addPreloaded(t.unpacked.vertices, t.colors);
                    return out;
                }
            }
        }
    } else if (kind == "tie") {
        for (const auto &trees : level.tie_trees) {
            for (const auto &t : trees) {
                if (index++ == tree) {
                    addPreloaded(t.unpacked.vertices, t.colors);
                    return out;
                }
            }
        }
    }
    throw std::runtime_error("mod level recipe: no " + kind + " tree " + std::to_string(tree) + " in " +
                             level.level_name);
}

namespace {

struct AccessorView {
    u8 *base = nullptr;
    size_t stride = 0;
    size_t count = 0;
    int componentType = 0;
    int components = 0;
    bool normalized = false;
};

AccessorView View(tinygltf::Model &model, int accessorIndex) {
    AccessorView view;
    if (accessorIndex < 0) return view;
    auto &accessor = model.accessors.at(accessorIndex);
    auto &bufferView = model.bufferViews.at(accessor.bufferView);
    view.base = model.buffers.at(bufferView.buffer).data.data() + bufferView.byteOffset + accessor.byteOffset;
    view.stride = accessor.ByteStride(bufferView);
    view.count = accessor.count;
    view.componentType = accessor.componentType;
    view.components = tinygltf::GetNumComponentsInType(accessor.type);
    view.normalized = accessor.normalized;
    return view;
}

void Write(const AccessorView &view, size_t vertex, const float *values, int count) {
    if (!view.base || vertex >= view.count) return;
    u8 *p = view.base + vertex * view.stride;
    for (int c = 0; c < std::min(count, view.components); c++) {
        const float v = values[c];
        switch (view.componentType) {
            case TINYGLTF_COMPONENT_TYPE_FLOAT: memcpy(p + 4 * c, &v, 4); break;
            case TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT: {
                const u16 s = (u16)std::lround(std::clamp(v, 0.f, 1.f) * 65535.f);
                memcpy(p + 2 * c, &s, 2);
                break;
            }
            case TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE: p[c] = (u8)std::lround(std::clamp(v, 0.f, 1.f) * 255.f); break;
            default: throw std::runtime_error("mod level recipe: unsupported vertex component type");
        }
    }
}

int Attribute(const tinygltf::Primitive &primitive, const char *name) {
    const auto found = primitive.attributes.find(name);
    return found == primitive.attributes.end() ? -1 : found->second;
}

}  // namespace

void ApplyModLevelGeometry(tinygltf::Model &model, const ModLevelRecipe &recipe, const std::string &fr3Directory) {
    if (recipe.primitives.empty()) return;
    // Source vertices per piece, loading each level once.
    std::vector<std::vector<SourceVertex>> pieceSources(recipe.pieces.size());
    std::map<std::string, std::vector<size_t>> piecesByLevel;
    for (size_t i = 0; i < recipe.pieces.size(); i++) piecesByLevel[recipe.pieces[i].level].push_back(i);
    for (const auto &[name, pieces] : piecesByLevel) {
        tfrag3::Level level;
        LoadFr3z(fr3Directory + "/Jak1Level-" + name + ".fr3z", level);
        for (size_t i : pieces) {
            const auto &piece = recipe.pieces[i];
            if (piece.kind == "tfrag" || piece.kind == "tie") {
                int index = 0;
                auto unpackTree = [&](auto &trees) {
                    for (auto &geometry : trees) {
                        for (auto &tree : geometry) {
                            if (index++ == piece.tree && tree.unpacked.vertices.empty()) tree.unpack();
                        }
                    }
                };
                if (piece.kind == "tfrag") unpackTree(level.tfrag_trees);
                else unpackTree(level.tie_trees);
            }
            pieceSources[i] = SourceVertices(level, piece.kind, piece.tree, piece.tod);
        }
    }

    for (const auto &entry : recipe.primitives) {
        auto &primitive = model.meshes.at(entry.mesh).primitives.at(entry.primitive);
        const AccessorView position = View(model, Attribute(primitive, "POSITION"));
        const AccessorView uv = View(model, Attribute(primitive, "TEXCOORD_0"));
        const AccessorView color = View(model, Attribute(primitive, "COLOR_0"));
        const AccessorView normal = View(model, Attribute(primitive, "NORMAL"));
        if (position.count != entry.piece.size()) {
            throw std::runtime_error("mod level recipe: vertex count differs from the glb");
        }
        bool recompute = false;
        for (size_t v = 0; v < entry.piece.size(); v++) {
            if (entry.piece[v] < 0) continue;
            const auto &piece = recipe.pieces.at(entry.piece[v]);
            const auto &source = pieceSources.at(entry.piece[v]).at(entry.source[v]);
            const u32 flags = entry.flags[v];
            if (flags & kRecipePosition) {
                float out[3];
                for (int r = 0; r < 3; r++) {
                    out[r] = (float)(piece.r[r * 3] * source.pos[0] + piece.r[r * 3 + 1] * source.pos[1] +
                                     piece.r[r * 3 + 2] * source.pos[2] + piece.t[r]);
                }
                Write(position, v, out, 3);
            }
            if (flags & kRecipeUv) Write(uv, v, source.st, 2);
            if (flags & kRecipeColor) {
                const float rgba[4] = {source.color[0], source.color[1], source.color[2], 1.f};
                Write(color, v, rgba, 4);
            }
            if (flags & kRecipeNormal) {
                float out[3];
                for (int r = 0; r < 3; r++) {
                    out[r] = (float)(piece.r[r * 3] * source.normal[0] + piece.r[r * 3 + 1] * source.normal[1] +
                                     piece.r[r * 3 + 2] * source.normal[2]);
                }
                Write(normal, v, out, 3);
            }
            recompute |= (flags & kRecipeNormalRecompute) != 0;
        }
        if (!recompute || !normal.base || primitive.indices < 0) continue;

        // Smooth normals from the rebuilt triangles: area-weighted face normals summed over vertices that share a
        // position, for the vertices flagged kRecipeNormalRecompute.
        const auto read = [&](size_t v, float *out) {
            for (int c = 0; c < 3; c++) memcpy(&out[c], position.base + v * position.stride + 4 * c, 4);
        };
        const auto &indexAccessor = model.accessors.at(primitive.indices);
        const auto &indexView = model.bufferViews.at(indexAccessor.bufferView);
        const u8 *indexBase =
            model.buffers.at(indexView.buffer).data.data() + indexView.byteOffset + indexAccessor.byteOffset;
        const auto index = [&](size_t i) -> u32 {
            switch (indexAccessor.componentType) {
                case TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE: return indexBase[i];
                case TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT: { u16 s; memcpy(&s, indexBase + 2 * i, 2); return s; }
                default: { u32 s; memcpy(&s, indexBase + 4 * i, 4); return s; }
            }
        };
        std::map<std::array<float, 3>, std::array<double, 3>> sums;
        for (size_t i = 0; i + 2 < indexAccessor.count; i += 3) {
            float a[3], b[3], c[3];
            read(index(i), a);
            read(index(i + 1), b);
            read(index(i + 2), c);
            const double e1[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
            const double e2[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
            const double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                                 e1[0] * e2[1] - e1[1] * e2[0]};
            for (const float *p : {a, b, c}) {
                auto &sum = sums[{p[0], p[1], p[2]}];
                for (int k = 0; k < 3; k++) sum[k] += n[k];
            }
        }
        for (size_t v = 0; v < entry.piece.size(); v++) {
            if (entry.piece[v] < 0 || !(entry.flags[v] & kRecipeNormalRecompute)) continue;
            float p[3];
            read(v, p);
            const auto &sum = sums[{p[0], p[1], p[2]}];
            const double length = std::sqrt(sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]);
            const float sign = (entry.flags[v] & kRecipeNormalFlip) ? -1.f : 1.f;
            const float out[3] = {length > 0 ? sign * float(sum[0] / length) : 0.f,
                                  length > 0 ? sign * float(sum[1] / length) : sign,
                                  length > 0 ? sign * float(sum[2] / length) : 0.f};
            Write(normal, v, out, 3);
        }
    }
}

}  // namespace jak1
