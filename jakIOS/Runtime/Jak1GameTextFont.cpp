// Converts PC-port strings to the game's character set with OpenGOAL's game-text font encoding
// (common/util/font, linked from the level extractor library, tools/ios_extractor), exactly as the
// desktop text compiler does.
#include "common/util/font/font_utils.h"

#include "Jak1GameTextFont.h"

namespace jak1 {
// OpenGOAL builds Jak 1 text with the fixed v2 encoding for every region (game_text.gp) and the
// decompiler reads disc text with the same version (jak1_config.jsonc "text_version": 11).
std::string GameTextUtf8ToGame(const std::string& utf8) {
    return get_font_bank(GameTextVersion::JAK1_V2)->convert_utf8_to_game(utf8);
}

std::string GameTextGameToUtf8(const std::string& game) {
    return get_font_bank(GameTextVersion::JAK1_V2)->convert_game_to_utf8(game.c_str());
}
}  // namespace jak1
