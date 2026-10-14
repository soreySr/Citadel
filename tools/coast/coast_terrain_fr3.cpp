// Builds Jak1Level-ios-coast.fr3z: stand-in coastline terrain between the Forbidden Jungle and Rock Village
// (the stretch no level has geometry for), packed as one tfrag tree so the iOS background renderer can draw
// it with village1's camera, fog and time of day. Grass / rock / sand / grass-fringe textures, draw modes and
// time-of-day palettes are copied from the neighbouring jungle level, so it matches the jungle's sea cliffs.
//
// Input: tris.bin from terrain.py (x y z s t floats in meters/uv, material int, light int per vertex).
// Build (from OpenGOAL/):
//   clang++ -std=c++20 -O2 -I. -Ithird-party -Ithird-party/fmt/include ../tools/coast/coast_terrain_fr3.cpp \
//     -Lbuild-make/common -lcommon -lcompression -Wl,-rpath,$PWD/build-make/common -o /tmp/coast_terrain_fr3
// Usage: coast_terrain_fr3 out/jak1/fr3/jungle.fr3 tris.bin Jak1Level-ios-coast.fr3z
#include <compression.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "common/custom_data/Tfrag3Data.h"
#include "common/util/FileUtil.h"
#include "common/util/Serializer.h"
#include "common/util/compress.h"

struct InVert {
  float x, y, z, s, t;
  int32_t material, light;
};

int main(int argc, char** argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s jungle.fr3 tris.bin out.fr3z\n", argv[0]);
    return 2;
  }
  auto packed = file_util::read_binary_file(std::string(argv[1]));
  auto raw = compression::decompress_zstd(packed.data(), packed.size());
  tfrag3::Level vil;
  {
    Serializer ser(raw.data(), raw.size());
    vil.serialize(ser);
  }
  for (auto& tree : vil.tfrag_trees[0]) tree.unpack();

  // materials: 0 grass, 1 rock, 2 sand, 3 grass fringe hanging over cliff lips
  constexpr int kMaterials = 4;
  const char* names[kMaterials] = {"jng-leafyground", "jng-rockwall-01", "jng-beach-01", "jng-leafyground-hang-2x1"};
  int texId[kMaterials] = {-1, -1, -1, -1};
  for (int m = 0; m < kMaterials; m++) {
    for (size_t i = 0; i < vil.textures.size(); i++) {
      if (vil.textures[i].debug_name == names[m]) {
        texId[m] = (int)i;
        break;
      }
    }
    if (texId[m] < 0) {
      fprintf(stderr, "texture %s not found\n", names[m]);
      return 3;
    }
  }

  // Per material: draw mode and the time-of-day colors its village1 vertices use.
  const tfrag3::TfragTree* main = nullptr;
  for (auto& tree : vil.tfrag_trees[0]) {
    if (tree.kind == tfrag3::TFragmentTreeKind::NORMAL &&
        (!main || tree.draws.size() > main->draws.size()))
      main = &tree;
  }
  DrawMode modes[kMaterials];
  bool haveMode[kMaterials] = {false, false, false, false};
  std::vector<int> colorsOf[kMaterials];
  for (const auto& draw : main->draws) {
    for (int m = 0; m < kMaterials; m++) {
      if (draw.tree_tex_id != texId[m]) continue;
      if (!haveMode[m]) {
        modes[m] = draw.mode;
        haveMode[m] = true;
      }
      const u32 first = draw.unpacked.idx_of_first_idx_in_full_buffer;
      u32 count = 0;
      for (const auto& g : draw.vis_groups) count += g.num_inds;
      for (u32 k = 0; k < count; k++) {
        const u32 idx = main->unpacked.indices[first + k];
        if (idx == UINT32_MAX) continue;
        colorsOf[m].push_back(main->unpacked.vertices[idx].color_index);
      }
    }
  }
  // Four brightness levels per material: quantiles of the material's colors by average brightness.
  auto brightness = [&](int c) {
    float sum = 0;
    for (int p = 0; p < 8; p++)
      for (int ch = 0; ch < 3; ch++) sum += main->colors.read(c, p, ch);
    return sum;
  };
  tfrag3::PackedTimeOfDay tod;
  tod.color_count = kMaterials * 4;
  tod.data.resize(kMaterials * 4 * 4 * 8);
  for (int m = 0; m < kMaterials; m++) {
    auto& cs = colorsOf[m];
    if (cs.empty()) {
      fprintf(stderr, "no colors for %s\n", names[m]);
      return 4;
    }
    std::sort(cs.begin(), cs.end(), [&](int a, int b) { return brightness(a) < brightness(b); });
    const float q[4] = {0.15f, 0.4f, 0.65f, 0.88f};
    for (int l = 0; l < 4; l++) {
      const int src = cs[std::min(cs.size() - 1, (size_t)(q[l] * cs.size()))];
      for (int p = 0; p < 8; p++)
        for (int ch = 0; ch < 4; ch++) tod.read(m * 4 + l, p, ch) = main->colors.read(src, p, ch);
    }
    fprintf(stderr, "%s: tex %d, %zu colored verts, mode 0x%08x\n", names[m], texId[m], cs.size(),
            modes[m].as_int());
  }

  // Geometry.
  auto in = file_util::read_binary_file(std::string(argv[2]));
  const size_t n = in.size() / sizeof(InVert);
  const InVert* v = reinterpret_cast<const InVert*>(in.data());
  tfrag3::TfragTree tree;
  tree.kind = tfrag3::TFragmentTreeKind::NORMAL;
  tree.use_strips = false;
  tree.colors = tod;
  std::map<std::tuple<u16, u16, u16>, u16> clusters;
  constexpr float kClusterSize = 4096 * 40;
  constexpr float kMasterOffset = 12000 * 4096;
  constexpr float rescale = kClusterSize / UINT16_MAX;
  std::vector<u32> indicesOf[kMaterials];
  for (size_t i = 0; i < n; i++) {
    const float p[3] = {v[i].x * 4096.f, v[i].y * 4096.f, v[i].z * 4096.f};
    u16 c[3];
    u16 off[3];
    for (int a = 0; a < 3; a++) {
      c[a] = (u16)std::floor((p[a] + kMasterOffset) / kClusterSize);
      const float origin = -kMasterOffset + kClusterSize * c[a];
      off[a] = (u16)std::clamp(std::lround((p[a] - origin) / rescale), 0L, 65535L);
    }
    auto key = std::make_tuple(c[0], c[1], c[2]);
    auto found = clusters.find(key);
    if (found == clusters.end()) {
      found = clusters.emplace(key, (u16)tree.packed_vertices.cluster_origins.size()).first;
      tree.packed_vertices.cluster_origins.push_back({c[0], c[1], c[2]});
    }
    tfrag3::PackedTfragVertices::Vertex out;
    out.xoff = off[0];
    out.yoff = off[1];
    out.zoff = off[2];
    out.cluster_idx = found->second;
    out.s = (s16)std::lround(v[i].s * 1024.f);
    out.t = (s16)std::lround(v[i].t * 1024.f);
    out.color_index = (u16)(v[i].material * 4 + std::clamp(v[i].light, 0, 3));
    tree.packed_vertices.vertices.push_back(out);
    indicesOf[std::clamp(v[i].material, 0, kMaterials - 1)].push_back((u32)i);
  }
  for (int m = 0; m < kMaterials; m++) {
    if (indicesOf[m].empty()) continue;
    tfrag3::StripDraw draw;
    draw.mode = modes[m];
    draw.tree_tex_id = m;  // index into this level's textures
    draw.plain_indices = indicesOf[m];
    draw.num_triangles = indicesOf[m].size() / 3;
    tfrag3::StripDraw::VisGroup group;
    group.num_inds = indicesOf[m].size();
    group.num_tris = draw.num_triangles;
    group.vis_idx_in_pc_bvh = UINT16_MAX;  // always drawn (no BVH)
    draw.vis_groups.push_back(group);
    tree.draws.push_back(draw);
  }

  tfrag3::Level coast;
  coast.level_name = "ios-coast";
  for (int m = 0; m < kMaterials; m++) {
    tfrag3::Texture tex = vil.textures[texId[m]];
    tex.combo_id = 0;  // not in the texture pool (the jungle registers the originals when it loads)
    tex.load_to_pool = false;
    coast.textures.push_back(tex);
  }
  for (int geom = 0; geom < tfrag3::TFRAG_GEOS; geom++) coast.tfrag_trees[geom].push_back(tree);

  Serializer ser;
  coast.serialize(ser);
  auto [data, size] = ser.get_save_result();
  std::vector<uint8_t> out(size + 4096);
  const size_t encoded =
      compression_encode_buffer(out.data(), out.size(), data, size, nullptr, COMPRESSION_LZFSE);
  if (encoded == 0) return 5;
  FILE* f = fopen(argv[3], "wb");
  if (!f) return 6;
  const uint32_t magic = 0x5a335246;  // "FR3Z"
  const uint64_t rawSize = size;
  fwrite(&magic, 4, 1, f);
  fwrite(&rawSize, 8, 1, f);
  fwrite(out.data(), 1, encoded, f);
  fclose(f);
  fprintf(stderr, "%zu verts, %zu clusters, %zu draws -> %s (%zu raw, %zu lzfse)\n", n,
          tree.packed_vertices.cluster_origins.size(), tree.draws.size(), argv[3], size, encoded);
  return 0;
}
