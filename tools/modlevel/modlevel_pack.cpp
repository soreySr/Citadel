// Packs an OpenGOAL custom level's glb for the app: takes the game's data out and writes the recipe the import
// uses to put it back from the player's disc (jakIOS/Import/Jak1ModLevelRecipe.h).
//
//   * Images that are disc textures (same pixels, possibly a renamed copy, or with whole channels painted a
//     constant) become 1x1 placeholders; the recipe names the disc texture.
//   * Meshes cut from the game's levels (merc models, TIE / tfrag pieces) are found by rotation-invariant edge-pair
//     signatures against every extracted level, then fitted piece by piece with rigid transforms. Each vertex that
//     lands on a game vertex gets its position / uv / color / normal zeroed and a source reference in the recipe;
//     vertices the author moved keep their data. Invisible ripped meshes are zeroed outright.
//   * Then the stripped glb is loaded again, the recipe applied (the import's own code) and compared with the
//     original, so a pack that doesn't reproduce the mod's data fails here instead of on the phone.
//
// Usage: modlevel_pack --glb <mod.glb> --project <OpenGOAL dir with decompiler/config, goal_src/jak1/build>
//                      --disc <iso_data/jak1> --levels <dir of Jak1Level-*.fr3z>
//                      --out-glb <stripped.glb> --out-recipe <recipe.json>
// Build: sh tools/modlevel/build.sh (needs build-ios-extractor/macos from sh tools/ios_extractor/build.sh macos).
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <random>
#include <set>
#include <unordered_map>
#include <unordered_set>

#include "common/custom_data/Tfrag3Data.h"
#include "common/log/log.h"
#include "common/util/FileUtil.h"
#include "common/util/gltf_util.h"
#include "decompiler/Disasm/OpcodeInfo.h"
#include "decompiler/ObjectFile/ObjectFileDB.h"
#include "decompiler/config.h"
#include "decompiler/data/TextureDB.h"
#include "third-party/json.hpp"
#include "third-party/tiny_gltf/tiny_gltf.h"

#include "Jak1ModLevelRecipe.h"

namespace {

using jak1::ModLevelRecipe;
using jak1::RecipePiece;
using jak1::RecipePrimitive;

// ---------------------------------------------------------------------------------------------------------------
// small vector math

struct V3 {
  double v[3] = {0, 0, 0};
  V3() = default;
  V3(double a, double b, double c) : v{a, b, c} {}
  V3 operator-(const V3& o) const { return {v[0] - o.v[0], v[1] - o.v[1], v[2] - o.v[2]}; }
  V3 operator+(const V3& o) const { return {v[0] + o.v[0], v[1] + o.v[1], v[2] + o.v[2]}; }
  V3 operator*(double s) const { return {v[0] * s, v[1] * s, v[2] * s}; }
  double dot(const V3& o) const { return v[0] * o.v[0] + v[1] * o.v[1] + v[2] * o.v[2]; }
  V3 cross(const V3& o) const {
    return {v[1] * o.v[2] - v[2] * o.v[1], v[2] * o.v[0] - v[0] * o.v[2], v[0] * o.v[1] - v[1] * o.v[0]};
  }
  double norm() const { return std::sqrt(dot(*this)); }
  V3 normalized() const { return *this * (1.0 / norm()); }
};
struct M3 {
  double m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  V3 operator*(const V3& p) const {
    return {m[0][0] * p.v[0] + m[0][1] * p.v[1] + m[0][2] * p.v[2], m[1][0] * p.v[0] + m[1][1] * p.v[1] + m[1][2] * p.v[2],
            m[2][0] * p.v[0] + m[2][1] * p.v[1] + m[2][2] * p.v[2]};
  }
  M3 transposed() const {
    M3 t;
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++) t.m[i][j] = m[j][i];
    return t;
  }
};
// rotation taking frame (a, b, c) of the local points onto the same frame of the game points
M3 frame(const V3& a, const V3& b, const V3& c) {
  V3 e1 = (b - a).normalized();
  V3 t = c - a;
  V3 e2 = (t - e1 * t.dot(e1)).normalized();
  V3 e3 = e1.cross(e2);
  M3 f;
  for (int j = 0; j < 3; j++) {
    f.m[0][j] = e1.v[j];
    f.m[1][j] = e2.v[j];
    f.m[2][j] = e3.v[j];
  }
  return f;
}
M3 mul(const M3& a, const M3& b) {
  M3 r;
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] + a.m[i][2] * b.m[2][j];
  return r;
}
// Horn's closed-form absolute orientation (least squares), largest eigenvector by power iteration.
void fit_rigid(const std::vector<V3>& p, const std::vector<V3>& q, M3* R, V3* T) {
  V3 pc, qc;
  for (size_t i = 0; i < p.size(); i++) {
    pc = pc + p[i];
    qc = qc + q[i];
  }
  pc = pc * (1.0 / p.size());
  qc = qc * (1.0 / q.size());
  double S[3][3] = {};
  for (size_t i = 0; i < p.size(); i++) {
    V3 a = p[i] - pc, b = q[i] - qc;
    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++) S[r][c] += a.v[r] * b.v[c];
  }
  double N[4][4] = {
      {S[0][0] + S[1][1] + S[2][2], S[1][2] - S[2][1], S[2][0] - S[0][2], S[0][1] - S[1][0]},
      {S[1][2] - S[2][1], S[0][0] - S[1][1] - S[2][2], S[0][1] + S[1][0], S[2][0] + S[0][2]},
      {S[2][0] - S[0][2], S[0][1] + S[1][0], -S[0][0] + S[1][1] - S[2][2], S[1][2] + S[2][1]},
      {S[0][1] - S[1][0], S[2][0] + S[0][2], S[1][2] + S[2][1], -S[0][0] - S[1][1] + S[2][2]}};
  double shift = 0;
  for (auto& row : N)
    for (double x : row) shift += std::fabs(x);
  // start from the current rotation's quaternion
  const auto& m = R->m;
  double w = std::sqrt(std::max(0.0, 1 + m[0][0] + m[1][1] + m[2][2])) / 2;
  double qv[4] = {w, 0, 0, 0};
  if (w > 1e-6) {
    qv[1] = (m[2][1] - m[1][2]) / (4 * w);
    qv[2] = (m[0][2] - m[2][0]) / (4 * w);
    qv[3] = (m[1][0] - m[0][1]) / (4 * w);
  } else {
    qv[1] = 1;
  }
  for (int it = 0; it < 500; it++) {
    double nq[4] = {};
    for (int r = 0; r < 4; r++) {
      nq[r] = shift * qv[r];
      for (int c = 0; c < 4; c++) nq[r] += N[r][c] * qv[c];
    }
    double len = std::sqrt(nq[0] * nq[0] + nq[1] * nq[1] + nq[2] * nq[2] + nq[3] * nq[3]);
    for (int r = 0; r < 4; r++) qv[r] = nq[r] / len;
  }
  double a = qv[0], b = qv[1], c = qv[2], d = qv[3];
  M3 out;
  out.m[0][0] = a * a + b * b - c * c - d * d;
  out.m[0][1] = 2 * (b * c - a * d);
  out.m[0][2] = 2 * (b * d + a * c);
  out.m[1][0] = 2 * (b * c + a * d);
  out.m[1][1] = a * a - b * b + c * c - d * d;
  out.m[1][2] = 2 * (c * d - a * b);
  out.m[2][0] = 2 * (b * d - a * c);
  out.m[2][1] = 2 * (c * d + a * b);
  out.m[2][2] = a * a - b * b - c * c + d * d;
  *R = out;
  *T = qc - out * pc;
}

// ---------------------------------------------------------------------------------------------------------------
// geometry signatures

int64_t mm(double v) { return std::llround(v * 1000.0); }
uint64_t cell(int64_t x, int64_t y, int64_t z) {
  return (uint64_t(x & 0x1fffff) << 42) | (uint64_t(y & 0x1fffff) << 21) | uint64_t(z & 0x1fffff);
}
uint64_t cell(const V3& p) { return cell(mm(p.v[0]), mm(p.v[1]), mm(p.v[2])); }

struct Pair {
  uint32_t a, b, c1, c2;
};
// Two triangles sharing an edge: 5 side lengths (bin meters), canonical under the pair's symmetries.
void edge_pairs(const std::vector<V3>& pos, const std::vector<std::array<uint32_t, 3>>& tris, double bin,
                std::vector<std::pair<uint64_t, Pair>>& out) {
  auto q = [&](double m) { return std::min<uint64_t>(4095, (uint64_t)std::llround(m / bin)); };
  std::unordered_map<uint64_t, std::vector<uint32_t>> by_edge;
  for (auto& t : tris)
    for (int e = 0; e < 3; e++) {
      uint32_t a = t[e], b = t[(e + 1) % 3], c = t[(e + 2) % 3];
      by_edge[a < b ? (uint64_t(a) << 32 | b) : (uint64_t(b) << 32 | a)].push_back(c);
    }
  for (auto& [key, opp] : by_edge) {
    if (opp.size() != 2) continue;
    uint32_t a = key >> 32, b = key & 0xffffffff, c1 = opp[0], c2 = opp[1];
    auto d = [&](uint32_t x, uint32_t y) { return (pos[x] - pos[y]).norm(); };
    if (d(a, c1) + d(a, c2) > d(b, c1) + d(b, c2)) std::swap(a, b);
    if (d(a, c1) > d(a, c2)) std::swap(c1, c2);
    uint64_t e = q(d(a, b));
    if (!e) continue;
    out.push_back({e | q(d(a, c1)) << 12 | q(d(b, c1)) << 24 | q(d(a, c2)) << 36 | q(d(b, c2)) << 48, {a, b, c1, c2}});
  }
}

void strips_to_tris(const std::vector<uint32_t>& idx, size_t begin, size_t end, bool strips, uint32_t base,
                    std::vector<std::array<uint32_t, 3>>& tris) {
  if (!strips) {
    for (size_t i = begin; i + 2 < end; i += 3) tris.push_back({idx[i] + base, idx[i + 1] + base, idx[i + 2] + base});
    return;
  }
  size_t run = 0;
  for (size_t i = begin; i < end; i++) {
    if (idx[i] == UINT32_MAX) {
      run = 0;
      continue;
    }
    if (++run >= 3) {
      uint32_t a = idx[i - 2], b = idx[i - 1], c = idx[i];
      if (a != b && b != c && a != c) tris.push_back({a + base, b + base, c + base});
    }
  }
}

// One extracted level's geometry, flattened.
struct GameLevel {
  std::string name;
  struct Ref {
    uint8_t kind;  // 0 tfrag, 1 tie, 2 merc
    uint16_t tree;
    uint32_t index;
  };
  std::vector<V3> pos;
  std::vector<Ref> refs;
  std::vector<std::array<uint32_t, 3>> tris;
  tfrag3::Level level;
};

void load_level(const std::string& path, GameLevel& out) {
  jak1::LoadFr3z(path, out.level);
  out.name = out.level.level_name;
  auto& lvl = out.level;
  int tree = 0;
  for (auto& trees : lvl.tfrag_trees)
    for (auto& t : trees) {
      t.unpack();
      uint32_t base = out.pos.size();
      for (uint32_t i = 0; i < t.unpacked.vertices.size(); i++) {
        auto& v = t.unpacked.vertices[i];
        out.pos.push_back(V3(v.x / 4096.f, v.y / 4096.f, v.z / 4096.f));
        out.refs.push_back({0, (uint16_t)tree, i});
      }
      strips_to_tris(t.unpacked.indices, 0, t.unpacked.indices.size(), t.use_strips, base, out.tris);
      tree++;
    }
  tree = 0;
  for (auto& trees : lvl.tie_trees)
    for (auto& t : trees) {
      t.unpack();
      uint32_t base = out.pos.size();
      for (uint32_t i = 0; i < t.unpacked.vertices.size(); i++) {
        auto& v = t.unpacked.vertices[i];
        out.pos.push_back(V3(v.x / 4096.f, v.y / 4096.f, v.z / 4096.f));
        out.refs.push_back({1, (uint16_t)tree, i});
      }
      strips_to_tris(t.unpacked.indices, 0, t.unpacked.indices.size(), t.use_strips, base, out.tris);
      tree++;
    }
  uint32_t base = out.pos.size();
  auto& m = lvl.merc_data;
  for (uint32_t i = 0; i < m.vertices.size(); i++) {
    auto& v = m.vertices[i];
    out.pos.push_back(V3(v.pos[0] / 4096.f, v.pos[1] / 4096.f, v.pos[2] / 4096.f));
    out.refs.push_back({2, 0, i});
  }
  for (auto& model : m.models)
    for (auto& e : model.effects)
      for (auto& d : e.all_draws) strips_to_tris(m.indices, d.first_index, d.first_index + d.index_count, !d.no_strip, base, out.tris);
}

std::vector<std::string> level_files(const std::string& dir) {
  std::vector<std::string> out;
  for (auto& entry : fs::directory_iterator(dir)) {
    auto name = entry.path().filename().string();
    if (name.rfind("Jak1Level-", 0) == 0 && entry.path().extension() == ".fr3z" &&
        name.find("ios-") == std::string::npos && name != "Jak1Level-test-zone.fr3z") {
      out.push_back(entry.path().string());
    }
  }
  std::sort(out.begin(), out.end());
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// glb access

struct Glb {
  nlohmann::json json;
  tinygltf::Model model;  // buffers[0] is the BIN chunk
};

struct Attr {
  int accessor = -1;
  size_t offset = 0, stride = 0, count = 0;
  int type = 0, comps = 0;
};
Attr attr(const tinygltf::Model& m, int accessor) {
  Attr a;
  if (accessor < 0) return a;
  auto& acc = m.accessors[accessor];
  auto& bv = m.bufferViews[acc.bufferView];
  a.accessor = accessor;
  a.offset = bv.byteOffset + acc.byteOffset;
  a.stride = acc.ByteStride(bv);
  a.count = acc.count;
  a.type = acc.componentType;
  a.comps = tinygltf::GetNumComponentsInType(acc.type);
  return a;
}
float read_comp(const tinygltf::Model& m, const Attr& a, size_t v, int c) {
  const uint8_t* p = m.buffers[0].data.data() + a.offset + v * a.stride;
  switch (a.type) {
    case TINYGLTF_COMPONENT_TYPE_FLOAT: { float f; memcpy(&f, p + 4 * c, 4); return f; }
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT: { uint16_t s; memcpy(&s, p + 2 * c, 2); return s / 65535.f; }
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE: return p[c] / 255.f;
  }
  return NAN;
}
size_t comp_size(int type) {
  return type == TINYGLTF_COMPONENT_TYPE_FLOAT || type == TINYGLTF_COMPONENT_TYPE_UNSIGNED_INT ? 4
         : type == TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT ? 2 : 1;
}
void zero(tinygltf::Model& m, const Attr& a, size_t v) {
  if (a.accessor < 0) return;
  memset(m.buffers[0].data.data() + a.offset + v * a.stride, 0, comp_size(a.type) * a.comps);
}
std::vector<uint32_t> indices(const tinygltf::Model& m, int accessor) {
  auto& acc = m.accessors[accessor];
  auto& bv = m.bufferViews[acc.bufferView];
  const uint8_t* p = m.buffers[bv.buffer].data.data() + bv.byteOffset + acc.byteOffset;
  std::vector<uint32_t> out(acc.count);
  for (size_t i = 0; i < acc.count; i++) {
    if (acc.componentType == TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT) { uint16_t s; memcpy(&s, p + 2 * i, 2); out[i] = s; }
    else if (acc.componentType == TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE) out[i] = p[i];
    else memcpy(&out[i], p + 4 * i, 4);
  }
  return out;
}

bool node_invisible(const tinygltf::Node& node) {
  return node.extras.Has("set_invisible") && node.extras.Get("set_invisible").Get<int>();
}
// excluded from collision too (gltf_mesh_extract's custom_props_to_pat "ignore")
bool node_unused(const tinygltf::Node& node) {
  return node_invisible(node) && node.extras.Has("ignore") && node.extras.Get("ignore").Get<int>();
}

// A 1x1 transparent PNG.
const uint8_t kPlaceholderPng[] = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, 0xe9, 0xfa,
    0xdc, 0xd8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82};

// ---------------------------------------------------------------------------------------------------------------

struct MeshWork {
  int mesh;
  std::string node;
  bool invisible = false;  // never drawn and not collidable
  // welded local positions over all primitives
  std::vector<V3> wpos;
  std::vector<std::array<uint32_t, 3>> wtris;
  std::vector<std::vector<std::pair<int, uint32_t>>> members;  // welded vertex -> (primitive, vertex)
  std::vector<bool> explained;
  // per welded vertex: piece transform id + game candidates
  std::vector<int> transform;
  std::vector<std::vector<GameLevel::Ref>> candidates;
  std::vector<std::string> candidate_level;
};

struct Transform {
  M3 R;  // game = R * local + T
  V3 T;
};

}  // namespace

int main(int argc, char** argv) {
  std::map<std::string, std::string> args;
  for (int i = 1; i + 1 < argc; i += 2) args[argv[i]] = argv[i + 1];
  for (const char* k : {"--glb", "--project", "--disc", "--levels", "--out-glb", "--out-recipe"}) {
    if (!args.count(k)) {
      fprintf(stderr, "missing %s\n", k);
      return 2;
    }
  }
  lg::set_stdout_level(lg::level::warn);

  // Load the glb twice: raw JSON (for rewriting) and tinygltf (pixels, accessors).
  Glb glb;
  {
    auto bytes = file_util::read_binary_file(args["--glb"]);
    uint32_t json_len;
    memcpy(&json_len, bytes.data() + 12, 4);
    glb.json = nlohmann::json::parse(bytes.begin() + 20, bytes.begin() + 20 + json_len);
    tinygltf::TinyGLTF loader;
    std::string err, warn;
    if (!loader.LoadBinaryFromMemory(&glb.model, &err, &warn, bytes.data(), bytes.size())) {
      fprintf(stderr, "glb: %s\n", err.c_str());
      return 1;
    }
    if (glb.model.buffers.size() != 1) {
      fprintf(stderr, "expected one buffer\n");
      return 1;
    }
  }
  auto& model = glb.model;
  ModLevelRecipe recipe;
  std::set<int> placeholder_images;

  // ---- images ------------------------------------------------------------------------------------------------
  {
    using namespace decompiler;
    file_util::setup_project_path(fs::path(args["--project"]), true);
    init_opcode_info();
    Config config = read_config_file(fs::path(args["--project"]) / "decompiler/config/jak1/jak1_config.jsonc",
                                     "ntsc_v1", R"({"decompile_code": false, "find_functions": false})");
    std::vector<fs::path> dgos;
    for (auto& d : config.dgo_names) dgos.push_back(fs::path(args["--disc"]) / d);
    ObjectFileDB db(dgos, fs::path(config.obj_file_name_map_file), {}, {}, {}, {}, config);
    db.process_link_data(config);
    TextureDB tex;
    auto dump = fs::temp_directory_path() / "modlevel-pack-textures";
    file_util::create_dir_if_needed(dump);
    db.process_tpages(tex, dump, config, "");
    fs::remove_all(dump);

    std::set<int> visible_images;
    {
      std::set<int> materials;
      for (auto& node : model.nodes) {
        if (node.mesh < 0 || node_invisible(node)) continue;
        for (auto& prim : model.meshes[node.mesh].primitives) materials.insert(prim.material);
      }
      for (int mi : materials) {
        if (mi < 0) continue;
        auto& mat = model.materials[mi];
        for (int t : {mat.pbrMetallicRoughness.baseColorTexture.index, mat.pbrMetallicRoughness.metallicRoughnessTexture.index}) {
          if (t >= 0) visible_images.insert(model.textures[t].source);
        }
      }
    }
    std::multimap<std::string, uint32_t> by_name;
    std::multimap<std::pair<int, int>, uint32_t> by_size;
    for (auto& [id, t] : tex.textures) {
      if ((id >> 16) == 0x7fff) continue;  // OpenGOAL's own placeholder page (placeholder-white...), not on the disc
      by_name.insert({t.name, id});
      by_size.insert({{t.w, t.h}, id});
    }
    for (size_t i = 0; i < model.images.size(); i++) {
      auto& img = model.images[i];
      if (img.bits != 8 || img.component != 4) {
        fprintf(stderr, "image %zu %s: not 8-bit RGBA\n", i, img.name.c_str());
        return 1;
      }
      // channel c of the glb image equals the disc texture's, or is one constant
      // channel c of the glb image equals a channel of the disc texture (its own, or another: Blender's
      // metallic-roughness images carry the alpha in blue), or is one constant
      auto compare = [&](const TextureDB::TextureData& t, std::array<int, 4>* set, std::array<int, 4>* from) {
        if (t.w != img.width || t.h != img.height) return false;
        std::array<int, 4> s{-1, -1, -1, -1};
        std::array<int, 4> f{0, 1, 2, 3};
        bool derived = false;  // some kept channel actually varies
        for (int c = 0; c < 4; c++) {
          const int constant = img.image[c];
          bool is_constant = true;
          for (size_t p = 0; p < t.rgba_bytes.size() && is_constant; p++) is_constant &= img.image[p * 4 + c] == constant;
          int source = -1;
          for (int k : {c, 0, 1, 2, 3}) {
            bool equal = true;
            for (size_t p = 0; p < t.rgba_bytes.size() && equal; p++) {
              equal &= img.image[p * 4 + c] == int((t.rgba_bytes[p] >> (8 * k)) & 255);
            }
            if (equal) {
              source = k;
              break;
            }
          }
          if (source >= 0 && !(is_constant && source != c)) {
            f[c] = source;
            derived |= !is_constant;
            continue;
          }
          if (!is_constant) return false;
          s[c] = constant;
        }
        if (s[0] >= 0 && s[1] >= 0 && s[2] >= 0 && f[3] == 3) return false;  // nothing of the texture left but alpha
        const bool exact = s == std::array<int, 4>{-1, -1, -1, -1} && f == std::array<int, 4>{0, 1, 2, 3};
        if (!derived && !exact) return false;  // a constant image is no copy of anything (unless all equal)
        *set = s;
        *from = f;
        return true;
      };
      std::array<int, 4> set{};
      std::array<int, 4> from{};
      int found = -1;
      // by name ("name.png" / "name.001" are Blender's copies of "name")
      std::string base_name = img.name;
      for (const char* suffix : {".png", ".001", ".002", ".003"}) {
        if (base_name.size() > strlen(suffix) && base_name.ends_with(suffix)) base_name.resize(base_name.size() - strlen(suffix));
      }
      for (auto [it, end] = by_name.equal_range(base_name); it != end && found < 0; ++it) {
        if (compare(tex.textures.at(it->second), &set, &from)) found = it->second;
      }
      if (found < 0) {  // a renamed copy (same colors; alpha may be a constant)
        for (auto [it, end] = by_size.equal_range({img.width, img.height}); it != end && found < 0; ++it) {
          if (compare(tex.textures.at(it->second), &set, &from) && set[0] < 0 && set[1] < 0 && set[2] < 0 &&
              from == std::array<int, 4>{0, 1, 2, 3}) {
            found = it->second;
          }
        }
      }
      const bool visible = visible_images.count(i);
      if (found >= 0) {
        recipe.images.push_back({(int)i, (uint32_t)found, tex.textures.at(found).name, set, from});
        placeholder_images.insert(i);
        printf("image %3zu %-40s <- disc 0x%08x %s%s\n", i, img.name.c_str(), found,
               tex.textures.at(found).name.c_str(),
               (set == std::array<int, 4>{-1, -1, -1, -1} ? std::string() : fmt::format(" set [{} {} {} {}]", set[0], set[1], set[2], set[3])).c_str());
        if (from != std::array<int, 4>{0, 1, 2, 3}) printf("          from [%d %d %d %d]\n", from[0], from[1], from[2], from[3]);
      } else if (!visible) {
        placeholder_images.insert(i);
        printf("image %3zu %-40s unused by visible meshes -> placeholder\n", i, img.name.c_str());
      } else {
        // Not on the disc: is it close to a disc texture of the same size? Then it is an edit of game art.
        double best = 1e9;
        std::string best_name;
        uint32_t best_id = 0;
        for (auto [it, end] = by_size.equal_range({img.width, img.height}); it != end; ++it) {
          auto& t = tex.textures.at(it->second);
          double diff = 0;
          for (size_t p = 0; p < t.rgba_bytes.size(); p++)
            for (int c = 0; c < 3; c++) diff += std::abs(int(img.image[p * 4 + c]) - int((t.rgba_bytes[p] >> (8 * c)) & 255));
          diff /= t.rgba_bytes.size() * 3.0;
          if (diff < best) {
            best = diff;
            best_name = t.name;
            best_id = it->second;
          }
        }
        std::string same_name;
        for (auto [it, end] = by_name.equal_range(img.name); it != end; ++it) {
          auto& t = tex.textures.at(it->second);
          same_name += fmt::format(" {}x{}", t.w, t.h);
        }
        printf("image %3zu %-40s KEPT (mod's own %dx%d; closest disc texture %s, mean rgb diff %.1f; same name on disc:%s)\n",
               i, img.name.c_str(), img.width, img.height, best_name.c_str(), best, same_name.c_str());
        // --substitute-near-copies 1: an image this close to a disc texture is a re-save of it (the mod's export
        // recompressed / slightly retouched it); use the disc's own texture instead of shipping it.
        bool flat = true;  // one colour everywhere: nobody's art
        for (size_t p = 1; p < img.image.size() / 4 && flat; p++)
          for (int c = 0; c < 4; c++) flat &= img.image[p * 4 + c] == img.image[c];
        double best_alpha = 1e9;
        if (best < 4) {
          auto& t = tex.textures.at(best_id);
          best_alpha = 0;
          for (size_t p = 0; p < t.rgba_bytes.size(); p++)
            best_alpha += std::abs(int(img.image[p * 4 + 3]) - int((t.rgba_bytes[p] >> 24) & 255));
          best_alpha /= t.rgba_bytes.size();
        }
        if (flat) best = 1e9;
        // the alpha may be one constant instead (Blender exports opaque copies)
        bool alpha_constant = true;
        for (size_t p = 1; p < img.image.size() / 4 && alpha_constant; p++) alpha_constant &= img.image[p * 4 + 3] == img.image[3];
        if (best < 4 && (best_alpha < 4 || alpha_constant) && args.count("--substitute-near-copies")) {
          recipe.images.push_back({(int)i, best_id, best_name,
                                   {-1, -1, -1, best_alpha < 4 ? -1 : int(img.image[3])}, {0, 1, 2, 3}});
          placeholder_images.insert(i);
          printf("          -> substituted with disc 0x%08x %s\n", best_id, best_name.c_str());
          continue;
        }
        if (best < 4) {
          fprintf(stderr, "image %zu %s looks like an edit of %s (alpha diff %.1f); handle it before publishing\n", i,
                  img.name.c_str(), best_name.c_str(), best_alpha);
          return 1;
        }
      }
    }
  }

  // ---- candidate meshes: signatures vs all levels (5 mm), against a 2 cm jitter control ----------------------
  auto files = level_files(args["--levels"]);
  std::vector<MeshWork> work;
  {
    std::set<int> seen_mesh;
    for (auto& nwt : gltf_util::flatten_nodes_from_all_scenes(model)) {
      auto& node = model.nodes[nwt.node_idx];
      if (node.mesh < 0 || seen_mesh.count(node.mesh)) continue;
      seen_mesh.insert(node.mesh);
      MeshWork w;
      w.mesh = node.mesh;
      w.node = node.name;
      w.invisible = node_unused(node);
      std::unordered_map<uint64_t, uint32_t> weld;
      auto& mesh = model.meshes[node.mesh];
      for (size_t pi = 0; pi < mesh.primitives.size(); pi++) {
        auto& prim = mesh.primitives[pi];
        auto pa = attr(model, prim.attributes.at("POSITION"));
        std::vector<uint32_t> local(pa.count);
        for (size_t v = 0; v < pa.count; v++) {
          V3 p(read_comp(model, pa, v, 0), read_comp(model, pa, v, 1), read_comp(model, pa, v, 2));
          // weld at 0.01 mm
          uint64_t k = cell(std::llround(p.v[0] * 1e5), std::llround(p.v[1] * 1e5), std::llround(p.v[2] * 1e5));
          auto it = weld.find(k);
          if (it == weld.end()) {
            it = weld.insert({k, (uint32_t)w.wpos.size()}).first;
            w.wpos.push_back(p);
            w.members.emplace_back();
          }
          w.members[it->second].push_back({(int)pi, (uint32_t)v});
          local[v] = it->second;
        }
        if (prim.indices >= 0) {
          auto idx = indices(model, prim.indices);
          for (size_t i = 0; i + 2 < idx.size(); i += 3) w.wtris.push_back({local[idx[i]], local[idx[i + 1]], local[idx[i + 2]]});
        }
      }
      w.explained.assign(w.wpos.size(), false);
      w.transform.assign(w.wpos.size(), -1);
      w.candidates.resize(w.wpos.size());
      w.candidate_level.resize(w.wpos.size());
      work.push_back(std::move(w));
    }

    std::unordered_set<uint64_t> game;
    for (auto& f : files) {
      GameLevel lvl;
      load_level(f, lvl);
      std::vector<std::pair<uint64_t, Pair>> sigs;
      edge_pairs(lvl.pos, lvl.tris, 0.005, sigs);
      for (auto& s : sigs) game.insert(s.first);
    }
    std::mt19937 rng(1);
    std::uniform_real_distribution<double> jitter(-0.02, 0.02);
    std::vector<MeshWork> keep;
    for (auto& w : work) {
      std::vector<std::pair<uint64_t, Pair>> s, c;
      edge_pairs(w.wpos, w.wtris, 0.005, s);
      std::vector<V3> jit = w.wpos;
      for (auto& p : jit) p = p + V3(jitter(rng), jitter(rng), jitter(rng));
      edge_pairs(jit, w.wtris, 0.005, c);
      if (s.empty()) continue;
      size_t hs = 0, hc = 0;
      for (auto& x : s) hs += game.count(x.first);
      for (auto& x : c) hc += game.count(x.first);
      double match = 100.0 * hs / s.size(), control = 100.0 * hc / std::max<size_t>(1, c.size());
      const bool collision_only = !w.invisible && node_invisible(*std::find_if(model.nodes.begin(), model.nodes.end(), [&](auto& n) { return n.mesh == w.mesh; }));
      if (collision_only && w.wpos.size() <= 64) continue;  // invisible collision boxes: generic shapes, kept as they are
      if (match - control >= 8 && match >= 10) {
        printf("rip candidate %-30s %6zu verts  match %5.1f%%  control %5.1f%%%s\n", w.node.c_str(), w.wpos.size(), match,
               control, w.invisible ? "  (invisible)" : "");
        keep.push_back(std::move(w));
      }
    }
    work = std::move(keep);
  }

  // ---- piecewise rigid fit, one level at a time --------------------------------------------------------------
  std::vector<Transform> transforms;
  std::vector<std::string> transform_level;
  for (auto& f : files) {
    bool any = false;
    for (auto& w : work) any |= !w.invisible && std::count(w.explained.begin(), w.explained.end(), false) > 0;
    if (!any) break;
    GameLevel lvl;
    load_level(f, lvl);
    std::unordered_multimap<uint64_t, uint32_t> by_pos;
    by_pos.reserve(lvl.pos.size());
    for (uint32_t i = 0; i < lvl.pos.size(); i++) by_pos.insert({cell(lvl.pos[i]), i});
    std::vector<std::pair<uint64_t, Pair>> pairs;
    edge_pairs(lvl.pos, lvl.tris, 0.002, pairs);
    std::unordered_multimap<uint64_t, Pair> gsig;
    gsig.reserve(pairs.size());
    for (auto& [s, p] : pairs) gsig.insert({s, p});
    pairs = {};
    // game vertices within 1 mm of p
    auto near = [&](const V3& p, std::vector<uint32_t>& out) {
      out.clear();
      int64_t x = mm(p.v[0]), y = mm(p.v[1]), z = mm(p.v[2]);
      for (int dx = -1; dx <= 1; dx++)
        for (int dy = -1; dy <= 1; dy++)
          for (int dz = -1; dz <= 1; dz++)
            for (auto [it, end] = by_pos.equal_range(cell(x + dx, y + dy, z + dz)); it != end; ++it)
              if ((lvl.pos[it->second] - p).norm() < 0.001) out.push_back(it->second);
    };

    for (auto& w : work) {
      if (w.invisible) continue;
      for (int piece = 0; piece < 16; piece++) {
        std::vector<std::array<uint32_t, 3>> open;
        for (auto& t : w.wtris)
          if (!w.explained[t[0]] || !w.explained[t[1]] || !w.explained[t[2]]) open.push_back(t);
        std::vector<std::pair<uint64_t, Pair>> mp;
        edge_pairs(w.wpos, open, 0.002, mp);
        std::erase_if(mp, [&](auto& x) { return w.explained[x.second.a] || w.explained[x.second.b] || w.explained[x.second.c1]; });
        std::vector<std::pair<size_t, size_t>> order;  // (game count, index)
        for (size_t i = 0; i < mp.size(); i++) {
          size_t c = gsig.count(mp[i].first);
          if (c) order.push_back({c, i});
        }
        std::sort(order.begin(), order.end());
        size_t best = 0;
        Transform best_t;
        for (size_t k = 0; k < std::min<size_t>(order.size(), 60); k++) {
          if (order[k].first > 4000) break;
          auto& p = mp[order[k].second].second;
          for (auto [it, end] = gsig.equal_range(mp[order[k].second].first); it != end; ++it) {
            auto& g = it->second;
            M3 Fl = frame(w.wpos[p.a], w.wpos[p.b], w.wpos[p.c1]), Fg = frame(lvl.pos[g.a], lvl.pos[g.b], lvl.pos[g.c1]);
            Transform t;
            t.R = mul(Fg.transposed(), Fl);
            t.T = lvl.pos[g.a] - t.R * w.wpos[p.a];
            size_t hit = 0;
            for (size_t v = 0; v < w.wpos.size(); v++)
              if (!w.explained[v] && by_pos.count(cell(t.R * w.wpos[v] + t.T))) hit++;
            if (hit > best) {
              best = hit;
              best_t = t;
            }
          }
        }
        if (best < 8) break;
        // refine on the hits, then assign
        std::vector<uint32_t> found;
        for (int iter = 0; iter < 3; iter++) {
          std::vector<V3> P, Q;
          for (size_t v = 0; v < w.wpos.size(); v++) {
            if (w.explained[v]) continue;
            near(best_t.R * w.wpos[v] + best_t.T, found);
            if (!found.empty()) {
              P.push_back(w.wpos[v]);
              Q.push_back(lvl.pos[found[0]]);
            }
          }
          if (P.size() >= 3) fit_rigid(P, Q, &best_t.R, &best_t.T);
        }
        // exact transforms stay exact (merc models placed in their own space)
        bool identity = true;
        for (int i = 0; i < 3; i++)
          for (int j = 0; j < 3; j++) identity &= std::fabs(best_t.R.m[i][j] - (i == j)) < 1e-6;
        if (identity) best_t.R = M3();
        for (double& x : best_t.T.v)
          if (std::fabs(x) < 1e-6) x = 0;
        int ti = transforms.size();
        transforms.push_back(best_t);
        transform_level.push_back(f);
        size_t assigned = 0;
        for (size_t v = 0; v < w.wpos.size(); v++) {
          if (w.explained[v]) continue;
          near(best_t.R * w.wpos[v] + best_t.T, found);
          if (found.empty()) continue;
          w.explained[v] = true;
          w.transform[v] = ti;
          w.candidate_level[v] = f;
          for (uint32_t g : found) w.candidates[v].push_back(lvl.refs[g]);
          assigned++;
        }
        printf("  %-30s piece in %-10s %5zu verts\n", w.node.c_str(), lvl.name.c_str(), assigned);
        if (assigned < 8) break;
      }
    }
  }

  // ---- per glb vertex: source + flags; zero the data -------------------------------------------------------
  std::map<std::tuple<int, int, int, int>, int> piece_ids;  // (transform, kind, tree, tod) -> recipe piece
  std::map<std::string, std::unique_ptr<GameLevel>> loaded;
  auto level_of = [&](const std::string& f) -> GameLevel& {
    auto& p = loaded[f];
    if (!p) {
      p = std::make_unique<GameLevel>();
      load_level(f, *p);
    }
    return *p;
  };
  const char* kinds[] = {"tfrag", "tie", "merc"};
  size_t kept_vertices = 0, rebuilt_vertices = 0;
  for (auto& w : work) {
    auto& mesh = model.meshes[w.mesh];
    if (w.invisible) {
      // never drawn or collided with: zero everything, the recipe doesn't restore it
      for (auto& prim : mesh.primitives) {
        for (auto& [name, acc] : prim.attributes) {
          auto a = attr(model, acc);
          for (size_t v = 0; v < a.count; v++) zero(model, a, v);
        }
        if (prim.indices >= 0) {
          auto& acc = model.accessors[prim.indices];
          auto& bv = model.bufferViews[acc.bufferView];
          memset(model.buffers[0].data.data() + bv.byteOffset + acc.byteOffset, 0, acc.count * comp_size(acc.componentType));
        }
      }
      printf("%-30s invisible: zeroed\n", w.node.c_str());
      continue;
    }
    std::vector<RecipePrimitive> prims(mesh.primitives.size());
    for (size_t pi = 0; pi < mesh.primitives.size(); pi++) {
      auto count = model.accessors[mesh.primitives[pi].attributes.at("POSITION")].count;
      prims[pi].mesh = w.mesh;
      prims[pi].primitive = pi;
      prims[pi].piece.assign(count, -1);
      prims[pi].source.assign(count, 0);
      prims[pi].flags.assign(count, 0);
    }
    // Source vertex tables, cached per (level, kind, tree, tod)
    std::map<std::tuple<std::string, int, int, int>, std::vector<jak1::SourceVertex>> tables;
    auto table = [&](const std::string& f, int kind, int tree, int tod) -> const std::vector<jak1::SourceVertex>& {
      auto key = std::make_tuple(f, kind, tree, kind == 2 ? 0 : tod);
      auto it = tables.find(key);
      if (it == tables.end()) it = tables.insert({key, jak1::SourceVertices(level_of(f).level, kinds[kind], tree, kind == 2 ? 0 : tod)}).first;
      return it->second;
    };
    for (size_t v = 0; v < w.wpos.size(); v++) {
      for (auto& [pi, vi] : w.members[v]) {
        auto& prim = mesh.primitives[pi];
        auto get = [&](const char* n) { return attr(model, prim.attributes.count(n) ? prim.attributes.at(n) : -1); };
        Attr pa = get("POSITION"), ua = get("TEXCOORD_0"), ca = get("COLOR_0"), na = get("NORMAL");
        if (!w.explained[v]) {
          kept_vertices++;
          continue;
        }
        auto& t = transforms[w.transform[v]];
        M3 r = t.R.transposed();  // local = r * game + t'
        V3 tt = (r * t.T) * -1.0;
        // pick the candidate whose uv (then color, then normal) matches this glb vertex
        int best_score = -1;
        uint32_t best_flags = 0;
        GameLevel::Ref best_ref{};
        int best_tod = 0;
        for (auto& ref : w.candidates[v]) {
          for (int tod = 0; tod < (ref.kind == 2 ? 1 : 8); tod++) {
            auto& src = table(w.candidate_level[v], ref.kind, ref.tree, tod)[ref.index];
            uint32_t flags = jak1::kRecipePosition;
            int score = 0;
            if (ua.accessor >= 0 && std::fabs(read_comp(model, ua, vi, 0) - src.st[0]) < 2e-6 &&
                std::fabs(read_comp(model, ua, vi, 1) - src.st[1]) < 2e-6) {
              flags |= jak1::kRecipeUv;
              score += 4;
            }
            if (ca.accessor >= 0) {
              bool ok = true;
              double tol = ca.type == TINYGLTF_COMPONENT_TYPE_FLOAT ? 1e-6 : ca.type == TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT ? 1.0 / 65535 : 1.0 / 255;
              for (int c = 0; c < 3; c++) ok &= std::fabs(read_comp(model, ca, vi, c) - src.color[c]) <= tol;
              if (ca.comps == 4) ok &= std::fabs(read_comp(model, ca, vi, 3) - 1.f) <= tol;
              if (ok) {
                flags |= jak1::kRecipeColor;
                score += 2;
              }
            }
            if (na.accessor >= 0) {
              V3 n(src.normal[0], src.normal[1], src.normal[2]);
              V3 rn = r * n;
              bool ok = ref.kind == 2;
              for (int c = 0; c < 3 && ok; c++) ok &= std::fabs(read_comp(model, na, vi, c) - rn.v[c]) < 1e-5;
              if (ok) {
                flags |= jak1::kRecipeNormal;
                score += 1;
              } else {
                flags |= jak1::kRecipeNormalRecompute;
              }
            }
            if (score > best_score) {
              best_score = score;
              best_flags = flags;
              best_ref = ref;
              best_tod = tod;
            }
          }
        }
        auto key = std::make_tuple(w.transform[v], (int)best_ref.kind, (int)best_ref.tree, best_ref.kind == 2 ? 0 : best_tod);
        auto it = piece_ids.find(key);
        if (it == piece_ids.end()) {
          RecipePiece piece;
          piece.level = level_of(w.candidate_level[v]).name;
          piece.kind = kinds[best_ref.kind];
          piece.tree = best_ref.tree;
          piece.tod = best_ref.kind == 2 ? 0 : best_tod;
          for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++) piece.r[i * 3 + j] = r.m[i][j];
          for (int i = 0; i < 3; i++) piece.t[i] = tt.v[i];
          it = piece_ids.insert({key, (int)recipe.pieces.size()}).first;
          recipe.pieces.push_back(piece);
        }
        prims[pi].piece[vi] = it->second;
        prims[pi].source[vi] = best_ref.index;
        prims[pi].flags[vi] = best_flags;
        zero(model, pa, vi);
        if (best_flags & jak1::kRecipeUv) zero(model, ua, vi);
        if (best_flags & jak1::kRecipeColor) zero(model, ca, vi);
        if (best_flags & (jak1::kRecipeNormal | jak1::kRecipeNormalRecompute)) zero(model, na, vi);
        rebuilt_vertices++;
      }
    }
    for (auto& p : prims) {
      if (std::any_of(p.piece.begin(), p.piece.end(), [](int x) { return x >= 0; })) recipe.primitives.push_back(std::move(p));
    }
  }
  printf("geometry: %zu vertices rebuilt from the disc, %zu edited vertices kept, %zu pieces\n", rebuilt_vertices,
         kept_vertices, recipe.pieces.size());
  std::map<uint32_t, size_t> flag_counts;
  for (auto& p : recipe.primitives)
    for (size_t i = 0; i < p.piece.size(); i++)
      if (p.piece[i] >= 0) flag_counts[p.flags[i]]++;
  for (auto& [f, c] : flag_counts) printf("  flags %2u: %zu vertices\n", f, c);

  // ---- write the stripped glb --------------------------------------------------------------------------------
  {
    auto& json = glb.json;
    auto& views = json["bufferViews"];
    std::vector<size_t> order(views.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return views[a].value("byteOffset", 0) < views[b].value("byteOffset", 0); });
    std::set<size_t> placeholder_views;
    for (int i : placeholder_images) placeholder_views.insert(json["images"][i]["bufferView"].get<size_t>());
    const auto& bin = model.buffers[0].data;
    std::vector<uint8_t> out;
    size_t last_end = 0;
    for (size_t vi : order) {
      auto& view = views[vi];
      size_t offset = view.value("byteOffset", 0), length = view["byteLength"].get<size_t>();
      if (offset < last_end) {
        fprintf(stderr, "overlapping buffer views\n");
        return 1;
      }
      last_end = offset + length;
      while (out.size() % 4) out.push_back(0);
      view["byteOffset"] = out.size();
      if (placeholder_views.count(vi)) {
        out.insert(out.end(), std::begin(kPlaceholderPng), std::end(kPlaceholderPng));
        view["byteLength"] = sizeof(kPlaceholderPng);
      } else {
        out.insert(out.end(), bin.begin() + offset, bin.begin() + offset + length);
      }
    }
    while (out.size() % 4) out.push_back(0);
    json["buffers"][0]["byteLength"] = out.size();
    std::string text = json.dump();
    while (text.size() % 4) text.push_back(' ');
    std::ofstream file(args["--out-glb"], std::ios::binary);
    auto u32 = [&](uint32_t x) { file.write(reinterpret_cast<const char*>(&x), 4); };
    u32(0x46546C67);
    u32(2);
    u32(12 + 8 + text.size() + 8 + out.size());
    u32(text.size());
    u32(0x4E4F534A);
    file.write(text.data(), text.size());
    u32(out.size());
    u32(0x004E4942);
    file.write(reinterpret_cast<const char*>(out.data()), out.size());
    printf("wrote %s (%zu bytes)\n", args["--out-glb"].c_str(), (size_t)file.tellp());
  }
  {
    std::ofstream file(args["--out-recipe"]);
    file << jak1::SerializeModLevelRecipe(recipe);
  }

  // ---- recomputed normals: remember which ones the mod had facing the other way ------------------------------
  {
    tinygltf::TinyGLTF loader;
    tinygltf::Model original, rebuilt;
    std::string err, warn;
    loader.LoadBinaryFromFile(&original, &err, &warn, args["--glb"]);
    loader.LoadBinaryFromFile(&rebuilt, &err, &warn, args["--out-glb"]);
    jak1::ApplyModLevelGeometry(rebuilt, recipe, args["--levels"]);
    size_t flipped = 0;
    for (auto& p : recipe.primitives) {
      auto& po = original.meshes[p.mesh].primitives[p.primitive];
      auto& pr = rebuilt.meshes[p.mesh].primitives[p.primitive];
      if (!po.attributes.count("NORMAL")) continue;
      auto ao = attr(original, po.attributes.at("NORMAL")), ar = attr(rebuilt, pr.attributes.at("NORMAL"));
      for (size_t v = 0; v < p.piece.size(); v++) {
        if (p.piece[v] < 0 || !(p.flags[v] & jak1::kRecipeNormalRecompute)) continue;
        double dot = 0;
        for (int c = 0; c < 3; c++) dot += read_comp(original, ao, v, c) * read_comp(rebuilt, ar, v, c);
        if (dot < 0) {
          p.flags[v] |= jak1::kRecipeNormalFlip;
          flipped++;
        }
      }
    }
    printf("recomputed normals flipped to the mod's side: %zu\n", flipped);
    std::ofstream file(args["--out-recipe"]);
    file << jak1::SerializeModLevelRecipe(recipe);
  }

  // ---- verify: stripped glb + recipe == original, for every rebuilt vertex ------------------------------------
  {
    tinygltf::TinyGLTF loader;
    tinygltf::Model original, rebuilt;
    std::string err, warn;
    loader.LoadBinaryFromFile(&original, &err, &warn, args["--glb"]);
    loader.LoadBinaryFromFile(&rebuilt, &err, &warn, args["--out-glb"]);
    auto parsed = jak1::ParseModLevelRecipe(file_util::read_text_file(args["--out-recipe"]));
    jak1::ApplyModLevelGeometry(rebuilt, parsed, args["--levels"]);
    double worst[4] = {};
    size_t normal_flips = 0;
    std::map<int, double> piece_worst;
    for (auto& p : parsed.primitives) {
      auto& po = original.meshes[p.mesh].primitives[p.primitive];
      auto& pr = rebuilt.meshes[p.mesh].primitives[p.primitive];
      const char* names[] = {"POSITION", "TEXCOORD_0", "COLOR_0", "NORMAL"};
      uint32_t bits[] = {jak1::kRecipePosition, jak1::kRecipeUv, jak1::kRecipeColor,
                         jak1::kRecipeNormal | jak1::kRecipeNormalRecompute};
      for (int a = 0; a < 4; a++) {
        if (!po.attributes.count(names[a])) continue;
        auto ao = attr(original, po.attributes.at(names[a])), ar = attr(rebuilt, pr.attributes.at(names[a]));
        for (size_t v = 0; v < p.piece.size(); v++) {
          if (p.piece[v] < 0 || !(p.flags[v] & bits[a])) continue;
          if (a == 3 && (p.flags[v] & jak1::kRecipeNormalRecompute)) {
            double dot = 0;
            for (int c = 0; c < 3; c++) dot += read_comp(original, ao, v, c) * read_comp(rebuilt, ar, v, c);
            normal_flips += dot < 0;
            continue;
          }
          for (int c = 0; c < ao.comps; c++) {
            double e = std::fabs(read_comp(original, ao, v, c) - read_comp(rebuilt, ar, v, c));
            worst[a] = std::max<double>(worst[a], e);
            if (a == 0) piece_worst[p.piece[v]] = std::max(piece_worst[p.piece[v]], e);
          }
        }
      }
    }
    printf("verify: worst position %.2e m, uv %.2e, color %.2e, normal %.2e; recomputed normals facing away: %zu\n",
           worst[0], worst[1], worst[2], worst[3], normal_flips);
    for (auto& [piece, e] : piece_worst)
      if (e > 1e-5) printf("  piece %d (%s %s %d): worst position %.2e m\n", piece, parsed.pieces[piece].level.c_str(), parsed.pieces[piece].kind.c_str(), parsed.pieces[piece].tree, e);
    if (worst[0] > 1e-3 || worst[1] > 1e-5 || worst[2] > 2.0 / 255) {
      fprintf(stderr, "verify FAILED\n");
      return 1;
    }
  }
  return 0;
}
