#pragma once

// Jak 1 ocean: OpenGOAL's OceanMidAndFar (bucket 4) and OceanNear (bucket 63), including the
// per-frame ocean wave texture. The VU programs are OpenGOAL's C++ ports (Ocean/*_PS2.cpp);
// this class walks the DMA, renders the wave textures and draws the resulting geometry.

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "Jak1Direct.h"

namespace jak1 {

class Ocean {
public:
    Ocean(id<MTLDevice> device, id<MTLLibrary> library);
    ~Ocean();

    static constexpr int kMidAndFarBucket = 4;   // OCEAN_MID_AND_FAR
    static constexpr int kNearBucket = 63;       // OCEAN_NEAR

    // Before the main pass: runs the ocean programs for this frame's trace and renders the wave
    // textures into `commandBuffer`.
    void prepare(id<MTLCommandBuffer> commandBuffer, const uint8_t *trace, size_t traceLength,
                 const std::vector<uint32_t> &bucketOffsets);
    // In the main pass, at the bucket's position: draws what prepare() produced for it.
    void submitBucket(id<MTLRenderCommandEncoder> encoder, int bucket, const DirectViewport &viewport,
                      const float fogColor[4]);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

// Scales the fog on the near and mid ocean (1 = stock). Fog only tints the water's colour toward the fog
// colour, but from a high camera it washes the water out so nothing shows through it; the driveable boat
// lowers it while Jak is at the wheel (host SyncDriveableBoatOption). Thread safe.
void SetOceanFogScale(float scale);

// Fish in Ocean: while set, the near ocean's see-through pass uses the alpha and colour it has right next to the
// camera everywhere (normally it turns opaque from ~24 m away), so fish stay visible from a high camera.
// The host sets it from GOAL *ios-clear-ocean*. Thread-safe.
void SetOceanClearWater(bool clear);

}  // namespace jak1
