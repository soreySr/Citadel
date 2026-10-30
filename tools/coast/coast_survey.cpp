// Offline survey tool for the east coastline rebuild (coastline-plan.md phase 0): renders extracted levels' background
// geometry (tfrag, optionally TIE) with their own textures and time-of-day colours, from a sea viewpoint or top-down,
// and prints statistics for the triangles inside a box. Used to find the rock chunks to cut from the Forbidden Jungle
// and Rock Village and the gaps between them. Images are binary PPM (convert with `sips -s format png`).
//
// Build (from the repo root, after sh tools/ios_extractor/build.sh macos):
//   clang++ -std=c++20 -O2 -IOpenGOAL -IOpenGOAL/third-party -IOpenGOAL/third-party/fmt/include \
//     tools/coast/coast_survey.cpp build-ios-extractor/macos/libjak1_extractor.a -lcompression -o /tmp/coast_survey
// Usage (metres, degrees; yaw 0 looks along +z, 90 along +x; palette 0-7 = time-of-day slot):
//   coast_survey view out.ppm W H x y z yaw pitch fov palette [+tie] level.fr3z...
//   coast_survey top out.ppm x0 z0 x1 z1 metresPerPixel palette [+tie] level.fr3z...
//   coast_survey region level.fr3z x0 z0 x1 z1 [ymin]
//   coast_survey holes [worst.ppm] level.fr3z...   (see-through check of the coast from the boat route)
#include <compression.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "common/custom_data/Tfrag3Data.h"
#include "common/util/Serializer.h"

namespace {

constexpr float kMeter = 4096.f;

struct Vert {
  float x, y, z, s, t;
  float r, g, b;  // time-of-day colour, 1.0 = neutral (PS2 0x80)
};

struct Tri {
  Vert v[3];
  const tfrag3::Texture* tex;
  bool alphaTest;
  int tree;  // index of the source tree (for stats)
  int draw;
  const std::string* proto = nullptr;  // TIE prototype name (nullptr = tfrag)
  u32 vi[3] = {0, 0, 0};               // TIE vertex indices (instance grouping)
  bool highlight = false;
};

struct LoadedLevel {
  std::string name;
  tfrag3::Level level;
};

bool LoadLevel(const char* path, tfrag3::Level& level) {
  std::ifstream s(path, std::ios::binary);
  if (!s) return false;
  std::vector<uint8_t> f((std::istreambuf_iterator<char>(s)), {});
  if (f.size() < 12) return false;
  uint64_t raw;
  memcpy(&raw, f.data() + 4, 8);
  std::vector<uint8_t> r(raw);
  size_t got = compression_decode_buffer(r.data(), raw, f.data() + 12, f.size() - 12, nullptr, COMPRESSION_LZFSE);
  if (got != raw) return false;
  Serializer ser(r.data(), raw);
  level.serialize(ser);
  return true;
}

// Triangles of a strip / list index stream (UINT32_MAX restarts strips).
template <typename F>
void ForEachTri(const std::vector<u32>& idx, size_t begin, size_t end, bool strips, F&& f) {
  if (!strips) {
    for (size_t i = begin; i + 2 < end; i += 3) f(idx[i], idx[i + 1], idx[i + 2]);
    return;
  }
  size_t run = 0;
  for (size_t i = begin; i < end; i++) {
    if (idx[i] == UINT32_MAX) {
      run = 0;
      continue;
    }
    if (++run >= 3) f(idx[i - 2], idx[i - 1], idx[i]);
  }
}

bool gAllTrees = false;  // +alltrees: also lowres / water trees

void CollectTfrag(tfrag3::Level& level, int palette, std::vector<Tri>& out) {
  int treeNo = 0;
  for (auto& tree : level.tfrag_trees[0]) {
    int t = treeNo++;
    if (!gAllTrees && (tree.kind == tfrag3::TFragmentTreeKind::LOWRES ||
                       tree.kind == tfrag3::TFragmentTreeKind::LOWRES_TRANS ||
                       tree.kind == tfrag3::TFragmentTreeKind::WATER))
      continue;
    tree.unpack();
    auto& verts = tree.unpacked.vertices;
    for (size_t d = 0; d < tree.draws.size(); d++) {
      auto& draw = tree.draws[d];
      size_t begin = draw.unpacked.idx_of_first_idx_in_full_buffer;
      size_t end = d + 1 < tree.draws.size() ? tree.draws[d + 1].unpacked.idx_of_first_idx_in_full_buffer
                                              : tree.unpacked.indices.size();
      const tfrag3::Texture* tex =
          draw.tree_tex_id >= 0 && draw.tree_tex_id < (int)level.textures.size() ? &level.textures[draw.tree_tex_id]
                                                                                 : nullptr;
      bool at = draw.mode.get_at_enable();
      ForEachTri(tree.unpacked.indices, begin, end, tree.use_strips, [&](u32 a, u32 b, u32 c) {
        Tri tri;
        u32 id[3] = {a, b, c};
        for (int k = 0; k < 3; k++) {
          auto& pv = verts[id[k]];
          tri.v[k] = {pv.x / kMeter, pv.y / kMeter, pv.z / kMeter, pv.s, pv.t,
                      tree.colors.read(pv.color_index, palette, 0) / 128.f,
                      tree.colors.read(pv.color_index, palette, 1) / 128.f,
                      tree.colors.read(pv.color_index, palette, 2) / 128.f};
        }
        tri.tex = tex;
        tri.alphaTest = at;
        tri.tree = t;
        tri.draw = (int)d;
        out.push_back(tri);
      });
    }
  }
}

// TIE (instanced props, most of the jungle's sea cliffs): base draws only, with the tree's time-of-day colours.
void CollectTie(tfrag3::Level& level, int palette, std::vector<Tri>& out) {
  int treeNo = 0;
  for (auto& tree : level.tie_trees[0]) {
    int t = treeNo++;
    tree.unpack();
    auto& verts = tree.unpacked.vertices;
    const u32 lastBase = tree.category_draw_indices[(int)tfrag3::TieCategory::NORMAL_ENVMAP_SECOND_DRAW];
    for (u32 d = 0; d < lastBase && d < tree.static_draws.size(); d++) {
      auto& draw = tree.static_draws[d];
      size_t at = draw.unpacked.idx_of_first_idx_in_full_buffer;
      const tfrag3::Texture* tex =
          draw.tree_tex_id >= 0 && draw.tree_tex_id < (int)level.textures.size() ? &level.textures[draw.tree_tex_id]
                                                                                 : nullptr;
      for (auto& group : draw.vis_groups) {
        const std::string* proto = &tree.proto_names.at(group.tie_proto_idx);
        ForEachTri(tree.unpacked.indices, at, at + group.num_inds, true, [&](u32 a, u32 b, u32 c) {
          Tri tri;
          u32 id[3] = {a, b, c};
          for (int k = 0; k < 3; k++) {
            auto& pv = verts[id[k]];
            tri.v[k] = {pv.x / kMeter, pv.y / kMeter, pv.z / kMeter, pv.s, pv.t,
                        tree.colors.read(pv.color_index, palette, 0) / 128.f,
                        tree.colors.read(pv.color_index, palette, 1) / 128.f,
                        tree.colors.read(pv.color_index, palette, 2) / 128.f};
            tri.vi[k] = id[k];
          }
          tri.tex = tex;
          tri.alphaTest = true;
          tri.tree = t;
          tri.draw = (int)d;
          tri.proto = proto;
          out.push_back(tri);
        });
        at += group.num_inds;
      }
    }
  }
}

struct Image {
  int w, h;
  std::vector<float> rgb, depth;
  Image(int w_, int h_) : w(w_), h(h_), rgb(w_ * h_ * 3), depth(w_ * h_, 1e30f) {}
  void Save(const char* path) const {
    FILE* f = fopen(path, "wb");
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    std::vector<uint8_t> b(w * h * 3);
    for (size_t i = 0; i < b.size(); i++) b[i] = (uint8_t)std::clamp(rgb[i] * 255.f, 0.f, 255.f);
    fwrite(b.data(), 1, b.size(), f);
    fclose(f);
  }
};

void Sample(const tfrag3::Texture* tex, float s, float t, float out[4]) {
  if (!tex || tex->w == 0 || tex->data.empty()) {
    out[0] = out[1] = out[2] = 0.6f;
    out[3] = 1.f;
    return;
  }
  int x = (int)std::floor(s * tex->w) % tex->w, y = (int)std::floor(t * tex->h) % tex->h;
  if (x < 0) x += tex->w;
  if (y < 0) y += tex->h;
  u32 p = tex->data[y * tex->w + x];
  out[0] = (p & 0xff) / 255.f;
  out[1] = ((p >> 8) & 0xff) / 255.f;
  out[2] = ((p >> 16) & 0xff) / 255.f;
  out[3] = ((p >> 24) & 0xff) / 255.f;
}

// Screen-space vertex: x, y pixels, z = view depth, iw = 1/depth, attributes pre-divided by depth.
struct SV {
  float x, y, z, iw, a[5];  // a = s, t, r, g, b (times iw)
};

void RasterTri(Image& img, const SV& p0, const SV& p1, const SV& p2, const tfrag3::Texture* tex, bool alphaTest,
               float fogStart, float fogEnd, const float fogCol[3]) {
  float minx = std::max(0.f, std::floor(std::min({p0.x, p1.x, p2.x})));
  float maxx = std::min((float)img.w - 1, std::ceil(std::max({p0.x, p1.x, p2.x})));
  float miny = std::max(0.f, std::floor(std::min({p0.y, p1.y, p2.y})));
  float maxy = std::min((float)img.h - 1, std::ceil(std::max({p0.y, p1.y, p2.y})));
  float area = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y);
  if (std::fabs(area) < 1e-6f) return;
  for (int y = (int)miny; y <= (int)maxy; y++) {
    for (int x = (int)minx; x <= (int)maxx; x++) {
      float px = x + 0.5f, py = y + 0.5f;
      float w0 = ((p1.x - px) * (p2.y - py) - (p2.x - px) * (p1.y - py)) / area;
      float w1 = ((p2.x - px) * (p0.y - py) - (p0.x - px) * (p2.y - py)) / area;
      float w2 = 1.f - w0 - w1;
      if (w0 < 0 || w1 < 0 || w2 < 0) continue;
      float iw = w0 * p0.iw + w1 * p1.iw + w2 * p2.iw;
      float z = 1.f / iw;
      int at = y * img.w + x;
      if (z >= img.depth[at]) continue;
      float a[5];
      for (int k = 0; k < 5; k++) a[k] = (w0 * p0.a[k] + w1 * p1.a[k] + w2 * p2.a[k]) * z;
      float c[4];
      Sample(tex, a[0], a[1], c);
      if (alphaTest && c[3] < 0.25f) continue;
      img.depth[at] = z;
      float fog = std::clamp((z - fogStart) / (fogEnd - fogStart), 0.f, 0.85f);
      for (int k = 0; k < 3; k++) {
        float v = std::min(1.f, c[k] * a[2 + k]);
        img.rgb[at * 3 + k] = v * (1 - fog) + fogCol[k] * fog;
      }
    }
  }
}

struct Camera {
  float pos[3], right[3], up[3], fwd[3];
  float focal;  // pixels
  int w, h;
  bool ortho = false;
  float mpp = 1.f, x0 = 0, z0 = 0;  // top-down: metres per pixel, x/z of the top-left corner
};

// View-space vertex with attributes; near-plane clipping happens on these.
struct CV {
  float x, y, z, a[5];
};

void DrawTri(Image& img, const Camera& cam, const Tri& tri, float fogStart, float fogEnd, const float fogCol[3]) {
  CV in[3];
  for (int k = 0; k < 3; k++) {
    const Vert& v = tri.v[k];
    float d[3] = {v.x - cam.pos[0], v.y - cam.pos[1], v.z - cam.pos[2]};
    if (cam.ortho) {
      in[k] = {v.x, v.z, cam.pos[1] - v.y, {v.s, v.t, v.r, v.g, v.b}};
    } else {
      in[k] = {d[0] * cam.right[0] + d[1] * cam.right[1] + d[2] * cam.right[2],
               d[0] * cam.up[0] + d[1] * cam.up[1] + d[2] * cam.up[2],
               d[0] * cam.fwd[0] + d[1] * cam.fwd[1] + d[2] * cam.fwd[2],
               {v.s, v.t, v.r, v.g, v.b}};
    }
  }
  auto project = [&](const CV& c) {
    SV s;
    if (cam.ortho) {
      s.x = (c.x - cam.x0) / cam.mpp;
      s.y = (cam.z0 - c.y) / cam.mpp;  // +z up the image
      s.z = c.z;
      s.iw = 1.f / c.z;
    } else {
      s.x = cam.w * 0.5f + c.x / c.z * cam.focal;
      s.y = cam.h * 0.5f - c.y / c.z * cam.focal;
      s.z = c.z;
      s.iw = 1.f / c.z;
    }
    for (int k = 0; k < 5; k++) s.a[k] = c.a[k] * s.iw;
    return s;
  };
  if (cam.ortho) {
    RasterTri(img, project(in[0]), project(in[1]), project(in[2]), tri.tex, tri.alphaTest, 1e9f, 2e9f, fogCol);
    return;
  }
  // clip against z = near
  constexpr float kNear = 0.3f;
  std::vector<CV> poly(in, in + 3), clipped;
  for (size_t i = 0; i < poly.size(); i++) {
    const CV& a = poly[i];
    const CV& b = poly[(i + 1) % poly.size()];
    bool ain = a.z >= kNear, bin = b.z >= kNear;
    if (ain) clipped.push_back(a);
    if (ain != bin) {
      float t = (kNear - a.z) / (b.z - a.z);
      CV m;
      m.x = a.x + (b.x - a.x) * t;
      m.y = a.y + (b.y - a.y) * t;
      m.z = kNear;
      for (int k = 0; k < 5; k++) m.a[k] = a.a[k] + (b.a[k] - a.a[k]) * t;
      clipped.push_back(m);
    }
  }
  if (clipped.size() < 3) return;
  SV s0 = project(clipped[0]);
  for (size_t i = 1; i + 1 < clipped.size(); i++)
    RasterTri(img, s0, project(clipped[i]), project(clipped[i + 1]), tri.tex, tri.alphaTest, fogStart, fogEnd,
              fogCol);
}

// Options among the level files: +tie (also draw TIE props), +notfrag, +hl=<proto> (tint a TIE prototype red),
// +only=<proto> (draw just these prototypes), +tex=<texture> (tfrag: just these textures), +tree=<n> (just tfrag tree n), +box=x0,z0,x1,z1 (keep only triangles with their centre inside).
void LoadAll(int argc, char** argv, int first, int palette, std::vector<Tri>& tris) {
  bool tie = false, tfrag = true;
  std::set<std::string> hl, only, texOnly;
  bool box = false;
  int onlyTree = -1;
  float bx0 = 0, bz0 = 0, bx1 = 0, bz1 = 0;
  for (int i = first; i < argc; i++) {
    if (!strcmp(argv[i], "+tie")) {
      tie = true;
      continue;
    }
    if (!strcmp(argv[i], "+alltrees")) {
      gAllTrees = true;
      continue;
    }
    if (!strcmp(argv[i], "+notfrag")) {
      tfrag = false;
      continue;
    }
    if (!strncmp(argv[i], "+hl=", 4)) {
      hl.insert(argv[i] + 4);
      continue;
    }
    if (!strncmp(argv[i], "+only=", 6)) {
      only.insert(argv[i] + 6);
      continue;
    }
    if (!strncmp(argv[i], "+top=", 5)) continue;  // holes option
    if (!strncmp(argv[i], "+tree=", 6)) {
      onlyTree = atoi(argv[i] + 6);
      continue;
    }
    if (!strncmp(argv[i], "+tex=", 5)) {
      texOnly.insert(argv[i] + 5);
      continue;
    }
    if (!strncmp(argv[i], "+box=", 5)) {
      box = sscanf(argv[i] + 5, "%f,%f,%f,%f", &bx0, &bz0, &bx1, &bz1) == 4;
      if (bx0 > bx1) std::swap(bx0, bx1);
      if (bz0 > bz1) std::swap(bz0, bz1);
      continue;
    }
    static std::vector<LoadedLevel*> keep;  // textures are referenced by pointer
    auto* l = new LoadedLevel{argv[i], {}};
    keep.push_back(l);
    if (!LoadLevel(argv[i], l->level)) {
      fprintf(stderr, "can't load %s\n", argv[i]);
      exit(1);
    }
    size_t before = tris.size();
    if (tfrag && (only.empty() || !texOnly.empty())) CollectTfrag(l->level, palette, tris);
    if (tie || !only.empty()) CollectTie(l->level, palette, tris);
    size_t keepAt = before;
    for (size_t k = before; k < tris.size(); k++) {
      Tri& t = tris[k];
      if (onlyTree >= 0 && (t.proto || t.tree != onlyTree)) continue;
      if (t.proto ? (!only.empty() && !only.count(*t.proto))
                  : (!texOnly.empty() && (!t.tex || !texOnly.count(t.tex->debug_name))))
        continue;
      if (box) {
        float cx = (t.v[0].x + t.v[1].x + t.v[2].x) / 3, cz = (t.v[0].z + t.v[1].z + t.v[2].z) / 3;
        if (cx < bx0 || cx > bx1 || cz < bz0 || cz > bz1) continue;
      }
      t.highlight = t.proto && hl.count(*t.proto);
      if (t.highlight)
        for (auto& v : t.v) v.r = 2.f, v.g = 0.4f, v.b = 0.4f;
      tris[keepAt++] = t;
    }
    tris.resize(keepAt);
    fprintf(stderr, "%s: %zu triangles\n", argv[i], tris.size() - before);
  }
}

Camera MakeCamera(int w, int h, float px, float py, float pz, float yaw, float pitch, float fov) {
  Camera cam{};
  cam.w = w;
  cam.h = h;
  cam.pos[0] = px;
  cam.pos[1] = py;
  cam.pos[2] = pz;
  cam.fwd[0] = std::sin(yaw) * std::cos(pitch);
  cam.fwd[1] = std::sin(pitch);
  cam.fwd[2] = std::cos(yaw) * std::cos(pitch);
  // screen right = forward x up (matches the game: looking west from the sea, the jungle is on the left)
  float upw[3] = {0, 1, 0};
  cam.right[0] = cam.fwd[1] * upw[2] - cam.fwd[2] * upw[1];
  cam.right[1] = cam.fwd[2] * upw[0] - cam.fwd[0] * upw[2];
  cam.right[2] = cam.fwd[0] * upw[1] - cam.fwd[1] * upw[0];
  float rl = std::sqrt(cam.right[0] * cam.right[0] + cam.right[1] * cam.right[1] + cam.right[2] * cam.right[2]);
  for (float& c : cam.right) c /= rl;
  cam.up[0] = cam.fwd[1] * cam.right[2] - cam.fwd[2] * cam.right[1];
  cam.up[1] = cam.fwd[2] * cam.right[0] - cam.fwd[0] * cam.right[2];
  cam.up[2] = cam.fwd[0] * cam.right[1] - cam.fwd[1] * cam.right[0];
  if (cam.up[1] < 0)
    for (float& c : cam.up) c = -c;
  cam.focal = w * 0.5f / std::tan(fov * 0.5f);
  return cam;
}

int View(int argc, char** argv) {
  if (argc < 13) return 1;
  int w = atoi(argv[3]), h = atoi(argv[4]);
  float px = atof(argv[5]), py = atof(argv[6]), pz = atof(argv[7]);
  float yaw = atof(argv[8]) * M_PI / 180, pitch = atof(argv[9]) * M_PI / 180, fov = atof(argv[10]) * M_PI / 180;
  int palette = atoi(argv[11]);
  std::vector<Tri> tris;
  LoadAll(argc, argv, 12, palette, tris);
  Camera cam = MakeCamera(w, h, px, py, pz, yaw, pitch, fov);
  Image img(w, h);
  const float sky[3] = {0.55f, 0.68f, 0.92f}, sea[3] = {0.12f, 0.38f, 0.45f};
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      // sky above the horizon, sea plane (y = 0) below it
      float dy = (h * 0.5f - (y + 0.5f)) / cam.focal, dx = ((x + 0.5f) - w * 0.5f) / cam.focal;
      float dir[3];
      for (int k = 0; k < 3; k++) dir[k] = cam.fwd[k] + dx * cam.right[k] + dy * cam.up[k];
      const float* c = sky;
      if (dir[1] < 0 && py > 0) {
        float t = -py / dir[1];
        float len = std::sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]) * t;
        img.depth[y * w + x] = t * 1.0f;  // depth along fwd (dir has unit fwd component)
        float fog = std::clamp(len / 1500.f, 0.f, 0.85f);
        for (int k = 0; k < 3; k++) img.rgb[(y * w + x) * 3 + k] = sea[k] * (1 - fog) + sky[k] * fog;
        continue;
      }
      for (int k = 0; k < 3; k++) img.rgb[(y * w + x) * 3 + k] = c[k];
    }
  for (auto& t : tris) DrawTri(img, cam, t, 200.f, 1500.f, sky);
  img.Save(argv[2]);
  return 0;
}

int Top(int argc, char** argv) {
  if (argc < 10) return 1;
  float x0 = atof(argv[3]), z0 = atof(argv[4]), x1 = atof(argv[5]), z1 = atof(argv[6]), mpp = atof(argv[7]);
  int palette = atoi(argv[8]);
  std::vector<Tri> tris;
  LoadAll(argc, argv, 9, palette, tris);
  Camera cam{};
  cam.ortho = true;
  cam.mpp = mpp;
  cam.x0 = std::min(x0, x1);
  cam.z0 = std::max(z0, z1);
  cam.pos[1] = 1000.f;
  int w = (int)std::ceil(std::fabs(x1 - x0) / mpp), h = (int)std::ceil(std::fabs(z1 - z0) / mpp);
  Image img(w, h);
  const float sea[3] = {0.12f, 0.38f, 0.45f};
  for (int i = 0; i < w * h; i++)
    for (int k = 0; k < 3; k++) img.rgb[i * 3 + k] = sea[k];
  for (auto& t : tris) DrawTri(img, cam, t, 0, 1, sea);
  // 100 m grid
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      float wx = cam.x0 + x * mpp, wz = cam.z0 - y * mpp;
      if (std::fmod(std::fabs(wx) + mpp * 0.5f, 100.f) < mpp || std::fmod(std::fabs(wz) + mpp * 0.5f, 100.f) < mpp) {
        float* p = &img.rgb[(y * w + x) * 3];
        p[0] = p[0] * 0.5f + 0.5f;
        p[1] *= 0.5f;
        p[2] *= 0.5f;
      }
    }
  img.Save(argv[2]);
  fprintf(stderr, "%d x %d px, top-left x %.0f z %.0f, %.2f m/px, red grid every 100 m\n", w, h, cam.x0, cam.z0, mpp);
  return 0;
}

int Region(int argc, char** argv) {
  if (argc < 7) return 1;
  float x0 = atof(argv[3]), z0 = atof(argv[4]), x1 = atof(argv[5]), z1 = atof(argv[6]);
  float ymin = argc > 7 ? atof(argv[7]) : -1e9f;
  if (x0 > x1) std::swap(x0, x1);
  if (z0 > z1) std::swap(z0, z1);
  tfrag3::Level level;
  if (!LoadLevel(argv[2], level)) return 1;
  std::vector<Tri> tris, ties;
  CollectTfrag(level, 1, tris);
  CollectTie(level, 1, ties);
  auto inside = [&](float cx, float cy, float cz) {
    return cx >= x0 && cx <= x1 && cz >= z0 && cz <= z1 && cy >= ymin;
  };
  float lo[3] = {1e9, 1e9, 1e9}, hi[3] = {-1e9, -1e9, -1e9};
  std::map<std::string, int> texCount;
  std::set<std::pair<int, int>> draws;
  size_t n = 0, steep = 0;
  for (auto& t : tris) {
    float cx = (t.v[0].x + t.v[1].x + t.v[2].x) / 3, cy = (t.v[0].y + t.v[1].y + t.v[2].y) / 3,
          cz = (t.v[0].z + t.v[1].z + t.v[2].z) / 3;
    if (!inside(cx, cy, cz)) continue;
    n++;
    for (auto& v : t.v) {
      lo[0] = std::min(lo[0], v.x), lo[1] = std::min(lo[1], v.y), lo[2] = std::min(lo[2], v.z);
      hi[0] = std::max(hi[0], v.x), hi[1] = std::max(hi[1], v.y), hi[2] = std::max(hi[2], v.z);
    }
    float ax = t.v[1].x - t.v[0].x, ay = t.v[1].y - t.v[0].y, az = t.v[1].z - t.v[0].z;
    float bx = t.v[2].x - t.v[0].x, by = t.v[2].y - t.v[0].y, bz = t.v[2].z - t.v[0].z;
    float nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
    if (std::fabs(ny) < 0.5f * std::sqrt(nx * nx + ny * ny + nz * nz)) steep++;
    texCount[t.tex ? t.tex->debug_name : "(none)"]++;
    draws.insert({t.tree, t.draw});
  }
  printf("TFRAG: %zu triangles (%zu steeper than 60 deg) in %zu draws\n", n, steep, draws.size());
  if (n) printf("  bounds x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f m\n", lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]);
  std::vector<std::pair<int, std::string>> sorted;
  for (auto& [k, v] : texCount) sorted.push_back({v, k});
  std::sort(sorted.rbegin(), sorted.rend());
  for (auto& [v, k] : sorted) printf("  %6d  %s\n", v, k.c_str());

  // TIE instances: triangles of one prototype joined by shared vertices (each instance has its own vertices).
  std::map<std::pair<int, u32>, u32> parent;
  std::function<u32(int, u32)> find = [&](int tree, u32 x) -> u32 {
    auto it = parent.find({tree, x});
    if (it == parent.end() || it->second == x) return x;
    return it->second = find(tree, it->second);
  };
  for (auto& t : ties) {
    for (int k = 0; k < 3; k++) parent.try_emplace({t.tree, t.vi[k]}, t.vi[k]);
    u32 r0 = find(t.tree, t.vi[0]);
    for (int k = 1; k < 3; k++) parent[{t.tree, find(t.tree, t.vi[k])}] = r0;
  }
  struct Inst {
    std::string proto;
    int tris = 0;
    float lo[3] = {1e9, 1e9, 1e9}, hi[3] = {-1e9, -1e9, -1e9};
  };
  std::map<std::pair<int, u32>, Inst> inst;
  for (auto& t : ties) {
    Inst& in = inst[{t.tree, find(t.tree, t.vi[0])}];
    in.proto = *t.proto;
    in.tris++;
    for (auto& v : t.v) {
      in.lo[0] = std::min(in.lo[0], v.x), in.lo[1] = std::min(in.lo[1], v.y), in.lo[2] = std::min(in.lo[2], v.z);
      in.hi[0] = std::max(in.hi[0], v.x), in.hi[1] = std::max(in.hi[1], v.y), in.hi[2] = std::max(in.hi[2], v.z);
    }
  }
  std::map<std::string, std::vector<const Inst*>> byProto;
  for (auto& [k, in] : inst) {
    float cx = (in.lo[0] + in.hi[0]) / 2, cy = (in.lo[1] + in.hi[1]) / 2, cz = (in.lo[2] + in.hi[2]) / 2;
    if (inside(cx, cy, cz)) byProto[in.proto].push_back(&in);
  }
  std::vector<std::pair<int, std::string>> protos;
  for (auto& [p, v] : byProto) {
    int sum = 0;
    for (auto* in : v) sum += in->tris;
    protos.push_back({sum, p});
  }
  std::sort(protos.rbegin(), protos.rend());
  printf("TIE: %zu prototypes with pieces centred in the box\n", protos.size());
  for (auto& [sum, p] : protos) {
    auto& v = byProto[p];
    printf("  %-28s %3zu pieces %6d tris\n", p.c_str(), v.size(), sum);
    std::vector<const Inst*> big(v.begin(), v.end());
    std::sort(big.begin(), big.end(), [](auto* a, auto* b) { return a->tris > b->tris; });
    for (size_t i = 0; i < big.size() && i < 6; i++) {
      auto* in = big[i];
      printf("      %5d tris  size %5.1f x %5.1f x %5.1f  centre %7.1f %6.1f %7.1f  y %.1f..%.1f\n", in->tris,
             in->hi[0] - in->lo[0], in->hi[1] - in->lo[1], in->hi[2] - in->lo[2], (in->lo[0] + in->hi[0]) / 2,
             (in->lo[1] + in->hi[1]) / 2, (in->lo[2] + in->hi[2]) / 2, in->lo[1], in->hi[1]);
    }
  }
  return 0;
}


// See-through check for the east coastline (coastline-plan.md): renders the given levels from viewpoints along the
// boat route around the coast and counts "holes": pixels where no rock is drawn although the view ray passes
// through the coast's land (the strip between its two faces) below 12 m, or meets the water inside it. Those are
// the caves / gaps through which the open sea or the bare ocean edge shows.
// Usage: coast_survey holes [worst.ppm] [+top=12] level.fr3z...   (prints the total and the worst views)
int Holes(int argc, char** argv) {
  int first = 2;
  float top = 12;  // +top=<m>: how high up a see-through ray still counts
  for (int i = 2; i < argc; i++) {
    if (!strncmp(argv[i], "+top=", 5)) top = atof(argv[i] + 5);
  }
  const char* worstPath = nullptr;
  if (argc > 2 && strstr(argv[2], ".ppm")) {
    worstPath = argv[2];
    first = 3;
  }
  std::vector<Tri> tris;
  LoadAll(argc, argv, first, 1, tris);
  // the coast's land: LayOutCoast's rows (Jak1CustomLevelBuilder.cpp WriteCoastHeights polygon)
  const std::vector<std::array<float, 2>> land = {
      {392, -392}, {500, -362}, {500, -1413}, {213, -1393}, {308, -1200}, {308, -480}};
  auto onLand = [&](float x, float z) {
    bool in = false;
    for (size_t i = 0, j = land.size() - 1; i < land.size(); j = i++) {
      float xi = land[i][0], zi = land[i][1], xj = land[j][0], zj = land[j][1];
      if ((zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi) in = !in;
    }
    return in;
  };
  struct ViewSpec {
    float x, y, z, yaw;
  };
  std::vector<ViewSpec> views;
  for (float z = -360; z >= -1460; z -= 50) {
    for (float x : {540.f, 600.f, 700.f, 900.f}) {
      for (float yaw : {-90.f, -135.f, -45.f}) views.push_back({x, 3, z, yaw});
    }
  }
  for (float z = -500; z >= -1220; z -= 60) {
    for (float x : {270.f, 230.f}) {
      for (float yaw : {90.f, 135.f, 45.f}) views.push_back({x, 3, z, yaw});
    }
  }
  constexpr int W = 240, H = 110;
  const float sea[3] = {0, 0, 0};
  struct Result {
    size_t holes;
    ViewSpec v;
  };
  std::vector<Result> results;
  size_t total = 0;
  Image worst(W, H);
  size_t worstHoles = 0;
  for (const auto& v : views) {
    Camera cam = MakeCamera(W, H, v.x, v.y, v.z, v.yaw * M_PI / 180, 0, 100 * M_PI / 180);
    Image img(W, H);
    for (auto& t : tris) DrawTri(img, cam, t, 1e9f, 2e9f, sea);
    size_t holes = 0;
    std::vector<uint8_t> mark(W * H, 0);
    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        if (img.depth[y * W + x] < 1e29f) continue;  // rock
        float dy = (H * 0.5f - (y + 0.5f)) / cam.focal, dx = ((x + 0.5f) - W * 0.5f) / cam.focal;
        float dir[3];
        for (int k = 0; k < 3; k++) dir[k] = cam.fwd[k] + dx * cam.right[k] + dy * cam.up[k];
        float len = std::sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
        for (float& c : dir) c /= len;
        for (float t = 2; t < 1500; t += 2) {
          float px = cam.pos[0] + dir[0] * t, py = cam.pos[1] + dir[1] * t, pz = cam.pos[2] + dir[2] * t;
          if (py > top) break;
          bool water = py < 0;
          if (onLand(px, pz)) {
            holes++;
            mark[y * W + x] = 1;
            break;
          }
          if (water) break;
        }
      }
    }
    total += holes;
    results.push_back({holes, v});
    if (holes > worstHoles) {
      worstHoles = holes;
      worst = img;
      for (int i = 0; i < W * H; i++) {
        bool rock = img.depth[i] < 1e29f;
        img.rgb[i * 3 + 0] = mark[i] ? 1.f : rock ? 0.5f : 0.1f;
        img.rgb[i * 3 + 1] = mark[i] ? 0.f : rock ? 0.5f : 0.2f;
        img.rgb[i * 3 + 2] = mark[i] ? 0.f : rock ? 0.5f : 0.3f;
      }
      worst = img;
    }
  }
  std::sort(results.begin(), results.end(), [](const Result& a, const Result& b) { return a.holes > b.holes; });
  printf("holes: %zu pixels over %zu views (%zu views with any)\n", total, views.size(),
         (size_t)std::count_if(results.begin(), results.end(), [](const Result& r) { return r.holes > 0; }));
  for (size_t i = 0; i < results.size() && i < 8 && results[i].holes; i++)
    printf("  %5zu  at x %.0f z %.0f yaw %.0f\n", results[i].holes, results[i].v.x, results[i].v.z, results[i].v.yaw);
  if (worstPath) worst.Save(worstPath);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc >= 2 && !strcmp(argv[1], "view")) return View(argc, argv);
  if (argc >= 2 && !strcmp(argv[1], "top")) return Top(argc, argv);
  if (argc >= 2 && !strcmp(argv[1], "region")) return Region(argc, argv);
  if (argc >= 2 && !strcmp(argv[1], "holes")) return Holes(argc, argv);
  fprintf(stderr,
          "usage:\n  coast_survey view out.ppm W H x y z yaw pitch fov palette [+tie] level.fr3z...\n"
          "  coast_survey top out.ppm x0 z0 x1 z1 metresPerPixel palette [+tie] level.fr3z...\n"
          "  coast_survey region level.fr3z x0 z0 x1 z1 [ymin]\n");
  return 1;
}
