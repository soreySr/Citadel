#import "Jak1PCTextBuilder.h"

#include <map>
#include <string>
#include <vector>

#include "common/util/crc32.h"
#include "third-party/xdelta3/xdelta3.h"

#include "Jak1GameText.h"
#include "Jak1GameTextFont.h"

namespace {

// game/assets/jak1/game_text.gp: language id -> custom JSON files layered over the disc text.
struct LanguageFiles {
    int languageId;
    std::vector<const char *> resources;
};
const std::vector<LanguageFiles> kLanguageFiles = {
    {0, {"game_custom_text_en-US"}},
    {1, {"game_custom_text_fr-FR"}},
    {2, {"game_custom_text_de-DE"}},
    {3, {"game_custom_text_es-ES"}},
    {4, {"game_custom_text_it-IT", "game_base_text_it-IT"}},
    {5, {"game_custom_text_ja-JP"}},
    {6, {"game_custom_text_en-GB"}},
    {7, {"game_custom_text_pt-PT"}},
    {8, {"game_custom_text_fi-FI", "game_base_text_fi-FI"}},
    {9, {"game_custom_text_sv-SE"}},
    {10, {"game_custom_text_da-DK"}},
    {11, {"game_custom_text_no-NO"}},
    {12, {"game_custom_text_nl-NL"}},
    {13, {"game_custom_text_pt-BR"}},
    {14, {"game_custom_text_hu-HU", "game_base_text_hu-HU"}},
    {15, {"game_custom_text_ca-ES"}},
    {16, {"game_custom_text_is-IS"}},
    {19, {"game_custom_text_pl-PL", "game_base_text_pl-PL"}},
    {20, {"game_custom_text_lt-LT"}},
    {21, {"game_custom_text_cs-CZ"}},
    {22, {"game_custom_text_hr-HR"}},
    {23, {"game_custom_text_gl-ES", "game_base_text_gl-ES"}},
    {24, {"game_custom_text_bs-BA", "game_base_text_bs-BA"}},
};

// decompiler/config/jak1/jak1_config.jsonc "object_patches": the NTSC v1 disc text CRCs that
// OpenGOAL patches to the v2 revision (its "text_version": 11) before decompiling.
const uint32_t kDiscTextPatchCRCs[] = {
    0xDD2CD7E2, 0x2B9C79F9, 0xDA35C5F3, 0x50C4A6A0, 0xC475F525, 0x92D44110, 0x85B23FEE,
};
constexpr int kDiscLanguageCount = sizeof(kDiscTextPatchCRCs) / sizeof(kDiscTextPatchCRCs[0]);

NSError *BuilderError(NSString *message) {
    return [NSError errorWithDomain:@"Jak1PCTextBuilder" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

std::vector<uint8_t> BytesOf(NSData *data) {
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    return std::vector<uint8_t>(bytes, bytes + data.length);
}

// ObjectFileDB::ObjectFileDB: apply the patch only to the exact file it was made for.
bool PatchDiscTextIfNeeded(int language, std::vector<uint8_t> *file) {
    if (crc32(file->data(), file->size()) != kDiscTextPatchCRCs[language]) {
        return true;  // already the v2 revision (or another region): use as-is
    }
    NSString *name = [NSString stringWithFormat:@"%dcommon", language];
    NSData *patch = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:name withExtension:@"xd3"]];
    if (patch == nil) {
        return false;
    }
    std::vector<uint8_t> output(file->size() * 2 + patch.length);
    size_t outputSize = 0;
    const int result = xd3_decode_memory(static_cast<const uint8_t *>(patch.bytes), patch.length,
                                         file->data(), file->size(), output.data(), &outputSize,
                                         output.size(), 0);
    if (result != 0) {
        return false;
    }
    output.resize(outputSize);
    *file = std::move(output);
    return true;
}

// parse_text_json: each key is a hex text id; arrays fill consecutive ids.
bool ApplyCustomText(NSString *resource, jak1::GameTextBank *bank) {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:resource withExtension:@"json"]];
    NSDictionary *json = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        return false;
    }
    for (NSString *key in json) {
        int lineId = static_cast<int>(strtol(key.UTF8String, nullptr, 16));
        id value = json[key];
        NSArray *lines = [value isKindOfClass:NSArray.class] ? value : @[value];
        for (id line in lines) {
            if (![line isKindOfClass:NSString.class]) {
                return false;
            }
            bank->lines[lineId++] = jak1::GameTextUtf8ToGame(static_cast<NSString *>(line).UTF8String);
        }
    }
    return true;
}

}  // namespace

@implementation Jak1PCTextBuilder

+ (NSString *)outputDirectoryName {
    return @"pc-text";
}

+ (BOOL)buildPCTextInGameDirectory:(NSURL *)gameDirectory error:(NSError **)error {
    std::map<int, jak1::GameTextBank> banks;

    // The decompiled disc text (game_text.txt), round-tripped through UTF-8 like the desktop build.
    NSURL *textDirectory = [gameDirectory URLByAppendingPathComponent:@"TEXT" isDirectory:YES];
    for (int language = 0; language < kDiscLanguageCount; language++) {
        NSString *name = [NSString stringWithFormat:@"%dCOMMON.TXT", language];
        NSData *data = [NSData dataWithContentsOfURL:[textDirectory URLByAppendingPathComponent:name]];
        if (data == nil) {
            continue;  // not every region ships every language
        }
        std::vector<uint8_t> file = BytesOf(data);
        jak1::GameTextBank bank;
        std::string parseError;
        if (!PatchDiscTextIfNeeded(language, &file) ||
            !jak1::ParseGameTextFile(file.data(), file.size(), &bank, &parseError)) {
            if (error != nullptr) {
                *error = BuilderError([NSString stringWithFormat:@"Could not read %@ (%s).", name,
                                       parseError.empty() ? "patch failed" : parseError.c_str()]);
            }
            return NO;
        }
        for (auto &[lineId, line] : bank.lines) {
            line = jak1::GameTextUtf8ToGame(jak1::GameTextGameToUtf8(line));
        }
        banks[language] = std::move(bank);
    }
    if (banks.empty()) {
        if (error != nullptr) *error = BuilderError(@"The game data has no TEXT/*COMMON.TXT files.");
        return NO;
    }

    for (const LanguageFiles &language : kLanguageFiles) {
        jak1::GameTextBank &bank = banks[language.languageId];
        bank.languageId = language.languageId;
        bank.group = "common";
        for (const char *resource : language.resources) {
            if (!ApplyCustomText(@(resource), &bank)) {
                if (error != nullptr) {
                    *error = BuilderError([NSString stringWithFormat:@"Missing bundled text %s.json.", resource]);
                }
                return NO;
            }
        }
    }

    // The trademark glyph (font code 0x1 0xb1, e.g. after the intro title "THE PRECURSOR LEGACY™")
    // has no image in the font texture here and renders as an empty box, so drop it.
    const std::string trademark = "\x1\xb1";
    for (auto &[language, bank] : banks) {
        for (auto &[lineId, line] : bank.lines) {
            for (size_t pos = line.find(trademark); pos != std::string::npos; pos = line.find(trademark, pos)) {
                line.erase(pos, trademark.size());
            }
        }
    }

    NSURL *output = [gameDirectory URLByAppendingPathComponent:self.outputDirectoryName isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:output withIntermediateDirectories:YES
                                                 attributes:nil error:error]) {
        return NO;
    }
    for (const auto &[language, bank] : banks) {
        const std::vector<uint8_t> file = jak1::WriteGameTextFile(bank);
        NSData *data = [NSData dataWithBytes:file.data() length:file.size()];
        NSURL *url = [output URLByAppendingPathComponent:[NSString stringWithFormat:@"%dCOMMON.TXT", language]];
        if (![data writeToURL:url options:NSDataWritingAtomic error:error]) {
            return NO;
        }
    }
    return YES;
}

@end
