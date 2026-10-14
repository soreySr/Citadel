// Converts an OpenGOAL .fr3 (zstd-compressed serialized tfrag3::Level) into an LZFSE stream the
// iOS app can decode with Apple's Compression framework. The serialized payload is unchanged,
// so the app deserializes it with the same common/custom_data/Tfrag3Data.cpp.
//
// Build (from OpenGOAL/):
//   clang++ -std=c++20 -O2 -I. -Ithird-party -Ithird-party/zstd/lib -Ithird-party/fmt/include \
//     ../tools/fr3_to_lzfse.cpp -Lbuild-make/common -lcommon -lcompression \
//     -Wl,-rpath,$PWD/build-make/common -o /tmp/fr3_to_lzfse
// Usage: fr3_to_lzfse in.fr3 out.fr3z
#include <compression.h>

#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

#include "common/util/compress.h"

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s in.fr3 out.fr3z\n", argv[0]);
    return 2;
  }
  std::ifstream input(argv[1], std::ios::binary);
  std::vector<uint8_t> compressed((std::istreambuf_iterator<char>(input)), {});
  auto raw = compression::decompress_zstd(compressed.data(), compressed.size());

  // Header: magic "FR3Z", uncompressed size, then the LZFSE stream.
  std::vector<uint8_t> out(raw.size() + 4096);
  const size_t encoded = compression_encode_buffer(out.data(), out.size(), raw.data(), raw.size(),
                                                   nullptr, COMPRESSION_LZFSE);
  if (encoded == 0) {
    fprintf(stderr, "LZFSE encode failed\n");
    return 3;
  }
  FILE* file = fopen(argv[2], "wb");
  if (!file) return 4;
  const uint32_t magic = 0x5a335246;  // "FR3Z"
  const uint64_t rawSize = raw.size();
  fwrite(&magic, 4, 1, file);
  fwrite(&rawSize, 8, 1, file);
  fwrite(out.data(), 1, encoded, file);
  fclose(file);
  fprintf(stderr, "%s: %zu raw bytes -> %zu LZFSE bytes\n", argv[1], raw.size(), encoded);
  return 0;
}
