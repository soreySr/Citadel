#pragma once

#include <functional>
#include <string>

namespace jak1 {

struct LevelExtractorPaths {
    std::string project;  // read-only: decompiler/config/jak1/... and goal_src/jak1/build/all_objs.json
    std::string disc;     // the imported disc (CGO/, DGO/, TEXT/ ...)
    std::string output;   // receives <level>.fr3 for GAME.CGO and every level DGO
    std::string scratch;  // writable temporary folder (texture dump dir, entity JSON); may be deleted after
};

// Called before each output file: (index, total, name). index == total means finished.
using LevelExtractorProgress = std::function<void(int, int, const std::string &)>;

// Runs OpenGOAL's level extraction (decompiler minimal mode, as the OpenGOAL extractor does) on the
// player's disc and writes the PC renderer's FR3 files. Levels are extracted one at a time to keep
// memory down. Returns false and sets *error on failure.
bool ExtractLevels(const LevelExtractorPaths &paths, const LevelExtractorProgress &progress,
                   std::string *error);

}  // namespace jak1
