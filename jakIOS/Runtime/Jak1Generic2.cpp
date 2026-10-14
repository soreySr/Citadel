#include "Jak1Generic2.h"

#include <cstring>

namespace jak1 {
namespace {

// VIF command kinds (UNPACK kinds have the mask bit stripped).
constexpr uint32_t kVifNop = 0x00;
constexpr uint32_t kVifStcycl = 0x01;
constexpr uint32_t kVifOffset = 0x02;
constexpr uint32_t kVifBase = 0x03;
constexpr uint32_t kVifStmod = 0x05;
constexpr uint32_t kVifMark = 0x07;
constexpr uint32_t kVifFlushe = 0x10;
constexpr uint32_t kVifFlush = 0x11;
constexpr uint32_t kVifFlusha = 0x13;
constexpr uint32_t kVifMscal = 0x14;
constexpr uint32_t kVifMscalf = 0x15;
constexpr uint32_t kVifDirect = 0x50;
constexpr uint32_t kVifUnpackV2_16 = 0x65;
constexpr uint32_t kVifUnpackV3_32 = 0x68;
constexpr uint32_t kVifUnpackV4_32 = 0x6c;
constexpr uint32_t kVifUnpackV4_8 = 0x6e;

constexpr uint32_t kFragHeaderSize = 16 * 7;
constexpr uint32_t kAdgifSize = 16 * 5;

// GS register addresses that appear in generic adgif data.
constexpr uint8_t kGsTex0_1 = 0x06;
constexpr uint8_t kGsTex1_1 = 0x14;
constexpr uint8_t kGsAlpha_1 = 0x42;
constexpr uint8_t kGsTest_1 = 0x47;
constexpr uint8_t kGsZbuf_1 = 0x4e;

// DrawMode::AlphaBlend values.
constexpr uint8_t kBlendSrcDstSrcDst = 1;
constexpr uint8_t kBlendSrc0SrcDst = 2;
constexpr uint8_t kBlendSrc0FixDst = 3;
constexpr uint8_t kBlendSrcDstFixDst = 4;
constexpr uint8_t kBlendZeroSrcSrcDst = 5;
constexpr uint8_t kBlendSrcSrcSrcSrc = 6;
constexpr uint8_t kBlendSrc0DstDst = 7;

// GS TEST alpha test methods used by generic.
constexpr uint32_t kAtstNever = 0;
constexpr uint32_t kAtstGequal = 5;
constexpr uint32_t kAfailFbOnly = 1;

constexpr uint32_t kPsmPsmt4hh = 0x2c;

// GS ALPHA blend inputs.
constexpr uint32_t kBlendSource = 0;
constexpr uint32_t kBlendDest = 1;
constexpr uint32_t kBlendZeroOrFixed = 2;

uint32_t VifKind(uint32_t word) {
    const uint32_t cmd = (word >> 24) & 0x7f;
    return (cmd & 0x60) == 0x60 ? (cmd & 0x6f) : cmd;
}

uint32_t VifNum(uint32_t word) { return (word >> 16) & 0xff; }
uint32_t VifImmediate(uint32_t word) { return word & 0xffff; }

struct AdgifData {
    uint64_t tex0Data, tex0Addr;
    uint64_t tex1Data, tex1Addr;
    uint64_t mipData, mipAddr;
    uint64_t clampData, clampAddr;
    uint64_t alphaData, alphaAddr;
};
static_assert(sizeof(AdgifData) == kAdgifSize, "adgif is five quadwords");

struct Fragment {
    uint8_t header[kFragHeaderSize];
    uint32_t adgifIndex = 0;
    uint32_t adgifCount = 0;
    uint32_t vertexIndex = 0;
    uint32_t vertexCount = 0;
    bool usesHud = false;
    // Continued fragments are only usable once their positions arrive in the next transfer.
    bool complete = false;
};

// Accumulates one generic bucket, from its constants packet until the data stops
// matching the generic protocol.
struct BucketState {
    bool active = false;
    size_t traceOffset = 0;
    bool zmsk = false;
    Generic2Projection constants;
    std::vector<Fragment> fragments;
    std::vector<AdgifData> adgifs;
    int continuedFragment = -1;
};

class VifReader {
public:
    VifReader(const uint8_t *data, uint32_t length) : _data(data), _length(length) {}

    bool word(uint32_t offset, uint32_t *value) const {
        if (offset + 4 > _length) {
            return false;
        }
        memcpy(value, _data + offset, 4);
        return true;
    }

    // Upstream skips NOPs (and optionally FLUSHE) between unpacks.
    uint32_t skipNops(uint32_t offset, bool allowFlushe) const {
        uint32_t value = 0;
        while (word(offset, &value)) {
            const uint32_t kind = VifKind(value);
            if (kind != kVifNop && !(allowFlushe && kind == kVifFlushe)) {
                break;
            }
            offset += 4;
        }
        return offset;
    }

    bool contains(uint32_t offset, uint64_t bytes) const {
        return offset <= _length && bytes <= _length - offset;
    }

    const uint8_t *at(uint32_t offset) const { return _data + offset; }
    uint32_t length() const { return _length; }

private:
    const uint8_t *_data;
    uint32_t _length;
};

void UnpackPositions(Generic2Vertex *vertices, const uint8_t *data, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        memcpy(vertices[i].xyz, data + i * 12, 12);
    }
}

void UnpackColors(Generic2Vertex *vertices, const uint8_t *data, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        memcpy(vertices[i].rgba, data + i * 4, 4);
    }
}

void UnpackTexCoords(Generic2Vertex *vertices, const uint8_t *data, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) {
        int16_t s = 0;
        int16_t t = 0;
        memcpy(&s, data + i * 4, 2);
        memcpy(&t, data + i * 4 + 2, 2);
        // The low bit of S is the ADC flag: when set, the vertex does not draw a triangle.
        const int16_t sMasked = static_cast<int16_t>(s & static_cast<int16_t>(0xfffe));
        vertices[i].st[0] = sMasked;
        vertices[i].st[1] = t;
        vertices[i].adc = sMasked == s;
    }
}

// Port of Generic2::handle_fragments_after_unpack_v4_32. Returns false (with a reason)
// instead of asserting when the data does not follow the generic protocol.
bool ParseFragment(const VifReader &vif,
                   uint32_t offset,
                   uint32_t firstUnpackBytes,
                   bool loop,
                   Fragment *fragment,
                   BucketState *bucket,
                   std::vector<Generic2Vertex> *vertices,
                   uint32_t *endOffset,
                   const char **reason) {
    const uint32_t end = vif.length();
    const uint32_t alignedOffset = (offset + 15) & ~15u;
    if (firstUnpackBytes < kFragHeaderSize + kAdgifSize ||
        !vif.contains(alignedOffset, firstUnpackBytes)) {
        *reason = "fragment header upload is truncated";
        return false;
    }
    const uint32_t adgifBytes = firstUnpackBytes - kFragHeaderSize;
    if (adgifBytes % kAdgifSize != 0) {
        *reason = "fragment header is not followed by whole adgifs";
        return false;
    }
    memcpy(fragment->header, vif.at(alignedOffset), kFragHeaderSize);
    fragment->adgifIndex = static_cast<uint32_t>(bucket->adgifs.size());
    fragment->adgifCount = adgifBytes / kAdgifSize;
    for (uint32_t i = 0; i < fragment->adgifCount; i++) {
        AdgifData adgif {};
        memcpy(&adgif, vif.at(alignedOffset + kFragHeaderSize + i * kAdgifSize), kAdgifSize);
        bucket->adgifs.push_back(adgif);
    }

    // Matches upstream: for continued fragments `offset` points at the UNPACK code, so this
    // lands on the last word of the final adgif, which the NOP skip below steps over.
    offset += firstUnpackBytes;
    offset = vif.skipNops(offset, false);

    uint32_t code = 0;
    if (!vif.word(offset, &code) || VifKind(code) != kVifStcycl || VifImmediate(code) != 0x103) {
        *reason = "expected STCYCL 0x103 before vertex data";
        return false;
    }
    offset += 4;

    if (!vif.word(offset, &code)) {
        *reason = "fragment ends before vertex data";
        return false;
    }
    if (VifKind(code) == kVifUnpackV4_8) {
        if (!loop) {
            *reason = "vertex colors arrived before positions";
            return false;
        }
    } else {
        if (loop || VifKind(code) != kVifUnpackV3_32 || VifNum(code) == 0) {
            *reason = "expected UNPACK V3-32 vertex positions";
            return false;
        }
        offset += 4;
        fragment->vertexIndex = static_cast<uint32_t>(vertices->size());
        fragment->vertexCount = VifNum(code);
        if (!vif.contains(offset, fragment->vertexCount * 12ull)) {
            *reason = "vertex positions are truncated";
            return false;
        }
        vertices->resize(vertices->size() + fragment->vertexCount);
        UnpackPositions(vertices->data() + fragment->vertexIndex, vif.at(offset), fragment->vertexCount);
        offset += fragment->vertexCount * 12;
        offset = vif.skipNops(offset, false);
    }

    // Vertex colors.
    if (!vif.word(offset, &code) || VifKind(code) != kVifUnpackV4_8) {
        *reason = "expected UNPACK V4-8 vertex colors";
        return false;
    }
    offset += 4;
    if (loop) {
        if (VifNum(code) == 0) {
            *reason = "continued fragment has no vertices";
            return false;
        }
        fragment->vertexIndex = static_cast<uint32_t>(vertices->size());
        fragment->vertexCount = VifNum(code);
        vertices->resize(vertices->size() + fragment->vertexCount);
    } else if (VifNum(code) != fragment->vertexCount) {
        *reason = "vertex color count does not match positions";
        return false;
    }
    if (!vif.contains(offset, fragment->vertexCount * 4ull)) {
        *reason = "vertex colors are truncated";
        return false;
    }
    UnpackColors(vertices->data() + fragment->vertexIndex, vif.at(offset), fragment->vertexCount);
    offset += fragment->vertexCount * 4;
    offset = vif.skipNops(offset, false);

    // Texture coordinates.
    if (!vif.word(offset, &code) || VifKind(code) != kVifUnpackV2_16 ||
        VifNum(code) != fragment->vertexCount) {
        *reason = "expected UNPACK V2-16 texture coordinates";
        return false;
    }
    offset += 4;
    if (!vif.contains(offset, fragment->vertexCount * 4ull)) {
        *reason = "texture coordinates are truncated";
        return false;
    }
    UnpackTexCoords(vertices->data() + fragment->vertexIndex, vif.at(offset), fragment->vertexCount);
    offset += fragment->vertexCount * 4;
    if (offset == end) {
        *endOffset = offset;
        return true;
    }

    // STCYCL reset and MSCAL, in either order.
    offset = vif.skipNops(offset, false);
    if (!vif.word(offset, &code)) {
        *reason = "fragment ends before MSCAL";
        return false;
    }
    offset += 4;
    const uint32_t expectedNext = VifKind(code) == kVifStcycl ? kVifMscal :
        VifKind(code) == kVifMscal ? kVifStcycl : UINT32_MAX;
    if (expectedNext == UINT32_MAX) {
        *reason = "expected STCYCL/MSCAL after fragment";
        return false;
    }
    offset = vif.skipNops(offset, false);
    if (!vif.word(offset, &code) || VifKind(code) != expectedNext) {
        *reason = "fragment is missing its MSCAL";
        return false;
    }
    offset += 4;
    *endOffset = vif.skipNops(offset, true);
    return true;
}

// GS state resolved for one adgif; adgifs with equal settings share a batch.
struct DrawSettings {
    uint32_t tbp = UINT32_MAX;
    uint8_t blend = kBlendSrcSrcSrcSrc;
    uint8_t fix = 0;
    uint8_t vertexFlags = 0;
    bool filter = true;
    bool clampS = false;
    bool clampT = false;
    bool depthWrite = true;
    float alphaReject = 0;

    bool operator==(const DrawSettings &other) const {
        return tbp == other.tbp && blend == other.blend && fix == other.fix &&
            vertexFlags == other.vertexFlags && filter == other.filter &&
            clampS == other.clampS && clampT == other.clampT &&
            depthWrite == other.depthWrite && alphaReject == other.alphaReject;
    }
};

// Port of Generic2::determine_draw_modes: tracks the GS state that carries over between
// adgifs (alpha and test registers persist until an adgif overrides them).
class DrawModeTracker {
public:
    DrawModeTracker(bool zmsk) {
        // setup_draws(enable_at = true, default_fog = true) for Jak 1 NORMAL buckets.
        _alphaTestEnable = true;
        _alphaTest = kAtstGequal;
        _aref = 0x26;
        _alphaFail = kAfailFbOnly;
        _settings.depthWrite = !zmsk;
        _settings.vertexFlags = kGeneric2FlagFog;
    }

    DrawSettings update(const AdgifData &adgif, const uint8_t *fragmentHeader) {
        // The fragment's giftag may set fogging through PRIM.FGE.
        uint64_t tag = 0;
        memcpy(&tag, fragmentHeader + 4 * 16, sizeof(tag));
        if ((tag >> 46) & 1) {
            setFlag(kGeneric2FlagFog, ((tag >> 52) & 1) != 0);
        }

        if (!_haveTex0 || adgif.tex0Data != _tex0) {
            _haveTex0 = true;
            _tex0 = adgif.tex0Data;
            _settings.tbp = static_cast<uint32_t>(_tex0 & 0x3fff);
            if (((_tex0 >> 20) & 0x3f) == kPsmPsmt4hh) {
                _settings.tbp |= 0x8000;
            }
            setFlag(kGeneric2FlagTcc, ((_tex0 >> 34) & 1) != 0);
            setFlag(kGeneric2FlagDecal, ((_tex0 >> 35) & 3) == 1);
        }
        _settings.filter = ((adgif.tex1Data >> 5) & 1) != 0;
        _settings.clampS = (adgif.clampData & 0b001) != 0;
        _settings.clampT = (adgif.clampData & 0b100) != 0;

        bool haveAlpha = false;
        uint64_t alpha = 0;
        bool haveTest = false;
        uint64_t test = 0;
        if (static_cast<uint8_t>(adgif.alphaAddr) == kGsAlpha_1) {
            haveAlpha = true;
            alpha = adgif.alphaData;
        }
        // Extra adgif registers live in the fragment header after the giftag.
        uint64_t bonus[4];
        memcpy(bonus, fragmentHeader + 5 * 16, sizeof(bonus));
        if (static_cast<uint8_t>(bonus[1]) == kGsAlpha_1) {
            haveAlpha = true;
            alpha = bonus[0];
            if (static_cast<uint8_t>(bonus[3]) == kGsTest_1) {
                haveTest = true;
                test = bonus[2];
            }
        } else {
            if (static_cast<uint8_t>(bonus[1]) == kGsTest_1) {
                haveTest = true;
                test = bonus[0];
            }
            if (static_cast<uint8_t>(bonus[3]) == kGsAlpha_1) {
                haveAlpha = true;
                alpha = bonus[2];
            } else if (static_cast<uint8_t>(bonus[3]) == kGsTest_1) {
                haveTest = true;
                test = bonus[2];
            }
        }

        if (haveAlpha && (!_haveAlpha || alpha != _alpha)) {
            _haveAlpha = true;
            _alpha = alpha;
            const uint32_t a = alpha & 3;
            const uint32_t b = (alpha >> 2) & 3;
            const uint32_t c = (alpha >> 4) & 3;
            const uint32_t d = (alpha >> 6) & 3;
            _settings.fix = static_cast<uint8_t>(alpha >> 32);
            if (a == kBlendSource && b == kBlendDest && c == kBlendSource && d == kBlendDest) {
                _settings.blend = kBlendSrcDstSrcDst;
            } else if (a == kBlendSource && b == kBlendZeroOrFixed && c == kBlendSource && d == kBlendDest) {
                _settings.blend = kBlendSrc0SrcDst;
            } else if (a == kBlendZeroOrFixed && b == kBlendSource && c == kBlendSource && d == kBlendDest) {
                _settings.blend = kBlendZeroSrcSrcDst;
            } else if (a == kBlendSource && b == kBlendDest && c == kBlendZeroOrFixed && d == kBlendDest) {
                _settings.blend = kBlendSrcDstFixDst;
            } else if (a == kBlendSource && b == kBlendSource && c == kBlendSource && d == kBlendSource) {
                _settings.blend = kBlendSrcSrcSrcSrc;
            } else if (a == kBlendSource && b == kBlendZeroOrFixed && c == kBlendDest && d == kBlendDest) {
                _settings.blend = kBlendSrc0DstDst;
            } else if (a == kBlendSource && b == kBlendZeroOrFixed && c == kBlendZeroOrFixed && d == kBlendDest) {
                _settings.blend = kBlendSrc0FixDst;
            }
        }

        if (haveTest) {
            _alphaTestEnable = (test & 1) != 0;
            if (_alphaTestEnable) {
                _alphaTest = (test >> 1) & 7;
            }
            _aref = static_cast<uint8_t>(test >> 4);
            _alphaFail = (test >> 12) & 3;
            // Tricks some effects use to disable z writes; Generic2 maps them to ALWAYS.
            if (_alphaFail == kAfailFbOnly && _aref == 0x80 && _alphaTest == kAtstGequal) {
                _alphaTest = 1;
                _settings.depthWrite = false;
            }
            if (_alphaTest == kAtstNever && _alphaFail == kAfailFbOnly) {
                _alphaTest = 1;
                _settings.depthWrite = false;
            }
        }
        _settings.alphaReject = _alphaTestEnable && _alphaTest == kAtstGequal ? _aref / 128.0f : 0.0f;
        return _settings;
    }

private:
    void setFlag(uint8_t flag, bool value) {
        _settings.vertexFlags = value ? (_settings.vertexFlags | flag) : (_settings.vertexFlags & ~flag);
    }

    DrawSettings _settings;
    bool _haveTex0 = false;
    uint64_t _tex0 = 0;
    bool _haveAlpha = false;
    uint64_t _alpha = 0;
    bool _alphaTestEnable = true;
    uint32_t _alphaTest = kAtstGequal;
    uint8_t _aref = 0;
    uint32_t _alphaFail = 0;
};

// Order in which Generic2::do_draws issues the world draws of each blend mode.
int BlendDrawOrder(uint8_t blend) {
    switch (blend) {
        case kBlendSrc0FixDst: return 0;
        case kBlendSrcSrcSrcSrc: return 1;
        case kBlendSrcDstSrcDst: return 2;
        case kBlendSrc0SrcDst: return 3;
        case kBlendZeroSrcSrcDst: return 4;
        case kBlendSrcDstFixDst: return 5;
        case kBlendSrc0DstDst: return 6;
        default: return 7;
    }
}

// Port of Generic2::process_matrices, link_adgifs_back_to_frags, determine_draw_modes,
// draws_to_buckets, and build_index_buffer.
void FinishBucket(BucketState *bucket, Generic2Frame *frame) {
    if (!bucket->active) {
        return;
    }
    bucket->active = false;
    if (bucket->continuedFragment >= 0) {
        frame->rejectedTransfers++;
        if (frame->firstRejection.empty()) {
            frame->firstRejection = "continued fragment never received its positions";
        }
    }
    bucket->continuedFragment = -1;
    frame->bucketCount++;

    auto matrixElement = [](const Fragment &fragment, uint32_t row, uint32_t column) {
        float value = 0;
        memcpy(&value, fragment.header + (row * 4 + column) * sizeof(float), sizeof(float));
        return value;
    };

    // A projection matrix has m[3][3] == 0; HUD fragments use an orthographic matrix.
    Generic2Projection world = bucket->constants;
    Generic2Projection hud = bucket->constants;
    bool foundWorld = false;
    bool foundHud = false;
    for (Fragment &fragment : bucket->fragments) {
        Generic2Projection *target = nullptr;
        fragment.usesHud = matrixElement(fragment, 3, 3) != 0;
        if (!fragment.usesHud && !foundWorld) {
            foundWorld = true;
            target = &world;
        } else if (fragment.usesHud && !foundHud) {
            foundHud = true;
            target = &hud;
        }
        if (target != nullptr) {
            target->scale[0] = matrixElement(fragment, 0, 0);
            target->scale[1] = matrixElement(fragment, 1, 1);
            target->scale[2] = matrixElement(fragment, 2, 2);
            target->mat23 = matrixElement(fragment, 2, 3);
            target->mat32 = matrixElement(fragment, 3, 2);
            target->mat33 = fragment.usesHud ? matrixElement(fragment, 3, 3) : 0;
        }
    }

    // Group adgif strips by draw settings. HUD draws each get their own group, like
    // Generic2::draws_to_buckets.
    struct Strip {
        uint32_t first;
        uint32_t count;
    };
    struct DrawGroup {
        DrawSettings settings;
        bool usesHud = false;
        std::vector<Strip> strips;
    };
    std::vector<DrawGroup> groups;
    DrawModeTracker tracker(bucket->zmsk);
    for (const Fragment &fragment : bucket->fragments) {
        for (uint32_t i = 0; i < fragment.adgifCount; i++) {
            const AdgifData &adgif = bucket->adgifs[fragment.adgifIndex + i];
            if (static_cast<uint8_t>(adgif.tex0Addr) != kGsTex0_1 ||
                static_cast<uint8_t>(adgif.tex1Addr) != kGsTex1_1) {
                continue;
            }
            const DrawSettings settings = tracker.update(adgif, fragment.header);
            if (!fragment.complete) {
                continue;
            }
            // The VU program stores the strip's length and start in the adgif's unused
            // address bits.
            const uint32_t count = static_cast<uint32_t>((adgif.tex1Addr >> 32) & 0xfff);
            const uint32_t start = static_cast<uint32_t>(((adgif.tex0Addr >> 32) & 0xffff) / 3);
            if (count == 0 || start + count > fragment.vertexCount) {
                continue;
            }
            frame->adgifCount++;
            const uint32_t first = fragment.vertexIndex + start;
            for (uint32_t vertex = first; vertex < first + count; vertex++) {
                frame->vertices[vertex].flags = settings.vertexFlags;
            }
            DrawGroup *group = nullptr;
            if (!fragment.usesHud) {
                for (DrawGroup &existing : groups) {
                    if (!existing.usesHud && existing.settings == settings) {
                        group = &existing;
                        break;
                    }
                }
            }
            if (group == nullptr) {
                groups.push_back(DrawGroup {settings, fragment.usesHud, {}});
                group = &groups.back();
            }
            group->strips.push_back({first, count});
        }
    }

    // World draws are issued by blend mode, then the HUD draws in submission order.
    std::stable_sort(groups.begin(), groups.end(), [](const DrawGroup &a, const DrawGroup &b) {
        if (a.usesHud != b.usesHud) {
            return !a.usesHud;
        }
        return !a.usesHud && BlendDrawOrder(a.settings.blend) < BlendDrawOrder(b.settings.blend);
    });

    for (const DrawGroup &group : groups) {
        Generic2Batch batch;
        batch.traceOffset = bucket->traceOffset;
        batch.firstIndex = static_cast<uint32_t>(frame->indices.size());
        batch.usesHud = group.usesHud;
        batch.depthWrite = group.settings.depthWrite;
        batch.tbp = group.settings.tbp;
        batch.blend = group.settings.blend;
        batch.fix = group.settings.fix;
        batch.filter = group.settings.filter;
        batch.clampS = group.settings.clampS;
        batch.clampT = group.settings.clampT;
        batch.alphaReject = group.settings.alphaReject;
        batch.projection = group.usesHud ? hud : world;
        for (const Strip &strip : group.strips) {
            frame->indices.push_back(UINT32_MAX);
            for (uint32_t vertex = strip.first; vertex < strip.first + strip.count; vertex++) {
                if (frame->vertices[vertex].adc || vertex == strip.first) {
                    frame->indices.push_back(vertex);
                } else {
                    // ADC vertex: restart the strip from the previous vertex.
                    frame->indices.push_back(UINT32_MAX);
                    frame->indices.push_back(vertex - 1);
                    frame->indices.push_back(vertex);
                }
            }
        }
        batch.indexCount = static_cast<uint32_t>(frame->indices.size()) - batch.firstIndex;
        if (batch.indexCount > 0) {
            frame->batches.push_back(batch);
        }
    }
    bucket->fragments.clear();
    bucket->adgifs.clear();
}

void Reject(BucketState *bucket, Generic2Frame *frame, const char *reason) {
    frame->rejectedTransfers++;
    if (frame->firstRejection.empty()) {
        frame->firstRejection = reason;
    }
    FinishBucket(bucket, frame);
}

// Handles a STCYCL + UNPACK V4-32 transfer that carries one fragment and optionally the
// start of a second fragment whose positions arrive in the following transfer.
bool ParseFragmentTransfer(const VifReader &vif,
                           uint32_t vif1,
                           BucketState *bucket,
                           Generic2Frame *frame,
                           const char **reason) {
    const size_t vertexRollback = frame->vertices.size();
    const size_t adgifRollback = bucket->adgifs.size();
    const size_t fragmentRollback = bucket->fragments.size();
    auto rollback = [&]() {
        frame->vertices.resize(vertexRollback);
        bucket->adgifs.resize(adgifRollback);
        bucket->fragments.resize(fragmentRollback);
    };

    Fragment fragment {};
    uint32_t offset = 0;
    if (!ParseFragment(vif, 0, VifNum(vif1) * 16, false, &fragment, bucket, &frame->vertices,
                       &offset, reason)) {
        rollback();
        return false;
    }
    fragment.complete = true;
    bucket->fragments.push_back(fragment);
    frame->fragmentCount++;

    if (offset < vif.length()) {
        uint32_t code = 0;
        if (!vif.word(offset, &code) || VifKind(code) != kVifStcycl) {
            *reason = "expected STCYCL before continued fragment";
            rollback();
            return false;
        }
        offset += 4;
        if (!vif.word(offset, &code) || VifKind(code) != kVifUnpackV4_32) {
            *reason = "expected UNPACK V4-32 for continued fragment";
            rollback();
            return false;
        }
        Fragment continued {};
        if (!ParseFragment(vif, offset, VifNum(code) * 16, true, &continued, bucket,
                           &frame->vertices, &offset, reason)) {
            rollback();
            return false;
        }
        bucket->continuedFragment = static_cast<int>(bucket->fragments.size());
        bucket->fragments.push_back(continued);
        frame->fragmentCount++;
    }
    return true;
}

} // namespace

void DecodeGeneric2Jak1(const uint8_t *trace, size_t length, Generic2Frame *frame) {
    if (trace == nullptr || frame == nullptr) {
        return;
    }
    BucketState bucket;
    bool lastSetupHadZmsk = false;
    size_t offset = 0;
    while (offset + 16 <= length) {
        uint64_t tag = 0;
        uint32_t vif0 = 0;
        uint32_t vif1 = 0;
        memcpy(&tag, trace + offset, sizeof(tag));
        memcpy(&vif0, trace + offset + 8, sizeof(vif0));
        memcpy(&vif1, trace + offset + 12, sizeof(vif1));
        const size_t payloadLength = static_cast<size_t>(tag & 0xffff) * 16;
        if (payloadLength > length - offset - 16) {
            break;
        }
        const uint8_t *payload = trace + offset + 16;
        const uint32_t kind0 = VifKind(vif0);
        const uint32_t kind1 = VifKind(vif1);
        const bool previousWasZbufSetup = lastSetupHadZmsk;
        lastSetupHadZmsk = false;

        if (payloadLength == 160 && kind0 == kVifStcycl && VifImmediate(vif0) == 0x404 &&
            kind1 == kVifUnpackV4_32 && VifImmediate(vif1) == 0x381 && VifNum(vif1) == 10) {
            // generic-add-constants: starts a new generic bucket.
            FinishBucket(&bucket, frame);
            bucket = BucketState();
            bucket.active = true;
            bucket.traceOffset = offset;
            bucket.zmsk = previousWasZbufSetup;
            memcpy(&bucket.constants.pfog0, payload + 0, 4);
            memcpy(&bucket.constants.fogMin, payload + 4, 4);
            memcpy(&bucket.constants.fogMax, payload + 8, 4);
            memcpy(bucket.constants.hvdfOffset, payload + 48, 16);
        } else if (kind1 == kVifDirect && payloadLength == 48) {
            // generic-init-buf's TEST/ZBUF setup immediately precedes the constants packet.
            // Only ZMSK matters (ZBUF bit 32).
            uint64_t zbufData = 0;
            uint64_t zbufAddress = 0;
            memcpy(&zbufData, payload + 32, 8);
            memcpy(&zbufAddress, payload + 40, 8);
            lastSetupHadZmsk = static_cast<uint8_t>(zbufAddress) == kGsZbuf_1 &&
                ((zbufData >> 32) & 1) != 0;
            FinishBucket(&bucket, frame);
        } else if (bucket.active) {
            const VifReader vif(payload, static_cast<uint32_t>(payloadLength));
            const char *reason = nullptr;
            if (bucket.continuedFragment >= 0) {
                Fragment &continued = bucket.fragments[bucket.continuedFragment];
                if (kind0 == kVifNop && kind1 == kVifUnpackV3_32 &&
                    VifNum(vif1) == continued.vertexCount &&
                    payloadLength >= continued.vertexCount * 12ull) {
                    UnpackPositions(frame->vertices.data() + continued.vertexIndex, payload,
                                    continued.vertexCount);
                    continued.complete = true;
                    bucket.continuedFragment = -1;
                } else if (!(payloadLength == 0 && kind0 == kVifNop && kind1 == kVifNop)) {
                    Reject(&bucket, frame, "continued fragment positions are missing");
                }
            } else if (kind0 == kVifStcycl && kind1 == kVifUnpackV4_32) {
                if (!ParseFragmentTransfer(vif, vif1, &bucket, frame, &reason)) {
                    Reject(&bucket, frame, reason);
                }
            } else {
                // Everything else that may appear inside a generic bucket: the MSCALF/STMOD
                // VU setup, per-fragment MSCAL tags, flushes, and empty NOP link tags.
                const auto allowed = [](uint32_t kind) {
                    return kind == kVifNop || kind == kVifMscal || kind == kVifMscalf ||
                        kind == kVifStmod || kind == kVifStcycl || kind == kVifBase ||
                        kind == kVifOffset || kind == kVifMark || kind == kVifFlushe ||
                        kind == kVifFlush || kind == kVifFlusha;
                };
                if (!allowed(kind0) || !allowed(kind1)) {
                    // Another renderer's data: the generic bucket has ended.
                    FinishBucket(&bucket, frame);
                }
            }
        }
        offset += 16 + payloadLength;
    }
    FinishBucket(&bucket, frame);
}

} // namespace jak1
