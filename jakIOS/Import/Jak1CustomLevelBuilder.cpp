// See Jak1CustomLevelBuilder.h. The model selection, texture/vertex remapping and the flut pad conversion
// are the former desktop tools (tools/boat, tools/fish, tools/flut), now run on the device at import.
#include "Jak1CustomLevelBuilder.h"

#include <compression.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <stdexcept>
#include <tuple>
#include <vector>

#include "common/custom_data/Tfrag3Data.h"
#include "common/util/Serializer.h"

namespace jak1 {

namespace {

constexpr uint32_t kFr3zMagic = 0x5a335246;  // "FR3Z": u32 magic, u64 raw size, LZFSE stream

std::vector<uint8_t> ReadFile(const std::string &path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("cannot read " + path);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(stream), {});
}

tfrag3::Level ReadFr3z(const std::string &path) {
    const std::vector<uint8_t> file = ReadFile(path);
    uint32_t magic = 0;
    uint64_t rawSize = 0;
    if (file.size() < 12) throw std::runtime_error(path + " is truncated");
    memcpy(&magic, file.data(), 4);
    memcpy(&rawSize, file.data() + 4, 8);
    if (magic != kFr3zMagic || rawSize == 0 || rawSize > (1ull << 31)) {
        throw std::runtime_error(path + " is not a level file");
    }
    std::vector<uint8_t> raw(rawSize);
    if (compression_decode_buffer(raw.data(), raw.size(), file.data() + 12, file.size() - 12, nullptr,
                                  COMPRESSION_LZFSE) != rawSize) {
        throw std::runtime_error(path + " could not be decoded");
    }
    tfrag3::Level level;
    Serializer ser(raw.data(), raw.size());
    level.serialize(ser);
    return level;
}

void WriteFr3z(tfrag3::Level &level, const std::string &path) {
    Serializer ser;
    level.serialize(ser);
    const auto [data, size] = ser.get_save_result();
    std::vector<uint8_t> encoded(size + 4096);
    const size_t encodedSize = compression_encode_buffer(encoded.data(), encoded.size(), data, size, nullptr,
                                                         COMPRESSION_LZFSE);
    if (encodedSize == 0) throw std::runtime_error("could not compress " + path);
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    const uint64_t rawSize = size;
    stream.write(reinterpret_cast<const char *>(&kFr3zMagic), 4);
    stream.write(reinterpret_cast<const char *>(&rawSize), 8);
    stream.write(reinterpret_cast<const char *>(encoded.data()), static_cast<std::streamsize>(encodedSize));
    if (!stream) throw std::runtime_error("could not write " + path);
}

// Copies src's Merc models whose names pass `keep` into out, with only the textures and vertices they use
// (indices into out). Texture and vertex indices are per source level, so each call remaps separately.
size_t AppendMercModels(tfrag3::Level &out, const tfrag3::Level &src,
                        const std::function<bool(const std::string &)> &keep) {
    std::map<s32, s32> texRemap;
    std::map<u32, u32> vertRemap;
    const auto remapTexture = [&](s32 id) {
        auto found = texRemap.find(id);
        if (found == texRemap.end()) {
            found = texRemap.emplace(id, static_cast<s32>(out.textures.size())).first;
            out.textures.push_back(src.textures.at(id));
        }
        return found->second;
    };
    const auto remapDraw = [&](tfrag3::MercDraw &draw) {
        if (draw.tree_tex_id >= 0) draw.tree_tex_id = remapTexture(draw.tree_tex_id);
        const u32 first = static_cast<u32>(out.merc_data.indices.size());
        for (u32 i = 0; i < draw.index_count; i++) {
            const u32 index = src.merc_data.indices.at(draw.first_index + i);
            if (index == UINT32_MAX) {  // strip restart
                out.merc_data.indices.push_back(index);
                continue;
            }
            auto found = vertRemap.find(index);
            if (found == vertRemap.end()) {
                found = vertRemap.emplace(index, static_cast<u32>(out.merc_data.vertices.size())).first;
                out.merc_data.vertices.push_back(src.merc_data.vertices.at(index));
            }
            out.merc_data.indices.push_back(found->second);
        }
        draw.first_index = first;
    };
    size_t kept = 0;
    for (const auto &model : src.merc_data.models) {
        if (!keep(model.name)) continue;
        tfrag3::MercModel copy = model;
        for (auto &effect : copy.effects) {
            if (effect.has_mod_draw) throw std::runtime_error(model.name + " has blend shapes");
            for (auto &draw : effect.all_draws) remapDraw(draw);
            if (effect.has_envmap) {
                effect.envmap_texture = static_cast<u32>(remapTexture(static_cast<s32>(effect.envmap_texture)));
            }
        }
        out.merc_data.models.push_back(std::move(copy));
        kept++;
    }
    return kept;
}

bool StartsWith(const std::string &text, const char *prefix) {
    return text.rfind(prefix, 0) == 0;
}

// These files are drawn by texture index only: registering their textures in the pool (combo id) would
// shadow the source levels' own copies.
void KeepTexturesOutOfPool(tfrag3::Level &level) {
    for (auto &texture : level.textures) {
        texture.combo_id = 0;
        texture.load_to_pool = false;
    }
}

// One TIE prototype instance as a tfrag tree in prop-local coordinates, with its textures and time-of-day
// colors. With an anchor (game units), only the instance within kAnchorRadius of it is taken and the anchor is
// the local origin; without one, the whole prototype with its bounding box's top centre as the origin.
struct TieAnchor {
    float x, y, z;
};

void AppendTieProtoAsTfrag(tfrag3::Level &out, tfrag3::Level &source, const char *protoName,
                           const TieAnchor *anchor) {
    struct Tri {
        tfrag3::PreloadedVertex v[3];
        int draw;
    };
    constexpr float kAnchorRadius = 8 * 4096;
    const auto nearAnchor = [&](const Tri &t) {
        if (anchor == nullptr) return true;
        for (const auto &v : t.v) {
            if (std::hypot(v.x - anchor->x, v.z - anchor->z) > kAnchorRadius ||
                std::fabs(v.y - anchor->y) > kAnchorRadius) return false;
        }
        return true;
    };
    for (auto &tree : source.tie_trees[0]) {
        const auto proto = std::find(tree.proto_names.begin(), tree.proto_names.end(), protoName);
        if (proto == tree.proto_names.end()) continue;
        const u16 protoIdx = static_cast<u16>(proto - tree.proto_names.begin());
        tree.unpack();
        // Base draws only (the shiny envmap second pass needs the TIE renderer).
        const u32 lastBaseDraw = tree.category_draw_indices[(int)tfrag3::TieCategory::NORMAL_ENVMAP_SECOND_DRAW];
        std::vector<Tri> tris;
        for (u32 d = 0; d < lastBaseDraw && d < tree.static_draws.size(); d++) {
            const auto &draw = tree.static_draws[d];
            u32 at = draw.unpacked.idx_of_first_idx_in_full_buffer;
            for (const auto &group : draw.vis_groups) {
                if (group.tie_proto_idx == protoIdx) {
                    // triangle strips with restart markers
                    std::vector<u32> strip;
                    const auto flushStrip = [&]() {
                        for (size_t k = 2; k < strip.size(); k++) {
                            Tri t;
                            t.draw = static_cast<int>(d);
                            const bool odd = k & 1;
                            t.v[0] = tree.unpacked.vertices[strip[k - 2]];
                            t.v[1] = tree.unpacked.vertices[strip[odd ? k : k - 1]];
                            t.v[2] = tree.unpacked.vertices[strip[odd ? k - 1 : k]];
                            if (nearAnchor(t)) tris.push_back(t);
                        }
                        strip.clear();
                    };
                    for (u32 k = 0; k < group.num_inds; k++) {
                        const u32 idx = tree.unpacked.indices[at + k];
                        if (idx == UINT32_MAX) {
                            flushStrip();
                        } else {
                            strip.push_back(idx);
                        }
                    }
                    flushStrip();
                }
                at += group.num_inds;
            }
        }
        if (tris.empty()) continue;

        float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
        for (const auto &t : tris) {
            for (const auto &v : t.v) {
                const float p[3] = {v.x, v.y, v.z};
                for (int a = 0; a < 3; a++) lo[a] = std::min(lo[a], p[a]), hi[a] = std::max(hi[a], p[a]);
            }
        }
        const float origin[3] = {anchor ? anchor->x : (lo[0] + hi[0]) / 2, anchor ? anchor->y : hi[1],
                                 anchor ? anchor->z : (lo[2] + hi[2]) / 2};

        tfrag3::TfragTree padTree;
        padTree.kind = tfrag3::TFragmentTreeKind::NORMAL;
        padTree.use_strips = false;
        std::map<u16, u16> colorRemap;
        std::map<s32, s32> texRemap;
        std::map<int, std::vector<u32>> indicesOfDraw;
        std::map<std::tuple<u16, u16, u16>, u16> clusters;
        constexpr float kClusterSize = 4096 * 40;
        constexpr float kMasterOffset = 12000 * 4096;
        constexpr float rescale = kClusterSize / UINT16_MAX;
        for (const auto &t : tris) {
            for (const auto &v : t.v) {
                const float p[3] = {v.x - origin[0], v.y - origin[1], v.z - origin[2]};
                u16 c[3], off[3];
                for (int a = 0; a < 3; a++) {
                    c[a] = static_cast<u16>(std::floor((p[a] + kMasterOffset) / kClusterSize));
                    const float o = -kMasterOffset + kClusterSize * c[a];
                    off[a] = static_cast<u16>(std::clamp(std::lround((p[a] - o) / rescale), 0L, 65535L));
                }
                const auto key = std::make_tuple(c[0], c[1], c[2]);
                auto cl = clusters.find(key);
                if (cl == clusters.end()) {
                    cl = clusters.emplace(key, static_cast<u16>(padTree.packed_vertices.cluster_origins.size())).first;
                    padTree.packed_vertices.cluster_origins.push_back({c[0], c[1], c[2]});
                }
                auto col = colorRemap.find(v.color_index);
                if (col == colorRemap.end()) {
                    col = colorRemap.emplace(v.color_index, static_cast<u16>(colorRemap.size())).first;
                }
                tfrag3::PackedTfragVertices::Vertex pv;
                pv.xoff = off[0];
                pv.yoff = off[1];
                pv.zoff = off[2];
                pv.cluster_idx = cl->second;
                pv.s = static_cast<s16>(std::clamp(std::lround(v.s * 1024.f), -32768L, 32767L));
                pv.t = static_cast<s16>(std::clamp(std::lround(v.t * 1024.f), -32768L, 32767L));
                pv.color_index = col->second;
                indicesOfDraw[t.draw].push_back(static_cast<u32>(padTree.packed_vertices.vertices.size()));
                padTree.packed_vertices.vertices.push_back(pv);
            }
        }
        // time-of-day palette: the referenced colors only, in groups of four
        padTree.colors.color_count = static_cast<u32>((colorRemap.size() + 3) / 4 * 4);
        padTree.colors.data.assign(padTree.colors.color_count / 4 * 4 * 4 * 8, 0);
        for (const auto &[src, dst] : colorRemap) {
            for (int pal = 0; pal < 8; pal++) {
                for (int ch = 0; ch < 4; ch++) padTree.colors.read(dst, pal, ch) = tree.colors.read(src, pal, ch);
            }
        }
        for (const auto &[d, indices] : indicesOfDraw) {
            const auto &src = tree.static_draws[d];
            tfrag3::StripDraw draw;
            draw.mode = src.mode;
            if (src.tree_tex_id >= 0) {
                auto tex = texRemap.find(src.tree_tex_id);
                if (tex == texRemap.end()) {
                    tex = texRemap.emplace(src.tree_tex_id, static_cast<s32>(out.textures.size())).first;
                    out.textures.push_back(source.textures.at(src.tree_tex_id));
                }
                draw.tree_tex_id = tex->second;
            } else {
                draw.tree_tex_id = src.tree_tex_id;
            }
            draw.plain_indices = indices;
            draw.num_triangles = static_cast<u32>(indices.size()) / 3;
            tfrag3::StripDraw::VisGroup group;
            group.num_inds = static_cast<u32>(indices.size());
            group.num_tris = draw.num_triangles;
            group.vis_idx_in_pc_bvh = UINT16_MAX;  // always drawn (no BVH)
            draw.vis_groups.push_back(group);
            padTree.draws.push_back(draw);
        }
        for (int geom = 0; geom < tfrag3::TFRAG_GEOS; geom++) out.tfrag_trees[geom].push_back(padTree);
        return;
    }
    throw std::runtime_error(std::string(protoName) + " not found in " + source.level_name);
}

// The coast template (tools/coast) holds our terrain tree with draw modes and per-vertex material/light
// (color_index = material * 4 + light) but no texture pixels or colors. Fill them from the jungle level:
// each material's texture by name, and four brightness levels per material from the colors the jungle's
// vertices with that texture use (same rule as tools/coast/coast_terrain_fr3.cpp).
void FillCoastFromJungle(tfrag3::Level &coast, tfrag3::Level &jungle) {
    if (coast.tfrag_trees[0].empty()) throw std::runtime_error("the coast template has no terrain");
    for (auto &tree : jungle.tfrag_trees[0]) tree.unpack();
    const tfrag3::TfragTree *main = nullptr;
    for (const auto &tree : jungle.tfrag_trees[0]) {
        if (tree.kind == tfrag3::TFragmentTreeKind::NORMAL && (!main || tree.draws.size() > main->draws.size())) {
            main = &tree;
        }
    }
    if (main == nullptr) throw std::runtime_error("jungle has no tfrag tree");

    const int materials = static_cast<int>(coast.textures.size());
    std::vector<int> jungleTexture(materials, -1);
    for (int m = 0; m < materials; m++) {
        for (size_t i = 0; i < jungle.textures.size(); i++) {
            if (jungle.textures[i].debug_name == coast.textures[m].debug_name) {
                jungleTexture[m] = static_cast<int>(i);
                break;
            }
        }
        if (jungleTexture[m] < 0) throw std::runtime_error("jungle texture " + coast.textures[m].debug_name);
        coast.textures[m] = jungle.textures[jungleTexture[m]];
    }

    std::vector<std::vector<int>> colorsOf(materials);
    for (const auto &draw : main->draws) {
        for (int m = 0; m < materials; m++) {
            if (draw.tree_tex_id != jungleTexture[m]) continue;
            const u32 first = draw.unpacked.idx_of_first_idx_in_full_buffer;
            u32 count = 0;
            for (const auto &g : draw.vis_groups) count += g.num_inds;
            for (u32 k = 0; k < count; k++) {
                const u32 idx = main->unpacked.indices[first + k];
                if (idx == UINT32_MAX) continue;
                colorsOf[m].push_back(main->unpacked.vertices[idx].color_index);
            }
        }
    }
    const auto brightness = [&](int c) {
        float sum = 0;
        for (int p = 0; p < 8; p++) {
            for (int ch = 0; ch < 3; ch++) sum += main->colors.read(c, p, ch);
        }
        return sum;
    };
    tfrag3::PackedTimeOfDay tod;
    tod.color_count = materials * 4;
    tod.data.resize(materials * 4 * 4 * 8);
    for (int m = 0; m < materials; m++) {
        auto &cs = colorsOf[m];
        if (cs.empty()) throw std::runtime_error("no jungle colors for " + coast.textures[m].debug_name);
        std::sort(cs.begin(), cs.end(), [&](int a, int b) { return brightness(a) < brightness(b); });
        const float q[4] = {0.15f, 0.4f, 0.65f, 0.88f};
        for (int l = 0; l < 4; l++) {
            const int src = cs[std::min(cs.size() - 1, static_cast<size_t>(q[l] * cs.size()))];
            for (int p = 0; p < 8; p++) {
                for (int ch = 0; ch < 4; ch++) tod.read(m * 4 + l, p, ch) = main->colors.read(src, p, ch);
            }
        }
    }
    for (int geom = 0; geom < tfrag3::TFRAG_GEOS; geom++) {
        for (auto &tree : coast.tfrag_trees[geom]) tree.colors = tod;
    }
}

}  // namespace

bool BuildCustomLevels(const std::string &fr3Directory, const std::string &coastTemplatePath,
                       std::string *error) {
    const auto levelPath = [&](const std::string &name) {
        return fr3Directory + "/Jak1Level-" + name + ".fr3z";
    };
    try {
        tfrag3::Level village1 = ReadFr3z(levelPath("village1"));
        {
            tfrag3::Level boat;
            boat.level_name = "ios-boat";
            const auto kept = AppendMercModels(boat, village1, [](const std::string &name) {
                return StartsWith(name, "fishermans-boat") || StartsWith(name, "sharkey");
            });
            if (kept == 0) throw std::runtime_error("no fishermans-boat / sharkey model in village1");
            KeepTexturesOutOfPool(boat);
            WriteFr3z(boat, levelPath("ios-boat"));
        }
        {
            tfrag3::Level flut;
            flut.level_name = "ios-flut";
            const tfrag3::Level swamp = ReadFr3z(levelPath("swamp"));
            if (AppendMercModels(flut, swamp, [](const std::string &name) { return StartsWith(name, "flut-saddle"); }) == 0) {
                throw std::runtime_error("no flut-saddle model in swamp");
            }
            AppendTieProtoAsTfrag(flut, village1, "vil1-portal.mb", nullptr);
            KeepTexturesOutOfPool(flut);
            WriteFr3z(flut, levelPath("ios-flut"));
        }
        village1 = {};
        {
            tfrag3::Level fish;
            fish.level_name = "ios-fish";
            // catch-fisha/b and junglefish from jungle (not catch-fishc, the fishing game's poisonous eel), the
            // three sunkenfisha colour variants from sunken.
            const auto isOceanFish = [](const std::string &name) {
                for (const char *prefix : {"catch-fisha-", "catch-fishb-", "junglefish-", "sunkenfisha-"}) {
                    if (StartsWith(name, prefix)) return true;
                }
                return false;
            };
            size_t kept = 0;
            for (const char *source : {"jungle", "sunken"}) {
                kept += AppendMercModels(fish, ReadFr3z(levelPath(source)), isOceanFish);
            }
            if (kept == 0) throw std::runtime_error("no ocean fish models in jungle / sunken");
            KeepTexturesOutOfPool(fish);
            WriteFr3z(fish, levelPath("ios-fish"));
        }
        {
            tfrag3::Level coast = ReadFr3z(coastTemplatePath);
            tfrag3::Level jungle = ReadFr3z(levelPath("jungle"));
            FillCoastFromJungle(coast, jungle);
            // not in the texture pool: the jungle registers the originals when it loads
            KeepTexturesOutOfPool(coast);
            WriteFr3z(coast, levelPath("ios-coast"));
        }
        try {
            // The citadel's eco vent ring (cit-ecovent.mb), cut around the vent actor ecovent-248 so the vent's
            // position is the local origin. Not fatal: without it the extra vents show only their eco stream.
            tfrag3::Level citadel = ReadFr3z(levelPath("citadel"));
            tfrag3::Level vents;
            vents.level_name = "ios-vents";
            const TieAnchor ecovent248 {2951.6157f * 4096, -8.6212f * 4096, -4665.8765f * 4096};
            AppendTieProtoAsTfrag(vents, citadel, "cit-ecovent.mb", &ecovent248);
            KeepTexturesOutOfPool(vents);
            WriteFr3z(vents, levelPath("ios-vents"));
        } catch (const std::exception &exception) {
            fprintf(stderr, "jakIOS: ios-vents not built: %s\n", exception.what());
        }
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    }
    return false;
}

}  // namespace jak1
