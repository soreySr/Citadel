#pragma once

// OpenGOAL's Jak 1 (v2) game-text character encoding, compiled from common/util/font.

#include <string>

namespace jak1 {

// UTF-8 -> game string bytes (GameTextFontBank::convert_utf8_to_game).
std::string GameTextUtf8ToGame(const std::string& utf8);
// Game string bytes -> UTF-8 (GameTextFontBank::convert_game_to_utf8).
std::string GameTextGameToUtf8(const std::string& game);

}  // namespace jak1
