#pragma once

// Decoder for Jak 1's "generic" VU1 renderer DMA, ported from OpenGOAL's
// Generic2::process_dma_jak1 (Generic2_DMA.cpp) and the draw-building steps in
// Generic2_Build.cpp. Instead of emulating the VU1 microprogram, fragments are decoded
// into a vertex buffer plus primitive-restart triangle-strip indices, and the projection
// performed by the microprogram is reproduced in the Metal vertex shader.

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace jak1 {

// Matches Generic2::Vertex and the Metal shader's Generic2Vertex layout.
struct Generic2Vertex {
    float xyz[3];
    uint8_t rgba[4];
    float st[2];
    uint8_t texUnit;
    uint8_t flags;
    uint8_t adc;
    uint8_t pad0;
    uint32_t pad1;
};
static_assert(sizeof(Generic2Vertex) == 32, "Generic2Vertex must match the shader layout");

// Projection settings for one batch; mirrors Generic2's DrawingConfig uniforms.
struct Generic2Projection {
    float scale[3] = {0, 0, 0};
    float mat23 = 0;
    float mat32 = 0;
    float mat33 = 0;
    float hvdfOffset[4] = {0, 0, 0, 0};
    float pfog0 = 0;
    float fogMin = 0;
    float fogMax = 0;
};

// Vertex flag bits, matching generic.frag's tex_info.y.
constexpr uint8_t kGeneric2FlagTcc = 1;
constexpr uint8_t kGeneric2FlagDecal = 2;
constexpr uint8_t kGeneric2FlagFog = 4;

struct Generic2Batch {
    // Byte offset of the bucket's constants packet in the DMA trace, used to keep
    // generic draws ordered relative to direct GIF draws.
    size_t traceOffset = 0;
    uint32_t firstIndex = 0;
    uint32_t indexCount = 0;
    bool usesHud = false;
    bool depthWrite = true;
    // Draw settings resolved from the batch's adgifs (Generic2::determine_draw_modes).
    uint32_t tbp = 0;          // TEX0 base pointer; 0x8000 marks PSMT4HH
    uint8_t blend = 6;         // DrawMode::AlphaBlend (0 disabled ... 7 SRC_0_DST_DST)
    uint8_t fix = 0;           // GS ALPHA FIX, for SRC_DST_FIX_DST
    bool filter = true;        // TEX1 MMAG
    bool clampS = false;
    bool clampT = false;
    float alphaReject = 0;     // fragments with alpha below this are discarded
    Generic2Projection projection;
};

struct Generic2Frame {
    std::vector<Generic2Vertex> vertices;
    std::vector<uint32_t> indices;
    std::vector<Generic2Batch> batches;
    uint32_t bucketCount = 0;
    uint32_t fragmentCount = 0;
    uint32_t adgifCount = 0;
    uint32_t rejectedTransfers = 0;
    // Reason for the first rejected transfer, for diagnostics.
    std::string firstRejection;
};

// `trace` is the linear DMA capture produced by CaptureDMAChain: each 16-byte DMA tag is
// immediately followed by the payload it transferred.
void DecodeGeneric2Jak1(const uint8_t *trace, size_t length, Generic2Frame *frame);

} // namespace jak1
