#include "Jak1GameText.h"

#include <algorithm>
#include <cstring>

namespace jak1 {
namespace {

// common/link_types.h LinkHeaderV2.
struct LinkHeaderV2 {
    uint32_t typeTag;  // always -1
    uint32_t length;   // header + link table size; the object data follows
    uint32_t version;  // always 2
};
static_assert(sizeof(LinkHeaderV2) == 12, "LinkHeaderV2 layout");

uint32_t ReadWord(const uint8_t *data, size_t offset) {
    uint32_t word = 0;
    memcpy(&word, data + offset, sizeof(word));
    return word;
}

// DataObjectGenerator encodings.
void PushVariableLengthInteger(uint32_t value, std::vector<uint8_t> *out) {
    while (value > UINT8_MAX) {
        out->push_back(UINT8_MAX);
        value -= UINT8_MAX;
    }
    if (value == UINT8_MAX) {
        out->push_back(UINT8_MAX);
        out->push_back(0);
    } else {
        out->push_back(static_cast<uint8_t>(value));
    }
}

void PushBetterVariableLengthInteger(uint32_t value, std::vector<uint8_t> *out) {
    if (value > 0xffffff) {
        out->push_back((value & 0xff) | 3);
        out->push_back((value >> 8) & 0xff);
        out->push_back((value >> 16) & 0xff);
        out->push_back((value >> 24) & 0xff);
    } else if (value > 0xffff) {
        out->push_back((value & 0xff) | 2);
        out->push_back((value >> 8) & 0xff);
        out->push_back((value >> 16) & 0xff);
    } else if (value > 0xff) {
        out->push_back((value & 0xff) | 1);
        out->push_back((value >> 8) & 0xff);
    } else {
        out->push_back(value & 0xff);
    }
}

// The subset of DataObjectGenerator used by compile_text (no symbol links).
class DataObjectGenerator {
public:
    int addWord(uint32_t word) {
        _words.push_back(word);
        return static_cast<int>(_words.size()) - 1;
    }
    void addTypeTag(const std::string &name) { _typeLinks[name].push_back(addWord(0)); }
    void addRefToStringInPool(const std::string &text) { _stringPool[text].push_back(addWord(0)); }

    std::vector<uint8_t> generateV2() {
        addStrings();
        const std::vector<uint8_t> link = generateLinkTable();

        const LinkHeaderV2 header {0xffffffff, static_cast<uint32_t>(sizeof(LinkHeaderV2) + link.size()), 2};
        std::vector<uint8_t> result(sizeof(header));
        memcpy(result.data(), &header, sizeof(header));
        result.insert(result.end(), link.begin(), link.end());
        const size_t start = result.size();
        result.resize(start + _words.size() * 4);
        memcpy(result.data() + start, _words.data(), _words.size() * 4);
        while (result.size() % 16) {
            result.push_back(0);
        }
        return result;
    }

private:
    struct PointerLink {
        int sourceWord;
        int targetByte;
    };

    void align(size_t words) {
        while (_words.size() % words) {
            _words.push_back(0);
        }
    }

    // Each pooled string becomes one GOAL `string` basic; every reference points at it.
    void addStrings() {
        for (const auto &[text, sources] : _stringPool) {
            align(4);
            addTypeTag("string");
            const int targetWord = addWord(static_cast<uint32_t>(text.length()));
            std::vector<uint8_t> buffer(text.begin(), text.end());
            buffer.push_back(0);
            while (buffer.size() & 3) {
                buffer.push_back(0);
            }
            for (size_t i = 0; i < buffer.size(); i += 4) {
                addWord(ReadWord(buffer.data(), i));
            }
            for (int source : sources) {
                _pointerLinks.push_back({source, targetWord * 4});
            }
        }
    }

    std::vector<uint8_t> generateLinkTable() {
        std::vector<uint8_t> link;
        std::sort(_pointerLinks.begin(), _pointerLinks.end(),
                  [](const PointerLink &a, const PointerLink &b) { return a.sourceWord < b.sourceWord; });

        // Pointer links: runs of consecutive words, each as (words skipped, run length).
        size_t i = 0;
        uint32_t lastWord = 0;
        while (i < _pointerLinks.size()) {
            const PointerLink &entry = _pointerLinks[i];
            PushVariableLengthInteger(static_cast<uint32_t>(entry.sourceWord) - lastWord, &link);
            lastWord = static_cast<uint32_t>(entry.sourceWord) + 1;
            _words[entry.sourceWord] = static_cast<uint32_t>(entry.targetByte);
            uint32_t consecutive = 1;
            while (i + 1 < _pointerLinks.size() &&
                   _pointerLinks[i + 1].sourceWord == _pointerLinks[i].sourceWord + 1) {
                _words[_pointerLinks[i + 1].sourceWord] = static_cast<uint32_t>(_pointerLinks[i + 1].targetByte);
                lastWord = static_cast<uint32_t>(_pointerLinks[i + 1].sourceWord) + 1;
                consecutive++;
                i++;
            }
            PushVariableLengthInteger(consecutive, &link);
            i++;
        }
        PushVariableLengthInteger(0, &link);

        // Type links: 0x80, name, then byte deltas to each tagged word.
        for (auto &[name, sources] : _typeLinks) {
            link.push_back(0x80);
            link.insert(link.end(), name.begin(), name.end());
            link.push_back(0);
            std::sort(sources.begin(), sources.end());
            int previous = 0;
            for (int source : sources) {
                PushBetterVariableLengthInteger(static_cast<uint32_t>(source - previous) * 4, &link);
                _words[source] = 0xffffffff;
                previous = source;
            }
            link.push_back(0);
        }
        PushVariableLengthInteger(0, &link);

        while ((link.size() + sizeof(LinkHeaderV2)) % 64) {
            link.push_back(0);
        }
        return link;
    }

    std::vector<uint32_t> _words;
    std::vector<PointerLink> _pointerLinks;
    std::map<std::string, std::vector<int>> _stringPool;
    std::map<std::string, std::vector<int>> _typeLinks;
};

}  // namespace

bool ParseGameTextFile(const uint8_t *bytes, size_t size, GameTextBank *bank, std::string *error) {
    auto fail = [error](const char *message) {
        if (error != nullptr) *error = message;
        return false;
    };
    if (bytes == nullptr || bank == nullptr || size < sizeof(LinkHeaderV2)) {
        return fail("file is too small");
    }
    LinkHeaderV2 header {};
    memcpy(&header, bytes, sizeof(header));
    if (header.typeTag != 0xffffffff || header.version != 2 || header.length > size) {
        return fail("not a v2 GOAL object");
    }
    // Pointer words in the unlinked data hold byte offsets from the start of the data.
    const uint8_t *data = bytes + header.length;
    const size_t dataSize = size - header.length;
    auto word = [&](size_t index, uint32_t *value) {
        if ((index + 1) * 4 > dataSize) return false;
        *value = ReadWord(data, index * 4);
        return true;
    };
    // `string` basic: length word, then the characters.
    auto string = [&](uint32_t offset, std::string *value) {
        if (offset < 4 || offset + 4 > dataSize) return false;
        const uint32_t length = ReadWord(data, offset);
        if (length > dataSize - offset - 4) return false;
        value->assign(reinterpret_cast<const char *>(data + offset + 4), length);
        return true;
    };

    // game-text-info: type tag, length, language-id, group-name, then (id, text) pairs.
    uint32_t count = 0, language = 0, groupOffset = 0;
    if (!word(1, &count) || !word(2, &language) || !word(3, &groupOffset) ||
        !string(groupOffset, &bank->group)) {
        return fail("truncated game-text-info header");
    }
    bank->languageId = static_cast<int>(language);
    bank->lines.clear();
    for (uint32_t i = 0; i < count; i++) {
        uint32_t id = 0, textOffset = 0;
        std::string text;
        if (!word(4 + i * 2, &id) || !word(5 + i * 2, &textOffset) || !string(textOffset, &text)) {
            return fail("truncated game-text entry");
        }
        bank->lines[static_cast<int>(id)] = text;
    }
    return true;
}

std::vector<uint8_t> WriteGameTextFile(const GameTextBank &bank) {
    DataObjectGenerator gen;
    gen.addTypeTag("game-text-info");
    gen.addWord(static_cast<uint32_t>(bank.lines.size()));
    gen.addWord(static_cast<uint32_t>(bank.languageId));
    gen.addRefToStringInPool(bank.group);
    for (const auto &[id, line] : bank.lines) {
        gen.addWord(static_cast<uint32_t>(id));
        // Pooled so duplicate strings are stored once, as in compile_text.
        gen.addRefToStringInPool(line);
    }
    return gen.generateV2();
}

}  // namespace jak1
