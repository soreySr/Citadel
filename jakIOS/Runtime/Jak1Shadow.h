#pragma once

// Jak 1 shadows: OpenGOAL's ShadowRenderer (bucket 47). The VU programs are OpenGOAL's C++ port
// (Shadow/Shadow_PS2.cpp); this class walks the bucket's DMA and draws the shadow volumes into the
// stencil buffer, then darkens the pixels the volumes marked.

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace jak1 {

class Shadow {
public:
    Shadow(id<MTLDevice> device, id<MTLLibrary> library);
    ~Shadow();

    static constexpr int kBucket = 47;  // SHADOW

    // In the main pass, at the bucket's position: runs the shadow programs for this frame's trace
    // and draws the result. The pass needs a stencil attachment cleared to 0.
    void submitBucket(id<MTLRenderCommandEncoder> encoder, const uint8_t *trace, size_t traceLength,
                      const std::vector<uint32_t> &bucketOffsets);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

}  // namespace jak1
