// See Jak1CustomLevelBuilder.h. The model selection, texture/vertex remapping and the flut pad conversion
// are the former desktop tools (tools/boat, tools/fish, tools/flut), now run on the device at import.
#include "Jak1CustomLevelBuilder.h"

#include <compression.h>

#include <algorithm>
#include <array>
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

struct TieTri {
    tfrag3::PreloadedVertex v[3];
    int draw;
};

void EmitTieTrisAsTfrag(tfrag3::Level &out, tfrag3::Level &source, tfrag3::TieTree &tree,
                        const std::vector<TieTri> &tris,
                        const std::function<void(const tfrag3::PreloadedVertex &, float *)> &toLocal);

// adjustLocal (optional) may move each vertex of the cut-out instance, given its draw's texture name and its
// position relative to the local origin (game units).
void AppendTieProtoAsTfrag(tfrag3::Level &out, tfrag3::Level &source, const char *protoName,
                           const TieAnchor *anchor,
                           const std::function<void(const std::string &, float *)> &adjustLocal = nullptr) {
    using Tri = TieTri;
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
        if (adjustLocal) {
            for (auto &t : tris) {
                const s32 texId = tree.static_draws[t.draw].tree_tex_id;
                const std::string &texture = texId >= 0 ? source.textures.at(texId).debug_name : std::string();
                for (auto &v : t.v) {
                    float p[3] = {v.x - origin[0], v.y - origin[1], v.z - origin[2]};
                    adjustLocal(texture, p);
                    v.x = p[0] + origin[0];
                    v.y = p[1] + origin[1];
                    v.z = p[2] + origin[2];
                }
            }
        }
        EmitTieTrisAsTfrag(out, source, tree, tris, [&](const tfrag3::PreloadedVertex &v, float *p) {
            p[0] = v.x - origin[0];
            p[1] = v.y - origin[1];
            p[2] = v.z - origin[2];
        });
        return;
    }
    throw std::runtime_error(std::string(protoName) + " not found in " + source.level_name);
}

// The triangles as one NORMAL tfrag tree (no BVH: always drawn), with the TIE tree's textures and
// time-of-day colors. toLocal gives each vertex's position in the prop's own coordinates (game units).
void EmitTieTrisAsTfrag(tfrag3::Level &out, tfrag3::Level &source, tfrag3::TieTree &tree,
                        const std::vector<TieTri> &tris,
                        const std::function<void(const tfrag3::PreloadedVertex &, float *)> &toLocal) {
    {
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
                float p[3];
                toLocal(v, p);
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
    }
}

// One rod of a TIE prototype that has several leaning instances (the fishing poles in the fisherman's hut,
// vil1-fishingpole.mb, each made of ~15 separate pieces whose bounding boxes overlap), stood upright: local +y runs
// along the rod from its lower end (the origin) to its tip; x and z are across it. Returns the rod's length in
// game units. The rod is the instance of the first piece taller than 2 m; pieces belong to it when their centre
// lies within 0.8 m of its axis (fitted twice: the rod bends, so the first piece's axis drifts towards the tip).
float AppendTieRodAsTfrag(tfrag3::Level &out, tfrag3::Level &source, const char *protoName) {
    struct V3 {
        double x, y, z;
        V3 operator-(const V3 &o) const { return {x - o.x, y - o.y, z - o.z}; }
        V3 operator*(double k) const { return {x * k, y * k, z * k}; }
        double dot(const V3 &o) const { return x * o.x + y * o.y + z * o.z; }
        V3 cross(const V3 &o) const { return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x}; }
        V3 unit() const { return *this * (1.0 / std::sqrt(dot(*this))); }
    };
    // principal axis (power iteration on the covariance), pointing up
    const auto fitAxis = [](const std::vector<V3> &points, V3 *centroid) {
        V3 c {0, 0, 0};
        for (const V3 &q : points) c = {c.x + q.x, c.y + q.y, c.z + q.z};
        c = c * (1.0 / points.size());
        double m[3][3] = {};
        for (const V3 &q : points) {
            const double d[3] = {q.x - c.x, q.y - c.y, q.z - c.z};
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) m[i][j] += d[i] * d[j];
        }
        V3 v {0.3, 1, 0.2};
        for (int it = 0; it < 64; it++) {
            v = V3 {m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z, m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
                    m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z}.unit();
        }
        *centroid = c;
        return v.y < 0 ? v * -1 : v;
    };
    constexpr double kMeter = 4096;
    for (auto &tree : source.tie_trees[0]) {
        const auto proto = std::find(tree.proto_names.begin(), tree.proto_names.end(), protoName);
        if (proto == tree.proto_names.end()) continue;
        const u16 protoIdx = static_cast<u16>(proto - tree.proto_names.begin());
        tree.unpack();
        // triangles of every instance, and pieces = strips connected through shared vertices
        std::vector<u32> parent(tree.unpacked.vertices.size());
        for (u32 i = 0; i < parent.size(); i++) parent[i] = i;
        const std::function<u32(u32)> root = [&](u32 x) { return parent[x] == x ? x : parent[x] = root(parent[x]); };
        std::vector<std::pair<TieTri, u32>> tris;  // with one of its vertex indices
        const u32 lastBaseDraw = tree.category_draw_indices[(int)tfrag3::TieCategory::NORMAL_ENVMAP_SECOND_DRAW];
        for (u32 d = 0; d < lastBaseDraw && d < tree.static_draws.size(); d++) {
            const auto &draw = tree.static_draws[d];
            u32 at = draw.unpacked.idx_of_first_idx_in_full_buffer;
            for (const auto &group : draw.vis_groups) {
                if (group.tie_proto_idx == protoIdx) {
                    std::vector<u32> strip;
                    const auto flushStrip = [&]() {
                        for (size_t k = 2; k < strip.size(); k++) {
                            TieTri t;
                            t.draw = static_cast<int>(d);
                            const bool odd = k & 1;
                            t.v[0] = tree.unpacked.vertices[strip[k - 2]];
                            t.v[1] = tree.unpacked.vertices[strip[odd ? k : k - 1]];
                            t.v[2] = tree.unpacked.vertices[strip[odd ? k - 1 : k]];
                            tris.emplace_back(t, strip[k]);
                        }
                        for (size_t k = 1; k < strip.size(); k++) parent[root(strip[k])] = root(strip[0]);
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
        std::map<u32, std::vector<V3>> pieces;  // root -> its triangles' vertices
        for (const auto &[t, idx] : tris) {
            for (const auto &v : t.v) pieces[root(idx)].push_back(V3 {v.x, v.y, v.z});
        }
        const std::vector<V3> *seed = nullptr;
        for (const auto &[r, points] : pieces) {
            double lo = 1e30, hi = -1e30;
            for (const V3 &q : points) {
                lo = std::min(lo, q.y);
                hi = std::max(hi, q.y);
            }
            if (hi - lo > 2 * kMeter) {
                seed = &points;
                break;
            }
        }
        if (seed == nullptr) throw std::runtime_error(std::string(protoName) + " has no rod piece");
        V3 centre;
        V3 axis = fitAxis(*seed, &centre);
        std::map<u32, bool> inRod;
        for (int pass = 0; pass < 2; pass++) {
            std::vector<V3> chosen;
            for (const auto &[r, points] : pieces) {
                V3 m {0, 0, 0};
                for (const V3 &q : points) m = {m.x + q.x, m.y + q.y, m.z + q.z};
                const V3 d = m * (1.0 / points.size()) - centre;
                const V3 across = d - axis * d.dot(axis);
                inRod[r] = across.dot(across) < 0.8 * kMeter * 0.8 * kMeter;
                if (inRod[r]) chosen.insert(chosen.end(), points.begin(), points.end());
            }
            axis = fitAxis(chosen, &centre);
        }
        std::vector<TieTri> rod;
        double tMin = 1e30, tMax = -1e30;
        for (const auto &[t, idx] : tris) {
            if (!inRod[root(idx)]) continue;
            rod.push_back(t);
            for (const auto &v : t.v) {
                const double along = (V3 {v.x, v.y, v.z} - centre).dot(axis);
                tMin = std::min(tMin, along);
                tMax = std::max(tMax, along);
            }
        }
        const V3 base = V3 {centre.x + axis.x * tMin, centre.y + axis.y * tMin, centre.z + axis.z * tMin};
        const V3 across = std::fabs(axis.z) < 0.9 ? axis.cross(V3 {0, 0, 1}).unit() : axis.cross(V3 {1, 0, 0}).unit();
        const V3 third = across.cross(axis);
        EmitTieTrisAsTfrag(out, source, tree, rod, [&](const tfrag3::PreloadedVertex &v, float *p) {
            const V3 d = V3 {v.x, v.y, v.z} - base;
            p[0] = static_cast<float>(d.dot(across));
            p[1] = static_cast<float>(d.dot(axis));
            p[2] = static_cast<float>(d.dot(third));
        });
        fprintf(stderr, "jakIOS: %s rod: %zu of %zu triangles, %.2f m\n", protoName, rod.size(), tris.size(),
                (tMax - tMin) / kMeter);
        return static_cast<float>(tMax - tMin);
    }
    throw std::runtime_error(std::string(protoName) + " not found in " + source.level_name);
}

// --- East coastline rock chunks (coastline-plan.md phase 1) ---
// The Forbidden Jungle and Rock Village build their sea cliffs from the same modular TIE rock kit over a tfrag
// rock core, each skinned with its own textures and time-of-day colors. A chunk is a box of one of those cliffs:
// the kit pieces and the rock / beach tfrag whose centres lie inside it, without trees, vines, huts or anything
// else (bare rock, user 2026-10-21). Survey and box choice: tools/coast/coast_survey.cpp.

// Coast layout tuning, overridable for the offline layout search (tools/coast/README.md).
#ifndef JAKIOS_COAST_SEED
#define JAKIOS_COAST_SEED 0x51c0a57u
#endif
#ifndef JAKIOS_COAST_EAST_SPACING
#define JAKIOS_COAST_EAST_SPACING 0.7f
#endif

// TIE prototypes of the rock kit (both levels use the same names).
bool IsRockKitProto(const std::string &name) {
    static const char *const kRockProtos[] = {
        "wallmed-01.mb", "wallmed-01-squaredoff.mb", "wallmed-02.mb", "wallmed-03.mb", "walllarge-01.mb",
        "walltall-01.mb", "walltall-02.mb", "wallsmall-01.mb", "wallsmall-02.mb", "wallsmall-04.mb",
        "cliffsmall.mb", "cliffmed.mb", "cliffmed-4m.mb", "clifflarge.mb", "groundlarge.mb", "groundsmall.mb",
        "lil-rock-06.mb", "lil-bigrock-02.mb", "boulder-01.mb", "boulder-02.mb", "boulder-03.mb",
        "boulder-04.mb"};
    for (const char *proto : kRockProtos) {
        if (name == proto) return true;
    }
    return false;
}

struct RockChunkSpec {
    const char *name;
    float x0, z0, x1, z1;  // world box (m) the triangles' centres must lie in
    float yMin, yMax;      // and their height range (m)
    float seaX, seaZ;      // direction from the cliff out to the sea (unit, world xz)
    // tfrag textures that are rock (the rest of the tfrag is ground, paths...; the beach's flat sand slabs stuck
    // out at the waterline like blades, so they are left out too)
    const char *tfragTextures[2];
};

// Jungle east face (looking out east, +x) and Rock Village north face (looking out north, +z). Boxes picked
// with tools/coast/coast_survey.cpp (coastline-plan.md phase 0 / 2): pieces that are solid down to the waterline
// (others there have caves / arches that show the open sea behind the coast).
constexpr RockChunkSpec kJungleRockChunks[] = {
    {"jungle-g", 420, -230, 530, -150, -6, 80, 1, 0, {"jng-rockwall-01", nullptr}},
    {"jungle-e", 440, -290, 530, -205, -6, 80, 1, 0, {"jng-rockwall-01", nullptr}},
};
constexpr RockChunkSpec kVillage2RockChunks[] = {
    {"village2-a", 150, -1530, 270, -1420, -6, 80, 0, 1, {"vil2-rockwall", nullptr}},
    // without the floating slabs above 45 m (their supports are outside the box)
    {"village2-b", 270, -1530, 380, -1400, -6, 45, 0, 1, {"vil2-rockwall", nullptr}},
};

// A chunk triangle in world game units, with where its color, draw mode and texture come from.
struct RockTri {
    tfrag3::PreloadedVertex v[3];
    const tfrag3::PackedTimeOfDay *colors;
    DrawMode mode;
    s32 texture;  // source level texture index (or negative: anim slot)
};

// Triangles of an index range: strips with UINT32_MAX restarts (alternate ones flipped so all keep the same
// winding), or a plain list.
template <typename F>
void ForEachIndexedTri(const std::vector<u32> &indices, size_t begin, size_t end, bool strips, F &&emit) {
    if (!strips) {
        for (size_t i = begin; i + 2 < end; i += 3) emit(indices[i], indices[i + 1], indices[i + 2]);
        return;
    }
    size_t run = 0;
    for (size_t i = begin; i < end; i++) {
        if (indices[i] == UINT32_MAX) {
            run = 0;
            continue;
        }
        if (++run < 3) continue;
        if (run & 1) {
            emit(indices[i - 2], indices[i - 1], indices[i]);
        } else {
            emit(indices[i - 2], indices[i], indices[i - 1]);
        }
    }
}

std::vector<RockTri> CollectRockChunk(tfrag3::Level &source, const RockChunkSpec &spec) {
    constexpr float kMeter = 4096.f;
    const auto inside = [&](const tfrag3::PreloadedVertex *v) {
        const float cx = (v[0].x + v[1].x + v[2].x) / (3 * kMeter);
        const float cy = (v[0].y + v[1].y + v[2].y) / (3 * kMeter);
        const float cz = (v[0].z + v[1].z + v[2].z) / (3 * kMeter);
        return cx >= spec.x0 && cx <= spec.x1 && cz >= spec.z0 && cz <= spec.z1 && cy >= spec.yMin &&
            cy <= spec.yMax;
    };
    std::vector<RockTri> tris;
    for (auto &tree : source.tie_trees[0]) {
        std::vector<bool> rockProto(tree.proto_names.size());
        bool any = false;
        for (size_t p = 0; p < tree.proto_names.size(); p++) any |= rockProto[p] = IsRockKitProto(tree.proto_names[p]);
        if (!any) continue;
        if (tree.unpacked.vertices.empty()) tree.unpack();  // several chunks come from one level
        // base draws only (the shiny envmap second pass needs the TIE renderer)
        const u32 lastBaseDraw = tree.category_draw_indices[(int)tfrag3::TieCategory::NORMAL_ENVMAP_SECOND_DRAW];
        // Whole kit pieces only: a piece is in when its centre is (pieces cut in half by the box left sharp
        // shards sticking out of the chunk's sides). A piece = one instance = one BVH visibility index.
        std::map<u16, std::array<double, 4>> centre;  // vis index -> x, y, z sums (game units), count
        const auto forEachRockTri = [&](const std::function<void(u32, const tfrag3::StripDraw &, u16, u32, u32, u32)> &f) {
            for (u32 d = 0; d < lastBaseDraw && d < tree.static_draws.size(); d++) {
                const auto &draw = tree.static_draws[d];
                size_t at = draw.unpacked.idx_of_first_idx_in_full_buffer;
                for (const auto &group : draw.vis_groups) {
                    if (rockProto.at(group.tie_proto_idx)) {
                        ForEachIndexedTri(tree.unpacked.indices, at, at + group.num_inds, true,
                                          [&](u32 a, u32 b, u32 c) { f(d, draw, group.vis_idx_in_pc_bvh, a, b, c); });
                    }
                    at += group.num_inds;
                }
            }
        };
        forEachRockTri([&](u32, const tfrag3::StripDraw &, u16 vis, u32 a, u32 b, u32 c) {
            auto &sum = centre[vis];
            for (u32 i : {a, b, c}) {
                const auto &v = tree.unpacked.vertices[i];
                sum[0] += v.x, sum[1] += v.y, sum[2] += v.z, sum[3] += 1;
            }
        });
        std::map<u16, bool> pieceInside;
        for (const auto &[vis, sum] : centre) {
            const double x = sum[0] / sum[3] / kMeter, y = sum[1] / sum[3] / kMeter, z = sum[2] / sum[3] / kMeter;
            pieceInside[vis] = x >= spec.x0 && x <= spec.x1 && z >= spec.z0 && z <= spec.z1 && y >= spec.yMin &&
                y <= spec.yMax;
        }
        forEachRockTri([&](u32, const tfrag3::StripDraw &draw, u16 vis, u32 a, u32 b, u32 c) {
            if (!pieceInside[vis]) return;
            tris.push_back({{tree.unpacked.vertices[a], tree.unpacked.vertices[b], tree.unpacked.vertices[c]},
                            &tree.colors, draw.mode, draw.tree_tex_id});
        });
    }
    for (auto &tree : source.tfrag_trees[0]) {
        if (tree.kind != tfrag3::TFragmentTreeKind::NORMAL) continue;
        if (tree.unpacked.vertices.empty()) tree.unpack();
        for (size_t d = 0; d < tree.draws.size(); d++) {
            const auto &draw = tree.draws[d];
            if (draw.tree_tex_id < 0 || draw.tree_tex_id >= static_cast<s32>(source.textures.size())) continue;
            const std::string &texture = source.textures[draw.tree_tex_id].debug_name;
            if (texture != spec.tfragTextures[0] && (!spec.tfragTextures[1] || texture != spec.tfragTextures[1])) continue;
            const size_t begin = draw.unpacked.idx_of_first_idx_in_full_buffer;
            const size_t end = d + 1 < tree.draws.size() ? tree.draws[d + 1].unpacked.idx_of_first_idx_in_full_buffer
                                                         : tree.unpacked.indices.size();
            ForEachIndexedTri(tree.unpacked.indices, begin, end, tree.use_strips, [&](u32 a, u32 b, u32 c) {
                RockTri t {{tree.unpacked.vertices[a], tree.unpacked.vertices[b], tree.unpacked.vertices[c]},
                           &tree.colors, draw.mode, draw.tree_tex_id};
                if (inside(t.v)) tris.push_back(t);
            });
        }
    }
    if (tris.empty()) throw std::runtime_error(std::string("rock chunk ") + spec.name + " is empty");
    return tris;
}

// A chunk in its own coordinates (game units): origin at sea level (y 0) below the centre of its footprint,
// local +z = out to the sea, so every chunk faces the same way and the coast layout only needs a yaw.
struct ChunkVertex {
    float p[3];
    float s, t;
    u16 color;  // index into the coast's merged time-of-day palette
};
struct ChunkTri {
    ChunkVertex v[3];
    u32 mode;     // DrawMode bits
    s32 texture;  // texture index in the coast level
};
struct RockChunk {
    const char *name;
    bool village2;
    std::vector<ChunkTri> tris;
    float width = 0, depth = 0, height = 0;  // m: along the coast (local x), into the land (local z), top
};

// Shared output state while the coast is built: textures copied once per source texture, colors once per
// (source palette, color), draw modes by their bits.
struct CoastOutput {
    tfrag3::Level level;
    std::map<std::pair<const tfrag3::Level *, s32>, s32> textures;
    std::map<std::pair<const tfrag3::PackedTimeOfDay *, u16>, u16> colors;
    std::vector<std::pair<const tfrag3::PackedTimeOfDay *, u16>> colorSources;
    std::map<u32, DrawMode> modes;
};

RockChunk MakeRockChunk(CoastOutput &out, tfrag3::Level &source, const RockChunkSpec &spec, bool village2) {
    const std::vector<RockTri> tris = CollectRockChunk(source, spec);
    float lo[2] = {1e30f, 1e30f}, hi[2] = {-1e30f, -1e30f};
    for (const auto &t : tris) {
        for (const auto &v : t.v) {
            lo[0] = std::min(lo[0], v.x), hi[0] = std::max(hi[0], v.x);
            lo[1] = std::min(lo[1], v.z), hi[1] = std::max(hi[1], v.z);
        }
    }
    const float cx = (lo[0] + hi[0]) / 2, cz = (lo[1] + hi[1]) / 2;
    // rotation about y taking the sea direction to +z: x' = x*seaZ - z*seaX, z' = x*seaX + z*seaZ
    const float sx = spec.seaX, sz = spec.seaZ;
    RockChunk chunk {spec.name, village2, {}};
    float llo[3] = {1e30f, 1e30f, 1e30f}, lhi[3] = {-1e30f, -1e30f, -1e30f};
    for (const auto &t : tris) {
        ChunkTri c;
        s32 texture = t.texture;
        if (texture >= 0) {
            auto found = out.textures.find({&source, texture});
            if (found == out.textures.end()) {
                found = out.textures.emplace(std::make_pair(&source, texture),
                                             static_cast<s32>(out.level.textures.size())).first;
                out.level.textures.push_back(source.textures.at(texture));
            }
            texture = found->second;
        }
        c.texture = texture;
        c.mode = t.mode.as_int();
        out.modes.emplace(c.mode, t.mode);
        for (int k = 0; k < 3; k++) {
            const auto &v = t.v[k];
            const float wx = v.x - cx, wz = v.z - cz;
            auto &o = c.v[k];
            o.p[0] = wx * sz - wz * sx;
            // the kit's lowest edges stop just above the sea, leaving a slit under the rock through which the
            // water behind showed: everything within 1.5 m of the sea is pulled 5 m down into it
            o.p[1] = v.y < 1.5f * 4096 ? v.y - 5.f * 4096 : v.y;
            o.p[2] = wx * sx + wz * sz;
            o.s = v.s;
            o.t = v.t;
            const auto key = std::make_pair(t.colors, v.color_index);
            auto col = out.colors.find(key);
            if (col == out.colors.end()) {
                if (out.colors.size() >= UINT16_MAX) throw std::runtime_error("the coast has too many colors");
                col = out.colors.emplace(key, static_cast<u16>(out.colorSources.size())).first;
                out.colorSources.push_back(key);
            }
            o.color = col->second;
            for (int a = 0; a < 3; a++) llo[a] = std::min(llo[a], o.p[a]), lhi[a] = std::max(lhi[a], o.p[a]);
        }
        chunk.tris.push_back(c);
    }
    chunk.width = (lhi[0] - llo[0]) / 4096;
    chunk.depth = (lhi[2] - llo[2]) / 4096;
    chunk.height = lhi[1] / 4096;
    return chunk;
}

// Drops the triangles that can't be seen from the sea in front of the chunk: its back, its insides, faces buried
// under other kit pieces. The chunk is rendered (depth + triangle id, no textures) from a fan of viewpoints on
// its sea side, near and far, low and raised; a triangle stays if it covers a visible pixel in any view, or if
// its centre passes the depth test (small triangles that cover no pixel centre). The kept set does not change
// with the layout's yaw jitter, scale or mirroring.
void CullHiddenTris(RockChunk &chunk) {
    constexpr int kW = 480, kH = 300;
    const size_t n = chunk.tris.size();
    std::vector<uint8_t> seen(n, 0);
    std::vector<float> depth(kW * kH);
    std::vector<int32_t> id(kW * kH);
    const float meter = 4096.f;
    const float target[3] = {0, std::max(8.f, chunk.height * 0.4f) * meter, 0};
    const float halfWidth = std::max(chunk.width, chunk.depth) * 0.5f;
    std::vector<std::array<float, 3>> eyes;
    for (float radius : {halfWidth + 25.f, halfWidth + 90.f, halfWidth + 300.f}) {
        for (float height : {3.f, 25.f}) {
            for (int a = -80; a <= 80; a += 16) {
                const float r = a * float(M_PI) / 180;
                eyes.push_back({std::sin(r) * radius * meter, height * meter, std::cos(r) * radius * meter});
            }
        }
    }
    for (const auto &eye : eyes) {
        // camera basis looking at the target
        float f[3] = {target[0] - eye[0], target[1] - eye[1], target[2] - eye[2]};
        const float fl = std::sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
        for (float &c : f) c /= fl;
        float r[3] = {f[2], 0, -f[0]};  // forward x up (sign irrelevant for visibility)
        const float rl = std::sqrt(r[0] * r[0] + r[2] * r[2]);
        r[0] /= rl, r[2] /= rl;
        const float u[3] = {r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]};
        const float focal = kW * 0.5f / std::tan(55.f * float(M_PI) / 180);  // 110 degrees across
        std::fill(depth.begin(), depth.end(), 1e30f);
        std::fill(id.begin(), id.end(), -1);
        struct S {
            float x, y, z;
        };
        std::vector<std::array<S, 3>> projected(n);
        std::vector<uint8_t> valid(n, 0);
        for (size_t i = 0; i < n; i++) {
            bool ok = true;
            for (int k = 0; k < 3; k++) {
                const float *p = chunk.tris[i].v[k].p;
                const float d[3] = {p[0] - eye[0], p[1] - eye[1], p[2] - eye[2]};
                const float z = d[0] * f[0] + d[1] * f[1] + d[2] * f[2];
                if (z < meter) {
                    ok = false;  // the views stand well clear of the chunk; nothing worth clipping
                    break;
                }
                projected[i][k] = {kW * 0.5f + (d[0] * r[0] + d[1] * r[1] + d[2] * r[2]) / z * focal,
                                   kH * 0.5f - (d[0] * u[0] + d[1] * u[1] + d[2] * u[2]) / z * focal, z};
            }
            if (!ok) continue;
            valid[i] = 1;
            const auto &s = projected[i];
            const float area = (s[1].x - s[0].x) * (s[2].y - s[0].y) - (s[2].x - s[0].x) * (s[1].y - s[0].y);
            if (std::fabs(area) < 1e-8f) continue;
            const int x0 = std::max(0, (int)std::floor(std::min({s[0].x, s[1].x, s[2].x})));
            const int x1 = std::min(kW - 1, (int)std::ceil(std::max({s[0].x, s[1].x, s[2].x})));
            const int y0 = std::max(0, (int)std::floor(std::min({s[0].y, s[1].y, s[2].y})));
            const int y1 = std::min(kH - 1, (int)std::ceil(std::max({s[0].y, s[1].y, s[2].y})));
            for (int y = y0; y <= y1; y++) {
                for (int x = x0; x <= x1; x++) {
                    const float px = x + 0.5f, py = y + 0.5f;
                    const float w0 = ((s[1].x - px) * (s[2].y - py) - (s[2].x - px) * (s[1].y - py)) / area;
                    const float w1 = ((s[2].x - px) * (s[0].y - py) - (s[0].x - px) * (s[2].y - py)) / area;
                    const float w2 = 1 - w0 - w1;
                    if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                    const float iz = w0 / s[0].z + w1 / s[1].z + w2 / s[2].z;
                    const float z = 1 / iz;
                    if (z < depth[y * kW + x]) {
                        depth[y * kW + x] = z;
                        id[y * kW + x] = static_cast<int32_t>(i);
                    }
                }
            }
        }
        for (int32_t i : id) {
            if (i >= 0) seen[i] = 1;
        }
        // centre test for triangles too small to own a pixel
        for (size_t i = 0; i < n; i++) {
            if (seen[i] || !valid[i]) continue;
            const auto &s = projected[i];
            const float cx = (s[0].x + s[1].x + s[2].x) / 3, cy = (s[0].y + s[1].y + s[2].y) / 3;
            const int x = (int)cx, y = (int)cy;
            if (x < 0 || y < 0 || x >= kW || y >= kH) continue;
            const float cz = (s[0].z + s[1].z + s[2].z) / 3;
            if (cz <= depth[y * kW + x] * 1.01f) seen[i] = 1;
        }
    }
    std::vector<ChunkTri> kept;
    for (size_t i = 0; i < n; i++) {
        if (seen[i]) kept.push_back(chunk.tris[i]);
    }
    fprintf(stderr, "jakIOS: coast rock %s: %zu of %zu triangles visible from the sea, %.0f m wide, %.0f deep, %.0f high\n",
            chunk.name, kept.size(), n, chunk.width, chunk.depth, chunk.height);
    chunk.tris = std::move(kept);
}

// One chunk copy on the coast (world metres): sea direction (unit, xz), position of its origin, scale, mirror.
struct CoastPlacement {
    int chunk;
    float x, z;
    float seaX, seaZ;
    float scale;
    bool mirror;
};

// The new east coastline: rows of chunks along the old stand-in coast (x 288..477, z -360..-1160) and on through
// the empty stretch to Rock Village (z -1420). Each row is a polyline of its sea-facing edge with the direction
// of the sea; chunks are set along it with their sea face on the line, overlapping their neighbours so the open
// cut sides stay hidden. Rock type follows the nearer level (user 2026-10-21): jungle rock north of z -1220,
// Rock Village rock south of -1320, mixed in between. Deterministic (fixed seed), so every import gets the same.
std::vector<CoastPlacement> LayOutCoast(const std::vector<RockChunk> &chunks) {
    struct Row {
        std::vector<std::array<float, 2>> line;  // x, z (m)
        float seaX, seaZ;                        // for straight rows; diagonal segments use their own normal
        float scaleMin, scaleMax;
        float spacing;  // fraction of a chunk's width between neighbours
    };
    const std::vector<Row> rows = {
        // east face, out to the open sea: one straight line, flush with the jungle's own sea cliffs (x ~520) and
        // running on to Rock Village's north-east corner (user 2026-10-21: "a straight line of rock")
        {{{508, -360}, {508, -1415}}, 1, 0, 0.95f, 1.25f, JAKIOS_COAST_EAST_SPACING},
        // a second row ~30 m behind it: the kit pieces are pillars with caves and gaps between them, and through
        // them the open sea showed; one row packed tight enough to close them cost as much as two (2026-10-21
        // offline check, coastline-plan.md). Collision does not depend on it: the land behind the first face is
        // solid (WriteCoastHeights), so the holes are invisible walls.
        {{{478, -400}, {478, -1395}}, 1, 0, 1.0f, 1.15f, 1.05f},
        // across the south end, facing Rock Village: the hollow between the rows showed through from the Fire
        // Canyon channel, and a narrow channel was left open to the east under an arch (user 2026-10-21,
        // IMG_2606); set into Rock Village's own north rocks (its bay and dock open to the east stay clear)
        {{{215, -1428}, {500, -1436}}, 0, -1, 0.9f, 1.05f, 0.7f},
        // the east face's last stretch down to Rock Village's north-east rocks: from the bay in front of Rock Village
        // a gap between them looked through to the open sea behind (user 2026-10-22); Rock Village's bay mouth and
        // dock further south stay open
        {{{512, -1415}, {512, -1495}}, 1, 0, 0.9f, 1.05f, 0.6f},
        // low rock along the jungle's own east shore: its cliffs there have caves under the grass that you could
        // see (and sail) under (user 2026-10-21, IMG_2607 / IMG_2608); low enough to leave the hills above visible
        {{{530, -40}, {530, -375}}, 1, 0, 0.55f, 0.7f, 0.95f},
        // west face, toward Fire Canyon's channel
        {{{392, -392}, {300, -480}, {300, -1200}, {205, -1395}}, -1, 0, 0.95f, 1.2f, 0.72f},
        // (a ridge row between the two faces added little to the skyline for ~60k triangles: left out)
    };
    uint32_t seed = JAKIOS_COAST_SEED;
    const auto random = [&]() {
        seed = seed * 1664525u + 1013904223u;
        return (seed >> 8) / float(1 << 24);
    };
    std::vector<int> pools[2];  // chunks by level: [village2]
    for (int i = 0; i < (int)chunks.size(); i++) pools[chunks[i].village2].push_back(i);
    std::vector<CoastPlacement> out;
    for (const Row &row : rows) {
        for (size_t seg = 0; seg + 1 < row.line.size(); seg++) {
            const float ax = row.line[seg][0], az = row.line[seg][1];
            const float bx = row.line[seg + 1][0], bz = row.line[seg + 1][1];
            const float len = std::hypot(bx - ax, bz - az);
            const float tx = (bx - ax) / len, tz = (bz - az) / len;
            // sea normal: perpendicular to the segment, on the row's sea side
            float nx = -tz, nz = tx;
            if (nx * row.seaX + nz * row.seaZ < 0) nx = -nx, nz = -nz;
            float along = seg == 0 ? 0.f : 10.f;
            while (along < len) {
                const float px = ax + tx * along, pz = az + tz * along;
                // rock type by position along the coast
                // jungle rock most of the way; Rock Village's darker rock only for the last stretch before it
                const float mixT = std::clamp((-pz - 1220.f) / 100.f, 0.f, 1.f);
                const bool useVillage2 = random() < mixT;
                const std::vector<int> &pool = pools[useVillage2];
                int c = pool[std::min(pool.size() - 1, static_cast<size_t>(random() * pool.size()))];
                const RockChunk &chunk = chunks[c];
                const float scale = row.scaleMin + (row.scaleMax - row.scaleMin) * random();
                // yaw jitter of up to 6 degrees off the row's normal (keeps the face straight)
                const float jitter = (random() * 2 - 1) * 6.f * float(M_PI) / 180;
                const float sx = nx * std::cos(jitter) - nz * std::sin(jitter);
                const float sz = nx * std::sin(jitter) + nz * std::cos(jitter);
                // sea face on the line (+-3 m), the body behind it
                const float inset = chunk.depth * scale * 0.38f + (random() * 2 - 1) * 3.f;
                out.push_back({c, px - nx * inset, pz - nz * inset, sx, sz, scale, random() < 0.5f});
                along += chunk.width * scale * row.spacing;
            }
        }
    }
    // by z, so each emitted tree covers one stretch of the coast
    std::stable_sort(out.begin(), out.end(), [](const CoastPlacement &a, const CoastPlacement &b) { return a.z > b.z; });
    return out;
}

// A chunk vertex (local game units) in the world: scale, mirror across local x, then local +z -> the sea direction.
void PlaceVertex(const CoastPlacement &place, const float *local, float *world) {
    const float lx = local[0] * place.scale * (place.mirror ? -1.f : 1.f);
    const float lz = local[2] * place.scale;
    world[0] = lx * place.seaZ + lz * place.seaX + place.x * 4096;
    world[1] = local[1] * place.scale;
    world[2] = -lx * place.seaX + lz * place.seaZ + place.z * 4096;
}

// All placed chunks as tfrag trees in world coordinates (game units), one tree per ~150k vertices so the packed
// cluster offsets stay within range; identical vertices of one copy are shared. Each copy is its own visibility
// group with a bounding sphere in the tree's BVH, so the renderer's frustum test (drawStripTree) skips the copies
// that are off screen (coastline-plan.md phase 6).
void EmitCoast(CoastOutput &out, const std::vector<RockChunk> &chunks, const std::vector<CoastPlacement> &layout) {
    constexpr float kClusterSize = 4096 * 40;
    constexpr float kMasterOffset = 12000 * 4096;
    constexpr float rescale = kClusterSize / UINT16_MAX;
    tfrag3::PackedTimeOfDay tod;
    tod.color_count = static_cast<u32>((out.colorSources.size() + 3) / 4 * 4);
    tod.data.assign(tod.color_count / 4 * 4 * 4 * 8, 0);
    for (size_t i = 0; i < out.colorSources.size(); i++) {
        const auto &[palette, index] = out.colorSources[i];
        for (int pal = 0; pal < 8; pal++) {
            for (int ch = 0; ch < 4; ch++) tod.read(static_cast<int>(i), pal, ch) = palette->read(index, pal, ch);
        }
    }
    size_t totalTris = 0, totalVerts = 0;
    size_t next = 0;
    while (next < layout.size()) {
        tfrag3::TfragTree tree;
        tree.kind = tfrag3::TFragmentTreeKind::NORMAL;
        tree.use_strips = false;
        tree.colors = tod;
        std::map<std::tuple<u16, u16, u16>, u16> clusters;
        // per draw: (visibility node, indices) runs, one per copy
        std::map<std::pair<u32, s32>, std::vector<std::pair<u16, std::vector<u32>>>> indicesOfDraw;
        for (; next < layout.size() && tree.packed_vertices.vertices.size() < 150000; next++) {
            const CoastPlacement &place = layout[next];
            const RockChunk &chunk = chunks[place.chunk];
            const u16 node = static_cast<u16>(tree.bvh.vis_nodes.size());
            float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
            std::map<std::tuple<u16, u16, u16, u16, s16, s16, u16>, u32> shared;
            for (const ChunkTri &t : chunk.tris) {
                auto &runs = indicesOfDraw[{t.mode, t.texture}];
                if (runs.empty() || runs.back().first != node) runs.push_back({node, {}});
                auto &indices = runs.back().second;
                u32 tri[3];
                for (int k = 0; k < 3; k++) {
                    const ChunkVertex &v = t.v[k];
                    float p[3];
                    PlaceVertex(place, v.p, p);
                    for (int a = 0; a < 3; a++) lo[a] = std::min(lo[a], p[a]), hi[a] = std::max(hi[a], p[a]);
                    u16 c[3], off[3];
                    for (int a = 0; a < 3; a++) {
                        c[a] = static_cast<u16>(std::floor((p[a] + kMasterOffset) / kClusterSize));
                        const float o = -kMasterOffset + kClusterSize * c[a];
                        off[a] = static_cast<u16>(std::clamp(std::lround((p[a] - o) / rescale), 0L, 65535L));
                    }
                    const auto ckey = std::make_tuple(c[0], c[1], c[2]);
                    auto cl = clusters.find(ckey);
                    if (cl == clusters.end()) {
                        cl = clusters.emplace(ckey, static_cast<u16>(tree.packed_vertices.cluster_origins.size())).first;
                        tree.packed_vertices.cluster_origins.push_back({c[0], c[1], c[2]});
                    }
                    tfrag3::PackedTfragVertices::Vertex pv;
                    pv.xoff = off[0];
                    pv.yoff = off[1];
                    pv.zoff = off[2];
                    pv.cluster_idx = cl->second;
                    pv.s = static_cast<s16>(std::clamp(std::lround(v.s * 1024.f), -32768L, 32767L));
                    pv.t = static_cast<s16>(std::clamp(std::lround(v.t * 1024.f), -32768L, 32767L));
                    pv.color_index = v.color;
                    const auto vkey = std::make_tuple(pv.xoff, pv.yoff, pv.zoff, pv.cluster_idx, pv.s, pv.t, pv.color_index);
                    auto found = shared.find(vkey);
                    if (found == shared.end()) {
                        found = shared.emplace(vkey, static_cast<u32>(tree.packed_vertices.vertices.size())).first;
                        tree.packed_vertices.vertices.push_back(pv);
                    }
                    tri[k] = found->second;
                }
                // mirroring flips the winding: swap two corners back
                indices.push_back(tri[0]);
                indices.push_back(place.mirror ? tri[2] : tri[1]);
                indices.push_back(place.mirror ? tri[1] : tri[2]);
            }
            // the copy's bounding sphere (game units), around its box
            tfrag3::VisNode vis;
            const float cx = (lo[0] + hi[0]) / 2, cy = (lo[1] + hi[1]) / 2, cz = (lo[2] + hi[2]) / 2;
            const float r = std::sqrt((hi[0] - cx) * (hi[0] - cx) + (hi[1] - cy) * (hi[1] - cy) + (hi[2] - cz) * (hi[2] - cz));
            vis.bsphere = math::Vector4f(cx, cy, cz, r);
            vis.my_id = node;
            vis.num_kids = 0;
            vis.flags = 0;
            tree.bvh.vis_nodes.push_back(vis);
        }
        tree.bvh.first_leaf_node = 0;
        tree.bvh.last_leaf_node = static_cast<u16>(tree.bvh.vis_nodes.size() - 1);
        tree.bvh.first_root = 0;
        tree.bvh.num_roots = static_cast<u16>(tree.bvh.vis_nodes.size());
        for (const auto &[key, runs] : indicesOfDraw) {
            tfrag3::StripDraw draw;
            draw.mode = out.modes.at(key.first);
            draw.tree_tex_id = key.second;
            for (const auto &[node, indices] : runs) {
                tfrag3::StripDraw::VisGroup group;
                group.num_inds = static_cast<u32>(indices.size());
                group.num_tris = group.num_inds / 3;
                group.vis_idx_in_pc_bvh = node;
                draw.vis_groups.push_back(group);
                draw.plain_indices.insert(draw.plain_indices.end(), indices.begin(), indices.end());
            }
            draw.num_triangles = static_cast<u32>(draw.plain_indices.size()) / 3;
            tree.draws.push_back(draw);
            totalTris += draw.num_triangles;
        }
        totalVerts += tree.packed_vertices.vertices.size();
        // the renderer draws only level of detail 0 (Jak1Background.mm kTfragLod): one copy, not three
        out.level.tfrag_trees[0].push_back(tree);
    }
    size_t texels = 0;
    for (const auto &texture : out.level.textures) texels += texture.data.size();
    fprintf(stderr, "jakIOS: coast: %zu chunk copies, %zu triangles, %zu vertices, %zu trees, %zu colors, "
            "%zu textures (%.1f MB)\n", layout.size(), totalTris, totalVerts, out.level.tfrag_trees[0].size(),
            out.colorSources.size(), out.level.textures.size(), texels * 4 / 1048576.0);
}

// Collision for the coast (coastline-plan.md phase 3): it is drawn natively and has no background collision, so
// the boat's shore probe and Jak (fishermans-boat.gc ios-coast-height) test a height grid of the placed rock
// instead: the highest rock point per 2 m cell, sampled over every triangle at 1 m steps (cliff faces are nearly
// vertical, so their outline matters more than their area). The land between the two rows' faces is solid, so
// nothing can get inside the hollow shell. File: float x0, z0, cell (game units), int32 nx, nz, 12 bytes padding, then nx * nz
// int8 heights (m, -128 = no rock), row by row from z0. The host loads it into GOAL (*ios-coast-grid*).
void WriteCoastHeights(const std::vector<RockChunk> &chunks, const std::vector<CoastPlacement> &layout,
                       const std::vector<const tfrag3::Level *> &groundLevels, const std::string &path) {
    constexpr float kX0 = 140, kZ0 = -1560, kCell = 2;
    constexpr int kNx = 250, kNz = 800;  // x 140..640, z -1560..40 m
    constexpr float kNone = -1e9f;
    std::vector<float> top(kNx * kNz, kNone);
    const auto mark = [&](float x, float y, float z) {
        const int cx = static_cast<int>(std::floor((x / 4096 - kX0) / kCell));
        const int cz = static_cast<int>(std::floor((z / 4096 - kZ0) / kCell));
        if (cx < 0 || cz < 0 || cx >= kNx || cz >= kNz) return;
        float &h = top[cz * kNx + cx];
        h = std::max(h, y / 4096);
    };
    for (const CoastPlacement &place : layout) {
        for (const ChunkTri &t : chunks[place.chunk].tris) {
            float w[3][3];
            for (int k = 0; k < 3; k++) PlaceVertex(place, t.v[k].p, w[k]);
            // rock well under the water (the kit's buried skirts) does not stop anything
            if (std::max({w[0][1], w[1][1], w[2][1]}) < -2.5f * 4096) continue;
            float longest = 0;
            for (int k = 0; k < 3; k++) {
                const float *a = w[k], *b = w[(k + 1) % 3];
                longest = std::max(longest, std::hypot(b[0] - a[0], b[2] - a[2]) / 4096);
            }
            const int n = std::max(1, static_cast<int>(std::ceil(longest)));
            for (int i = 0; i <= n; i++) {
                for (int j = 0; i + j <= n; j++) {
                    const float u = float(i) / n, v = float(j) / n;
                    float p[3];
                    for (int a = 0; a < 3; a++) p[a] = w[0][a] + (w[1][a] - w[0][a]) * u + (w[2][a] - w[0][a]) * v;
                    mark(p[0], p[1], p[2]);
                }
            }
        }
    }
    // Fill the inside: the rock kit is a shell of thin walls with gaps between pieces, so the land between the two
    // rows' faces (LayOutCoast, each face line moved ~8 m in so the edge stays at or behind the visible rock) is
    // solid whatever the pieces leave open.
    const std::vector<std::array<float, 2>> land = {
        {392, -392}, {500, -362}, {500, -1413}, {213, -1393}, {308, -1200}, {308, -480}};
    const auto onLand = [&](float x, float z) {
        bool in = false;
        for (size_t i = 0, j = land.size() - 1; i < land.size(); j = i++) {
            const float xi = land[i][0], zi = land[i][1], xj = land[j][0], zj = land[j][1];
            if ((zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi) in = !in;
        }
        return in;
    };
    // Where a real level has walkable ground (floor collision above the sea: the jungle's east cliffs, Rock
    // Village's north paths), the grid steps aside: that level's own collision handles it, and our rock there would
    // push Jak off ground he can stand on (2026-10-22: 1567 jungle floor triangles were under coast rock).
    std::vector<uint8_t> realGround(kNx * kNz, 0);
    for (const tfrag3::Level *level : groundLevels) {
        const auto &cv = level->collision.vertices;
        for (size_t i = 0; i + 2 < cv.size(); i += 3) {
            const float ax = cv[i + 1].x - cv[i].x, ay = cv[i + 1].y - cv[i].y, az = cv[i + 1].z - cv[i].z;
            const float bx = cv[i + 2].x - cv[i].x, by = cv[i + 2].y - cv[i].y, bz = cv[i + 2].z - cv[i].z;
            const float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
            if (std::fabs(ny) < 0.6f * std::sqrt(nx * nx + ny * ny + nz * nz)) continue;  // walls, not floor
            if ((cv[i].y + cv[i + 1].y + cv[i + 2].y) / 3 < 0.5f * 4096) continue;  // the sea floor / beach edge
            float p[3][2];
            for (int k = 0; k < 3; k++) p[k][0] = cv[i + k].x / 4096, p[k][1] = cv[i + k].z / 4096;
            const int cx0 = std::max(0, static_cast<int>(std::floor((std::min({p[0][0], p[1][0], p[2][0]}) - kX0) / kCell)));
            const int cx1 = std::min(kNx - 1, static_cast<int>(std::floor((std::max({p[0][0], p[1][0], p[2][0]}) - kX0) / kCell)));
            const int cz0 = std::max(0, static_cast<int>(std::floor((std::min({p[0][1], p[1][1], p[2][1]}) - kZ0) / kCell)));
            const int cz1 = std::min(kNz - 1, static_cast<int>(std::floor((std::max({p[0][1], p[1][1], p[2][1]}) - kZ0) / kCell)));
            for (int cz = cz0; cz <= cz1; cz++) {
                for (int cx = cx0; cx <= cx1; cx++) {
                    // the cell's centre inside the triangle (in x z), or the triangle smaller than a cell
                    const float x = kX0 + kCell * (cx + 0.5f), z = kZ0 + kCell * (cz + 0.5f);
                    float d[3];
                    for (int k = 0; k < 3; k++) {
                        const float *a0 = p[k], *a1 = p[(k + 1) % 3];
                        d[k] = (a1[0] - a0[0]) * (z - a0[1]) - (a1[1] - a0[1]) * (x - a0[0]);
                    }
                    const bool in = (d[0] >= 0 && d[1] >= 0 && d[2] >= 0) || (d[0] <= 0 && d[1] <= 0 && d[2] <= 0);
                    if (in || (cx0 == cx1 && cz0 == cz1)) realGround[cz * kNx + cx] = 1;
                }
            }
        }
    }
    constexpr float kInsideHeight = 40;  // m: inside the coast, under its top
    std::vector<int8_t> heights(kNx * kNz);
    size_t rock = 0, inside = 0;
    for (int i = 0; i < kNx * kNz; i++) {
        float h = top[i];
        const float x = kX0 + kCell * (i % kNx + 0.5f), z = kZ0 + kCell * (i / kNx + 0.5f);
        // and a thin wall along the jungle's own east shore, in front of its caves (the low rock row there leaves
        // gaps; the jungle's ground behind it has its own collision and must stay walkable, so only this strip)
        const bool jungleShore = x >= 521 && x <= 528 && z >= -375 && z <= -40;
        if (onLand(x, z) || jungleShore) {
            if (h == kNone) inside++;
            h = std::max(h, kInsideHeight);
        } else if (h != kNone) {
            rock++;
        }
        if (realGround[i]) h = kNone;
        heights[i] = h == kNone ? int8_t(-128) : static_cast<int8_t>(std::clamp(std::lround(h), -127L, 127L));
    }
    struct {
        float x0, z0, cell;
        int32_t nx, nz;
        uint8_t pad[12];
    } header {kX0 * 4096, kZ0 * 4096, kCell * 4096, kNx, kNz, {}};
    static_assert(sizeof(header) == 32);
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    stream.write(reinterpret_cast<const char *>(&header), sizeof(header));
    stream.write(reinterpret_cast<const char *>(heights.data()), static_cast<std::streamsize>(heights.size()));
    if (!stream) throw std::runtime_error("could not write " + path);
    fprintf(stderr, "jakIOS: coast collision: %zu rock cells, %zu inside cells of %d x %d (2 m)\n", rock, inside,
            kNx, kNz);
}

// Sandover's (and the training cliff's) LOWRES background includes a low-detail stand-in of the jungle's land
// and the east coast as seen from far away: a big grass plateau that sits above the new coast's rock and pokes
// out past it (user 2026-10-21: "that layer of green over it"). Its triangles over the coast are moved out of
// the level's lowres trees into a level of their own (Jak1Level-ios-backdrop-<level>.fr3z), which the renderer
// draws in their place only while the coast is hidden, so without the driveable boat the view is unchanged.
// The jungle's own part (z > -340, drawn as the real level when it is loaded) and the Rock Village stand-in
// (z < -1460) stay. Running it again on an already split level finds nothing and leaves the backdrop alone.
void SplitCoastBackdrop(const std::string &levelFile, const std::string &backdropFile, const char *backdropName) {
    tfrag3::Level level = ReadFr3z(levelFile);
    const auto overCoast = [](const tfrag3::PreloadedVertex &a, const tfrag3::PreloadedVertex &b,
                              const tfrag3::PreloadedVertex &c) {
        const float x = (a.x + b.x + c.x) / (3 * 4096.f), z = (a.z + b.z + c.z) / (3 * 4096.f);
        return x > 60 && x < 700 && z < -340 && z > -1460;
    };
    tfrag3::Level backdrop;
    backdrop.level_name = backdropName;
    std::map<s32, s32> texRemap;
    size_t moved = 0;
    for (int geom = 0; geom < tfrag3::TFRAG_GEOS; geom++) {
        for (auto &tree : level.tfrag_trees[geom]) {
            if (tree.kind != tfrag3::TFragmentTreeKind::LOWRES) continue;
            tree.unpack();
            tfrag3::TfragTree removed;
            removed.kind = tree.kind;
            removed.use_strips = false;
            removed.packed_vertices = tree.packed_vertices;
            removed.colors = tree.colors;
            std::vector<tfrag3::StripDraw> keptDraws;
            for (size_t d = 0; d < tree.draws.size(); d++) {
                const auto &draw = tree.draws[d];
                tfrag3::StripDraw kept = draw;
                kept.runs.clear();
                kept.plain_indices.clear();
                kept.vis_groups.clear();
                kept.num_triangles = 0;
                tfrag3::StripDraw gone = kept;
                gone.vis_groups.clear();
                size_t at = draw.unpacked.idx_of_first_idx_in_full_buffer;
                for (const auto &group : draw.vis_groups) {
                    tfrag3::StripDraw::VisGroup keptGroup = group;
                    keptGroup.num_inds = keptGroup.num_tris = 0;
                    ForEachIndexedTri(tree.unpacked.indices, at, at + group.num_inds, tree.use_strips,
                                      [&](u32 a, u32 b, u32 c) {
                        const auto &va = tree.unpacked.vertices[a], &vb = tree.unpacked.vertices[b],
                                   &vc = tree.unpacked.vertices[c];
                        auto &target = overCoast(va, vb, vc) ? gone : kept;
                        target.plain_indices.insert(target.plain_indices.end(), {a, b, c});
                        target.num_triangles++;
                        if (&target == &kept) {
                            keptGroup.num_inds += 3;
                            keptGroup.num_tris++;
                        }
                    });
                    at += group.num_inds;
                    if (keptGroup.num_inds) kept.vis_groups.push_back(keptGroup);
                }
                if (!kept.plain_indices.empty()) keptDraws.push_back(kept);
                if (!gone.plain_indices.empty()) {
                    moved += gone.num_triangles;
                    if (gone.tree_tex_id >= 0) {
                        auto tex = texRemap.find(gone.tree_tex_id);
                        if (tex == texRemap.end()) {
                            tex = texRemap.emplace(gone.tree_tex_id, static_cast<s32>(backdrop.textures.size())).first;
                            backdrop.textures.push_back(level.textures.at(gone.tree_tex_id));
                        }
                        gone.tree_tex_id = tex->second;
                    }
                    tfrag3::StripDraw::VisGroup group;
                    group.num_inds = static_cast<u32>(gone.plain_indices.size());
                    group.num_tris = gone.num_triangles;
                    group.vis_idx_in_pc_bvh = UINT16_MAX;  // always drawn (no BVH)
                    gone.vis_groups.push_back(group);
                    removed.draws.push_back(gone);
                }
            }
            if (removed.draws.empty()) continue;
            tree.draws = std::move(keptDraws);
            tree.use_strips = false;
            tree.unpacked = {};
            backdrop.tfrag_trees[geom].push_back(std::move(removed));
        }
    }
    // Its low-detail tree tops (TIE "v1-lores-trees.mb" etc.) float above the coast's rock just the same: the
    // instances over the coast go into the backdrop too (as tfrag), and are hidden in the level by moving them far
    // under the sea (a zero matrix at y -1e8 m; per instance, so the others are untouched).
    size_t movedTie = 0;
    for (auto &tree : level.tie_trees[0]) {
        std::vector<bool> lores(tree.proto_names.size());
        bool any = false;
        for (size_t p = 0; p < tree.proto_names.size(); p++) {
            any |= lores[p] = tree.proto_names[p].find("lores") != std::string::npos;
        }
        if (!any) continue;
        tree.unpack();
        // instances = matrix groups (unpacked vertices are laid out group after group)
        std::vector<u32> groupOf(tree.unpacked.vertices.size(), 0);
        {
            size_t first = 0;
            for (size_t g = 0; g < tree.packed_vertices.matrix_groups.size(); g++) {
                const auto &grp = tree.packed_vertices.matrix_groups[g];
                for (size_t i = first; i < first + (grp.end_vert - grp.start_vert) && i < groupOf.size(); i++) {
                    groupOf[i] = static_cast<u32>(g);
                }
                first += grp.end_vert - grp.start_vert;
            }
        }
        std::map<u32, std::array<double, 4>> centre;  // matrix group -> x, y, z sums (game units), count
        std::map<u32, std::vector<TieTri>> trisOf;
        for (u32 d = 0; d < tree.static_draws.size(); d++) {
            const auto &draw = tree.static_draws[d];
            size_t at = draw.unpacked.idx_of_first_idx_in_full_buffer;
            for (const auto &group : draw.vis_groups) {
                if (lores.at(group.tie_proto_idx)) {
                    ForEachIndexedTri(tree.unpacked.indices, at, at + group.num_inds, true, [&](u32 a, u32 b, u32 c) {
                        TieTri t;
                        t.v[0] = tree.unpacked.vertices[a];
                        t.v[1] = tree.unpacked.vertices[b];
                        t.v[2] = tree.unpacked.vertices[c];
                        t.draw = static_cast<int>(d);
                        trisOf[groupOf[a]].push_back(t);
                        auto &sum = centre[groupOf[a]];
                        for (const auto &v : t.v) sum[0] += v.x, sum[1] += v.y, sum[2] += v.z, sum[3] += 1;
                    });
                }
                at += group.num_inds;
            }
        }
        std::vector<TieTri> gone;
        std::vector<bool> hideGroup(tree.packed_vertices.matrix_groups.size(), false);
        for (const auto &[g, sum] : centre) {
            const double x = sum[0] / sum[3] / 4096, y = sum[1] / sum[3] / 4096, z = sum[2] / sum[3] / 4096;
            if (!(x > 60 && x < 700 && z < -340 && z > -1460 && y > -1000)) continue;
            for (const auto &t : trisOf[g]) gone.push_back(t);
            hideGroup[g] = true;
        }
        if (gone.empty()) continue;
        for (size_t g = 0; g < hideGroup.size(); g++) {
            if (!hideGroup[g]) continue;
            auto &grp = tree.packed_vertices.matrix_groups[g];
            if (grp.matrix_idx >= 0) {
                std::array<math::Vector4f, 4> sunk {};
                sunk[3] = math::Vector4f(0, -1e8f * 4096, 0, 1);
                grp.matrix_idx = static_cast<s32>(tree.packed_vertices.matrices.size());
                tree.packed_vertices.matrices.push_back(sunk);
            } else {
                for (u32 v = grp.start_vert; v < grp.end_vert; v++) tree.packed_vertices.vertices[v].y = -1e8f * 4096;
            }
        }
        EmitTieTrisAsTfrag(backdrop, level, tree, gone, [](const tfrag3::PreloadedVertex &v, float *p) {
            p[0] = v.x;
            p[1] = v.y;
            p[2] = v.z;
        });
        movedTie += gone.size();
        tree.unpacked = {};
    }
    if (moved == 0 && movedTie == 0) {
        fprintf(stderr, "jakIOS: %s: no lowres coast backdrop (already split)\n", backdropName);
        return;
    }
    KeepTexturesOutOfPool(backdrop);
    WriteFr3z(backdrop, backdropFile);
    WriteFr3z(level, levelFile);
    fprintf(stderr, "jakIOS: %s: moved %zu lowres + %zu lores TIE triangles over the coast out of the level\n",
            backdropName, moved, movedTie);
}

// A plain rock wall behind the west row's sea face, lower than the chunks: the kit pieces leave caves and arches
// that showed the open sea (and the bare ocean edge) through the coast; now they show rock. World
// coordinates (game units), returned as a chunk placed with the identity (see BuildCoastLevel). Deep inside the
// chunks (45 m behind the sea face) and lower than them, so it only shows through their gaps. Textured with the
// level's rockwall at 4 m per repeat (about the kit's own scale), one middle rock color of that level.
RockChunk MakeCoastCurtain(const CoastOutput &out, const std::vector<RockChunk> &chunks) {
    struct Look {
        bool found = false;
        u32 mode = 0;
        s32 texture = -1;
        u16 color = 0;
    };
    Look looks[2];  // [village2]
    for (int v2 = 0; v2 < 2; v2++) {
        const char *name = v2 ? "vil2-rockwall" : "jng-rockwall-01";
        std::vector<std::pair<int, u16>> colors;  // brightness, color
        for (const auto &chunk : chunks) {
            if (chunk.village2 != (v2 == 1)) continue;
            for (const auto &t : chunk.tris) {
                if (t.texture < 0 || out.level.textures.at(t.texture).debug_name != name) continue;
                looks[v2].found = true;
                looks[v2].mode = t.mode;
                looks[v2].texture = t.texture;
                const auto &[palette, index] = out.colorSources.at(t.v[0].color);
                colors.push_back({palette->read(index, 1, 0) + palette->read(index, 1, 1) + palette->read(index, 1, 2),
                                  t.v[0].color});
            }
        }
        if (!colors.empty()) {
            std::sort(colors.begin(), colors.end());
            looks[v2].color = colors[colors.size() * 3 / 5].second;  // a little lighter than the middle
        }
    }
    if (!looks[0].found) throw std::runtime_error("no jungle rockwall for the coast's back wall");
    if (!looks[1].found) looks[1] = looks[0];

    RockChunk curtain {"curtain", false, {}};
    uint32_t seed = 0xc0a57u;
    const auto random = [&]() {
        seed = seed * 1664525u + 1013904223u;
        return (seed >> 8) / float(1 << 24);
    };
    // the west row's sea face (LayOutCoast) moved 45 m inland and on behind the south end's row (the east face
    // has a second row of rock instead)
    const std::vector<std::vector<std::array<float, 2>>> lines = {
        {{420, -420}, {345, -490}, {345, -1190}, {255, -1380}, {470, -1392}},
    };
    // A bumpy wall, not a flat one: a 4 m grid whose points are pushed in and out by up to 3 m, rows up to a
    // ragged 26-34 m top (most chunks stand 45 m and more). UVs run up the wall like the kit's cliff textures
    // (s = height), so the rock grain is vertical, not streaked sideways.
    constexpr float kStep = 4;
    constexpr int kRows = 5;
    for (const auto &line : lines) {
        // the line as points every ~4 m, with its sideways direction there
        struct Column {
            float x, z, nx, nz, along, top;
        };
        std::vector<Column> columns;
        float along = 0;
        for (size_t seg = 0; seg + 1 < line.size(); seg++) {
            const float ax = line[seg][0], az = line[seg][1], bx = line[seg + 1][0], bz = line[seg + 1][1];
            const float len = std::hypot(bx - ax, bz - az);
            const int steps = std::max(1, static_cast<int>(std::ceil(len / kStep)));
            for (int i = seg == 0 ? 0 : 1; i <= steps; i++) {
                const float t = float(i) / steps;
                columns.push_back({ax + (bx - ax) * t, az + (bz - az) * t, -(bz - az) / len, (bx - ax) / len,
                                   along + len * t, 26 + 8 * random()});
            }
            along += len;
        }
        // grid points: row r of column c
        std::vector<std::array<float, 4>> grid(columns.size() * (kRows + 1));  // x, y, z, along
        for (size_t c = 0; c < columns.size(); c++) {
            const Column &col = columns[c];
            for (int r = 0; r <= kRows; r++) {
                const float y = r == kRows ? col.top : -4 + (col.top + 4) * r / kRows;
                const float push = (random() * 2 - 1) * 3;
                grid[c * (kRows + 1) + r] = {col.x + col.nx * push, y, col.z + col.nz * push, col.along};
            }
        }
        for (size_t c = 0; c + 1 < columns.size(); c++) {
            const Look &look = looks[(columns[c].z + columns[c + 1].z) / 2 < -1270 ? 1 : 0];
            const auto vertex = [&](const std::array<float, 4> &g) {
                return ChunkVertex {{g[0] * 4096, g[1] * 4096, g[2] * 4096}, -g[1] / 4, g[3] / 4, look.color};
            };
            for (int r = 0; r < kRows; r++) {
                const ChunkVertex a = vertex(grid[c * (kRows + 1) + r]), b = vertex(grid[(c + 1) * (kRows + 1) + r]);
                const ChunkVertex d = vertex(grid[c * (kRows + 1) + r + 1]);
                const ChunkVertex e = vertex(grid[(c + 1) * (kRows + 1) + r + 1]);
                curtain.tris.push_back({{a, b, d}, look.mode, look.texture});
                curtain.tris.push_back({{d, b, e}, look.mode, look.texture});
            }
        }
    }
    return curtain;
}

}  // namespace

bool BuildCoastLevel(const std::string &fr3Directory, std::string *error) {
    const auto levelPath = [&](const std::string &name) {
        return fr3Directory + "/Jak1Level-" + name + ".fr3z";
    };
    try {
        CoastOutput out;
        out.level.level_name = "ios-coast";
        std::vector<RockChunk> chunks;
        // both levels stay loaded until the coast is written: the chunks' palettes point into them
        tfrag3::Level jungle = ReadFr3z(levelPath("jungle"));
        tfrag3::Level village2 = ReadFr3z(levelPath("village2"));
        for (const auto &spec : kJungleRockChunks) chunks.push_back(MakeRockChunk(out, jungle, spec, false));
        for (const auto &spec : kVillage2RockChunks) chunks.push_back(MakeRockChunk(out, village2, spec, true));
        for (auto &chunk : chunks) CullHiddenTris(chunk);
        std::vector<CoastPlacement> layout = LayOutCoast(chunks);
        // the back wall, already in world coordinates: placed with the identity
#ifndef JAKIOS_COAST_NO_CURTAIN  // the offline layout search measures the holes without it
#ifndef JAKIOS_COAST_NO_CURTAIN  // the offline layout search measures the holes without it
        chunks.push_back(MakeCoastCurtain(out, chunks));
        layout.push_back({static_cast<int>(chunks.size()) - 1, 0, 0, 0, 1, 1, false});
#endif
#endif
        EmitCoast(out, chunks, layout);
        WriteCoastHeights(chunks, layout, {&jungle, &village2}, fr3Directory + "/Jak1Level-ios-coast.heights");
        // not in the texture pool: the source levels register the originals when they load
        KeepTexturesOutOfPool(out.level);
        WriteFr3z(out.level, levelPath("ios-coast"));
        for (const char *name : {"village1", "training"}) {
            SplitCoastBackdrop(levelPath(name), levelPath(std::string("ios-backdrop-") + name),
                               (std::string("ios-backdrop-") + name).c_str());
        }
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    }
    return false;
}

bool BuildCustomLevels(const std::string &fr3Directory, std::string *error) {
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
        try {
            // Fishing: one of the fisherman's hut fishing poles, upright (base at the origin, tip up +y), drawn as
            // the rod in fishing mode. Not fatal: without it fishing mode shows no rod.
            tfrag3::Level rod;
            rod.level_name = "ios-rod";
            AppendTieRodAsTfrag(rod, village1, "vil1-fishingpole.mb");
            KeepTexturesOutOfPool(rod);
            WriteFr3z(rod, levelPath("ios-rod"));
        } catch (const std::exception &exception) {
            fprintf(stderr, "jakIOS: ios-rod not built: %s\n", exception.what());
        }
        village1 = {};
        {
            tfrag3::Level fish;
            fish.level_name = "ios-fish";
            // catch-fisha/b/c (c = the fishing game's poisonous eel, a Fishing species) and junglefish from
            // jungle, the three sunkenfisha colour variants from sunken.
            const auto isOceanFish = [](const std::string &name) {
                for (const char *prefix : {"catch-fisha-", "catch-fishb-", "catch-fishc-", "junglefish-", "sunkenfisha-"}) {
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
            // The east coastline between the Forbidden Jungle and Rock Village (coastline-plan.md). Not fatal:
            // without it that stretch shows open sea.
            std::string coastError;
            if (!BuildCoastLevel(fr3Directory, &coastError)) {
                fprintf(stderr, "jakIOS: ios-coast not built: %s\n", coastError.c_str());
            }
        }
        try {
            // The citadel's eco vent ring (cit-ecovent.mb), cut around the vent actor ecovent-248 so the vent's
            // position is the local origin. Not fatal: without it the extra vents show only their eco stream.
            tfrag3::Level citadel = ReadFr3z(levelPath("citadel"));
            tfrag3::Level vents;
            vents.level_name = "ios-vents";
            const TieAnchor ecovent248 {2951.6157f * 4096, -8.6212f * 4096, -4665.8765f * 4096};
            // The vent's centre (the hole's wall and floor, cmn-precursor-eco-valve-inside, local y -0.26..0.14 m
            // at r <= 1.3 m, and the grate across it, cmn-precursor-ecovalve-grate, y -0.01 m out to r 1.83 m)
            // sits in a hole in the citadel's floor. Our vents stand on solid ground (local y 0), which buried it
            // (user 2026-10-26: "missing the center vent piece"), so it is raised into a shallow dish above the
            // ground: the hole's y -0.26..0.14 m becomes 0.04..0.14 m (the ring's inner lip stays at 0.14), and the
            // grate, which would now poke through the sloping ring beyond the hole, is pulled in to the hole's rim.
            constexpr float kMeter = 4096.f;
            constexpr float kHoleBottom = -0.26f * kMeter, kHoleTop = 0.14f * kMeter, kDishBottom = 0.04f * kMeter;
            constexpr float kHoleRadius = 1.29f * kMeter;
            const auto raiseCentre = [&](const std::string &texture, float *p) {
                const bool inside = texture == "cmn-precursor-eco-valve-inside";
                const bool grate = texture == "cmn-precursor-ecovalve-grate";
                if (!inside && !grate) return;
                p[1] = kDishBottom + (p[1] - kHoleBottom) * (kHoleTop - kDishBottom) / (kHoleTop - kHoleBottom);
                const float r = std::hypot(p[0], p[2]);
                if (grate && r > kHoleRadius) {
                    p[0] *= kHoleRadius / r;
                    p[2] *= kHoleRadius / r;
                }
            };
            AppendTieProtoAsTfrag(vents, citadel, "cit-ecovent.mb", &ecovent248, raiseCentre);
            KeepTexturesOutOfPool(vents);
            WriteFr3z(vents, levelPath("ios-vents"));
        } catch (const std::exception &exception) {
            fprintf(stderr, "jakIOS: ios-vents not built: %s\n", exception.what());
        }
        try {
            // Open Ocean Level: Misty's keg (keg-lod0/1/2, not the conveyor), the drifting barrels, and Sentinel
            // Beach's seagull and lurkerworm. Not fatal: without it kegs, gulls and the serpent are invisible.
            tfrag3::Level ocean;
            ocean.level_name = "ios-ocean";
            if (AppendMercModels(ocean, ReadFr3z(levelPath("misty")),
                                 [](const std::string &name) { return StartsWith(name, "keg-lod"); }) == 0) {
                throw std::runtime_error("no keg model in misty");
            }
            // seagull + lurkerworm (the sea serpent) from the beach
            if (AppendMercModels(ocean, ReadFr3z(levelPath("beach")), [](const std::string &name) {
                    return StartsWith(name, "seagull-lod") || StartsWith(name, "lurkerworm-lod");
                }) == 0) {
                throw std::runtime_error("no seagull / lurkerworm model in beach");
            }
            // the Precursor ruin's pillars and puzzle tiles (dark and lit) from Lost Precursor City
            if (AppendMercModels(ocean, ReadFr3z(levelPath("sunken")), [](const std::string &name) {
                    return StartsWith(name, "square-platform-lod") || StartsWith(name, "qbert-plat-lod") ||
                        StartsWith(name, "qbert-plat-on-lod");
                }) == 0) {
                throw std::runtime_error("no square-platform / qbert-plat model in sunken");
            }
            KeepTexturesOutOfPool(ocean);
            WriteFr3z(ocean, levelPath("ios-ocean"));
        } catch (const std::exception &exception) {
            fprintf(stderr, "jakIOS: ios-ocean not built: %s\n", exception.what());
        }
        return true;
    } catch (const std::exception &exception) {
        if (error) *error = exception.what();
    }
    return false;
}

}  // namespace jak1
