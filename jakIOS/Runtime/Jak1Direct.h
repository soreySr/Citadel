#pragma once

// Port of OpenGOAL's DirectRenderer (game/graphics/opengl_renderer/DirectRenderer.cpp): a GS
// emulator for GIF packets sent "directly" by the EE (sky, ocean, text, debug). GS state handling
// is kept as in OpenGOAL; draws are recorded and then encoded with Metal.
//
// Also hosts the Metal side of the texture pool: GS VRAM address (TBP) -> texture.

#import <Metal/Metal.h>

#include <cstdint>
#include <memory>
#include <vector>

namespace jak1 {

// The main pass's depth/stencil texture. The stencil is used by the shadow volumes (Jak1Shadow),
// so every main-pass pipeline sets both attachment formats with SetMainPassDepthFormats.
constexpr MTLPixelFormat kMainPassDepthStencilFormat = MTLPixelFormatDepth32Float_Stencil8;

inline void SetMainPassDepthFormats(MTLRenderPipelineDescriptor *descriptor) {
    descriptor.depthAttachmentPixelFormat = kMainPassDepthStencilFormat;
    descriptor.stencilAttachmentPixelFormat = kMainPassDepthStencilFormat;
}

// Texture pool --------------------------------------------------------------------------------

// Makes `texture` the texture for PC texture id `comboId` (tpage << 16 | index). First one wins.
void PoolRegisterTexture(uint32_t comboId, id<MTLTexture> texture);
// Removes an unloaded level's texture; the next registered provider of `comboId`, if any, takes over.
void PoolUnregisterTexture(uint32_t comboId, id<MTLTexture> texture);
// Places a renderer-generated texture (sky blend, ...) at a VRAM address, overriding uploads.
void PoolSetVramTexture(uint32_t tbp, id<MTLTexture> texture);
// The texture the GS would sample at `tbp`, or nil if nothing is known to live there.
id<MTLTexture> PoolTextureForTbp(uint32_t tbp);
// Texture pool snapshot slot holding the VRAM layout at the eye bucket (54, MERC_EYES_AFTER_PRIS).
constexpr int kEyeTexturePoolSnapshot = 2;
// Like PoolTextureForTbp, but as VRAM was when the eye bucket ran (later uploads reuse eye blocks).
id<MTLTexture> PoolTextureForTbpAtEyes(uint32_t tbp);
// Like PoolTextureForTbp, but as VRAM was when the chain reached byte `traceOffset` of the DMA trace.
id<MTLTexture> PoolTextureForTbpAtTraceOffset(uint32_t tbp, size_t traceOffset);

// Per-frame uploads ---------------------------------------------------------------------------

// Transient vertex/index data, suballocated from a 3-deep ring of growable shared buffers
// instead of a new MTLBuffer per draw list (allocating and freeing GPU buffers every frame was
// a measurable share of main-thread time). Like the renderer's other per-frame rings, this
// relies on at most 3 frames being in flight (the drawable pool size). Render thread only.
struct FrameUpload {
    id<MTLBuffer> buffer = nil;
    NSUInteger offset = 0;
};
// Call once at the start of each frame, before any FrameUploadBytes.
void FrameUploadsBeginFrame(id<MTLDevice> device);
FrameUpload FrameUploadBytes(const void *bytes, size_t length);

// Direct renderer -----------------------------------------------------------------------------

struct DirectViewport {
    float x, y, width, height;  // the game viewport inside the drawable, in pixels
};

class DirectRenderer {
public:
    DirectRenderer(id<MTLDevice> device, id<MTLLibrary> library);
    ~DirectRenderer();

    // DirectRenderer::reset_state.
    void resetState();
    // Feeds one DMA transfer (its two VIF codes and payload) / a raw GIF packet.
    void renderVif(uint32_t vif0, uint32_t vif1, const uint8_t *data, uint32_t size);
    void renderGif(const uint8_t *data, uint32_t size);
    // Ends the current batch.
    void flushPending();
    // Encodes and clears every draw recorded since the last call.
    void submit(id<MTLRenderCommandEncoder> encoder, const DirectViewport &viewport,
                const float fogColor[4]);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

// Sky blend (SkyBlendGPU::do_sky_blends): composites the time-of-day sky (32x32) and cloud
// (64x64) textures and publishes them at their VRAM addresses for the sky dome draws.
class SkyBlender {
public:
    SkyBlender(id<MTLDevice> device, id<MTLLibrary> library);
    ~SkyBlender();
    // Scans the sky-blend buckets of this frame's trace and encodes the blends.
    void encode(id<MTLCommandBuffer> commandBuffer, const uint8_t *trace, size_t traceLength,
                const std::vector<uint32_t> &bucketOffsets);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

}  // namespace jak1
