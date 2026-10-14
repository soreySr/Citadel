#import "Jak1Shadow.h"
#import "Jak1Direct.h"

#include "Shadow/ShadowRenderer.h"

#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include <cstring>

namespace jak1 {
namespace {

// The bucket's DMA transfers in chain order (same walk as Jak1Ocean's BucketEntries).
std::vector<ShadowRenderer::Transfer> BucketTransfers(const uint8_t *trace, size_t length,
                                                      const std::vector<uint32_t> &offsets, int bucket) {
    std::vector<ShadowRenderer::Transfer> transfers;
    if (bucket >= static_cast<int>(offsets.size()) || offsets[bucket] == UINT32_MAX) return transfers;
    size_t offset = offsets[bucket];
    size_t end = length;
    for (size_t next = bucket + 1; next < offsets.size(); next++) {
        if (offsets[next] != UINT32_MAX && offsets[next] > offset) {
            end = offsets[next];
            break;
        }
    }
    while (offset + 16 <= end) {
        uint64_t tag = 0;
        ShadowRenderer::Transfer t {};
        memcpy(&tag, trace + offset, 8);
        memcpy(&t.vif0, trace + offset + 8, 4);
        memcpy(&t.vif1, trace + offset + 12, 4);
        t.size_bytes = static_cast<u32>(tag & 0xffff) * 16;
        t.tag_kind = (tag >> 28) & 0x7;
        t.data = trace + offset + 16;
        if (t.size_bytes > length - offset - 16) break;
        transfers.push_back(t);
        offset += 16 + t.size_bytes;
    }
    return transfers;
}

}  // namespace

struct Shadow::Impl {
    std::unique_ptr<ShadowRenderer> program = std::make_unique<ShadowRenderer>();
    id<MTLRenderPipelineState> volumePipeline, darkenPipeline;
    id<MTLDepthStencilState> incrementOnPass, decrementOnPass, darkenWhereMarked;
    bool loggedFirst = false;
};

Shadow::Shadow(id<MTLDevice> device, id<MTLLibrary> library) : _impl(std::make_unique<Impl>()) {
    Impl &impl = *_impl;
    auto makePipeline = [&](bool darken) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"jak1_shadow_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"jak1_shadow_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        SetMainPassDepthFormats(descriptor);
        MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
        if (darken) {
            // glColorMask(1, 1, 1, 0) + glBlendFuncSeparate(GL_DST_COLOR, GL_ZERO, GL_ONE, GL_ZERO)
            color.writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;
            color.blendingEnabled = YES;
            color.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;
            color.destinationRGBBlendFactor = MTLBlendFactorZero;
            color.sourceAlphaBlendFactor = MTLBlendFactorOne;
            color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        } else {
            color.writeMask = MTLColorWriteMaskNone;  // volumes only touch the stencil
        }
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (error != nil) NSLog(@"Jak1Shadow pipeline error: %@", error.localizedDescription);
        return state;
    };
    impl.volumePipeline = makePipeline(false);
    impl.darkenPipeline = makePipeline(true);

    // Volumes: depth GEQUAL without writes; the stencil counts front faces up and back faces down
    // where the depth test passes (glStencilOp(KEEP, KEEP, INCR / DECR)).
    auto makeStencil = [&](MTLCompareFunction depthCompare, MTLCompareFunction stencilCompare,
                           MTLStencilOperation onPass) {
        MTLStencilDescriptor *stencil = [[MTLStencilDescriptor alloc] init];
        stencil.stencilCompareFunction = stencilCompare;
        stencil.stencilFailureOperation = MTLStencilOperationKeep;
        stencil.depthFailureOperation = MTLStencilOperationKeep;
        stencil.depthStencilPassOperation = onPass;
        stencil.readMask = 0xff;
        stencil.writeMask = 0xff;
        MTLDepthStencilDescriptor *depth = [[MTLDepthStencilDescriptor alloc] init];
        depth.depthCompareFunction = depthCompare;
        depth.depthWriteEnabled = NO;
        depth.frontFaceStencil = stencil;
        depth.backFaceStencil = stencil;
        return [device newDepthStencilStateWithDescriptor:depth];
    };
    impl.incrementOnPass = makeStencil(MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways,
                                       MTLStencilOperationIncrementClamp);
    impl.decrementOnPass = makeStencil(MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways,
                                       MTLStencilOperationDecrementClamp);
    // Final quad: depth ALWAYS, drawn where stencil != 0.
    impl.darkenWhereMarked = makeStencil(MTLCompareFunctionAlways, MTLCompareFunctionNotEqual,
                                         MTLStencilOperationKeep);
}

Shadow::~Shadow() = default;

void Shadow::submitBucket(id<MTLRenderCommandEncoder> encoder, const uint8_t *trace, size_t traceLength,
                          const std::vector<uint32_t> &bucketOffsets) {
    Impl &impl = *_impl;
    if (trace == nullptr || impl.volumePipeline == nil || impl.darkenPipeline == nil) return;
    const std::vector<ShadowRenderer::Transfer> transfers = BucketTransfers(trace, traceLength, bucketOffsets, kBucket);
    ShadowRenderer &program = *impl.program;
    if (!program.run(transfers.data(), transfers.size())) return;
    const u32 frontCount = program.front_index_count();
    const u32 backCount = program.back_index_count();
    if (frontCount == 0 && backCount == 0) return;

    if (!impl.loggedFirst) {
        NSLog(@"jakIOS: shadow volumes %u verts, %u front / %u back tris, color (%.2f %.2f %.2f %.2f)",
              program.vertex_count(), frontCount / 3, backCount / 3, program.color().x(), program.color().y(),
              program.color().z(), program.color().w());
        impl.loggedFirst = true;
    }

    const FrameUpload vertices = FrameUploadBytes(program.vertices(),
                                                  program.vertex_count() * sizeof(ShadowRenderer::Vertex));
    [encoder setCullMode:MTLCullModeNone];
    [encoder setStencilReferenceValue:0];
    [encoder setRenderPipelineState:impl.volumePipeline];
    [encoder setVertexBuffer:vertices.buffer offset:vertices.offset atIndex:0];
    const simd_float4 noColor = simd_make_float4(0, 0, 0, 0);
    [encoder setFragmentBytes:&noColor length:sizeof(noColor) atIndex:0];

    auto drawIndices = [&](const u32 *indices, u32 count, id<MTLDepthStencilState> state) {
        if (count == 0) return;
        const FrameUpload upload = FrameUploadBytes(indices, count * sizeof(u32));
        [encoder setDepthStencilState:state];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:count indexType:MTLIndexTypeUInt32
                           indexBuffer:upload.buffer indexBufferOffset:upload.offset];
    };
    // First pass: front faces increment, second pass: back faces decrement.
    drawIndices(program.front_indices(), frontCount, impl.incrementOnPass);
    drawIndices(program.back_indices(), backCount, impl.decrementOnPass);

    // Finally, multiply the framebuffer by the shadow color wherever the stencil is non-zero.
    // The quad (0.3..0.7 in GS space, as in ShadowRenderer::draw) covers the whole screen.
    const ShadowRenderer::Vertex quad[4] = {
        {math::Vector3f(0.3f, 0.3f, 0.f), 0}, {math::Vector3f(0.3f, 0.7f, 0.f), 0},
        {math::Vector3f(0.7f, 0.3f, 0.f), 0}, {math::Vector3f(0.7f, 0.7f, 0.f), 0}};
    const math::Vector4f &c = program.color();
    const simd_float4 color = simd_make_float4(c.x(), c.y(), c.z(), c.w());
    [encoder setRenderPipelineState:impl.darkenPipeline];
    [encoder setDepthStencilState:impl.darkenWhereMarked];
    [encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
    [encoder setFragmentBytes:&color length:sizeof(color) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

}  // namespace jak1
