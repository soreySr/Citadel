#include "common/custom_data/Tfrag3Data.h"
#include "common/util/compress.h"
#include "common/util/FileUtil.h"
#include "common/util/Serializer.h"
#include <cstdio>
int main(int argc, char** argv) {
  for (int a = 1; a < argc; a++) {
    auto data = file_util::read_binary_file(std::string(argv[a]));
    auto dec = compression::decompress_zstd(data.data(), data.size());
    tfrag3::Level lev;
    Serializer ser(dec.data(), dec.size());
    lev.serialize(ser);
    auto& v = lev.collision.vertices;
    std::string out = std::string(argv[a]) + ".coll";
    FILE* f = fopen(out.c_str(), "wb");
    fwrite(v.data(), sizeof(v[0]), v.size(), f);
    fclose(f);
    printf("%s: %zu collision verts\n", argv[a], v.size());
  }
}
