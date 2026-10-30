// Builds the disc's levels on the Mac exactly as the app's ISO import does (jakIOS/Import/Jak1LevelBuilder.mm,
// ExtractDiscLevels): Jak1ExtractorConfig.pack unpacked into a scratch project, jak1::ExtractLevels, then each
// <level>.fr3 converted to Jak1Level-<level>.fr3z. modlevel_pack matches mod meshes against these (--levels).
//
// Usage: extract_levels <Jak1ExtractorConfig.pack> <iso_data/jak1> <output dir>
// Build: sh tools/modlevel/build.sh
#include <compression.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "common/util/compress.h"

#include "Jak1LevelExtractor.h"

namespace fs = std::filesystem;

namespace {

std::vector<uint8_t> ReadFile(const fs::path &path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}

// Same format and checks as UnpackExtractorConfig in Jak1LevelBuilder.mm.
bool UnpackConfig(const fs::path &pack, const fs::path &project) {
    const std::vector<uint8_t> bytes = ReadFile(pack);
    if (bytes.size() < 12 || memcmp(bytes.data(), "JAK1CFG\0", 8) != 0) return false;
    uint32_t count = 0;
    memcpy(&count, bytes.data() + 8, 4);
    size_t offset = 12;
    for (uint32_t index = 0; index < count; index++) {
        uint16_t nameLength = 0;
        uint32_t size = 0;
        if (offset + 2 > bytes.size()) return false;
        memcpy(&nameLength, bytes.data() + offset, 2);
        offset += 2;
        if (offset + nameLength + 4 > bytes.size()) return false;
        const std::string name(reinterpret_cast<const char *>(bytes.data() + offset), nameLength);
        offset += nameLength;
        memcpy(&size, bytes.data() + offset, 4);
        offset += 4;
        if (name.find("..") != std::string::npos || offset + size > bytes.size()) return false;
        const fs::path path = project / name;
        fs::create_directories(path.parent_path());
        std::ofstream file(path, std::ios::binary);
        file.write(reinterpret_cast<const char *>(bytes.data() + offset), size);
        if (!file) return false;
        offset += size;
    }
    return true;
}

// Same as ConvertToFr3z in Jak1LevelBuilder.mm (and tools/fr3_to_lzfse.cpp).
bool ConvertToFr3z(const fs::path &fr3, const fs::path &output) {
    std::vector<uint8_t> compressed = ReadFile(fr3);
    if (compressed.empty()) return false;
    const std::vector<uint8_t> raw = compression::decompress_zstd(compressed.data(), compressed.size());
    compressed = {};
    if (raw.empty()) return false;
    std::vector<uint8_t> encoded(raw.size() + 4096);
    const size_t encodedSize = compression_encode_buffer(encoded.data(), encoded.size(), raw.data(), raw.size(),
                                                         nullptr, COMPRESSION_LZFSE);
    if (encodedSize == 0) return false;
    const uint32_t magic = 0x5a335246;  // "FR3Z"
    const uint64_t rawSize = raw.size();
    std::ofstream file(output, std::ios::binary);
    file.write(reinterpret_cast<const char *>(&magic), 4);
    file.write(reinterpret_cast<const char *>(&rawSize), 8);
    file.write(reinterpret_cast<const char *>(encoded.data()), encodedSize);
    return static_cast<bool>(file);
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <Jak1ExtractorConfig.pack> <iso_data/jak1> <output dir>\n", argv[0]);
        return 2;
    }
    const fs::path output = fs::absolute(argv[3]);
    const fs::path scratch = output / ".scratch";
    fs::remove_all(scratch);
    const fs::path project = scratch / "project";
    const fs::path extracted = scratch / "fr3";
    if (!UnpackConfig(argv[1], project)) {
        fprintf(stderr, "could not unpack %s\n", argv[1]);
        return 1;
    }
    std::string error;
    const bool extractedAll = jak1::ExtractLevels(
        {project.string(), fs::absolute(argv[2]).string(), extracted.string(), (scratch / "work").string()},
        [](int completed, int total, const std::string &name) {
            if (completed < total) printf("  level %d/%d %s\n", completed + 1, total, name.c_str());
            fflush(stdout);
        },
        &error);
    if (!extractedAll) {
        fprintf(stderr, "level extraction failed: %s\n", error.c_str());
        return 1;
    }
    int converted = 0;
    for (const auto &entry : fs::directory_iterator(extracted)) {
        if (entry.path().extension() != ".fr3") continue;
        // GAME.fr3 -> Jak1Level-game.fr3z: lower-case level names, as the import writes them.
        std::string level = entry.path().stem().string();
        for (auto &c : level) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
        if (!ConvertToFr3z(entry.path(), output / ("Jak1Level-" + level + ".fr3z"))) {
            fprintf(stderr, "could not convert %s\n", entry.path().c_str());
            return 1;
        }
        converted++;
    }
    fs::remove_all(scratch);
    if (converted == 0) {
        fprintf(stderr, "the level extractor produced no levels\n");
        return 1;
    }
    printf("wrote %d level files to %s\n", converted, output.c_str());
    return 0;
}
