#pragma once

// Decoder for Jak 1's sprite VU1 renderer DMA, ported from OpenGOAL's Sprite3::render_jak1
// (Sprite3.cpp). Each sprite becomes four vertices sharing its vector data; the quad corners
// are built in the Metal vertex shader (a port of sprite3_3d.vert).

#include <cstddef>
#include <cstdint>
#include <vector>

namespace jak1 {

// Matches the Metal shader's Sprite3Vertex layout.
struct Sprite3Vertex {
    float xyzSx[4];  // position + x scale
    float quatSy[4]; // flags/matrix bits, rotation (or quaternion for 3D), y scale
    float rgba[4];   // color, normalized from 0-255
    uint32_t flag;
    uint32_t matrix;
    uint8_t info[4]; // [1]: tcc, [2]: corner index, [3]: render mode
    uint32_t slot;   // sorted (premultiplied) batches: bits 0-7 texture slot, bit 8 additive
};
static_assert(sizeof(Sprite3Vertex) == 64, "Sprite3Vertex must match the shader layout");

enum class Sprite3Mode : uint8_t {
    World2D = 1,
    Hud = 2,
    World3D = 3,
};

enum class Sprite3Blend : uint8_t {
    Alpha,    // (Cs - Cd) * As + Cd
    Additive, // Cs * As + Cd (also used for FIX-based additive modes)
    Subtract, // Cd - Cs * As
};

// Per-frame constants shared by every sprite; mirrors the uniforms sprite3_3d.vert reads.
struct Sprite3Constants {
    float hvdfOffset[4] = {};
    float camera[16] = {};
    float hudMatrix[16] = {};
    float hudHvdfOffset[4] = {};
    float hudHvdfUser[75][4] = {};
    float basisX[4] = {};
    float basisY[4] = {};
    float xyArray[8][4] = {};
    float xyzArray[4][4] = {};
    float stArray[4][4] = {};
    float pfog0 = 0;
    float fogMin = 0;
    float fogMax = 0;
    float minScale = 0;
    float maxScale = 0;
    float degToRad = 0;
    float invArea = 0;
    float colorMultiplier = 1;
};
static_assert(sizeof(Sprite3Constants) == 1680, "Sprite3Constants must match Sprite3Uniforms");

// Texture + sampler settings for one texture binding.
struct Sprite3TextureSlot {
    uint32_t tbp = 0;     // TEX0 base pointer (GS VRAM address)
    bool filter = false;  // TEX1 MMAG
    bool clampS = false;  // CLAMP wms/wmt; REPEAT otherwise
    bool clampT = false;
};

// Number of textures a premultiplied (depth-sorted) batch can bind at once.
constexpr uint32_t kSprite3MaxSlots = 8;

struct Sprite3Batch {
    size_t traceOffset = 0;
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    Sprite3Blend blend = Sprite3Blend::Alpha;
    bool depthWrite = false;
    bool hud = false;     // HUD group: flushed with Sprite3's double_draw alpha handling
    bool filter = false;  // TEX1 MMAG
    bool clampS = false;  // CLAMP wms/wmt; REPEAT otherwise
    bool clampT = false;
    uint32_t tbp = 0;  // TEX0 base pointer (GS VRAM address) shared by the batch's sprites
    // Depth-sorted world sprites with alpha or additive blending: drawn with premultiplied
    // alpha so both blends share one draw; each vertex picks one of `slots` (Sprite3Vertex::slot).
    bool premultiplied = false;
    uint32_t slotCount = 0;
    Sprite3TextureSlot slots[kSprite3MaxSlots];
};

struct Sprite3Frame {
    std::vector<Sprite3Vertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<Sprite3Batch> batches;
    Sprite3Constants constants;
    bool hasFrameData = false;
    uint32_t spriteCount = 0;
    uint32_t chunkCount = 0;
    uint32_t rejectedChunks = 0;
};

// `trace` is the linear DMA capture produced by CaptureDMAChain.
void DecodeSprite3Jak1(const uint8_t *trace, size_t length, Sprite3Frame *frame);

} // namespace jak1
