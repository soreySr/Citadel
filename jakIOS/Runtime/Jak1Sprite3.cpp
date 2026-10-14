#include "Jak1Sprite3.h"

#include <algorithm>
#include <cstring>

namespace jak1 {
namespace {

constexpr uint32_t kVifStcycl = 0x01;
constexpr uint32_t kVifMscal = 0x14;
constexpr uint32_t kVifUnpackV4_32 = 0x6c;

// VU1 data memory layout used by the sprite program (SpriteDataMem in sprite_common.h).
constexpr uint32_t kMemHeader = 0;
constexpr uint32_t kMemVector = 1;
constexpr uint32_t kMemAdgif = 145;
constexpr uint32_t kMemMatrix = 900;
constexpr uint32_t kMemFrameData = 980;

// VU1 program entry points (SpriteProgMem in sprite_common.h).
constexpr uint32_t kProgSprites2dGrp0 = 3;
constexpr uint32_t kProgSprites2dHud = 109;
constexpr uint32_t kProgSprites3d = 211;

constexpr uint32_t kFrameDataSize = 0x290;
constexpr uint32_t k3dMatrixSize = 5 * 16;
constexpr uint32_t kHudMatrixSize = 80 * 16;
constexpr uint32_t kVecDataSize = 48;
constexpr uint32_t kAdgifSize = 80;
// Each half of the VU1 double buffer holds 400 quadwords.
constexpr uint32_t kMaxSpritesPerChunk = 48;
// SPRITE_RENDERER_MAX_SPRITES: Sprite3 flushes when its vertex buffer fills.
constexpr uint32_t kMaxSpritesPerFlush = 1920 * 12;

constexpr uint8_t kGsZbuf_1 = 0x4e;

uint32_t VifKind(uint32_t word) {
    const uint32_t cmd = (word >> 24) & 0x7f;
    return (cmd & 0x60) == 0x60 ? (cmd & 0x6f) : cmd;
}

uint32_t VifNum(uint32_t word) { return (word >> 16) & 0xff; }
// Unpack addresses may carry the FLG (double-buffer) bit; only the address bits matter here.
uint32_t VifUnpackAddress(uint32_t word) { return word & 0x3ff; }

struct Transfer {
    size_t tagOffset = 0;
    uint32_t qwc = 0;
    uint32_t vif0 = 0;
    uint32_t vif1 = 0;
    const uint8_t *data = nullptr;
    uint32_t size = 0;
};

bool ReadTransfer(const uint8_t *trace, size_t length, size_t offset, Transfer *transfer) {
    if (offset + 16 > length) {
        return false;
    }
    uint64_t tag = 0;
    memcpy(&tag, trace + offset, sizeof(tag));
    transfer->tagOffset = offset;
    transfer->qwc = static_cast<uint32_t>(tag & 0xffff);
    transfer->size = transfer->qwc * 16;
    if (transfer->size > length - offset - 16) {
        return false;
    }
    memcpy(&transfer->vif0, trace + offset + 8, 4);
    memcpy(&transfer->vif1, trace + offset + 12, 4);
    transfer->data = trace + offset + 16;
    return true;
}

bool IsUnpackTo(const Transfer &transfer, uint32_t address) {
    return VifKind(transfer.vif1) == kVifUnpackV4_32 && VifUnpackAddress(transfer.vif1) == address;
}

// Port of Sprite3::update_mode_from_alpha1. GS ALPHA selects A, B, C, D in 2-bit fields:
// 0 = source, 1 = destination, 2 = zero (A/B/D) or FIX (C).
Sprite3Blend BlendFromAlpha(uint64_t alpha) {
    const uint32_t a = alpha & 3;
    const uint32_t b = (alpha >> 2) & 3;
    const uint32_t c = (alpha >> 4) & 3;
    const uint32_t d = (alpha >> 6) & 3;
    if (a == 0 && b == 2 && d == 1) {
        return Sprite3Blend::Additive;
    }
    if (a == 2 && b == 0 && c == 0 && d == 1) {
        return Sprite3Blend::Subtract;
    }
    return Sprite3Blend::Alpha;
}

void ReadFrameData(const uint8_t *data, Sprite3Constants *constants) {
    // SpriteFrameDataJak1 layout.
    memcpy(constants->xyArray, data + 0, sizeof(constants->xyArray));
    memcpy(constants->stArray, data + 128, sizeof(constants->stArray));
    memcpy(constants->xyzArray, data + 192, sizeof(constants->xyzArray));
    memcpy(&constants->pfog0, data + 272, 4);
    memcpy(&constants->degToRad, data + 276, 4);
    memcpy(&constants->minScale, data + 280, 4);
    memcpy(&constants->invArea, data + 284, 4);
    memcpy(constants->basisX, data + 416, 16);
    memcpy(constants->basisY, data + 432, 16);
    memcpy(&constants->fogMin, data + 640, 4);
    memcpy(&constants->fogMax, data + 644, 4);
    memcpy(&constants->maxScale, data + 648, 4);
}

// HUD sprites are drawn in submission order, as the PS2 GS does; only consecutive sprites with
// the same (tbp, draw mode) are merged into one batch.
//
// World sprites (2D and 3D) are depth-sorted instead. Sparticles never write depth
// (sparticle-launcher.gc sets ZBUF zmsk 1), so on PS2 their overlap is decided purely by
// particle-slot order: e.g. Rock Village's hundreds of falls-particle puffs washed out the
// nearer blue eco vent cloud. Sorting back to front makes nearer effects draw over farther
// ones. Depth-writing world sprites keep submission order and are drawn before the sorted ones.
struct PendingGroup {
    uint64_t key = 0;
    size_t traceOffset = 0;
    Sprite3Blend blend = Sprite3Blend::Alpha;
    bool depthWrite = false;
    bool hud = false;
    bool filter = false;
    uint32_t clamp = 0;
    uint32_t tbp = 0;
    std::vector<uint32_t> firstVertices;
};

// A world sprite waiting to be depth-sorted.
struct WorldSprite {
    uint32_t firstVertex = 0;
    float closeness = 0;  // pfog0 / w: grows toward the camera
    Sprite3Blend blend = Sprite3Blend::Alpha;
    Sprite3TextureSlot slot;
};

struct PendingSprites {
    std::vector<PendingGroup> groups;
    uint32_t spriteCount = 0;
    // World sprites, emitted together before the HUD group (or at the end of the frame).
    std::vector<PendingGroup> worldDepthGroups;
    std::vector<WorldSprite> worldSorted;
    size_t worldTraceOffset = SIZE_MAX;
    bool worldEmitted = false;
};

Sprite3Batch BatchFromGroup(const PendingGroup &group, Sprite3Frame *frame) {
    Sprite3Batch batch;
    batch.traceOffset = group.traceOffset;
    batch.firstIndex = static_cast<uint32_t>(frame->indices.size());
    batch.blend = group.blend;
    batch.depthWrite = group.depthWrite;
    batch.hud = group.hud;
    batch.filter = group.filter;
    batch.clampS = (group.clamp & 0b001) != 0;
    batch.clampT = (group.clamp & 0b100) != 0;
    batch.tbp = group.tbp;
    for (uint32_t firstVertex : group.firstVertices) {
        for (uint32_t i = 0; i < 4; i++) {
            frame->indices.push_back(firstVertex + i);
        }
        frame->indices.push_back(UINT32_MAX);
    }
    batch.indexCount = static_cast<uint32_t>(group.firstVertices.size() * 5);
    return batch;
}

// Emits the pending HUD batches in submission order.
void FlushSprites(PendingSprites *pending, Sprite3Frame *frame) {
    for (const PendingGroup &group : pending->groups) {
        frame->batches.push_back(BatchFromGroup(group, frame));
    }
    pending->groups.clear();
    pending->spriteCount = 0;
}

bool SameSlot(const Sprite3TextureSlot &a, const Sprite3TextureSlot &b) {
    return a.tbp == b.tbp && a.filter == b.filter && a.clampS == b.clampS && a.clampT == b.clampT;
}

// Emits the world sprites: depth writers in submission order, then the rest back to front.
// Consecutive alpha/additive sprites share a premultiplied batch binding up to
// kSprite3MaxSlots textures; subtractive sprites get their own batches.
void EmitWorldSprites(PendingSprites *pending, Sprite3Frame *frame) {
    if (pending->worldEmitted) return;
    pending->worldEmitted = true;
    const size_t traceOffset = pending->worldTraceOffset == SIZE_MAX ? 0 : pending->worldTraceOffset;
    for (PendingGroup &group : pending->worldDepthGroups) {
        group.traceOffset = traceOffset;
        frame->batches.push_back(BatchFromGroup(group, frame));
    }
    pending->worldDepthGroups.clear();

    std::vector<WorldSprite> &sprites = pending->worldSorted;
    // Stable, so equally distant sprites keep the game's order.
    std::stable_sort(sprites.begin(), sprites.end(), [](const WorldSprite &a, const WorldSprite &b) {
        return a.closeness < b.closeness;
    });
    Sprite3Batch *batch = nullptr;
    for (const WorldSprite &sprite : sprites) {
        const bool premultiplied = sprite.blend != Sprite3Blend::Subtract;
        uint32_t slotIndex = 0;
        bool fits = batch != nullptr && batch->premultiplied == premultiplied;
        if (fits && premultiplied) {
            while (slotIndex < batch->slotCount && !SameSlot(batch->slots[slotIndex], sprite.slot)) slotIndex++;
            fits = slotIndex < kSprite3MaxSlots;
        } else if (fits) {
            fits = SameSlot(batch->slots[0], sprite.slot);
        }
        if (!fits) {
            frame->batches.emplace_back();
            batch = &frame->batches.back();
            batch->traceOffset = traceOffset;
            batch->firstIndex = static_cast<uint32_t>(frame->indices.size());
            batch->blend = sprite.blend;
            batch->premultiplied = premultiplied;
            batch->tbp = sprite.slot.tbp;
            batch->filter = sprite.slot.filter;
            batch->clampS = sprite.slot.clampS;
            batch->clampT = sprite.slot.clampT;
            slotIndex = 0;
        }
        if (slotIndex == batch->slotCount) batch->slots[batch->slotCount++] = sprite.slot;
        const uint32_t slotBits = slotIndex | (sprite.blend == Sprite3Blend::Additive ? 0x100u : 0u);
        for (uint32_t i = 0; i < 4; i++) {
            frame->vertices[sprite.firstVertex + i].slot = slotBits;
            frame->indices.push_back(sprite.firstVertex + i);
        }
        frame->indices.push_back(UINT32_MAX);
        batch->indexCount += 5;
    }
    sprites.clear();
}

// Port of Sprite3::do_block_common: expands each sprite into four corner vertices.
void AppendChunk(const Transfer &header,
                 const uint8_t *vecData,
                 const uint8_t *adgifData,
                 uint32_t count,
                 Sprite3Mode mode,
                 const Sprite3Constants &constants,
                 PendingSprites *pending,
                 Sprite3Frame *frame) {
    // Corner order for the triangle strip; PC swaps the last two corners.
    static constexpr uint8_t kCorners[4] = {0, 1, 3, 2};
    // m_current_mode is reset to the default at the start of each block; ZBUF/CLAMP persist
    // across the block's sprites when a sprite's adgif sets the other register.
    // m_default_mode starts from DrawMode's all-ones value, so S and T clamp are on until a CLAMP
    // register says otherwise. Sparticles put ZBUF in that slot and never set CLAMP, so they
    // must sample clamped: with repeat, bilinear filtering bleeds the opposite texture edge
    // into the sprite's border (e.g. a hairline at the right edge of the progress menu frame).
    bool depthWrite = false;
    uint32_t clamp = 0b101;
    const bool hud = mode == Sprite3Mode::Hud;
    if (!hud && pending->worldTraceOffset == SIZE_MAX) pending->worldTraceOffset = header.tagOffset;
    for (uint32_t sprite = 0; sprite < count; sprite++) {
        if (hud && pending->spriteCount == kMaxSpritesPerFlush) {
            FlushSprites(pending, frame);
        }
        uint64_t adgif[10];
        memcpy(adgif, adgifData + sprite * kAdgifSize, kAdgifSize);
        const uint64_t tex0 = adgif[0];
        // Slot 3 is CLAMP or, for some sprites, ZBUF.
        if (static_cast<uint8_t>(adgif[7]) == kGsZbuf_1) {
            depthWrite = ((adgif[6] >> 32) & 1) == 0;
        } else {
            clamp = static_cast<uint32_t>(adgif[6] & 0b101);
        }
        const Sprite3Blend blend = BlendFromAlpha(adgif[8]);

        Sprite3Vertex vertex {};
        memcpy(vertex.xyzSx, vecData + sprite * kVecDataSize, 16);
        memcpy(vertex.quatSy, vecData + sprite * kVecDataSize + 16, 16);
        float rgba[4];
        memcpy(rgba, vecData + sprite * kVecDataSize + 32, 16);
        for (int i = 0; i < 4; i++) {
            // The game ftoi's these and the VIF keeps only the low byte.
            vertex.rgba[i] = static_cast<float>(static_cast<int32_t>(rgba[i]) & 0xff) / 255.0f;
        }
        memcpy(&vertex.flag, &vertex.quatSy[0], 4);
        memcpy(&vertex.matrix, &vertex.quatSy[1], 4);
        vertex.info[1] = ((tex0 >> 34) & 1) != 0; // TCC
        vertex.info[3] = static_cast<uint8_t>(mode);

        const uint32_t tbp = static_cast<uint32_t>(tex0 & 0x3fff);
        const uint64_t mmag = (adgif[2] >> 5) & 1;
        const uint32_t firstVertex = static_cast<uint32_t>(frame->vertices.size());
        for (uint8_t corner : kCorners) {
            vertex.info[2] = corner;
            frame->vertices.push_back(vertex);
        }
        frame->spriteCount++;

        if (!hud && !depthWrite) {
            // Camera-space w of the sprite's center, as the vertex shader computes it
            // (matrix_transform: column 3 + columns 0-2 scaled by x, y, z).
            const float *m = constants.camera;
            const float w = m[15] + m[3] * vertex.xyzSx[0] + m[7] * vertex.xyzSx[1] + m[11] * vertex.xyzSx[2];
            WorldSprite world;
            world.firstVertex = firstVertex;
            world.closeness = w != 0.0f ? constants.pfog0 / w : 0.0f;
            world.blend = blend;
            world.slot.tbp = tbp;
            world.slot.filter = mmag != 0;
            world.slot.clampS = (clamp & 0b001) != 0;
            world.slot.clampT = (clamp & 0b100) != 0;
            pending->worldSorted.push_back(world);
            continue;
        }

        // Bucket key: tbp plus the DrawMode fields the adgif sets (tcc, filter, clamp, blend, ZMSK).
        const uint64_t key = (static_cast<uint64_t>(tbp) << 32) | ((adgif[8] & 0xff) << 8) |
            (static_cast<uint64_t>(clamp) << 4) | (mmag << 2) |
            (static_cast<uint64_t>(vertex.info[1]) << 1) | (depthWrite ? 1 : 0);
        std::vector<PendingGroup> &groups = hud ? pending->groups : pending->worldDepthGroups;
        if (groups.empty() || groups.back().key != key) {
            groups.emplace_back();
            PendingGroup &group = groups.back();
            group.key = key;
            group.traceOffset = header.tagOffset;
            group.blend = blend;
            group.depthWrite = depthWrite;
            group.hud = hud;
            group.filter = mmag != 0;
            group.clamp = clamp;
            group.tbp = tbp;
        }
        groups.back().firstVertices.push_back(firstVertex);
        if (hud) pending->spriteCount++;
    }
}

} // namespace

void DecodeSprite3Jak1(const uint8_t *trace, size_t length, Sprite3Frame *frame) {
    if (trace == nullptr || frame == nullptr) {
        return;
    }
    Sprite3Constants &constants = frame->constants;
    PendingSprites pending;
    uint32_t lastProgram = UINT32_MAX;
    size_t offset = 0;
    Transfer transfer;
    while (ReadTransfer(trace, length, offset, &transfer)) {
        size_t nextOffset = offset + 16 + transfer.size;

        if (VifKind(transfer.vif0) == kVifStcycl && IsUnpackTo(transfer, kMemFrameData) &&
            transfer.size == kFrameDataSize) {
            ReadFrameData(transfer.data, &constants);
            frame->hasFrameData = true;
        } else if (IsUnpackTo(transfer, kMemMatrix) && transfer.size == k3dMatrixSize) {
            // Sprite3DMatrixData: camera matrix + hvdf offset.
            memcpy(constants.camera, transfer.data, 64);
            memcpy(constants.hvdfOffset, transfer.data + 64, 16);
        } else if (IsUnpackTo(transfer, kMemMatrix) && transfer.size == kHudMatrixSize) {
            // SpriteHudMatrixData: matrix, hvdf offset, and 75 user hvdf offsets.
            memcpy(constants.hudMatrix, transfer.data, 64);
            memcpy(constants.hudHvdfOffset, transfer.data + 64, 16);
            memcpy(constants.hudHvdfUser, transfer.data + 80, sizeof(constants.hudHvdfUser));
        } else if (frame->hasFrameData && transfer.qwc == 1 && IsUnpackTo(transfer, kMemHeader) &&
                   VifNum(transfer.vif1) == 1) {
            // A chunk is four transfers: header, vector data, adgifs, and the MSCAL run.
            Transfer vec;
            Transfer adgif;
            Transfer run;
            uint32_t count = 0;
            memcpy(&count, transfer.data, 4);
            const size_t vecOffset = nextOffset;
            bool ok = count <= kMaxSpritesPerChunk &&
                ReadTransfer(trace, length, vecOffset, &vec) && IsUnpackTo(vec, kMemVector) &&
                vec.size >= count * kVecDataSize;
            const size_t adgifOffset = vecOffset + 16 + vec.size;
            ok = ok && ReadTransfer(trace, length, adgifOffset, &adgif) &&
                IsUnpackTo(adgif, kMemAdgif) && adgif.size >= count * kAdgifSize;
            const size_t runOffset = adgifOffset + 16 + adgif.size;
            ok = ok && ReadTransfer(trace, length, runOffset, &run) &&
                VifKind(run.vif1) == kVifMscal;
            Sprite3Mode mode = Sprite3Mode::World2D;
            if (ok) {
                switch (run.vif1 & 0xffff) {
                    case kProgSprites2dGrp0:
                        mode = Sprite3Mode::World2D;
                        break;
                    case kProgSprites2dHud:
                        mode = Sprite3Mode::Hud;
                        break;
                    case kProgSprites3d:
                        mode = Sprite3Mode::World3D;
                        break;
                    default:
                        ok = false;
                        break;
                }
            }
            if (ok) {
                // Sprite3 flushes whenever the VU program changes (2D, 3D, and the HUD group).
                const uint32_t program = run.vif1 & 0xffff;
                if (program != lastProgram) {
                    FlushSprites(&pending, frame);
                    lastProgram = program;
                }
                // World sprites (3D, then 2D group 0) all precede the HUD group in the chain.
                if (mode == Sprite3Mode::Hud) EmitWorldSprites(&pending, frame);
                frame->chunkCount++;
                AppendChunk(transfer, vec.data, adgif.data, count, mode, constants, &pending, frame);
                nextOffset = runOffset + 16 + run.size;
            } else {
                frame->rejectedChunks++;
            }
        }
        offset = nextOffset;
    }
    EmitWorldSprites(&pending, frame);
    FlushSprites(&pending, frame);
}

} // namespace jak1
