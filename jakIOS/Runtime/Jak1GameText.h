#pragma once

// Reads and writes Jak 1 XCOMMON.TXT files: a single `game-text-info` object in the GOAL v2
// object format. The writer is a port of OpenGOAL's compile_text (goalc/data_compiler/
// game_text_common.cpp) and DataObjectGenerator::generate_v2, so it produces the same bytes the
// desktop build writes to out/jak1/iso.

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace jak1 {

struct GameTextBank {
    int languageId = 0;
    std::string group = "common";
    std::map<int, std::string> lines;  // text id -> game-encoded string, sorted like GameTextBank
};

// Parses a TXT file from the disc. Strings stay in the game encoding.
bool ParseGameTextFile(const uint8_t *bytes, size_t size, GameTextBank *bank, std::string *error);

// Serializes a bank exactly like compile_text.
std::vector<uint8_t> WriteGameTextFile(const GameTextBank &bank);

}  // namespace jak1
