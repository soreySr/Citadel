#import "Jak1MetalRenderer.h"
#import "Jak1Background.h"
#import "Jak1Direct.h"
#import "Jak1Ocean.h"
#import "Jak1Shadow.h"
#import "Jak1Generic2.h"
#import "Jak1Sprite3.h"
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <unordered_map>
#include <mutex>
#include <unordered_set>
#include <vector>

struct MetalUniforms {
    simd_float4x4 projectionMatrix;
    simd_float4x4 modelViewMatrix;
    simd_float4 colorMultiplier;
    uint32_t flags;
    uint32_t pad[3];
};

struct MetalVertex {
    simd_float3 position;
    simd_float4 color;
    simd_float2 texCoord;
    simd_float3 normal;
};

// Must match Generic2Uniforms in Jak1Shaders.metal.
struct Generic2Uniforms {
    simd_float4 scale;
    simd_float4 hvdfOffset;
    simd_float4 fogConstants;
    float mat23;
    float mat32;
    float mat33;
    float colorMultiplier;
    float alphaReject;
    float pad[3];
    simd_float4 fogColor;  // rgb / 255, a = fog intensity / 255
};

struct alignas(32) MercVertex {
    float position[4];
    float normal[4];
    float weights[4];
    float texCoord[2];
    uint8_t rgba[4];
    uint8_t matrices[3];
    uint8_t pad;
};
static_assert(sizeof(MercVertex) == 64);

struct MercMatrix {
    float transform[4][4];
    float normal[3][4];
    float pad[4];
};
static_assert(sizeof(MercMatrix) == 128);

struct MercUniforms {
    float hvdfOffset[4];
    float perspective[4][4];
    float fog[4];
    float colorMultiplier;
    float pad[3];
    float fogColor[4];  // rgb / 255, a = fog intensity / 255 (merc2.frag fog_color)
};

// Default: opaque, depth write, GEQUAL z-test, no decal (DrawMode bits from common/dma/gs.h).
constexpr uint32_t kMercDefaultDrawMode = 0xf90a265d;

struct MercDraw {
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    int32_t texture = 0;
    uint32_t mode = kMercDefaultDrawMode;
    uint32_t eyeId = 0xff;  // (eye slot << 1) | right, or 0xff when not an eye (v4 assets)
};

// Accessors for the tfrag3 DrawMode bits (common/dma/gs.h).
static bool MercModeDepthWrite(uint32_t mode) { return mode & 1; }
static bool MercModeDepthTest(uint32_t mode) { return mode & (1u << 19); }
static bool MercModeBlendEnabled(uint32_t mode) { return mode & (1u << 20); }
static uint32_t MercModeAlphaBlend(uint32_t mode) { return (mode >> 24) & 0b111; }
static bool MercModeDecal(uint32_t mode) { return !(mode & (1u << 28)); }
static bool MercModeClampS(uint32_t mode) { return mode & (1u << 5); }
static bool MercModeClampT(uint32_t mode) { return mode & (1u << 23); }
static bool MercModeFilter(uint32_t mode) { return mode & (1u << 6); }

struct MercFragmentFlags {
    uint32_t decal;
    uint32_t ignoreAlpha;
};

// Merc2::kMaxBlerc: blend shape weights the game sends after PcMercFlags.
constexpr int kMercMaxBlerc = 40;
constexpr uint8_t kPcMercBitUpdateVerts = 1u << 0;
constexpr uint8_t kPcMercBitPcBlerc = 1u << 2;
constexpr uint32_t kBlercTargetIdxTerminator = UINT32_MAX;

struct MercEffect {
    std::vector<MercDraw> draws;
    // Modifiable vertex data (blend shapes / ripples). See LoadedMercLevel::Effect.
    bool hasModDraw = false;
    std::vector<MercDraw> fixDraws, modDraws;
    std::vector<MercVertex> modVertices;
    std::vector<float> blercFloats;  // 8 floats per entry: x y z pad nx ny nz pad
    std::vector<uint32_t> blercInts;
    std::vector<uint16_t> vertexLump4Addr;
    std::vector<uint8_t> fragmentMask;
    uint32_t expectVidxEnd = 0;
};

struct MercModel {
    std::string name;
    uint32_t maxBones = 0;
    std::vector<MercEffect> effects;
    uint32_t stVifAdd = 0;
    float xyzScale = 0.f;
    float stMagic = 0.f;
};

// GS VRAM block -> PC texture combo id, filled from __pc-texture-upload-now on the game thread.
// PSMT4HH copies (TexturePool::m_mt4hh_textures) use key tbp | kPsmt4hhKey; TBP0 is 14 bits.
static std::mutex gTexturePoolMutex;
static std::unordered_map<uint32_t, uint32_t> gTexturePoolVram;
constexpr uint32_t kPsmt4hhKey = 0x8000;
constexpr uint32_t kGsPsmPsmt4hh = 44;

// VRAM writes made while replaying a frame's upload packets, tagged with the packet's trace
// offset (see Jak1TexturePoolBeginTraceJournal). Only the replaying thread records, so uploads
// the game thread makes meanwhile (__pc-texture-upload-now) don't get a trace position.
struct TexturePoolJournalEntry {
    uint32_t traceOffset;
    uint32_t key;
    uint32_t comboId;
};
static std::vector<TexturePoolJournalEntry> gTexturePoolJournal;  // published; gTexturePoolMutex
static thread_local std::vector<TexturePoolJournalEntry> *tTexturePoolJournalBuilding = nullptr;
static thread_local uint32_t tTexturePoolJournalOffset = 0;

// Caller holds gTexturePoolMutex.
static void WriteTexturePoolVram(uint32_t key, uint32_t comboId) {
    gTexturePoolVram[key] = comboId;
    if (tTexturePoolJournalBuilding != nullptr) {
        tTexturePoolJournalBuilding->push_back({tTexturePoolJournalOffset, key, comboId});
    }
}

void Jak1TexturePoolSetVramSlot(uint32_t tbp, uint32_t comboId) {
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    WriteTexturePoolVram(tbp, comboId);
}

void Jak1TexturePoolRelocate(uint32_t destinationTbp, uint32_t sourceTbp, uint32_t format) {
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    auto source = gTexturePoolVram.find(sourceTbp);
    if (source == gTexturePoolVram.end()) {
        static int loggedMisses = 0;
        if (loggedMisses++ < 8) {
            NSLog(@"jakIOS: texture relocate from unknown VRAM block %u to %u (format %u)",
                  sourceTbp, destinationTbp, format);
        }
        return;
    }
    const uint32_t comboId = source->second;
    WriteTexturePoolVram(format == kGsPsmPsmt4hh ? (destinationTbp | kPsmt4hhKey) : destinationTbp, comboId);
}

void Jak1TexturePoolBeginTraceJournal(void) {
    static thread_local std::vector<TexturePoolJournalEntry> building;
    building.clear();
    tTexturePoolJournalBuilding = &building;
    tTexturePoolJournalOffset = 0;
}

void Jak1TexturePoolSetTraceJournalOffset(uint32_t traceOffset) {
    tTexturePoolJournalOffset = traceOffset;
}

void Jak1TexturePoolEndTraceJournal(void) {
    if (tTexturePoolJournalBuilding == nullptr) return;
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    gTexturePoolJournal.swap(*tTexturePoolJournalBuilding);
    tTexturePoolJournalBuilding = nullptr;
}

// The block's contents when the chain reached `traceOffset`: the last journaled write before it.
// Blocks not written earlier in this frame still hold what the previous frame left there, which
// (uploads repeating every frame) is the final layout.
bool Jak1TexturePoolLookupAtTraceOffset(size_t traceOffset, uint32_t tbp, uint32_t *comboId) {
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    for (auto entry = gTexturePoolJournal.rbegin(); entry != gTexturePoolJournal.rend(); ++entry) {
        if (entry->key == tbp && entry->traceOffset < traceOffset) {
            *comboId = entry->comboId;
            return true;
        }
    }
    auto found = gTexturePoolVram.find(tbp);
    if (found == gTexturePoolVram.end()) return false;
    *comboId = found->second;
    return true;
}

bool Jak1TexturePoolLookup(uint32_t tbp, uint32_t *comboId) {
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    auto found = gTexturePoolVram.find(tbp);
    if (found == gTexturePoolVram.end()) return false;
    *comboId = found->second;
    return true;
}

// VRAM layout at a point in the chain (see Jak1TexturePoolSaveSnapshot).
// Slots 0 / 1: sky blend of level 0 / 1; slot 2: eyes (bucket 54).
constexpr int kTexturePoolSnapshotCount = 3;
static std::unordered_map<uint32_t, uint32_t> gTexturePoolSnapshots[kTexturePoolSnapshotCount];
static bool gTexturePoolSnapshotValid[kTexturePoolSnapshotCount] = {};

void Jak1TexturePoolSaveSnapshot(int slot) {
    if (slot < 0 || slot >= kTexturePoolSnapshotCount) return;
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    gTexturePoolSnapshots[slot] = gTexturePoolVram;
    gTexturePoolSnapshotValid[slot] = true;
}

void Jak1TexturePoolClearSnapshot(int slot) {
    if (slot < 0 || slot >= kTexturePoolSnapshotCount) return;
    std::lock_guard<std::mutex> lock(gTexturePoolMutex);
    gTexturePoolSnapshotValid[slot] = false;
}

// Falls back to the frame's final layout when the snapshot wasn't taken.
bool Jak1TexturePoolLookupInSnapshot(int slot, uint32_t tbp, uint32_t *comboId) {
    {
        std::lock_guard<std::mutex> lock(gTexturePoolMutex);
        if (slot >= 0 && slot < kTexturePoolSnapshotCount && gTexturePoolSnapshotValid[slot]) {
            auto found = gTexturePoolSnapshots[slot].find(tbp);
            if (found == gTexturePoolSnapshots[slot].end()) return false;
            *comboId = found->second;
            return true;
        }
    }
    return Jak1TexturePoolLookup(tbp, comboId);
}

// pc-set-letterbox size, packed (width << 32 | height) so the render thread never sees a torn pair.
// 0 until the game's pc-settings first runs, which means "fill the drawable" (fit to screen).
static std::atomic<uint64_t> gLetterboxSize{0};

static std::atomic<bool> gBoatFadeActive{false};
static std::atomic<float> gBoatFadeAlpha{1.0f};
static std::atomic<float> gBoatFadeGlow{0.0f};

void Jak1RendererSetBoatFade(bool active, float alpha, float glow) {
    gBoatFadeAlpha.store(alpha, std::memory_order_relaxed);
    gBoatFadeGlow.store(glow, std::memory_order_relaxed);
    gBoatFadeActive.store(active, std::memory_order_relaxed);
}

void Jak1RendererSetLetterbox(int32_t width, int32_t height) {
    const uint64_t w = static_cast<uint32_t>(std::max(width, 0));
    const uint64_t h = static_cast<uint32_t>(std::max(height, 0));
    gLetterboxSize.store((w << 32) | h, std::memory_order_relaxed);
}

void Jak1RendererGetLetterbox(int32_t *width, int32_t *height) {
    const uint64_t letterbox = gLetterboxSize.load(std::memory_order_relaxed);
    *width = static_cast<int32_t>(letterbox >> 32);
    *height = static_cast<int32_t>(letterbox & 0xFFFFFFFFu);
}

struct MercAsset {
    std::vector<MercVertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<MercModel> models;
    std::unordered_map<std::string, size_t> modelLookup;
};

// One loaded FR3 level's Merc data plus its GPU copies. OpenGOAL keeps GAME (common art such as
// Jak and Daxter) loaded alongside the current level and searches all of them by model name.
struct MercLevelResources {
    std::string name;  // FR3 level name ("title", "game", "village1", ...)
    MercAsset asset;
    id<MTLBuffer> vertexBuffer = nil;
    id<MTLBuffer> indexBuffer = nil;
    NSMutableArray<id<MTLTexture>> *textures = nil;
};

// Merc2::VuLights, sent after the model name in each Merc packet.
struct MercVuLights {
    float direction0[3]; uint32_t w0;
    float direction1[3]; uint32_t w1;
    float direction2[3]; uint32_t w2;
    float color0[4];
    float color1[4];
    float color2[4];
    float ambient[4];
};
static_assert(sizeof(MercVuLights) == 112, "VuLights layout");

// merc2.vert light uniforms (mirrors MercLights in Jak1Shaders.metal).
struct MercLightUniforms {
    simd_float4 dir0Fade;
    simd_float4 dir1FadeEnable;
    simd_float4 dir2;
    simd_float4 color0, color1, color2;
    simd_float4 ambient;
};

struct MercSubmission {
    size_t traceOffset = 0;
    MercLightUniforms lights {};
    size_t level = 0;
    const MercModel *model = nullptr;
    std::vector<MercMatrix> bones;
    uint64_t effectEnableMask = UINT64_MAX;
    uint64_t ignoreAlphaMask = 0;
    bool usesWater = false;
    bool forceBlend = false;  // boat summon fade: draw opaque modes alpha blended
    bool usesBlerc = false;  // pc-merc-bits pc-blerc: blercWeights are valid
    float blercWeights[kMercMaxBlerc] {};
    // pc-merc-bits update-verts (ripple, texture scroll): GOAL addresses of each merc-effect,
    // whose fragments hold the vertices the game modified this frame.
    bool usesModVerts = false;
    std::vector<uint32_t> effectAddresses;
};

// Merc2 blerc_avx: each modifiable vertex is its base position/normal plus the weighted sum of
// its blend shape target offsets. int data per vertex: [target idx..., terminator, dest];
// float data per vertex: [base, target0, target1, ...].
static void ApplyBlerc(const MercEffect &effect, const float *weights, std::vector<MercVertex> *out) {
    *out = effect.modVertices;
    const float *floats = effect.blercFloats.data();
    const float *floatsEnd = floats + effect.blercFloats.size();
    const uint32_t *ints = effect.blercInts.data();
    const uint32_t *intsEnd = ints + effect.blercInts.size();
    while (ints < intsEnd && floats + 8 <= floatsEnd) {
        float pos[4], nrm[4];
        memcpy(pos, floats, sizeof(pos));
        memcpy(nrm, floats + 4, sizeof(nrm));
        floats += 8;
        while (ints < intsEnd && *ints != kBlercTargetIdxTerminator) {
            if (floats + 8 > floatsEnd) return;
            const float weight = *ints < kMercMaxBlerc ? weights[*ints] : 0.f;
            for (int i = 0; i < 4; i++) {
                pos[i] += floats[i] * weight;
                nrm[i] += floats[4 + i] * weight;
            }
            floats += 8;
            ints++;
        }
        if (ints + 1 >= intsEnd) return;  // terminator must be followed by the destination
        const uint32_t dest = ints[1];
        ints += 2;
        if (dest < out->size()) {
            memcpy((*out)[dest].position, pos, sizeof(pos));
            memcpy((*out)[dest].normal, nrm, sizeof(nrm));
        }
    }
}

// GOAL memory as seen by merc draws: the submission-time snapshot (setMercMemorySnapshot:),
// falling back to live memory for anything it didn't capture.
struct MercMemoryView {
    NSData *snapshot = nil;
    const uint8_t *live = nullptr;
    size_t liveSize = 0;

    const uint8_t *read(uint64_t address, uint64_t length) const {
        if (address == 0) return nullptr;
        if (snapshot != nil && snapshot.length >= 16) {
            const uint8_t *bytes = static_cast<const uint8_t *>(snapshot.bytes);
            uint32_t count = 0;
            memcpy(&count, bytes, 4);
            if (16 + static_cast<uint64_t>(count) * 16 <= snapshot.length) {
                // Last range starting at or before `address` (ranges are sorted, non-overlapping).
                size_t low = 0, high = count;
                while (low < high) {
                    const size_t middle = (low + high) / 2;
                    uint32_t start = 0;
                    memcpy(&start, bytes + 16 + middle * 16, 4);
                    if (start <= address) low = middle + 1; else high = middle;
                }
                if (low > 0) {
                    uint32_t entry[4];
                    memcpy(entry, bytes + 16 + (low - 1) * 16, sizeof(entry));
                    if (address + length <= static_cast<uint64_t>(entry[0]) + entry[1] &&
                        static_cast<uint64_t>(entry[2]) + entry[1] <= snapshot.length) {
                        return bytes + entry[2] + (address - entry[0]);
                    }
                }
            }
        }
        if (live == nullptr || address + length > liveSize) return nullptr;
        return live + address;
    }
};

// Merc2::UnpackTempVtx
struct MercUnpackedVertex {
    float pos[4];
    float nrm[4];
    float uv[2];
};

// Merc2::model_mod_draws: re-read the modifiable vertices from the game's merc fragments (which
// ripple/texture scroll rewrite in place), undoing the VU unpack (byte + magic float trick).
// Returns false if the fragment data doesn't match the FR3 layout; the caller then uses all_draws.
static bool UnpackModVertices(const MercModel &model, const MercEffect &effect, uint32_t effectAddress,
                              const MercMemoryView &memory,
                              std::vector<MercUnpackedVertex> *unpacked, std::vector<MercVertex> *out) {
    const uint8_t *mercEffect = memory.read(effectAddress, 20);
    if (mercEffect == nullptr) return false;
    uint16_t fragCount = 0;
    uint32_t fragAddress = 0, fragCtrlAddress = 0;
    memcpy(&fragCount, mercEffect + 18, 2);
    memcpy(&fragAddress, mercEffect, 4);
    memcpy(&fragCtrlAddress, mercEffect + 4, 4);
    if (fragCount < effect.fragmentMask.size()) return false;

    unpacked->assign(effect.expectVidxEnd, MercUnpackedVertex {});
    uint32_t vidx = 0;
    uint64_t frag = fragAddress, fragCtrl = fragCtrlAddress;
    for (size_t fi = 0; fi < effect.fragmentMask.size(); fi++) {
        const uint8_t *ctrl = memory.read(fragCtrl, 4);
        const uint8_t *fragBytes = memory.read(frag, 12);
        if (ctrl == nullptr || fragBytes == nullptr) return false;
        const uint8_t matXferCount = ctrl[3];
        // Fragments without mod vertices are skipped; the FR3 indexing assumes that.
        if (effect.fragmentMask[fi]) {
            const uint32_t unsignedFourCount = ctrl[0];
            const uint32_t lumpFourCount = ctrl[1];
            const uint32_t mmQwcOffset = fragBytes[10];
            const uint32_t u4Bytes = ((unsignedFourCount + 3) / 4) * 16;
            const uint32_t l4Bytes = u4Bytes + ((lumpFourCount + 3) / 4) * 16;
            fragBytes = memory.read(frag, std::max<uint64_t>(mmQwcOffset * 16 + 12, l4Bytes));
            if (fragBytes == nullptr) return false;
            float floatOffsets[3];
            memcpy(floatOffsets, fragBytes + mmQwcOffset * 16, sizeof(floatOffsets));
            for (uint32_t w = u4Bytes / 4; w + 2 < l4Bytes / 4; w += 3) {
                if (vidx >= unpacked->size()) return false;
                const uint8_t *q = fragBytes + w * 4;  // three 4-byte words: q0, q1, q2
                MercUnpackedVertex &v = (*unpacked)[vidx];
                for (int i = 0; i < 3; i++) {
                    const uint32_t posBits = 0x4b010000u + q[i * 4 + 3];
                    const uint32_t nrmBits = 0x47800000u + q[i * 4 + 2];
                    memcpy(&v.pos[i], &posBits, 4);
                    memcpy(&v.nrm[i], &nrmBits, 4);
                    v.pos[i] = (v.pos[i] + floatOffsets[i]) * model.xyzScale;
                    v.nrm[i] += -65537;
                }
                for (int i = 0; i < 2; i++) {
                    const uint32_t uvBits = model.stVifAdd + q[2 * 4 + i];
                    memcpy(&v.uv[i], &uvBits, 4);
                    v.uv[i] += model.stMagic;
                }
                vidx++;
            }
        }
        fragCtrl += 4 + 2 * matXferCount;
        frag += static_cast<uint64_t>(fragBytes[11]) * 16;  // mm_qwc_count
    }
    if (vidx != effect.expectVidxEnd) return false;

    // Back to the FR3's mod vertex order; weights/colors/matrices keep their model values.
    *out = effect.modVertices;
    for (size_t vi = 0; vi < out->size() && vi < effect.vertexLump4Addr.size(); vi++) {
        const uint32_t address = effect.vertexLump4Addr[vi];
        if (address >= vidx) continue;
        const MercUnpackedVertex &v = (*unpacked)[address];
        memcpy((*out)[vi].position, v.pos, sizeof(v.pos));
        memcpy((*out)[vi].normal, v.nrm, sizeof(v.nrm));
        (*out)[vi].texCoord[0] = v.uv[0];
        (*out)[vi].texCoord[1] = v.uv[1];
    }
    return true;
}

struct GifDrawBatch {
    // Byte offset of the DMA tag that produced this batch, for ordering against other
    // renderers' draws.
    size_t traceOffset;
    NSUInteger firstVertex;
    NSUInteger vertexCount;
    MTLPrimitiveType primitiveType;
};

struct GifRasterState {
    float xOffset = 32768.0f;
    float yOffset = 32768.0f;
    uint32_t scissorX0 = 0;
    uint32_t scissorX1 = 639;
    uint32_t scissorY0 = 0;
    uint32_t scissorY1 = 479;
};

static bool IsDirectVifCode(uint32_t vifCode) {
    const uint32_t kind = (vifCode >> 24) & 0x7f;
    return kind == 0x50 || kind == 0x51;
}

static MTLPrimitiveType MetalPrimitiveForGif(uint32_t primitive) {
    switch (primitive & 0x7) {
        case 3:
            return MTLPrimitiveTypeTriangle;
        case 4:
            return MTLPrimitiveTypeTriangleStrip;
        default:
            return MTLPrimitiveTypePoint;
    }
}

static MetalVertex InterpolatedSpriteVertex(const MetalVertex &first,
                                            const MetalVertex &second,
                                            float xWeight,
                                            float yWeight) {
    MetalVertex result {};
    result.position = simd_make_float3(
        first.position.x + (second.position.x - first.position.x) * xWeight,
        first.position.y + (second.position.y - first.position.y) * yWeight,
        0.0f
    );
    result.color = first.color;
    result.texCoord = simd_make_float2(
        first.texCoord.x + (second.texCoord.x - first.texCoord.x) * xWeight,
        first.texCoord.y + (second.texCoord.y - first.texCoord.y) * yWeight
    );
    return result;
}

static void AppendGifPackedVertices(const uint8_t *packet,
                                    uint32_t packetLength,
                                    size_t traceOffset,
                                    GifRasterState *rasterState,
                                    std::vector<MetalVertex> *vertices,
                                    std::vector<GifDrawBatch> *batches) {
    if (packet == nullptr || rasterState == nullptr || vertices == nullptr || batches == nullptr) {
        return;
    }
    uint32_t offset = 0;
    while (offset + 16 <= packetLength) {
        uint64_t low = 0;
        uint64_t high = 0;
        memcpy(&low, packet + offset, sizeof(low));
        memcpy(&high, packet + offset + 8, sizeof(high));
        const uint32_t loopCount = static_cast<uint32_t>(low & 0x7fff);
        const uint32_t format = static_cast<uint32_t>((low >> 58) & 0x3);
        const uint32_t encodedRegisterCount = static_cast<uint32_t>((low >> 60) & 0xf);
        const uint32_t registerCount = encodedRegisterCount == 0 ? 16 : encodedRegisterCount;
        if (format != 0) {
            return;
        }
        const uint64_t dataLength = static_cast<uint64_t>(loopCount) * registerCount * 16;
        if (dataLength > packetLength - offset - 16) {
            return;
        }

        NSUInteger batchFirstVertex = vertices->size();
        uint32_t activePrimitive = static_cast<uint32_t>((low >> 47) & 0x7);
        bool hasActivePrimitive = (low & (1ULL << 46)) != 0;
        bool activePrimitiveUsesTexture = (low & (1ULL << 51)) != 0;
        const auto finishBatch = [&]() {
            const NSUInteger vertexCount = vertices->size() - batchFirstVertex;
            // This fallback has no TEX0 state or texture binding. Rendering a textured primitive
            // with only its vertex colors leaves transition/logo geometry as an opaque overlay.
            // Dedicated bucket renderers handle the textured draws they support.
            if (!activePrimitiveUsesTexture && hasActivePrimitive &&
                activePrimitive >= 3 && activePrimitive <= 4 &&
                vertexCount >= 3) {
                batches->push_back({traceOffset, batchFirstVertex, vertexCount,
                                    MetalPrimitiveForGif(activePrimitive)});
            } else if (!activePrimitiveUsesTexture && hasActivePrimitive &&
                       activePrimitive == 5 && vertexCount >= 3) {
                // Metal has no triangle-fan primitive. Expand the fan into triangles.
                const NSUInteger expandedFirstVertex = vertices->size();
                for (NSUInteger index = 2; index < vertexCount; index++) {
                    vertices->push_back((*vertices)[batchFirstVertex]);
                    vertices->push_back((*vertices)[batchFirstVertex + index - 1]);
                    vertices->push_back((*vertices)[batchFirstVertex + index]);
                }
                batches->push_back({traceOffset, expandedFirstVertex, (vertexCount - 2) * 3,
                                    MTLPrimitiveTypeTriangle});
            } else if (hasActivePrimitive && activePrimitive == 6) {
                // The fallback GIF path does not decode TEX0 or bind the referenced GS texture.
                // Drawing a sprite here therefore turns textured full-screen transition effects
                // into opaque color rectangles. Sprite3 and DirectRenderer handle the sprite
                // buckets they understand; leave unsupported fallback sprites out of the frame.
            }
            batchFirstVertex = vertices->size();
        };
        simd_float4 color = simd_make_float4(1, 1, 1, 1);
        simd_float2 texCoord = simd_make_float2(0, 0);
        const uint8_t *data = packet + offset + 16;
        for (uint32_t loop = 0; loop < loopCount; loop++) {
            for (uint32_t reg = 0; reg < registerCount; reg++, data += 16) {
                const uint32_t descriptor = static_cast<uint32_t>((high >> (reg * 4)) & 0xf);
                uint64_t value = 0;
                memcpy(&value, data, sizeof(value));
                switch (descriptor) {
                    case 0: // PRIM
                        finishBatch();
                        activePrimitive = static_cast<uint32_t>(value & 0x7);
                        activePrimitiveUsesTexture = (value & (1ULL << 4)) != 0;
                        hasActivePrimitive = true;
                        break;
                    case 1: // RGBAQ
                        color = simd_make_float4(
                            static_cast<float>(value & 0xff) / 255.0f,
                            static_cast<float>((value >> 8) & 0xff) / 255.0f,
                            static_cast<float>((value >> 16) & 0xff) / 255.0f,
                            static_cast<float>((value >> 24) & 0xff) / 255.0f
                        );
                        break;
                    case 2: // ST
                        memcpy(&texCoord, data, sizeof(texCoord));
                        break;
                    case 3: // UV (14.4 fixed-point texture coordinates)
                        texCoord = simd_make_float2(
                            static_cast<float>(value & 0x3fff) / 16.0f,
                            static_cast<float>((value >> 16) & 0x3fff) / 16.0f
                        );
                        break;
                    case 4: // XYZF2
                    case 5: { // XYZ2
                        const float x = static_cast<float>(value & 0xffff);
                        const float y = static_cast<float>((value >> 16) & 0xffff);
                        MetalVertex vertex {};
                        // GS raster coordinates are 12.4 fixed point. XYOFFSET and
                        // SCISSOR define the active logical viewport for this context.
                        const uint32_t viewportWidthPixels = rasterState->scissorX1 >= rasterState->scissorX0
                            ? rasterState->scissorX1 - rasterState->scissorX0 + 1 : 640;
                        const uint32_t viewportHeightPixels = rasterState->scissorY1 >= rasterState->scissorY0
                            ? rasterState->scissorY1 - rasterState->scissorY0 + 1 : 480;
                        const float viewportWidth = static_cast<float>(viewportWidthPixels);
                        const float viewportHeight = static_cast<float>(viewportHeightPixels);
                        const float pixelX = (x - rasterState->xOffset) / 16.0f;
                        const float pixelY = (y - rasterState->yOffset) / 16.0f;
                        vertex.position = simd_make_float3(
                            ((pixelX - rasterState->scissorX0) / viewportWidth) * 2.0f - 1.0f,
                            1.0f - ((pixelY - rasterState->scissorY0) / viewportHeight) * 2.0f,
                            0.0f
                        );
                        vertex.color = color;
                        vertex.texCoord = texCoord;
                        vertices->push_back(vertex);
                        break;
                    }
                    case 14: { // A+D
                        uint64_t registerAddress = 0;
                        memcpy(&registerAddress, data + 8, sizeof(registerAddress));
                        switch (registerAddress & 0xff) {
                        case 0: // GS PRIM
                            finishBatch();
                            activePrimitive = static_cast<uint32_t>(value & 0x7);
                            activePrimitiveUsesTexture = (value & (1ULL << 4)) != 0;
                            hasActivePrimitive = true;
                            break;
                        case 0x18: // GS XYOFFSET_1
                            rasterState->xOffset = static_cast<float>(value & 0xffff);
                            rasterState->yOffset = static_cast<float>((value >> 32) & 0xffff);
                            break;
                        case 0x40: // GS SCISSOR_1
                            rasterState->scissorX0 = static_cast<uint32_t>(value & 0x7ff);
                            rasterState->scissorX1 = static_cast<uint32_t>((value >> 16) & 0x7ff);
                            rasterState->scissorY0 = static_cast<uint32_t>((value >> 32) & 0x7ff);
                            rasterState->scissorY1 = static_cast<uint32_t>((value >> 48) & 0x7ff);
                            break;
                        default:
                            break;
                        }
                        break;
                    }
                    default:
                        break;
                }
            }
        }
        finishBatch();
        offset += static_cast<uint32_t>(16 + dataLength);
    }
}

// Buckets drawn by jak1::DirectRenderer (the port of OpenGOAL's DirectRenderer users).
static const std::vector<int> &DirectBuckets() {
    static const std::vector<int> buckets = {
        3,   // SKY_DRAW (SkyRenderer)
        67,  // DEBUG: font text (draw-string), progress menu, HUD boxes
        68,  // DEBUG_NO_ZBUF
        69,  // SUBTITLE (PC-port custom bucket)
    };
    return buckets;
}

// Trace byte range [begin, end) of a bucket, or false if the chain never reached it.
static bool BucketTraceRange(const std::vector<uint32_t> &bucketOffsets, int bucket, size_t traceLength,
                             size_t *begin, size_t *end) {
    if (bucket >= static_cast<int>(bucketOffsets.size()) || bucketOffsets[bucket] == UINT32_MAX) return false;
    *begin = bucketOffsets[bucket];
    *end = traceLength;
    for (size_t next = bucket + 1; next < bucketOffsets.size(); next++) {
        if (bucketOffsets[next] != UINT32_MAX && bucketOffsets[next] > *begin) {
            *end = bucketOffsets[next];
            break;
        }
    }
    return true;
}

// Fog color from the default-registers packet at the head of the chain (CNT qwc 10, byte 144),
// as in OpenGLRenderer::dispatch_buckets_jak1. Alpha is fog_intensity / 255.
static void DefaultRegsFogColor(const uint8_t *trace, size_t length, float out[4]) {
    size_t offset = 0;
    for (int entry = 0; entry < 4 && offset + 16 <= length; entry++) {
        uint64_t tag = 0;
        memcpy(&tag, trace + offset, 8);
        const size_t size = static_cast<size_t>(tag & 0xffff) * 16;
        if (size > length - offset - 16) return;
        if ((tag & 0xffff) == 10) {
            const uint8_t *rgba = trace + offset + 16 + 144;
            for (int i = 0; i < 3; i++) out[i] = rgba[i] / 255.f;
            out[3] = 1.0f / 255.0f;
            return;
        }
        offset += 16 + size;
    }
}

static void DecodeDmaTrace(NSData *dmaBuffer,
                           const std::vector<std::pair<size_t, size_t>> &skipRanges,
                           std::vector<MetalVertex> *vertices,
                           std::vector<GifDrawBatch> *batches) {
    if (dmaBuffer == nil || vertices == nullptr || batches == nullptr) {
        return;
    }
    const uint8_t *bytes = static_cast<const uint8_t *>(dmaBuffer.bytes);
    NSUInteger offset = 0;
    GifRasterState rasterState;
    while (bytes != nullptr && offset + 16 <= dmaBuffer.length) {
        uint64_t tag = 0;
        memcpy(&tag, bytes + offset, sizeof(tag));
        const NSUInteger payloadLength = static_cast<NSUInteger>(tag & 0xffff) * 16;
        if (payloadLength > dmaBuffer.length - offset - 16) {
            return;
        }
        uint32_t vif0 = 0;
        uint32_t vif1 = 0;
        memcpy(&vif0, bytes + offset + 8, sizeof(vif0));
        memcpy(&vif1, bytes + offset + 12, sizeof(vif1));
        const bool skipped = std::any_of(skipRanges.begin(), skipRanges.end(), [&](const auto &range) {
            return offset >= range.first && offset < range.second;
        });
        if (!skipped && ((IsDirectVifCode(vif0) && (vif0 & 0xffff) == payloadLength / 16) ||
                         (IsDirectVifCode(vif1) && (vif1 & 0xffff) == payloadLength / 16))) {
            AppendGifPackedVertices(bytes + offset + 16, static_cast<uint32_t>(payloadLength),
                                    offset, &rasterState, vertices, batches);
        }
        offset += 16 + payloadLength;
    }
}

static void DecodeMercSubmissions(NSData *dmaBuffer,
                                  const MercMemoryView &memory,
                                  const std::vector<MercLevelResources> &levels,
                                  MercUniforms *uniforms,
                                  std::vector<MercSubmission> *submissions) {
    static bool loggedSetup = false;
    static bool loggedSubmission = false;
    static std::unordered_set<std::string> loggedMissingModels;
    if (dmaBuffer == nil || uniforms == nullptr || submissions == nullptr) return;
    const uint8_t *bytes = static_cast<const uint8_t *>(dmaBuffer.bytes);
    size_t offset = 0;
    while (bytes != nullptr && offset + 16 <= dmaBuffer.length) {
        uint64_t tag = 0;
        uint32_t vif0 = 0, vif1 = 0;
        memcpy(&tag, bytes + offset, 8);
        memcpy(&vif0, bytes + offset + 8, 4);
        memcpy(&vif1, bytes + offset + 12, 4);
        const size_t payloadLength = static_cast<size_t>(tag & 0xffff) * 16;
        if (payloadLength > dmaBuffer.length - offset - 16) return;
        const uint8_t *payload = bytes + offset + 16;
        const uint32_t kind0 = (vif0 >> 24) & 0x7f;
        const uint32_t kind1 = (vif1 >> 24) & 0x7f;

        // Merc setup: four VIF words followed by LowMemory. LowMemory begins with two GIF
        // tags, then the projection constants used by every model in this bucket.
        if (payloadLength == 160 && kind0 == 0x01 && kind1 == 0x05) {
            memcpy(uniforms->hvdfOffset, payload + 16 + 32, 16);
            memcpy(uniforms->perspective, payload + 16 + 48, 64);
            memcpy(uniforms->fog, payload + 16 + 112, 16);
            if (!loggedSetup) {
                NSLog(@"jakIOS: Merc setup hvdf=(%.2f %.2f %.2f %.2f) fog=(%.3f %.3f %.3f %.3f) "
                      @"perspective-w=(%.3f %.3f %.3f %.3f)",
                      uniforms->hvdfOffset[0], uniforms->hvdfOffset[1], uniforms->hvdfOffset[2],
                      uniforms->hvdfOffset[3], uniforms->fog[0], uniforms->fog[1], uniforms->fog[2],
                      uniforms->fog[3], uniforms->perspective[0][3], uniforms->perspective[1][3],
                      uniforms->perspective[2][3], uniforms->perspective[3][3]);
                loggedSetup = true;
            }
        }

        if (kind1 == 0x08 && payloadLength >= 288 && memchr(payload, 0, 128) != nullptr) {
            const std::string modelName(reinterpret_cast<const char *>(payload));
            // Like Loader::get_merc_model, search every loaded level for the model.
            const MercModel *foundModel = nullptr;
            size_t foundLevel = 0;
            for (size_t levelIndex = 0; levelIndex < levels.size() && foundModel == nullptr; levelIndex++) {
                const MercAsset &asset = levels[levelIndex].asset;
                auto found = asset.modelLookup.find(modelName);
                if (found != asset.modelLookup.end()) {
                    foundModel = &asset.models[found->second];
                    foundLevel = levelIndex;
                }
            }
            // Only report names that look like art names; other packets can pass the size check.
            const bool plausibleName = modelName.size() >= 3 &&
                std::all_of(modelName.begin(), modelName.end(), [](char c) {
                    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
                });
            if (foundModel == nullptr && plausibleName && loggedMissingModels.insert(modelName).second) {
                NSLog(@"jakIOS: Merc model %s is not in any loaded Merc asset", modelName.c_str());
            }
            if (foundModel != nullptr) {
                const MercModel &model = *foundModel;
                uint64_t usesWater = 0;
                memcpy(&usesWater, payload + 128 + 112, 8);
                // name + lights + Jak 1 water flag packet
                const uint8_t *matrixSlots = payload + 128 + 112 + 16;
                size_t slotCount = 0;
                while (slotCount < 128 && matrixSlots[slotCount] != 0xff) slotCount++;
                const size_t matrixPointersOffset = static_cast<size_t>(matrixSlots - payload) + 128;
                const size_t flagsOffset = matrixPointersOffset + slotCount * 16;
                if (flagsOffset + 18 <= payloadLength) {
                    MercSubmission submission;
                    submission.traceOffset = offset;
                    submission.level = foundLevel;
                    submission.model = &model;
                    submission.usesWater = usesWater != 0;
                    // Merc2::draw_merc2 light uniforms, including the fade mode in w1/w2.
                    MercVuLights vu;
                    memcpy(&vu, payload + 128, sizeof(vu));
                    const float fade = vu.w1 ? vu.w2 / 128.f : 1.f;
                    const float fadeEnable = vu.w1 ? 1.f : 0.f;
                    MercLightUniforms &lights = submission.lights;
                    lights.dir0Fade = simd_make_float4(vu.direction0[0], vu.direction0[1], vu.direction0[2], fade);
                    lights.dir1FadeEnable = simd_make_float4(vu.direction1[0], vu.direction1[1], vu.direction1[2], fadeEnable);
                    lights.dir2 = simd_make_float4(vu.direction2[0], vu.direction2[1], vu.direction2[2], 0);
                    lights.color0 = simd_make_float4(vu.color0[0], vu.color0[1], vu.color0[2], vu.color0[3]);
                    lights.color1 = simd_make_float4(vu.color1[0], vu.color1[1], vu.color1[2], vu.color1[3]);
                    lights.color2 = simd_make_float4(vu.color2[0], vu.color2[1], vu.color2[2], vu.color2[3]);
                    lights.ambient = simd_make_float4(vu.ambient[0], vu.ambient[1], vu.ambient[2], vu.ambient[3]);
                    // Boat summon: fade (scaled alpha, merc2 fade mode < 0) + glow (dir2.w, unused by lighting).
                    if (gBoatFadeActive.load(std::memory_order_relaxed) &&
                        model.name.rfind("fishermans-boat", 0) == 0) {
                        lights.dir0Fade.w = gBoatFadeAlpha.load(std::memory_order_relaxed);
                        lights.dir1FadeEnable.w = -1.0f;
                        lights.dir2.w = gBoatFadeGlow.load(std::memory_order_relaxed);
                        submission.forceBlend = true;
                    }
                    static int loggedLights = 0;
                    if (loggedLights < 3) {
                        NSLog(@"jakIOS: Merc lights %s dir0=(%.2f %.2f %.2f) dir1=(%.2f %.2f %.2f) w=(%u %u %u) "
                              @"col0=(%.2f %.2f %.2f %.2f) amb=(%.2f %.2f %.2f %.2f)",
                              model.name.c_str(), vu.direction0[0], vu.direction0[1], vu.direction0[2],
                              vu.direction1[0], vu.direction1[1], vu.direction1[2], vu.w0, vu.w1, vu.w2,
                              vu.color0[0], vu.color0[1], vu.color0[2], vu.color0[3], vu.ambient[0],
                              vu.ambient[1], vu.ambient[2], vu.ambient[3]);
                        loggedLights++;
                    }
                    submission.bones.resize(model.maxBones + 1);
                    uint32_t firstMatrixAddress = 0;
                    uint8_t firstBoneIndex = 0;
                    for (size_t slot = 0; slot < slotCount; slot++) {
                        uint32_t address = 0;
                        memcpy(&address, payload + matrixPointersOffset + slot * 16, 4);
                        if (slot == 0) {
                            firstMatrixAddress = address;
                            firstBoneIndex = matrixSlots[slot];
                        }
                        const uint8_t boneIndex = matrixSlots[slot];
                        if (boneIndex >= submission.bones.size()) continue;
                        // Prefer the copy taken at submission: by now the game may be writing
                        // the next frame's bones at this address (one-frame vertex explosions).
                        const uint8_t *matrix = memory.read(address, 112);
                        if (matrix != nullptr) {
                            // GOAL sends seven vectors. Metal's std140-compatible record has an
                            // eighth padding vector, initialized to zero here.
                            memcpy(&submission.bones[boneIndex], matrix, 112);
                        }
                    }
                    // PcMercFlags: enable_mask, ignore_alpha_mask, effect_count, bit_flags.
                    memcpy(&submission.effectEnableMask, payload + flagsOffset, 8);
                    memcpy(&submission.ignoreAlphaMask, payload + flagsOffset + 8, 8);
                    // pc-merc-draw-request: flags take 2 qw; with pc-blerc, 40 float weights follow.
                    const uint8_t bitFlags = payload[flagsOffset + 17];
                    const size_t blercOffset = flagsOffset + 32;
                    if ((bitFlags & kPcMercBitPcBlerc) != 0 &&
                        blercOffset + sizeof(submission.blercWeights) <= payloadLength) {
                        submission.usesBlerc = true;
                        memcpy(submission.blercWeights, payload + blercOffset, sizeof(submission.blercWeights));
                    } else if ((bitFlags & kPcMercBitUpdateVerts) != 0) {
                        // Then fades (u32 per effect) and merc-effect pointers, each qw padded.
                        const size_t effectCount = payload[flagsOffset + 16];
                        const size_t paddedBytes = ((effectCount * 4 + 15) / 16) * 16;
                        const size_t pointersOffset = blercOffset + paddedBytes;
                        if (pointersOffset + effectCount * 4 <= payloadLength) {
                            submission.usesModVerts = true;
                            submission.effectAddresses.resize(effectCount);
                            memcpy(submission.effectAddresses.data(), payload + pointersOffset, effectCount * 4);
                        }
                    }
                    if (!loggedSubmission) {
                        const MercMatrix &firstBone = submission.bones[firstBoneIndex];
                        NSLog(@"jakIOS: Merc model=%s payload=%zu slots=%zu max-bones=%u first-slot=%u "
                              @"first-matrix=0x%08x enable=0x%016llx matrix=(%.3f %.3f %.3f %.3f)",
                              model.name.c_str(), payloadLength, slotCount, model.maxBones,
                              firstBoneIndex, firstMatrixAddress, submission.effectEnableMask,
                              firstBone.transform[0][0], firstBone.transform[1][1],
                              firstBone.transform[2][2], firstBone.transform[3][3]);
                        for (int c = 0; c < 4; c++) {
                            NSLog(@"jakIOS: Merc bone[%u].t[%d]=(%.4f %.4f %.4f %.4f) persp[%d]=(%.4f %.4f %.4f %.4f)",
                                  firstBoneIndex, c, firstBone.transform[c][0], firstBone.transform[c][1],
                                  firstBone.transform[c][2], firstBone.transform[c][3], c,
                                  uniforms->perspective[c][0], uniforms->perspective[c][1],
                                  uniforms->perspective[c][2], uniforms->perspective[c][3]);
                        }
                        for (int c = 0; c < 3; c++) {
                            NSLog(@"jakIOS: Merc bone[%u].n[%d]=(%.4f %.4f %.4f %.4f)", firstBoneIndex, c,
                                  firstBone.normal[c][0], firstBone.normal[c][1], firstBone.normal[c][2],
                                  firstBone.normal[c][3]);
                        }
                        loggedSubmission = true;
                    }
                    submissions->push_back(std::move(submission));
                }
            }
        }
        offset += 16 + payloadLength;
    }
}

// ---------------------------------------------------------------------------------------------
// Eyes: port of OpenGOAL EyeRenderer (game/graphics/opengl_renderer/EyeRenderer.cpp, Jak 1).
// The game draws each eye (iris, pupil, lid sprites) into a small VRAM texture; Merc eye draws
// then sample it by eye slot. We decode those sprites and composite them with Metal.

constexpr int kEyePairCount = 20;
constexpr int kEyeSlotCount = kEyePairCount * 2;
constexpr int kSingleEyeSize = 32;
constexpr NSUInteger kEyeTextureSize = 128;  // OpenGOAL upsizes the 32x32 eyes to 128x128.

struct EyeSpriteDraw {
    uint32_t xyz0[2] {};
    uint32_t xyz1[2] {};
};

struct SingleEyeDraws {
    int lr = 0;
    int pair = 0;
    bool using64 = false;
    EyeSpriteDraw iris, pupil, lid;
    uint32_t irisTbp = 0, pupilTbp = 0, lidTbp = 0;
    int slot() const { return pair * 2 + lr; }
};

// Walks the linear DMA trace (16-byte tag + payload per entry) like DmaFollower.
class TraceCursor {
public:
    TraceCursor(const uint8_t *bytes, size_t length, size_t offset)
        : _bytes(bytes), _length(length), _offset(offset) {}
    bool valid() const { return _bytes != nullptr && _offset + 16 <= _length &&
                                payloadSize() <= _length - _offset - 16; }
    uint32_t qwc() const { uint64_t tag = 0; memcpy(&tag, _bytes + _offset, 8); return tag & 0xffff; }
    size_t payloadSize() const { return static_cast<size_t>(qwc()) * 16; }
    uint32_t vifKind(int index) const {
        uint32_t vif = 0;
        memcpy(&vif, _bytes + _offset + 8 + 4 * index, 4);
        return (vif >> 24) & 0x7f;
    }
    uint32_t vif(int index) const { uint32_t v = 0; memcpy(&v, _bytes + _offset + 8 + 4 * index, 4); return v; }
    const uint8_t *payload() const { return _bytes + _offset + 16; }
    size_t offset() const { return _offset; }
    void advance() { _offset += 16 + payloadSize(); }

private:
    const uint8_t *_bytes;
    size_t _length;
    size_t _offset;
};

constexpr uint32_t kVifDirect = 0x50;
constexpr uint32_t kVifFlushA = 0x13;

// 5-register A+D adgif packet; returns tex0's TBP0.
static bool ReadEyeAdgif(TraceCursor &cursor, uint32_t *tbp) {
    if (!cursor.valid() || cursor.payloadSize() != 96 || cursor.vif(0) != 0 ||
        cursor.vifKind(1) != kVifDirect) return false;
    uint64_t tex0 = 0;
    memcpy(&tex0, cursor.payload() + 16, 8);
    *tbp = static_cast<uint32_t>(tex0 & 0x3fff);
    cursor.advance();
    return true;
}

// read_eye_draw: a SCISSOR_1 packet followed by a textured sprite packet.
static bool ReadEyeDraw(TraceCursor &cursor, EyeSpriteDraw *draw, int *scissorHeight) {
    if (!cursor.valid() || cursor.payloadSize() != 32 || cursor.vif(0) != 0 ||
        cursor.vifKind(1) != kVifDirect || cursor.payload()[24] != 0x40) return false;
    uint64_t scissor = 0;
    memcpy(&scissor, cursor.payload() + 16, 8);
    if (scissorHeight != nullptr) {
        *scissorHeight = static_cast<int>((scissor >> 48) & 0x7ff) - static_cast<int>((scissor >> 32) & 0x7ff);
    }
    cursor.advance();
    if (!cursor.valid() || cursor.payloadSize() != 96 || cursor.vif(0) != 0 ||
        cursor.vifKind(1) != kVifDirect) return false;
    memcpy(draw->xyz0, cursor.payload() + 48, 8);
    memcpy(draw->xyz1, cursor.payload() + 80, 8);
    cursor.advance();
    return true;
}

// Reads the right eye's draw, which may be preceded by its own adgif (qwc 6).
static bool ReadRightEyeDraw(TraceCursor &cursor, uint32_t leftTbp, uint32_t *rightTbp,
                             EyeSpriteDraw *draw) {
    *rightTbp = leftTbp;
    if (cursor.valid() && cursor.qwc() == 6 && !ReadEyeAdgif(cursor, rightTbp)) return false;
    return ReadEyeDraw(cursor, draw, nullptr);
}

// EyeRenderer::get_draws for Jak 1, starting after the bucket's GS setup packets.
static bool ReadEyeDraws(TraceCursor cursor, std::vector<SingleEyeDraws> *draws) {
    while (cursor.valid() && cursor.qwc() != 8) {
        SingleEyeDraws left, right;
        left.lr = 0;
        right.lr = 1;
        uint32_t irisTbp = 0;
        if (!ReadEyeAdgif(cursor, &irisTbp)) return false;
        // Background draw: identifies the eye pair from its y position.
        EyeSpriteDraw background;
        int scissorHeight = 0;
        if (!ReadEyeDraw(cursor, &background, &scissorHeight)) return false;
        const bool using64 = scissorHeight == 63;
        uint32_t y0 = (background.xyz0[1] - 512) >> 4;
        if (using64) y0 = ((background.xyz0[1] - 1024) >> 5) * 4;
        left.pair = right.pair = static_cast<int>(y0 / kSingleEyeSize);
        left.using64 = right.using64 = using64;

        left.irisTbp = irisTbp;
        if (!ReadEyeDraw(cursor, &left.iris, nullptr) ||
            !ReadRightEyeDraw(cursor, irisTbp, &right.irisTbp, &right.iris)) return false;

        cursor.advance();  // test1
        uint32_t pupilTbp = 0;
        if (!ReadEyeAdgif(cursor, &pupilTbp)) return false;
        left.pupilTbp = pupilTbp;
        if (!ReadEyeDraw(cursor, &left.pupil, nullptr) ||
            !ReadRightEyeDraw(cursor, pupilTbp, &right.pupilTbp, &right.pupil)) return false;

        cursor.advance();  // test2
        uint32_t lidTbp = 0;
        if (!ReadEyeAdgif(cursor, &lidTbp)) return false;
        left.lidTbp = lidTbp;
        if (!ReadEyeDraw(cursor, &left.lid, nullptr) ||
            !ReadRightEyeDraw(cursor, lidTbp, &right.lidTbp, &right.lid)) return false;

        // Jak 1 ends each pair with an empty transfer.
        if (!cursor.valid() || cursor.qwc() != 0) return false;
        cursor.advance();
        if (left.pair < 0 || left.pair >= kEyePairCount) return false;
        draws->push_back(left);
        draws->push_back(right);
    }
    return cursor.valid();
}

// Finds the eye bucket (FLUSHA+DIRECT render-to-texture setup, NOP+DIRECT alpha setup) and decodes it.
static void DecodeEyeDraws(NSData *dmaBuffer, std::vector<SingleEyeDraws> *draws) {
    if (dmaBuffer == nil) return;
    const uint8_t *bytes = static_cast<const uint8_t *>(dmaBuffer.bytes);
    TraceCursor cursor(bytes, dmaBuffer.length, 0);
    while (cursor.valid()) {
        if (cursor.payloadSize() == 128 && cursor.vifKind(0) == kVifFlushA &&
            cursor.vifKind(1) == kVifDirect) {
            TraceCursor probe = cursor;
            probe.advance();
            if (probe.valid() && probe.payloadSize() == 32 && probe.vifKind(0) == 0 &&
                probe.vifKind(1) == kVifDirect) {
                probe.advance();
                if (probe.valid() && probe.qwc() == 0 && probe.vif(0) == 0 && probe.vif(1) == 0) {
                    probe.advance();
                }
                std::vector<SingleEyeDraws> found;
                if (ReadEyeDraws(probe, &found) && !found.empty()) {
                    draws->insert(draws->end(), found.begin(), found.end());
                    return;
                }
            }
        }
        cursor.advance();
    }
}

// add_draw_to_buffer_32/64: one eye sprite as a 4-vertex strip of (x, y, s, t).
static void AppendEyeQuad(std::vector<simd_float4> *vertices, const EyeSpriteDraw &draw, const SingleEyeDraws &eye) {
    const float scale = eye.using64 ? 2.0f : 1.0f;
    const float xOff = static_cast<float>(eye.lr * kSingleEyeSize * (eye.using64 ? 32 : 16));
    const float yOff = static_cast<float>((eye.using64 ? eye.pair / 4 : eye.pair) * kSingleEyeSize *
                                          (eye.using64 ? 32 : 16));
    const float x0 = (draw.xyz0[0] - xOff) / scale, x1 = (draw.xyz1[0] - xOff) / scale;
    const float y0 = (draw.xyz0[1] - yOff) / scale, y1 = (draw.xyz1[1] - yOff) / scale;
    vertices->push_back(simd_make_float4(x0, y0, 0, 0));
    vertices->push_back(simd_make_float4(x1, y0, 1, 0));
    vertices->push_back(simd_make_float4(x0, y1, 0, 1));
    vertices->push_back(simd_make_float4(x1, y1, 1, 1));
}

static void LogMercBoundsOnce(const std::vector<MercLevelResources> &levels,
                              const MercUniforms &uniforms,
                              const std::vector<MercSubmission> &submissions) {
    // Sample every 120th frame with Merc work: the first frames precede the logo camera setup.
    static unsigned frame = 0;
    if (submissions.empty() || frame++ % 120 != 0) return;
    const MercSubmission &submission = submissions.front();
    if (submission.model == nullptr || submission.level >= levels.size()) return;
    const MercAsset &asset = levels[submission.level].asset;
    if (asset.vertices.empty()) return;  // FR3 levels keep their vertices on the GPU only
    float minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
    float minW = INFINITY, maxW = -INFINITY;
    size_t valid = 0, invalid = 0;
    for (size_t effectIndex = 0; effectIndex < submission.model->effects.size(); effectIndex++) {
        if (effectIndex < 64 && ((submission.effectEnableMask >> effectIndex) & 1) == 0) continue;
        for (const MercDraw &draw : submission.model->effects[effectIndex].draws) {
            const uint64_t end = static_cast<uint64_t>(draw.firstIndex) + draw.indexCount;
            if (end > asset.indices.size()) continue;
            for (uint64_t i = draw.firstIndex; i < end; i++) {
                const uint32_t vertexIndex = asset.indices[i];
                if (vertexIndex == UINT32_MAX) continue;
                if (vertexIndex >= asset.vertices.size()) { invalid++; continue; }
                const MercVertex &vertex = asset.vertices[vertexIndex];
                float position[4] {};
                for (int influence = 0; influence < 3; influence++) {
                    const float weight = vertex.weights[influence];
                    const uint8_t boneIndex = vertex.matrices[influence];
                    if (weight <= 0 || boneIndex >= submission.bones.size()) continue;
                    const MercMatrix &bone = submission.bones[boneIndex];
                    for (int row = 0; row < 4; row++) {
                        position[row] -= (bone.transform[0][row] * vertex.position[0] +
                            bone.transform[1][row] * vertex.position[1] +
                            bone.transform[2][row] * vertex.position[2] +
                            bone.transform[3][row]) * weight;
                    }
                }
                float projected[4] {};
                for (int row = 0; row < 4; row++) {
                    projected[row] = uniforms.perspective[0][row] * position[0] +
                        uniforms.perspective[1][row] * position[1] +
                        uniforms.perspective[2][row] * position[2] +
                        uniforms.perspective[3][row] * position[3];
                }
                if (projected[3] == 0) { invalid++; continue; }
                const float q = uniforms.fog[0] / projected[3];
                const float x = (projected[0] * q + uniforms.hvdfOffset[0] - 2048.0f) / 256.0f;
                const float y = -(projected[1] * q + uniforms.hvdfOffset[1] - 2048.0f) / 128.0f *
                    (512.0f / 448.0f);
                if (!std::isfinite(x) || !std::isfinite(y)) { invalid++; continue; }
                minX = std::min(minX, x); maxX = std::max(maxX, x);
                minY = std::min(minY, y); maxY = std::max(maxY, y);
                minW = std::min(minW, projected[3]); maxW = std::max(maxW, projected[3]);
                valid++;
            }
        }
    }
    const MercMatrix &rootBone = submission.bones[std::min<size_t>(3, submission.bones.size() - 1)];
    NSLog(@"jakIOS: Merc NDC model=%s valid=%zu invalid=%zu x=[%.3f, %.3f] y=[%.3f, %.3f] w=[%.3f, %.3f] "
          @"bone3.x=(%.3f %.3f %.3f) bone3.t=(%.1f %.1f %.1f)",
          submission.model->name.c_str(), valid, invalid, minX, maxX, minY, maxY, minW, maxW,
          rootBone.transform[0][0], rootBone.transform[0][1], rootBone.transform[0][2],
          rootBone.transform[3][0], rootBone.transform[3][1], rootBone.transform[3][2]);
}

static simd_float4x4 MatrixIdentity() {
    return simd_matrix(
        simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 MatrixPerspective(float fovYRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovYRadians * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    return simd_matrix(
        simd_make_float4(xs, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, ys, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, zs, -1.0f),
        simd_make_float4(0.0f, 0.0f, zs * nearZ, 0.0f)
    );
}

static id<MTLBuffer> UpdateFrameBuffer(id<MTLDevice> device,
                                       __strong id<MTLBuffer> (&buffers)[3],
                                       NSUInteger &capacity, uint32_t slot,
                                       const void *bytes, NSUInteger length) {
    if (length == 0) return nil;
    if (capacity < length) {
        const NSUInteger grown = std::max(length, capacity + capacity / 2);
        for (size_t i = 0; i < 3; i++) {
            buffers[i] = [device newBufferWithLength:grown options:MTLResourceStorageModeShared];
        }
        capacity = grown;
    }
    id<MTLBuffer> buffer = buffers[slot];
    memcpy(buffer.contents, bytes, length);
    return buffer;
}

@interface Jak1MetalRenderer () {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipelineState;
    // Indexed by DrawMode::AlphaBlend.
    id<MTLRenderPipelineState> _genericPipelineStates[8];
    // Indexed by [filter][clamp s][clamp t].
    id<MTLSamplerState> _genericSamplers[2][2][2];
    // Indexed by DrawMode::AlphaBlend (0 = blending disabled).
    id<MTLRenderPipelineState> _mercPipelineStates[8];
    // Indexed by [filter][clamp s][clamp t] from the Merc draw's DrawMode.
    id<MTLSamplerState> _mercSamplers[2][2][2];
    // Indexed by jak1::Sprite3Blend.
    id<MTLRenderPipelineState> _spritePipelineStates[3];
    // Depth-sorted world sprites (alpha + additive in one premultiplied draw).
    id<MTLRenderPipelineState> _spritePremultipliedPipelineState;
    id<MTLDepthStencilState> _depthState;
    id<MTLDepthStencilState> _genericDepthState;
    id<MTLDepthStencilState> _genericDepthStateNoWrite;
    // Final full-screen pass that scales the frame by the PCRTC alpha (blackout/fades).
    id<MTLRenderPipelineState> _pcrtcPipelineState;
    id<MTLDepthStencilState> _pcrtcDepthState;
    id<MTLSamplerState> _samplerState;
    id<MTLTexture> _defaultTexture;
    std::vector<MercLevelResources> _mercLevels;
    // Blend-shaped or game-updated Merc vertices, reused across draws.
    std::vector<MercVertex> _modVertexScratch;
    std::vector<MercUnpackedVertex> _modUnpackScratch;
    std::unordered_set<std::string> _loggedModUnpackFailures;
    // Eye compositing: [0] opaque, [1] alpha blended.
    id<MTLRenderPipelineState> _eyePipelineStates[2];
    id<MTLTexture> _eyeTextures[kEyeSlotCount];
    BOOL _eyeTextureValid[kEyeSlotCount];
    BOOL _loggedEyeDraws;
    NSUInteger _lastDecodedVertexCount;
    NSUInteger _lastDecodedBatchCount;
    uint32_t _lastGenericFragmentCount;
    uint32_t _lastGenericRejectedCount;
    uint32_t _lastSpriteCount;
    uint32_t _lastSpriteRejectedCount;
    NSUInteger _lastMercSubmissionCount;
    uint64_t _diagnosticFrameCounter;
    CFTimeInterval _performanceWindowStart;
    double _performanceCPUSeconds;
    double _performanceStageSeconds[9];
    uint32_t _performanceFrameCount;
    __strong id<MTLBuffer> _genericVertexBuffers[3];
    __strong id<MTLBuffer> _genericIndexBuffers[3];
    __strong id<MTLBuffer> _spriteVertexBuffers[3];
    __strong id<MTLBuffer> _spriteIndexBuffers[3];
    __strong id<MTLBuffer> _mercBoneBuffers[3];
    NSUInteger _genericVertexCapacity;
    NSUInteger _genericIndexCapacity;
    NSUInteger _spriteVertexCapacity;
    NSUInteger _spriteIndexCapacity;
    NSUInteger _mercBoneCapacity;
    uint64_t _frameBufferCounter;
    std::unique_ptr<jak1::Background> _background;
    std::unique_ptr<jak1::DirectRenderer> _direct;
    std::unique_ptr<jak1::SkyBlender> _skyBlender;
    std::unique_ptr<jak1::Ocean> _ocean;
    std::unique_ptr<jak1::Shadow> _shadow;
    std::vector<uint32_t> _bucketTraceOffsets;
    NSData *_mercMemorySnapshot;
}
@end

@implementation Jak1MetalRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
        id<MTLLibrary> library = [device newDefaultLibrary];
        if (library != nil) {
            _background = std::make_unique<jak1::Background>(device, library);
            _direct = std::make_unique<jak1::DirectRenderer>(device, library);
            _skyBlender = std::make_unique<jak1::SkyBlender>(device, library);
            _ocean = std::make_unique<jak1::Ocean>(device, library);
            _shadow = std::make_unique<jak1::Shadow>(device, library);
            id<MTLFunction> pcrtcVertFunc = [library newFunctionWithName:@"jak1_pcrtc_vertex"];
            id<MTLFunction> pcrtcFragFunc = [library newFunctionWithName:@"jak1_pcrtc_fragment"];
            if (pcrtcVertFunc != nil && pcrtcFragFunc != nil) {
                // dst * blendAlpha, like OpenGOAL's glBlendFunc(GL_ZERO, GL_CONSTANT_ALPHA) blit.
                MTLRenderPipelineDescriptor *pcrtcDesc = [[MTLRenderPipelineDescriptor alloc] init];
                pcrtcDesc.vertexFunction = pcrtcVertFunc;
                pcrtcDesc.fragmentFunction = pcrtcFragFunc;
                pcrtcDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pcrtcDesc.colorAttachments[0].blendingEnabled = YES;
                pcrtcDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorZero;
                pcrtcDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
                pcrtcDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorBlendAlpha;
                pcrtcDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
                jak1::SetMainPassDepthFormats(pcrtcDesc);
                NSError *pcrtcError = nil;
                _pcrtcPipelineState = [device newRenderPipelineStateWithDescriptor:pcrtcDesc error:&pcrtcError];
                if (pcrtcError != nil) {
                    NSLog(@"Jak1MetalRenderer PCRTC pipeline error: %@", pcrtcError.localizedDescription);
                }
                MTLDepthStencilDescriptor *pcrtcDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
                pcrtcDepthDesc.depthCompareFunction = MTLCompareFunctionAlways;
                pcrtcDepthDesc.depthWriteEnabled = NO;
                _pcrtcDepthState = [device newDepthStencilStateWithDescriptor:pcrtcDepthDesc];
            }
            id<MTLFunction> vertFunc = [library newFunctionWithName:@"jak1_vertex_main"];
            id<MTLFunction> fragFunc = [library newFunctionWithName:@"jak1_fragment_main"];
            if (vertFunc != nil && fragFunc != nil) {
                MTLVertexDescriptor *vDesc = [MTLVertexDescriptor vertexDescriptor];
                vDesc.attributes[0].format = MTLVertexFormatFloat3;
                vDesc.attributes[0].offset = offsetof(MetalVertex, position);
                vDesc.attributes[0].bufferIndex = 0;

                vDesc.attributes[1].format = MTLVertexFormatFloat4;
                vDesc.attributes[1].offset = offsetof(MetalVertex, color);
                vDesc.attributes[1].bufferIndex = 0;

                vDesc.attributes[2].format = MTLVertexFormatFloat2;
                vDesc.attributes[2].offset = offsetof(MetalVertex, texCoord);
                vDesc.attributes[2].bufferIndex = 0;

                vDesc.attributes[3].format = MTLVertexFormatFloat3;
                vDesc.attributes[3].offset = offsetof(MetalVertex, normal);
                vDesc.attributes[3].bufferIndex = 0;

                vDesc.layouts[0].stride = sizeof(MetalVertex);

                MTLRenderPipelineDescriptor *pDesc = [[MTLRenderPipelineDescriptor alloc] init];
                pDesc.vertexFunction = vertFunc;
                pDesc.fragmentFunction = fragFunc;
                pDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pDesc.colorAttachments[0].blendingEnabled = YES;
                pDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
                pDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
                pDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                pDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                pDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                pDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                jak1::SetMainPassDepthFormats(pDesc);
                pDesc.vertexDescriptor = vDesc;

                NSError *error = nil;
                _pipelineState = [device newRenderPipelineStateWithDescriptor:pDesc error:&error];
                if (error != nil) {
                    NSLog(@"Jak1MetalRenderer pipeline error: %@", error.localizedDescription);
                }

                // The generic renderer reads its vertices directly from buffer 0.
                id<MTLFunction> genericVertFunc = [library newFunctionWithName:@"jak1_generic_vertex"];
                id<MTLFunction> genericFragFunc = [library newFunctionWithName:@"jak1_generic_fragment"];
                if (genericVertFunc != nil && genericFragFunc != nil) {
                    pDesc.vertexFunction = genericVertFunc;
                    pDesc.fragmentFunction = genericFragFunc;
                    pDesc.vertexDescriptor = nil;
                    // GS alpha blend modes, following Generic2::setup_opengl_for_draw_mode.
                    // Alpha channel: ONE, ZERO.
                    MTLRenderPipelineColorAttachmentDescriptor *color = pDesc.colorAttachments[0];
                    for (uint32_t blend = 0; blend < 8; blend++) {
                        color.blendingEnabled = blend != 0;
                        color.rgbBlendOperation = MTLBlendOperationAdd;
                        color.alphaBlendOperation = MTLBlendOperationAdd;
                        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                        color.destinationAlphaBlendFactor = MTLBlendFactorZero;
                        switch (blend) {
                            case 1:  // SRC_DST_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                                break;
                            case 2:  // SRC_0_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            case 3:  // SRC_0_FIX_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorOne;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            case 4:  // SRC_DST_FIX_DST, blend alpha = fix / 127 set on the encoder
                                color.sourceRGBBlendFactor = MTLBlendFactorBlendAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusBlendAlpha;
                                break;
                            case 5:  // ZERO_SRC_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                color.rgbBlendOperation = MTLBlendOperationReverseSubtract;
                                break;
                            case 7:  // SRC_0_DST_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorDestinationAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            default:  // DISABLED, SRC_SRC_SRC_SRC
                                color.sourceRGBBlendFactor = MTLBlendFactorOne;
                                color.destinationRGBBlendFactor = MTLBlendFactorZero;
                                break;
                        }
                        error = nil;
                        _genericPipelineStates[blend] = [device newRenderPipelineStateWithDescriptor:pDesc
                                                                                              error:&error];
                        if (error != nil) {
                            NSLog(@"Jak1MetalRenderer generic pipeline error: %@", error.localizedDescription);
                        }
                    }
                    // Restore the shared descriptor's blending for the pipelines below.
                    color.blendingEnabled = YES;
                    color.rgbBlendOperation = MTLBlendOperationAdd;
                    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                    color.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                }

                id<MTLFunction> mercVertFunc = [library newFunctionWithName:@"jak1_merc_vertex"];
                id<MTLFunction> mercFragFunc = [library newFunctionWithName:@"jak1_merc_fragment"];
                if (mercVertFunc != nil && mercFragFunc != nil) {
                    pDesc.vertexFunction = mercVertFunc;
                    pDesc.fragmentFunction = mercFragFunc;
                    pDesc.vertexDescriptor = nil;
                    // GS alpha blend modes, following setup_opengl_from_draw_mode
                    // (OpenGOAL background_common.cpp). Alpha channel: ONE, ZERO.
                    MTLRenderPipelineColorAttachmentDescriptor *color = pDesc.colorAttachments[0];
                    for (uint32_t blend = 0; blend < 8; blend++) {
                        color.blendingEnabled = blend != 0 && blend != 6;  // 6: SRC_SRC_SRC_SRC = no blend
                        color.rgbBlendOperation = MTLBlendOperationAdd;
                        color.alphaBlendOperation = MTLBlendOperationAdd;
                        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                        color.destinationAlphaBlendFactor = MTLBlendFactorZero;
                        switch (blend) {
                            case 1:  // SRC_DST_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                                break;
                            case 2:  // SRC_0_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            case 3:  // SRC_0_FIX_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorOne;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            case 4:  // SRC_DST_FIX_DST, blend color set to 0.5 on the encoder
                                color.sourceRGBBlendFactor = MTLBlendFactorBlendColor;
                                color.destinationRGBBlendFactor = MTLBlendFactorBlendColor;
                                break;
                            case 5:  // ZERO_SRC_SRC_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                color.rgbBlendOperation = MTLBlendOperationReverseSubtract;
                                break;
                            case 7:  // SRC_0_DST_DST
                                color.sourceRGBBlendFactor = MTLBlendFactorDestinationAlpha;
                                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                                break;
                            default:
                                color.sourceRGBBlendFactor = MTLBlendFactorOne;
                                color.destinationRGBBlendFactor = MTLBlendFactorZero;
                                break;
                        }
                        error = nil;
                        _mercPipelineStates[blend] = [device newRenderPipelineStateWithDescriptor:pDesc
                                                                                            error:&error];
                        if (error != nil) {
                            NSLog(@"Jak1MetalRenderer Merc pipeline error: %@", error.localizedDescription);
                        }
                    }
                    // Restore the shared descriptor's blending for the sprite pipelines below.
                    color.blendingEnabled = YES;
                    color.rgbBlendOperation = MTLBlendOperationAdd;
                    color.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                }

                id<MTLFunction> eyeVertFunc = [library newFunctionWithName:@"jak1_eye_vertex"];
                id<MTLFunction> eyeFragFunc = [library newFunctionWithName:@"jak1_eye_fragment"];
                if (eyeVertFunc != nil && eyeFragFunc != nil) {
                    MTLRenderPipelineDescriptor *eyeDesc = [[MTLRenderPipelineDescriptor alloc] init];
                    eyeDesc.vertexFunction = eyeVertFunc;
                    eyeDesc.fragmentFunction = eyeFragFunc;
                    eyeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
                    for (int blend = 0; blend < 2; blend++) {
                        MTLRenderPipelineColorAttachmentDescriptor *eyeColor = eyeDesc.colorAttachments[0];
                        eyeColor.blendingEnabled = blend == 1;
                        eyeColor.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                        eyeColor.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                        eyeColor.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                        eyeColor.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                        error = nil;
                        _eyePipelineStates[blend] = [device newRenderPipelineStateWithDescriptor:eyeDesc
                                                                                           error:&error];
                        if (error != nil) {
                            NSLog(@"Jak1MetalRenderer eye pipeline error: %@", error.localizedDescription);
                        }
                    }
                }

                id<MTLFunction> spriteVertFunc = [library newFunctionWithName:@"jak1_sprite_vertex"];
                id<MTLFunction> spriteFragFunc = [library newFunctionWithName:@"jak1_sprite_fragment"];
                if (spriteVertFunc != nil && spriteFragFunc != nil) {
                    pDesc.vertexFunction = spriteVertFunc;
                    pDesc.fragmentFunction = spriteFragFunc;
                    pDesc.vertexDescriptor = nil;
                    MTLRenderPipelineColorAttachmentDescriptor *color = pDesc.colorAttachments[0];
                    for (int blend = 0; blend < 3; blend++) {
                        const auto mode = static_cast<jak1::Sprite3Blend>(blend);
                        color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                        color.destinationRGBBlendFactor = mode == jak1::Sprite3Blend::Alpha
                            ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOne;
                        color.rgbBlendOperation = mode == jak1::Sprite3Blend::Subtract
                            ? MTLBlendOperationReverseSubtract : MTLBlendOperationAdd;
                        error = nil;
                        _spritePipelineStates[blend] =
                            [device newRenderPipelineStateWithDescriptor:pDesc error:&error];
                        if (error != nil) {
                            NSLog(@"Jak1MetalRenderer sprite pipeline error: %@", error.localizedDescription);
                        }
                    }
                    id<MTLFunction> premultipliedFunc =
                        [library newFunctionWithName:@"jak1_sprite_premultiplied_fragment"];
                    if (premultipliedFunc != nil) {
                        pDesc.fragmentFunction = premultipliedFunc;
                        color.sourceRGBBlendFactor = MTLBlendFactorOne;
                        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                        color.rgbBlendOperation = MTLBlendOperationAdd;
                        // Additive sprites output alpha 0, so leave the framebuffer alpha alone.
                        color.sourceAlphaBlendFactor = MTLBlendFactorZero;
                        color.destinationAlphaBlendFactor = MTLBlendFactorOne;
                        color.alphaBlendOperation = MTLBlendOperationAdd;
                        error = nil;
                        _spritePremultipliedPipelineState =
                            [device newRenderPipelineStateWithDescriptor:pDesc error:&error];
                        if (error != nil) {
                            NSLog(@"Jak1MetalRenderer sprite pipeline error: %@", error.localizedDescription);
                        }
                    }
                }
            }
        }

        // Direct GIF draws are 2D and carry no depth.
        MTLDepthStencilDescriptor *dDesc = [[MTLDepthStencilDescriptor alloc] init];
        dDesc.depthCompareFunction = MTLCompareFunctionAlways;
        dDesc.depthWriteEnabled = NO;
        _depthState = [device newDepthStencilStateWithDescriptor:dDesc];

        // GS depth is "greater is closer" (ZTST GEQUAL), so the buffer is cleared to 0.
        MTLDepthStencilDescriptor *genericDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
        genericDepthDesc.depthCompareFunction = MTLCompareFunctionGreaterEqual;
        genericDepthDesc.depthWriteEnabled = YES;
        _genericDepthState = [device newDepthStencilStateWithDescriptor:genericDepthDesc];
        genericDepthDesc.depthWriteEnabled = NO;
        _genericDepthStateNoWrite = [device newDepthStencilStateWithDescriptor:genericDepthDesc];

        MTLSamplerDescriptor *sDesc = [[MTLSamplerDescriptor alloc] init];
        sDesc.minFilter = MTLSamplerMinMagFilterLinear;
        sDesc.magFilter = MTLSamplerMinMagFilterLinear;
        sDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _samplerState = [device newSamplerStateWithDescriptor:sDesc];

        // Generic adgifs pick filtering (TEX1 MMAG) and wrapping (CLAMP) per draw.
        for (int filter = 0; filter < 2; filter++) {
            for (int clampS = 0; clampS < 2; clampS++) {
                for (int clampT = 0; clampT < 2; clampT++) {
                    MTLSamplerDescriptor *genericSampler = [[MTLSamplerDescriptor alloc] init];
                    genericSampler.minFilter = filter ? MTLSamplerMinMagFilterLinear
                                                      : MTLSamplerMinMagFilterNearest;
                    genericSampler.magFilter = genericSampler.minFilter;
                    genericSampler.sAddressMode = clampS ? MTLSamplerAddressModeClampToEdge
                                                         : MTLSamplerAddressModeRepeat;
                    genericSampler.tAddressMode = clampT ? MTLSamplerAddressModeClampToEdge
                                                         : MTLSamplerAddressModeRepeat;
                    _genericSamplers[filter][clampS][clampT] =
                        [device newSamplerStateWithDescriptor:genericSampler];
                    // Merc2 (setup_opengl_from_draw_mode): same wrap/filter bits, plus trilinear
                    // mipmapping when filtered. Models rely on REPEAT for UVs outside 0..1.
                    if (filter) genericSampler.mipFilter = MTLSamplerMipFilterLinear;
                    _mercSamplers[filter][clampS][clampT] =
                        [device newSamplerStateWithDescriptor:genericSampler];
                }
            }
        }

        MTLTextureDescriptor *tDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        _defaultTexture = [device newTextureWithDescriptor:tDesc];
        uint32_t white = 0xFFFFFFFF;
        [_defaultTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];

        // Like the OpenGOAL loader's always-loaded common level: GAME's FR3 (built from the disc at
        // import) holds the common Merc art (Jak, Daxter) including their facial blend shapes. The
        // title's Merc models arrive with the title level's FR3.
        jak1::RequestBackgroundLevels({"game"});

        MTLTextureDescriptor *eyeDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                       width:kEyeTextureSize height:kEyeTextureSize mipmapped:NO];
        eyeDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        eyeDescriptor.storageMode = MTLStorageModePrivate;
        for (int slot = 0; slot < kEyeSlotCount; slot++) {
            _eyeTextures[slot] = [device newTextureWithDescriptor:eyeDescriptor];
        }
    }
    return self;
}

- (void)setMercMemorySnapshot:(NSData *)snapshot {
    _mercMemorySnapshot = snapshot;
}

- (void)setDMABucketTraceOffsets:(NSData *)offsets {
    _bucketTraceOffsets.assign(static_cast<const uint32_t *>(offsets.bytes),
                               static_cast<const uint32_t *>(offsets.bytes) + offsets.length / sizeof(uint32_t));
    static int loggedFrames = 0;
    if (loggedFrames < 3 && !_bucketTraceOffsets.empty()) {
        size_t reached = 0;
        for (uint32_t offset : _bucketTraceOffsets) reached += offset != UINT32_MAX;
        NSLog(@"jakIOS: DMA buckets reached %zu/%zu (tfrag l0 @%u l1 @%u)", reached, _bucketTraceOffsets.size(),
              _bucketTraceOffsets.size() > 6 ? _bucketTraceOffsets[6] : 0,
              _bucketTraceOffsets.size() > 13 ? _bucketTraceOffsets[13] : 0);
        loggedFrames++;
    }
}

// EyeRenderer::run_gpu: composite each decoded eye into its slot texture before the main pass.
- (void)encodeEyesFromDMA:(NSData *)dmaBuffer commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (_eyePipelineStates[0] == nil || _eyePipelineStates[1] == nil) return;
    std::vector<SingleEyeDraws> eyes;
    DecodeEyeDraws(dmaBuffer, &eyes);
    if (eyes.empty()) return;

    // Shared pool: includes FR3 level textures (NPC eyes), not just the bundled title/GAME Merc art.
    // Looked up in the VRAM layout at the eye bucket (kEyeTexturePoolSnapshot): later uploads in the chain
    // (water / sprite / HUD tpages) can reuse the eye textures' blocks.
    auto textureForTbp = [](uint32_t tbp) -> id<MTLTexture> { return jak1::PoolTextureForTbpAtEyes(tbp); };

    // Per eye: background clear quad (samples the iris at st 0,0), iris, pupil, lid.
    std::vector<simd_float4> vertices;
    for (const SingleEyeDraws &eye : eyes) {
        const float lower = 768 - 256, upper = 768 + 256;
        vertices.push_back(simd_make_float4(lower, lower, 0, 0));
        vertices.push_back(simd_make_float4(upper, lower, 0, 0));
        vertices.push_back(simd_make_float4(lower, upper, 0, 0));
        vertices.push_back(simd_make_float4(upper, upper, 0, 0));
        AppendEyeQuad(&vertices, eye.iris, eye);
        AppendEyeQuad(&vertices, eye.pupil, eye);
        AppendEyeQuad(&vertices, eye.lid, eye);
    }
    const jak1::FrameUpload vertexUpload = jak1::FrameUploadBytes(vertices.data(), vertices.size() * sizeof(simd_float4));

    for (size_t eyeIndex = 0; eyeIndex < eyes.size(); eyeIndex++) {
        const SingleEyeDraws &eye = eyes[eyeIndex];
        const int slot = eye.slot();
        if (slot < 0 || slot >= kEyeSlotCount) continue;
        id<MTLTexture> iris = textureForTbp(eye.irisTbp);
        id<MTLTexture> pupil = textureForTbp(eye.pupilTbp);
        id<MTLTexture> lid = textureForTbp(eye.lidTbp);

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = _eyeTextures[slot];
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 0);
        id<MTLRenderCommandEncoder> eyeEncoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [eyeEncoder setVertexBuffer:vertexUpload.buffer offset:vertexUpload.offset atIndex:0];
        [eyeEncoder setFragmentSamplerState:_samplerState atIndex:0];
        const NSUInteger base = eyeIndex * 16;
        auto drawQuad = [&](id<MTLTexture> texture, NSUInteger quad, int pipeline) {
            if (texture == nil) return;
            [eyeEncoder setRenderPipelineState:_eyePipelineStates[pipeline]];
            [eyeEncoder setFragmentTexture:texture atIndex:0];
            [eyeEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:base + quad * 4 vertexCount:4];
        };
        drawQuad(iris, 0, 0);   // background
        drawQuad(iris, 1, 0);   // iris
        drawQuad(pupil, 2, 1);  // pupil, alpha blended
        drawQuad(lid, 3, 0);    // lid
        [eyeEncoder endEncoding];
        _eyeTextureValid[slot] = YES;
    }

    if (!_loggedEyeDraws) {
        const SingleEyeDraws &first = eyes.front();
        NSLog(@"jakIOS: decoded %zu eye draws; first slot=%d tbp iris=%u pupil=%u lid=%u found=%d%d%d",
              eyes.size(), first.slot(), first.irisTbp, first.pupilTbp, first.lidTbp,
              textureForTbp(first.irisTbp) != nil, textureForTbp(first.pupilTbp) != nil,
              textureForTbp(first.lidTbp) != nil);
        _loggedEyeDraws = YES;
    }
}

- (void)renderFrameWithPassDescriptor:(MTLRenderPassDescriptor *)passDesc
                             drawable:(id<CAMetalDrawable>)drawable
                         commandQueue:(id<MTLCommandQueue>)commandQueue
                dmaBuffer:(NSData *)dmaBuffer
            textureBuffer:(id<MTLBuffer>)textureBuffer
                goalMemory:(const void *)goalMemory
            goalMemorySize:(NSUInteger)goalMemorySize
             displayAlpha:(double)displayAlpha
             contentReady:(BOOL)contentReady {
    const CFTimeInterval cpuFrameStart = CACurrentMediaTime();
    double performanceStages[9] = {};
    if (passDesc == nil || drawable == nil || commandQueue == nil) {
        return;
    }

    // Black, since this clear also fills the letterbox/pillarbox bars outside the game viewport.
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.depthAttachment.clearDepth = 0.0;
    passDesc.depthAttachment.loadAction = MTLLoadActionClear;
    passDesc.stencilAttachment.clearStencil = 0;
    passDesc.stencilAttachment.loadAction = MTLLoadActionClear;

    id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
    jak1::FrameUploadsBeginFrame(_device);
    // Level loads/unloads happen between frames, before anything looks levels up.
    if (_background != nullptr) _background->beginFrame();
    const CFTimeInterval prepassStart = CACurrentMediaTime();
    if (contentReady) {
        [self encodeEyesFromDMA:dmaBuffer commandBuffer:cmdBuf];
        if (_skyBlender != nullptr && dmaBuffer != nil) {
            _skyBlender->encode(cmdBuf, static_cast<const uint8_t *>(dmaBuffer.bytes), dmaBuffer.length,
                                _bucketTraceOffsets);
        }
        if (_ocean != nullptr && dmaBuffer != nil) {
            _ocean->prepare(cmdBuf, static_cast<const uint8_t *>(dmaBuffer.bytes), dmaBuffer.length,
                            _bucketTraceOffsets);
        }
    }
    performanceStages[5] += CACurrentMediaTime() - prepassStart;
    id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];

    // The game's aspect-ratio setting drives the viewport through pc-set-letterbox: "fit to
    // screen" requests the full window (and widens its projection to match), while fixed ratios
    // like 4:3 request a smaller box. Keep the requested aspect, centered in the drawable; the
    // aspect (not the raw size) is used so point/pixel scale differences can't crop the image.
    // From the drawable itself: this runs on the render thread, where MTKView state must not be read.
    const CGSize drawableSize = CGSizeMake(drawable.texture.width, drawable.texture.height);
    double viewportWidth = drawableSize.width;
    double viewportHeight = drawableSize.height;
    const uint64_t letterbox = gLetterboxSize.load(std::memory_order_relaxed);
    const double letterboxWidth = static_cast<double>(letterbox >> 32);
    const double letterboxHeight = static_cast<double>(letterbox & 0xFFFFFFFFu);
    if (letterboxWidth > 0 && letterboxHeight > 0 && drawableSize.height > 0) {
        const double gameAspect = letterboxWidth / letterboxHeight;
        if (gameAspect < drawableSize.width / drawableSize.height) {
            viewportWidth = viewportHeight * gameAspect;
        } else {
            viewportHeight = viewportWidth / gameAspect;
        }
    }
    MTLViewport gameViewport {
        (drawableSize.width - viewportWidth) * 0.5,
        (drawableSize.height - viewportHeight) * 0.5,
        viewportWidth,
        viewportHeight,
        0.0,
        1.0
    };
    [encoder setViewport:gameViewport];

    if (_pipelineState != nil) {
        [encoder setRenderPipelineState:_pipelineState];
        if (_depthState != nil) {
            [encoder setDepthStencilState:_depthState];
        }

        MetalUniforms uniforms {};
        uniforms.projectionMatrix = MatrixIdentity();
        uniforms.modelViewMatrix = MatrixIdentity();
        // The PCRTC fade is applied once at the end of the frame, not per pass.
        uniforms.colorMultiplier = simd_make_float4(1.0f, 1.0f, 1.0f, 1.0f);
        uniforms.flags = 0;

        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];

        if (_samplerState != nil) {
            [encoder setFragmentSamplerState:_samplerState atIndex:0];
        }
        if (_defaultTexture != nil) {
            [encoder setFragmentTexture:_defaultTexture atIndex:0];
        }

        std::vector<MetalVertex> vertices;
        std::vector<GifDrawBatch> batches;
        std::vector<std::pair<size_t, size_t>> directRanges;
        std::vector<std::pair<size_t, int>> oceanBuckets;  // trace offset, bucket
        std::vector<std::pair<size_t, size_t>> skipRanges;
        if (dmaBuffer != nil) {
            static uint32_t directLogFrame = 0;
            const bool logDirect = directLogFrame++ % 300 == 0;
            for (int bucket : DirectBuckets()) {
                size_t begin = 0, end = 0;
                if (BucketTraceRange(_bucketTraceOffsets, bucket, dmaBuffer.length, &begin, &end)) {
                    directRanges.push_back({begin, end});
                    skipRanges.push_back({begin, end});
                    if (logDirect && bucket != 3) {
                        NSLog(@"jakIOS: direct bucket %d carries %zu bytes", bucket, end - begin);
                    }
                }
            }
            for (int bucket : {jak1::Ocean::kMidAndFarBucket, jak1::Ocean::kNearBucket}) {
                size_t begin = 0, end = 0;
                if (_ocean != nullptr && BucketTraceRange(_bucketTraceOffsets, bucket, dmaBuffer.length, &begin, &end)) {
                    oceanBuckets.push_back({begin, bucket});
                    skipRanges.push_back({begin, end});
                }
            }
        }
        // Once bucket offsets are known, every bucket has a dedicated renderer or, as with OpenGOAL's
        // EmptyBucketRenderer, draws nothing. The untextured fallback would otherwise turn textured
        // or translucent GIF data in unported buckets into opaque colored quads.
        if (_bucketTraceOffsets.empty()) {
            DecodeDmaTrace(dmaBuffer, skipRanges, &vertices, &batches);
        }
        if (_lastDecodedVertexCount != vertices.size() || _lastDecodedBatchCount != batches.size()) {
            NSLog(@"jakIOS: decoded GIF draws: %zu vertices across %zu triangle batches",
                  vertices.size(), batches.size());
            _lastDecodedVertexCount = vertices.size();
            _lastDecodedBatchCount = batches.size();
        }

        jak1::Generic2Frame generic;
        if (dmaBuffer != nil) {
            const CFTimeInterval start = CACurrentMediaTime();
            jak1::DecodeGeneric2Jak1(static_cast<const uint8_t *>(dmaBuffer.bytes),
                                     dmaBuffer.length, &generic);
            performanceStages[0] += CACurrentMediaTime() - start;
        }

        // Levels whose FR3 finished loading bring their actors' Merc models (bridges, distant
        // islands, windmills...); GAME and the title come the same way (built from the disc at import).
        // Match by level name: levels share some models (training and village1 both carry
        // sharkey and warp-gate-switch), so a model-name check drops whole levels.
        // Unloaded FR3 levels go first (a level may unload and load again between frames).
        for (const std::string &name : jak1::TakeUnloadedMercLevels()) {
            _mercLevels.erase(std::remove_if(_mercLevels.begin(), _mercLevels.end(),
                [&](const MercLevelResources &existing) { return existing.name == name; }),
                _mercLevels.end());
        }
        for (const auto &loaded : jak1::TakeLoadedMercLevels()) {
            auto known = std::find_if(_mercLevels.begin(), _mercLevels.end(),
                [&](const MercLevelResources &existing) { return existing.name == loaded->name; });
            if (known != _mercLevels.end()) continue;
            MercLevelResources level;
            level.name = loaded->name;
            level.asset.vertices.resize(loaded->vertices.size() / sizeof(MercVertex));
            memcpy(level.asset.vertices.data(), loaded->vertices.data(), loaded->vertices.size());
            level.asset.indices = loaded->indices;
            for (const auto &model : loaded->models) {
                MercModel out;
                out.name = model.name;
                out.maxBones = model.maxBones;
                out.stVifAdd = model.stVifAdd;
                out.xyzScale = model.xyzScale;
                out.stMagic = model.stMagic;
                auto convertDraws = [](const std::vector<jak1::LoadedMercLevel::Draw> &draws) {
                    std::vector<MercDraw> result;
                    for (const auto &draw : draws) {
                        MercDraw d;
                        d.firstIndex = draw.firstIndex;
                        d.indexCount = draw.indexCount;
                        d.texture = draw.texture;
                        d.mode = draw.mode;
                        d.eyeId = draw.eyeId;
                        result.push_back(d);
                    }
                    return result;
                };
                for (const auto &effect : model.effects) {
                    MercEffect e;
                    e.draws = convertDraws(effect.draws);
                    e.hasModDraw = effect.hasModDraw;
                    if (e.hasModDraw) {
                        e.fixDraws = convertDraws(effect.fixDraws);
                        e.modDraws = convertDraws(effect.modDraws);
                        e.modVertices.resize(effect.modVertices.size() / sizeof(MercVertex));
                        memcpy(e.modVertices.data(), effect.modVertices.data(),
                               e.modVertices.size() * sizeof(MercVertex));
                        e.blercFloats = effect.blercFloats;
                        e.blercInts = effect.blercInts;
                        e.vertexLump4Addr = effect.vertexLump4Addr;
                        e.fragmentMask = effect.fragmentMask;
                        e.expectVidxEnd = effect.expectVidxEnd;
                    }
                    out.effects.push_back(std::move(e));
                }
                level.asset.modelLookup[out.name] = level.asset.models.size();
                level.asset.models.push_back(std::move(out));
            }
            if (level.asset.vertices.empty() || level.asset.indices.empty()) continue;
            level.vertexBuffer = [_device newBufferWithBytes:level.asset.vertices.data()
                                                      length:level.asset.vertices.size() * sizeof(MercVertex)
                                                     options:MTLResourceStorageModeShared];
            level.indexBuffer = [_device newBufferWithBytes:level.asset.indices.data()
                                                     length:level.asset.indices.size() * sizeof(uint32_t)
                                                    options:MTLResourceStorageModeShared];
            // Drawing reads vertices from vertexBuffer only; the CPU copy is just for bounds logging.
            level.asset.vertices = {};
            level.textures = [NSMutableArray arrayWithCapacity:loaded->textures.size()];
            for (id<MTLTexture> texture : loaded->textures) [level.textures addObject:texture];
            NSLog(@"jakIOS: Merc models from FR3 level %s: %zu models", loaded->name.c_str(),
                  level.asset.models.size());
            // Lookups take the first level with a model name: the title's models win over GAME's.
            if (level.name == "title") {
                _mercLevels.insert(_mercLevels.begin(), std::move(level));
            } else {
                _mercLevels.push_back(std::move(level));
            }
        }

        MercUniforms mercUniforms {};
        mercUniforms.colorMultiplier = 1.0f;
        mercUniforms.fogColor[3] = 1.0f / 255.0f;
        if (dmaBuffer != nil) {
            DefaultRegsFogColor(static_cast<const uint8_t *>(dmaBuffer.bytes), dmaBuffer.length,
                                mercUniforms.fogColor);
        }
        std::vector<MercSubmission> mercSubmissions;
        const MercMemoryView mercMemory {_mercMemorySnapshot, static_cast<const uint8_t *>(goalMemory),
                                         goalMemorySize};
        {
            const CFTimeInterval start = CACurrentMediaTime();
            DecodeMercSubmissions(dmaBuffer, mercMemory, _mercLevels, &mercUniforms, &mercSubmissions);
            performanceStages[1] += CACurrentMediaTime() - start;
        }
        LogMercBoundsOnce(_mercLevels, mercUniforms, mercSubmissions);
        if (_lastMercSubmissionCount != mercSubmissions.size()) {
            const char *firstModel = mercSubmissions.empty() || mercSubmissions.front().model == nullptr
                ? "none" : mercSubmissions.front().model->name.c_str();
            std::string modelNames;
            for (const MercSubmission &submission : mercSubmissions) {
                if (!modelNames.empty()) modelNames += ",";
                modelNames += submission.model == nullptr ? "none" : submission.model->name;
            }
            NSLog(@"jakIOS: decoded Merc submissions: %zu first-model=%s models=%s",
                  mercSubmissions.size(), firstModel, modelNames.c_str());
            _lastMercSubmissionCount = mercSubmissions.size();
        }
        if (_lastGenericFragmentCount != generic.fragmentCount ||
            _lastGenericRejectedCount != generic.rejectedTransfers) {
            NSLog(@"jakIOS: decoded generic draws: buckets=%u fragments=%u adgifs=%u vertices=%zu "
                  @"indices=%zu batches=%zu rejected=%u%s%s",
                  generic.bucketCount, generic.fragmentCount, generic.adgifCount,
                  generic.vertices.size(), generic.indices.size(), generic.batches.size(),
                  generic.rejectedTransfers,
                  generic.firstRejection.empty() ? "" : " first-rejection=",
                  generic.firstRejection.c_str());
            _lastGenericFragmentCount = generic.fragmentCount;
            _lastGenericRejectedCount = generic.rejectedTransfers;
        }

        id<MTLBuffer> vertexBuffer = nil;
        if (!vertices.empty() && !batches.empty()) {
            vertexBuffer = [_device newBufferWithBytes:vertices.data()
                                                length:vertices.size() * sizeof(MetalVertex)
                                               options:MTLResourceStorageModeShared];
        }
        jak1::Sprite3Frame sprites;
        if (dmaBuffer != nil) {
            const CFTimeInterval start = CACurrentMediaTime();
            jak1::DecodeSprite3Jak1(static_cast<const uint8_t *>(dmaBuffer.bytes),
                                    dmaBuffer.length, &sprites);
            performanceStages[2] += CACurrentMediaTime() - start;
        }
        if (_lastSpriteCount != sprites.spriteCount ||
            _lastSpriteRejectedCount != sprites.rejectedChunks) {
            NSLog(@"jakIOS: decoded sprite draws: chunks=%u sprites=%u batches=%zu rejected=%u",
                  sprites.chunkCount, sprites.spriteCount, sprites.batches.size(),
                  sprites.rejectedChunks);
            _lastSpriteCount = sprites.spriteCount;
            _lastSpriteRejectedCount = sprites.rejectedChunks;
        }

        id<MTLBuffer> genericVertexBuffer = nil;
        id<MTLBuffer> genericIndexBuffer = nil;
        const uint32_t frameBufferSlot = static_cast<uint32_t>(_frameBufferCounter++ % 3);
        if (_genericPipelineStates[0] != nil && !generic.batches.empty()) {
            genericVertexBuffer = UpdateFrameBuffer(
                _device, _genericVertexBuffers, _genericVertexCapacity, frameBufferSlot,
                generic.vertices.data(), generic.vertices.size() * sizeof(jak1::Generic2Vertex));
            genericIndexBuffer = UpdateFrameBuffer(
                _device, _genericIndexBuffers, _genericIndexCapacity, frameBufferSlot,
                generic.indices.data(), generic.indices.size() * sizeof(uint32_t));
        }
        id<MTLBuffer> spriteVertexBuffer = nil;
        id<MTLBuffer> spriteIndexBuffer = nil;
        if (_spritePipelineStates[0] != nil && !sprites.batches.empty()) {
            spriteVertexBuffer = UpdateFrameBuffer(
                _device, _spriteVertexBuffers, _spriteVertexCapacity, frameBufferSlot,
                sprites.vertices.data(), sprites.vertices.size() * sizeof(jak1::Sprite3Vertex));
            spriteIndexBuffer = UpdateFrameBuffer(
                _device, _spriteIndexBuffers, _spriteIndexCapacity, frameBufferSlot,
                sprites.indices.data(), sprites.indices.size() * sizeof(uint32_t));
        }

        std::vector<NSUInteger> mercBoneOffsets(mercSubmissions.size());
        std::vector<MercMatrix> mercBones;
        const CFTimeInterval bufferStart = CACurrentMediaTime();
        for (size_t i = 0; i < mercSubmissions.size(); i++) {
            mercBoneOffsets[i] = mercBones.size() * sizeof(MercMatrix);
            mercBones.insert(mercBones.end(), mercSubmissions[i].bones.begin(), mercSubmissions[i].bones.end());
        }
        id<MTLBuffer> mercBoneBuffer = mercBones.empty() ? nil : UpdateFrameBuffer(
            _device, _mercBoneBuffers, _mercBoneCapacity, frameBufferSlot,
            mercBones.data(), mercBones.size() * sizeof(MercMatrix));
        performanceStages[3] += CACurrentMediaTime() - bufferStart;

        // Draw every renderer's batches in DMA order so later buckets draw on top.
        enum class DrawKind { Gif, Generic, Merc, Sprite, Background, Direct, Ocean, Shadow };
        struct DrawItem {
            size_t traceOffset;
            DrawKind kind;
            size_t index;
        };
        std::vector<DrawItem> drawItems;
        if (vertexBuffer != nil) {
            for (size_t i = 0; i < batches.size(); i++) {
                drawItems.push_back({batches[i].traceOffset, DrawKind::Gif, i});
            }
        }
        if (genericVertexBuffer != nil && genericIndexBuffer != nil) {
            for (size_t i = 0; i < generic.batches.size(); i++) {
                drawItems.push_back({generic.batches[i].traceOffset, DrawKind::Generic, i});
            }
        }
        if (_mercPipelineStates[0] != nil) {
            for (size_t i = 0; i < mercSubmissions.size(); i++) {
                drawItems.push_back({mercSubmissions[i].traceOffset, DrawKind::Merc, i});
            }
        }
        if (spriteVertexBuffer != nil && spriteIndexBuffer != nil) {
            for (size_t i = 0; i < sprites.batches.size(); i++) {
                drawItems.push_back({sprites.batches[i].traceOffset, DrawKind::Sprite, i});
            }
        }
        for (size_t i = 0; i < directRanges.size() && _direct != nullptr; i++) {
            drawItems.push_back({directRanges[i].first, DrawKind::Direct, i});
        }
        for (const auto &ocean : oceanBuckets) {
            drawItems.push_back({ocean.first, DrawKind::Ocean, static_cast<size_t>(ocean.second)});
        }
        if (_shadow != nullptr && dmaBuffer != nil &&
            jak1::Shadow::kBucket < static_cast<int>(_bucketTraceOffsets.size()) &&
            _bucketTraceOffsets[jak1::Shadow::kBucket] != UINT32_MAX) {
            drawItems.push_back({_bucketTraceOffsets[jak1::Shadow::kBucket], DrawKind::Shadow, 0});
        }
        // Background buckets (tfrag) are drawn at their bucket's position in the chain.
        if (_background != nullptr && dmaBuffer != nil) {
            for (int bucket : jak1::Background::buckets()) {
                if (bucket < static_cast<int>(_bucketTraceOffsets.size()) &&
                    _bucketTraceOffsets[bucket] != UINT32_MAX) {
                    drawItems.push_back({_bucketTraceOffsets[bucket], DrawKind::Background,
                                         static_cast<size_t>(bucket)});
                }
            }
        }
        std::stable_sort(drawItems.begin(), drawItems.end(),
                         [](const DrawItem &a, const DrawItem &b) {
                             return a.traceOffset < b.traceOffset;
                         });


        sprites.constants.colorMultiplier = 1.0f;
        bool haveActiveKind = false;
        DrawKind activeKind = DrawKind::Gif;
        for (const DrawItem &item : drawItems) {
            const bool kindChanged = !haveActiveKind || activeKind != item.kind;
            haveActiveKind = true;
            activeKind = item.kind;
            switch (item.kind) {
                case DrawKind::Gif: {
                    const GifDrawBatch &batch = batches[item.index];
                    if (kindChanged) {
                        [encoder setRenderPipelineState:_pipelineState];
                        [encoder setDepthStencilState:_depthState];
                        // Generic draws bind their own texture and sampler.
                        [encoder setFragmentSamplerState:_samplerState atIndex:0];
                        [encoder setFragmentTexture:_defaultTexture atIndex:0];
                        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
                        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
                        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
                    }
                    [encoder drawPrimitives:batch.primitiveType
                                vertexStart:batch.firstVertex
                                vertexCount:batch.vertexCount];
                    break;
                }
                case DrawKind::Generic: {
                    const jak1::Generic2Batch &batch = generic.batches[item.index];
                    if (kindChanged) {
                        [encoder setVertexBuffer:genericVertexBuffer offset:0 atIndex:0];
                    }
                    [encoder setRenderPipelineState:_genericPipelineStates[batch.blend & 7]];
                    if (batch.blend == 4) {  // SRC_DST_FIX_DST
                        const float fixAlpha = batch.fix / 127.0f;
                        [encoder setBlendColorRed:0.0f green:0.0f blue:0.0f alpha:fixAlpha];
                    }
                    // PSMT4HH textures (tbp | 0x8000) resolve through the relocated copies,
                    // like OpenGOAL's lookup_mt4hh. Looked up in VRAM as of this bucket: later
                    // pris/water/common uploads reuse the blocks (Gol's silo dark eco pool).
                    id<MTLTexture> genericTexture = jak1::PoolTextureForTbpAtTraceOffset(batch.tbp,
                                                                                         batch.traceOffset);
                    [encoder setFragmentTexture:genericTexture != nil ? genericTexture : _defaultTexture
                                        atIndex:0];
                    [encoder setFragmentSamplerState:_genericSamplers[batch.filter ? 1 : 0]
                                                                     [batch.clampS ? 1 : 0]
                                                                     [batch.clampT ? 1 : 0]
                                             atIndex:0];
                    [encoder setDepthStencilState:batch.depthWrite ? _genericDepthState
                                                                   : _genericDepthStateNoWrite];
                    const jak1::Generic2Projection &projection = batch.projection;
                    Generic2Uniforms genericUniforms {};
                    genericUniforms.scale = simd_make_float4(projection.scale[0], projection.scale[1],
                                                             projection.scale[2], 0.0f);
                    genericUniforms.hvdfOffset = simd_make_float4(projection.hvdfOffset[0],
                                                                  projection.hvdfOffset[1],
                                                                  projection.hvdfOffset[2],
                                                                  projection.hvdfOffset[3]);
                    genericUniforms.fogConstants = simd_make_float4(projection.pfog0, projection.fogMin,
                                                                    projection.fogMax, 0.0f);
                    genericUniforms.mat23 = projection.mat23;
                    genericUniforms.mat32 = projection.mat32;
                    genericUniforms.mat33 = projection.mat33;
                    genericUniforms.colorMultiplier = 1.0f;
                    genericUniforms.alphaReject = batch.alphaReject;
                    genericUniforms.fogColor = simd_make_float4(mercUniforms.fogColor[0], mercUniforms.fogColor[1],
                                                                mercUniforms.fogColor[2], mercUniforms.fogColor[3]);
                    [encoder setVertexBytes:&genericUniforms length:sizeof(genericUniforms) atIndex:1];
                    [encoder setFragmentBytes:&genericUniforms length:sizeof(genericUniforms) atIndex:1];
                    // 0xFFFFFFFF indices restart the strip.
                    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                        indexCount:batch.indexCount
                                         indexType:MTLIndexTypeUInt32
                                       indexBuffer:genericIndexBuffer
                                 indexBufferOffset:batch.firstIndex * sizeof(uint32_t)];
                    break;
                }
                case DrawKind::Merc: {
                    const CFTimeInterval mercStart = CACurrentMediaTime();
                    const MercSubmission &submission = mercSubmissions[item.index];
                    if (submission.model == nullptr || submission.bones.empty() ||
                        submission.level >= _mercLevels.size()) break;
                    const MercLevelResources &level = _mercLevels[submission.level];
                    [encoder setVertexBytes:&mercUniforms length:sizeof(mercUniforms) atIndex:2];
                    [encoder setFragmentBytes:&mercUniforms length:sizeof(mercUniforms) atIndex:2];
                    [encoder setFragmentSamplerState:_samplerState atIndex:0];
                    [encoder setBlendColorRed:0.5f green:0.5f blue:0.5f alpha:0.5f];
                    [encoder setVertexBuffer:level.vertexBuffer offset:0 atIndex:0];
                    [encoder setVertexBuffer:mercBoneBuffer offset:mercBoneOffsets[item.index] atIndex:1];
                    [encoder setVertexBytes:&submission.lights length:sizeof(submission.lights) atIndex:3];
                    [encoder setFragmentBytes:&submission.lights length:sizeof(submission.lights) atIndex:3];
                    for (size_t effectIndex = 0; effectIndex < submission.model->effects.size(); effectIndex++) {
                        if (effectIndex < 64 && ((submission.effectEnableMask >> effectIndex) & 1) == 0) continue;
                        const bool ignoreAlpha = effectIndex < 64 &&
                            ((submission.ignoreAlphaMask >> effectIndex) & 1) != 0;
                        const MercEffect &effect = submission.model->effects[effectIndex];
                        // Merc2::handle_pc_model: with blerc weights or game-updated vertices, draw
                        // the fixed part from the level buffer and the modifiable part from
                        // freshly computed vertices.
                        jak1::FrameUpload modUpload;
                        if (effect.hasModDraw && !effect.modVertices.empty()) {
                            bool haveModVertices = false;
                            if (submission.usesBlerc) {
                                ApplyBlerc(effect, submission.blercWeights, &_modVertexScratch);
                                haveModVertices = true;
                            } else if (submission.usesModVerts &&
                                       effectIndex < submission.effectAddresses.size()) {
                                haveModVertices = UnpackModVertices(
                                    *submission.model, effect, submission.effectAddresses[effectIndex],
                                    mercMemory, &_modUnpackScratch, &_modVertexScratch);
                                if (!haveModVertices && _loggedModUnpackFailures.insert(submission.model->name).second) {
                                    NSLog(@"jakIOS: Merc %s effect %zu: game fragment data doesn't match FR3 "
                                          @"mod layout, drawing unmodified", submission.model->name.c_str(), effectIndex);
                                }
                            }
                            if (haveModVertices) {
                                modUpload = jak1::FrameUploadBytes(_modVertexScratch.data(),
                                                                   _modVertexScratch.size() * sizeof(MercVertex));
                            }
                        }
                        const bool drawMod = modUpload.buffer != nil;
                        std::vector<std::pair<const MercDraw *, bool>> effectDraws;  // draw, uses mod vertices
                        if (drawMod) {
                            for (const MercDraw &draw : effect.fixDraws) effectDraws.push_back({&draw, false});
                            for (const MercDraw &draw : effect.modDraws) effectDraws.push_back({&draw, true});
                        } else {
                            for (const MercDraw &draw : effect.draws) effectDraws.push_back({&draw, false});
                        }
                        bool modBound = false;
                        for (const auto &[drawPointer, usesMod] : effectDraws) {
                            const MercDraw &draw = *drawPointer;
                            if (static_cast<uint64_t>(draw.firstIndex) + draw.indexCount >
                                level.asset.indices.size()) continue;
                            if (usesMod != modBound) {
                                if (usesMod) {
                                    [encoder setVertexBuffer:modUpload.buffer offset:modUpload.offset atIndex:0];
                                } else {
                                    [encoder setVertexBuffer:level.vertexBuffer offset:0 atIndex:0];
                                }
                                modBound = usesMod;
                            }
                            uint32_t mode = draw.mode;
                            if (submission.usesWater) mode = (mode | (1u << 20)) & ~1u;
                            uint32_t blend = MercModeBlendEnabled(mode) ? MercModeAlphaBlend(mode) : 0;
                            // Boat summon fade: opaque draws become SRC_DST_SRC_DST alpha blends.
                            if (submission.forceBlend && (blend == 0 || blend == 6)) blend = 1;
                            [encoder setRenderPipelineState:_mercPipelineStates[blend]];
                            [encoder setDepthStencilState:!MercModeDepthTest(mode) ? _depthState :
                                (MercModeDepthWrite(mode) ? _genericDepthState : _genericDepthStateNoWrite)];
                            const MercFragmentFlags flags {MercModeDecal(mode) ? 1u : 0u,
                                                          ignoreAlpha ? 1u : 0u};
                            [encoder setFragmentBytes:&flags length:sizeof(flags) atIndex:0];
                            [encoder setFragmentSamplerState:_mercSamplers[MercModeFilter(mode) ? 1 : 0]
                                                                          [MercModeClampS(mode) ? 1 : 0]
                                                                          [MercModeClampT(mode) ? 1 : 0]
                                                     atIndex:0];
                            id<MTLTexture> texture = _defaultTexture;
                            const int eyeSlot = static_cast<int>(draw.eyeId % kEyeSlotCount);
                            if (draw.eyeId != 0xff && _eyeTextureValid[eyeSlot]) {
                                texture = _eyeTextures[eyeSlot];
                            } else if (draw.texture >= 0 &&
                                       static_cast<NSUInteger>(draw.texture) < level.textures.count) {
                                texture = level.textures[draw.texture];
                            }
                            [encoder setFragmentTexture:texture atIndex:0];
                            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                                indexCount:draw.indexCount
                                                 indexType:MTLIndexTypeUInt32
                                               indexBuffer:level.indexBuffer
                                         indexBufferOffset:draw.firstIndex * sizeof(uint32_t)];
                        }
                        if (modBound) [encoder setVertexBuffer:level.vertexBuffer offset:0 atIndex:0];
                    }
                    performanceStages[8] += CACurrentMediaTime() - mercStart;
                    haveActiveKind = false;
                    break;
                }
                case DrawKind::Direct: {
                    const CFTimeInterval directStart = CACurrentMediaTime();
                    // SkyRenderer::render / DirectRenderer::render over this bucket's transfers.
                    const uint8_t *trace = static_cast<const uint8_t *>(dmaBuffer.bytes);
                    const auto &range = directRanges[item.index];
                    _direct->resetState();
                    size_t offset = range.first;
                    uint32_t previousKind = 0;
                    while (offset + 16 <= range.second) {
                        uint64_t tag = 0;
                        uint32_t vif0 = 0, vif1 = 0;
                        memcpy(&tag, trace + offset, 8);
                        memcpy(&vif0, trace + offset + 8, 4);
                        memcpy(&vif1, trace + offset + 12, 4);
                        const uint32_t size = static_cast<uint32_t>(tag & 0xffff) * 16;
                        if (size > dmaBuffer.length - offset - 16) break;
                        const uint8_t *payload = trace + offset + 16;
                        const bool afterCall = previousKind == 5;  // the default-regs subroutine
                        if (size != 0 && !afterCall) {
                            if (IsDirectVifCode(vif0) || IsDirectVifCode(vif1)) {
                                _direct->renderVif(vif0, vif1, payload, size);
                            } else if (vif0 == 0 && vif1 == 0) {
                                _direct->renderGif(payload, size);  // raw GS setup packet
                            }
                        }
                        previousKind = static_cast<uint32_t>((tag >> 28) & 0x7);
                        offset += 16 + size;
                    }
                    const jak1::DirectViewport viewport {
                        static_cast<float>(gameViewport.originX), static_cast<float>(gameViewport.originY),
                        static_cast<float>(gameViewport.width), static_cast<float>(gameViewport.height)};
                    float fogColor[4] = {0, 0, 0, 1.0f / 255.0f};
                    DefaultRegsFogColor(trace, dmaBuffer.length, fogColor);
                    _direct->submit(encoder, viewport, fogColor);
                    performanceStages[6] += CACurrentMediaTime() - directStart;
                    haveActiveKind = false;
                    break;
                }
                case DrawKind::Ocean: {
                    const CFTimeInterval oceanStart = CACurrentMediaTime();
                    const jak1::DirectViewport viewport {
                        static_cast<float>(gameViewport.originX), static_cast<float>(gameViewport.originY),
                        static_cast<float>(gameViewport.width), static_cast<float>(gameViewport.height)};
                    float fogColor[4] = {0, 0, 0, 1.0f / 255.0f};
                    DefaultRegsFogColor(static_cast<const uint8_t *>(dmaBuffer.bytes), dmaBuffer.length, fogColor);
                    _ocean->submitBucket(encoder, static_cast<int>(item.index), viewport, fogColor);
                    performanceStages[7] += CACurrentMediaTime() - oceanStart;
                    haveActiveKind = false;
                    break;
                }
                case DrawKind::Shadow: {
                    const CFTimeInterval shadowStart = CACurrentMediaTime();
                    _shadow->submitBucket(encoder, static_cast<const uint8_t *>(dmaBuffer.bytes), dmaBuffer.length,
                                          _bucketTraceOffsets);
                    performanceStages[7] += CACurrentMediaTime() - shadowStart;
                    // The shadow binds its own pipeline/buffers and depth-stencil state.
                    haveActiveKind = false;
                    break;
                }
                case DrawKind::Background: {
                    const CFTimeInterval start = CACurrentMediaTime();
                    _background->renderBucket(encoder, static_cast<int>(item.index),
                                              static_cast<const uint8_t *>(dmaBuffer.bytes),
                                              dmaBuffer.length, _bucketTraceOffsets);
                    performanceStages[4] += CACurrentMediaTime() - start;
                    // The background binds its own pipeline/buffers; force the next kind to rebind.
                    haveActiveKind = false;
                    break;
                }
                case DrawKind::Sprite: {
                    const jak1::Sprite3Batch &batch = sprites.batches[item.index];
                    if (kindChanged) {
                        [encoder setVertexBuffer:spriteVertexBuffer offset:0 atIndex:0];
                        [encoder setVertexBytes:&sprites.constants length:sizeof(sprites.constants) atIndex:1];
                        [encoder setFragmentBytes:&sprites.constants length:sizeof(sprites.constants) atIndex:1];
                    }
                    if (batch.premultiplied) {
                        if (_spritePremultipliedPipelineState == nil) break;
                        [encoder setRenderPipelineState:_spritePremultipliedPipelineState];
                        for (uint32_t slot = 0; slot < jak1::kSprite3MaxSlots; slot++) {
                            const jak1::Sprite3TextureSlot &info = batch.slots[slot < batch.slotCount ? slot : 0];
                            // Unknown VRAM addresses fall back to white, i.e. the old untextured look.
                            id<MTLTexture> slotTexture = jak1::PoolTextureForTbp(info.tbp);
                            [encoder setFragmentTexture:slotTexture != nil ? slotTexture : _defaultTexture
                                                atIndex:slot];
                            [encoder setFragmentSamplerState:_genericSamplers[info.filter ? 1 : 0]
                                                                             [info.clampS ? 1 : 0]
                                                                             [info.clampT ? 1 : 0]
                                                     atIndex:slot];
                        }
                        [encoder setDepthStencilState:_genericDepthStateNoWrite];
                        const simd_float2 alphaRange = simd_make_float2(0.016f, 10.0f);
                        [encoder setFragmentBytes:&alphaRange length:sizeof(alphaRange) atIndex:2];
                        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                            indexCount:batch.indexCount
                                             indexType:MTLIndexTypeUInt32
                                           indexBuffer:spriteIndexBuffer
                                     indexBufferOffset:batch.firstIndex * sizeof(uint32_t)];
                        break;
                    }
                    [encoder setRenderPipelineState:_spritePipelineStates[static_cast<int>(batch.blend)]];
                    // Unknown VRAM addresses fall back to white, i.e. the old untextured look.
                    id<MTLTexture> spriteTexture = jak1::PoolTextureForTbp(batch.tbp);
                    [encoder setFragmentTexture:spriteTexture != nil ? spriteTexture : _defaultTexture
                                        atIndex:0];
                    // setup_opengl_from_draw_mode: filtering and wrap come from the adgif.
                    [encoder setFragmentSamplerState:_genericSamplers[batch.filter ? 1 : 0]
                                                                     [batch.clampS ? 1 : 0]
                                                                     [batch.clampT ? 1 : 0]
                                             atIndex:0];
                    [encoder setDepthStencilState:batch.depthWrite ? _genericDepthState
                                                                   : _genericDepthStateNoWrite];
                    // sprite.gc sets TEST to ATST GEQUAL aref 38, AFAIL FB_ONLY for every sprite.
                    // Without depth writes that needs no cutoff (world groups drop near-invisible
                    // fragments, like Sprite3::flush_sprites). With depth writes, pass 1 writes
                    // depth for alpha >= aref and pass 2 draws the rest without depth, so faint
                    // edges of depth-writing sprites don't hide sprites drawn after them.
                    constexpr float kSpriteAref = 38.0f / 127.0f;
                    const simd_float2 alphaRange = simd_make_float2(
                        batch.depthWrite ? kSpriteAref : (batch.hud ? 0.0f : 0.016f), 10.0f);
                    [encoder setFragmentBytes:&alphaRange length:sizeof(alphaRange) atIndex:2];
                    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                        indexCount:batch.indexCount
                                         indexType:MTLIndexTypeUInt32
                                       indexBuffer:spriteIndexBuffer
                                 indexBufferOffset:batch.firstIndex * sizeof(uint32_t)];
                    if (batch.depthWrite) {
                        const simd_float2 failRange = simd_make_float2(-10.0f, kSpriteAref);
                        [encoder setFragmentBytes:&failRange length:sizeof(failRange) atIndex:2];
                        [encoder setDepthStencilState:_genericDepthStateNoWrite];
                        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                            indexCount:batch.indexCount
                                             indexType:MTLIndexTypeUInt32
                                           indexBuffer:spriteIndexBuffer
                                     indexBufferOffset:batch.firstIndex * sizeof(uint32_t)];
                    }
                    break;
                }
            }
        }

        if (false && _mercPipelineStates[0] != nil && !mercSubmissions.empty()) {
            [encoder setVertexBytes:&mercUniforms length:sizeof(mercUniforms) atIndex:2];
            [encoder setFragmentSamplerState:_samplerState atIndex:0];
            [encoder setBlendColorRed:0.5f green:0.5f blue:0.5f alpha:0.5f];  // SRC_DST_FIX_DST
            // Draw every submitted model, as Merc2 does (helpers such as ndi-cam sit off-screen).
            for (const MercSubmission &submission : mercSubmissions) {
                if (submission.model == nullptr || submission.bones.empty() ||
                    submission.level >= _mercLevels.size()) continue;
                const MercLevelResources &level = _mercLevels[submission.level];
                [encoder setVertexBuffer:level.vertexBuffer offset:0 atIndex:0];
                id<MTLBuffer> bones = [_device newBufferWithBytes:submission.bones.data()
                                                            length:submission.bones.size() * sizeof(MercMatrix)
                                                           options:MTLResourceStorageModeShared];
                [encoder setVertexBuffer:bones offset:0 atIndex:1];
                [encoder setVertexBytes:&submission.lights length:sizeof(submission.lights) atIndex:3];
                [encoder setFragmentBytes:&submission.lights length:sizeof(submission.lights) atIndex:3];
                for (size_t effectIndex = 0; effectIndex < submission.model->effects.size(); effectIndex++) {
                    if (effectIndex < 64 && ((submission.effectEnableMask >> effectIndex) & 1) == 0) continue;
                    const bool ignoreAlpha = effectIndex < 64 &&
                        ((submission.ignoreAlphaMask >> effectIndex) & 1) != 0;
                    for (const MercDraw &draw : submission.model->effects[effectIndex].draws) {
                        if (static_cast<uint64_t>(draw.firstIndex) + draw.indexCount >
                            level.asset.indices.size()) continue;
                        uint32_t mode = draw.mode;
                        if (submission.usesWater) {
                            // Merc2::alloc_normal_draw: jak1 water forces blending, no z write.
                            mode = (mode | (1u << 20)) & ~1u;
                        }
                        const uint32_t blend = MercModeBlendEnabled(mode) ? MercModeAlphaBlend(mode) : 0;
                        [encoder setRenderPipelineState:_mercPipelineStates[blend]];
                        if (!MercModeDepthTest(mode)) {
                            [encoder setDepthStencilState:_depthState];
                        } else {
                            [encoder setDepthStencilState:MercModeDepthWrite(mode) ? _genericDepthState
                                                                                  : _genericDepthStateNoWrite];
                        }
                        const MercFragmentFlags flags {MercModeDecal(mode) ? 1u : 0u, ignoreAlpha ? 1u : 0u};
                        [encoder setFragmentBytes:&flags length:sizeof(flags) atIndex:0];
                        id<MTLTexture> texture = _defaultTexture;
                        const int eyeSlot = static_cast<int>(draw.eyeId % kEyeSlotCount);
                        if (draw.eyeId != 0xff && _eyeTextureValid[eyeSlot]) {
                            // Merc2: eye draws bind EyeRenderer's texture for (slot << 1 | right).
                            texture = _eyeTextures[eyeSlot];
                        } else if (draw.texture >= 0 &&
                                   static_cast<NSUInteger>(draw.texture) < level.textures.count) {
                            texture = level.textures[draw.texture];
                        }
                        [encoder setFragmentTexture:texture atIndex:0];
                        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                                            indexCount:draw.indexCount
                                             indexType:MTLIndexTypeUInt32
                                           indexBuffer:level.indexBuffer
                                     indexBufferOffset:draw.firstIndex * sizeof(uint32_t)];
                    }
                }
            }
        }
    }

    // PCRTC blackout/fade: the game hides loads, respawns and menu transitions by lowering
    // pmode.alp rather than drawing black, so scale everything drawn above (all buckets) at once.
    if (displayAlpha < 1.0 && _pcrtcPipelineState != nil) {
        [encoder setViewport:MTLViewport {0.0, 0.0, drawableSize.width, drawableSize.height, 0.0, 1.0}];
        [encoder setRenderPipelineState:_pcrtcPipelineState];
        [encoder setDepthStencilState:_pcrtcDepthState];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setTriangleFillMode:MTLTriangleFillModeFill];
        [encoder setBlendColorRed:0.0f green:0.0f blue:0.0f alpha:static_cast<float>(std::max(displayAlpha, 0.0))];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }

    [encoder endEncoding];
    [cmdBuf presentDrawable:drawable];

    const CFTimeInterval now = CACurrentMediaTime();
    if (_performanceWindowStart == 0) _performanceWindowStart = now;
    _performanceCPUSeconds += now - cpuFrameStart;
    for (size_t i = 0; i < 9; i++) _performanceStageSeconds[i] += performanceStages[i];
    _performanceFrameCount++;
    const CFTimeInterval windowSeconds = now - _performanceWindowStart;
    if (windowSeconds >= 1.0) {
        const double fps = _performanceFrameCount / windowSeconds;
        const double cpuMilliseconds = 1000.0 * _performanceCPUSeconds / _performanceFrameCount;
        const uint32_t reportedFrames = _performanceFrameCount;
        NSLog(@"jakIOS perf: %.1f fps, %.2f ms CPU encode, drawable %.0fx%.0f",
              fps, cpuMilliseconds, drawableSize.width, drawableSize.height);
        double stageMilliseconds[9];
        double stageTotal = 0;
        for (size_t i = 0; i < 9; i++) {
            stageMilliseconds[i] = 1000.0 * _performanceStageSeconds[i] / _performanceFrameCount;
            stageTotal += stageMilliseconds[i];
        }
        NSLog(@"jakIOS perf CPU: generic %.2f, merc decode %.2f, merc draw %.2f, sprite %.2f, buffers %.2f, "
              @"background %.2f, eyes/sky/ocean prep %.2f, direct %.2f, ocean %.2f, other %.2f ms",
              stageMilliseconds[0], stageMilliseconds[1], stageMilliseconds[8], stageMilliseconds[2],
              stageMilliseconds[3], stageMilliseconds[4], stageMilliseconds[5], stageMilliseconds[6],
              stageMilliseconds[7], std::max(0.0, cpuMilliseconds - stageTotal));
        [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.GPUEndTime > completed.GPUStartTime) {
                NSLog(@"jakIOS perf: %.2f ms GPU (sample at frame %u)",
                      1000.0 * (completed.GPUEndTime - completed.GPUStartTime), reportedFrames);
            }
        }];
        _performanceWindowStart = now;
        _performanceCPUSeconds = 0;
        for (double &seconds : _performanceStageSeconds) seconds = 0;
        _performanceFrameCount = 0;
    }
    [cmdBuf commit];
}

@end
