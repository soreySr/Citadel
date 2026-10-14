// Turns a built stand-in coastline (Jak1Level-ios-coast.fr3z, from coast_terrain_fr3.cpp) into the template
// the app ships: our terrain tree, draw modes and the names of the jungle textures it uses, with the texture
// pixels and the time-of-day colors (both copied from the jungle level) removed. The app refills them from
// the player's own extracted jungle level at import (jakIOS/Import/Jak1CustomLevelBuilder.cpp).
//
// Build (from the repo root, after sh tools/ios_extractor/build.sh macos):
//   clang++ -std=c++20 -O2 -IOpenGOAL -IOpenGOAL/third-party -IOpenGOAL/third-party/fmt/include \
//     tools/coast/coast_template.cpp build-ios-extractor/macos/libjak1_extractor.a -lcompression \
//     -o /tmp/coast_template
// Usage: coast_template Jak1Level-ios-coast.fr3z jakIOS/Import/Jak1CoastTerrain.fr3z
#include <compression.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

#include "common/custom_data/Tfrag3Data.h"
#include "common/util/Serializer.h"

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s ios-coast.fr3z template.fr3z\n", argv[0]);
    return 2;
  }
  std::ifstream input(argv[1], std::ios::binary);
  std::vector<uint8_t> file((std::istreambuf_iterator<char>(input)), {});
  uint32_t magic = 0;
  uint64_t rawSize = 0;
  if (file.size() < 12) return 3;
  memcpy(&magic, file.data(), 4);
  memcpy(&rawSize, file.data() + 4, 8);
  if (magic != 0x5a335246) return 3;
  std::vector<uint8_t> raw(rawSize);
  if (compression_decode_buffer(raw.data(), raw.size(), file.data() + 12, file.size() - 12, nullptr,
                                COMPRESSION_LZFSE) != rawSize) {
    return 4;
  }
  tfrag3::Level coast;
  {
    Serializer ser(raw.data(), raw.size());
    coast.serialize(ser);
  }

  for (auto& texture : coast.textures) {
    fprintf(stderr, "texture %s (%s) %dx%d: pixels removed\n", texture.debug_name.c_str(),
            texture.debug_tpage_name.c_str(), texture.w, texture.h);
    texture.data.clear();
    texture.w = 0;
    texture.h = 0;
  }
  size_t trees = 0;
  for (auto& geom : coast.tfrag_trees) {
    for (auto& tree : geom) {
      std::fill(tree.colors.data.begin(), tree.colors.data.end(), 0);
      trees++;
    }
  }
  fprintf(stderr, "%zu terrain trees, %zu vertices: colors removed\n", trees,
          coast.tfrag_trees[0].empty() ? 0 : coast.tfrag_trees[0][0].packed_vertices.vertices.size());

  Serializer ser;
  coast.serialize(ser);
  auto [data, size] = ser.get_save_result();
  std::vector<uint8_t> encoded(size + 4096);
  const size_t encodedSize =
      compression_encode_buffer(encoded.data(), encoded.size(), data, size, nullptr, COMPRESSION_LZFSE);
  if (encodedSize == 0) return 5;
  FILE* out = fopen(argv[2], "wb");
  if (!out) return 6;
  const uint64_t size64 = size;
  fwrite(&magic, 4, 1, out);
  fwrite(&size64, 8, 1, out);
  fwrite(encoded.data(), 1, encodedSize, out);
  fclose(out);
  fprintf(stderr, "wrote %s (%zu raw, %zu lzfse)\n", argv[2], size, encodedSize);
  return 0;
}
