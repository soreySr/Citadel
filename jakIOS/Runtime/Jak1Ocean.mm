#import "Jak1Ocean.h"
#include <atomic>

#define FMT_HEADER_ONLY 1
#include "Ocean/CommonOceanRenderer.h"
#include "Ocean/OceanMid.h"
#include "Ocean/OceanNear.h"
#include "Ocean/OceanTexture.h"

#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include <algorithm>
#include <cstring>

namespace jak1 {
namespace {

constexpr int kOceanTextureTbp = 8160;  // OCEAN_TEX_TBP_JAK1
constexpr int kOceanTextureSize = 128;  // OceanTexture::TEX0_SIZE
constexpr int kOceanTextureMips = 8;    // OceanTexture::NUM_MIPS

struct Entry {
    uint32_t qwc, kind, vif0, vif1;
    const uint8_t *payload;
    uint32_t size() const { return qwc * 16; }
    uint32_t vifKind(int i) const { return ((i == 0 ? vif0 : vif1) >> 24) & 0x7f; }
};

std::vector<Entry> BucketEntries(const uint8_t *trace, size_t length, const std::vector<uint32_t> &offsets,
                                 int bucket) {
    std::vector<Entry> entries;
    if (bucket >= static_cast<int>(offsets.size()) || offsets[bucket] == UINT32_MAX) return entries;
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
        Entry e {};
        memcpy(&tag, trace + offset, 8);
        memcpy(&e.vif0, trace + offset + 8, 4);
        memcpy(&e.vif1, trace + offset + 12, 4);
        e.qwc = tag & 0xffff;
        e.kind = (tag >> 28) & 0x7;
        e.payload = trace + offset + 16;
        if (e.size() > length - offset - 16) break;
        entries.push_back(e);
        offset += 16 + e.size();
    }
    return entries;
}

constexpr uint32_t kTagCnt = 1, kTagCall = 5;
constexpr uint32_t kVifNop = 0x00, kVifBase = 0x03, kVifDirect = 0x50;

// ocean_common.vert/frag `bucket` values: near uses 0-2, mid uses 3 (ocean) and 4 (envmap), 5 = mid drawn clear,
// 6 = near drawn as an opaque backdrop (Fish in Ocean clear water).
struct OceanUniforms {
    simd_float4 fogColor;
    int32_t bucket;
    float clearWater;
    float pad[2];
};

// Fish in Ocean: the near ocean drawn at its clearest (SetOceanClearWater).
std::atomic<bool> gOceanClearWater{false};

}  // namespace

struct Ocean::Impl {
    id<MTLDevice> device;
    // Wave texture generation.
    id<MTLRenderPipelineState> texturePipeline, mipmapPipeline;
    id<MTLComputePipelineState> mipmapCompute;
    __strong id<MTLTexture> midMipViews[kOceanTextureMips];
    id<MTLBuffer> texturePositions, textureIndices;
    id<MTLTexture> midTemp, midTexture, nearTexture;
    id<MTLSamplerState> linearClamp, linearRepeatMip;
    // Ocean geometry.
    id<MTLRenderPipelineState> oceanOpaque, oceanAlphaBlend, oceanAlphaOnly, oceanDestAlphaAdd;
    id<MTLDepthStencilState> depthAlwaysWrite, depthGequalNoWrite, depthGreaterWrite, depthAlwaysNoWrite;
    id<MTLTexture> placeholder;

    OceanTexture midTextureProgram, nearTextureProgram;
    OceanMid mid;
    OceanNear near;
    std::unique_ptr<DirectRenderer> far;

    OceanDrawList midDraws, nearDraws;
    bool haveMid = false, haveNear = false, haveFar = false;
    // Clear water this frame (latched at the mid bucket, see submitBucket).
    bool clearFrame = false;

    id<MTLRenderPipelineState> makePipeline(id<MTLLibrary> library, NSString *vertexName, NSString *fragmentName,
                                            MTLPixelFormat format, bool depth,
                                            void (^blend)(MTLRenderPipelineColorAttachmentDescriptor *)) {
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:vertexName];
        descriptor.fragmentFunction = [library newFunctionWithName:fragmentName];
        descriptor.colorAttachments[0].pixelFormat = format;
        if (depth) SetMainPassDepthFormats(descriptor);
        if (blend) blend(descriptor.colorAttachments[0]);
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (error != nil) NSLog(@"Jak1Ocean pipeline %@ error: %@", vertexName, error.localizedDescription);
        return state;
    }

    // OceanTexture::flush (+ make_texture_with_mipmaps when `mipmapped`).
    void renderTexture(id<MTLCommandBuffer> commandBuffer, const OceanTexture &program, id<MTLTexture> target,
                       bool mipmapped) {
        id<MTLTexture> envmap = PoolTextureForTbp(program.envmap_tbp());
        if (envmap == nil) envmap = placeholder;
        const FrameUpload dynamic = FrameUploadBytes(program.dynamic_vertex_data(), program.positions().size() * 16);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = mipmapped ? midTemp : target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:texturePipeline];
        [encoder setVertexBuffer:texturePositions offset:0 atIndex:0];
        [encoder setVertexBuffer:dynamic.buffer offset:dynamic.offset atIndex:1];
        [encoder setFragmentTexture:envmap atIndex:0];
        [encoder setFragmentSamplerState:linearRepeatMip atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip
                            indexCount:program.indices().size()
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:textureIndices
                     indexBufferOffset:0];
        [encoder endEncoding];
        if (!mipmapped) return;

        // Each mip is a downscale of the 128x128 render with fading alpha, so the ocean
        // texture fades out with distance. All levels in one compute dispatch when possible:
        // 8 render passes per frame cost far more CPU (and submission) than the work itself.
        if (mipmapCompute != nil) {
            id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
            [compute setComputePipelineState:mipmapCompute];
            [compute setTexture:midTemp atIndex:0];
            [compute setTextures:midMipViews withRange:NSMakeRange(1, kOceanTextureMips)];
            [compute setSamplerState:linearClamp atIndex:0];
            [compute dispatchThreads:MTLSizeMake(kOceanTextureSize, kOceanTextureSize, 1)
               threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [compute endEncoding];
            return;
        }
        for (int level = 0; level < kOceanTextureMips; level++) {
            MTLRenderPassDescriptor *mipPass = [MTLRenderPassDescriptor renderPassDescriptor];
            mipPass.colorAttachments[0].texture = target;
            mipPass.colorAttachments[0].level = level;
            mipPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            mipPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> mip = [commandBuffer renderCommandEncoderWithDescriptor:mipPass];
            [mip setRenderPipelineState:mipmapPipeline];
            const float alphaIntensity = std::max(0.f, 1.f - 0.51f * level);
            [mip setFragmentBytes:&alphaIntensity length:sizeof(alphaIntensity) atIndex:0];
            [mip setFragmentTexture:midTemp atIndex:0];
            [mip setFragmentSamplerState:linearClamp atIndex:0];
            [mip drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [mip endEncoding];
        }
    }

    // Runs the 28 ocean-texture transfers starting at entries[at]; returns how many were used.
    int runTexture(OceanTexture &program, const std::vector<Entry> &entries, size_t at) {
        std::vector<OceanTexture::Transfer> transfers;
        for (size_t i = at; i < entries.size() && transfers.size() < 40; i++) {
            transfers.push_back({entries[i].vif0, entries[i].vif1, entries[i].payload, entries[i].size()});
        }
        return program.run(transfers.data(), static_cast<int>(transfers.size()));
    }

    void drawList(id<MTLRenderCommandEncoder> encoder, const OceanDrawList &list, id<MTLTexture> oceanTexture,
                  const float fogColor[4], bool clearMid = false, bool clearBase = false) {
        if (list.vertices.empty()) return;
        const FrameUpload vertices =
            FrameUploadBytes(list.vertices.data(), list.vertices.size() * sizeof(OceanDrawList::Vertex));
        [encoder setVertexBuffer:vertices.buffer offset:vertices.offset atIndex:0];
        id<MTLTexture> envmap = PoolTextureForTbp(list.envmap_tbp);
        if (envmap == nil) envmap = placeholder;
        OceanUniforms uniforms {};
        uniforms.fogColor = simd_make_float4(fogColor[0], fogColor[1], fogColor[2], fogColor[3]);
        uniforms.clearWater = gOceanClearWater.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        [encoder setFragmentSamplerState:linearRepeatMip atIndex:0];

        auto draw = [&](const std::vector<u32> &indices, id<MTLRenderPipelineState> pipeline, id<MTLTexture> texture,
                        int bucket) {
            if (indices.empty()) return;
            const FrameUpload indexUpload = FrameUploadBytes(indices.data(), indices.size() * sizeof(u32));
            uniforms.bucket = bucket;
            [encoder setRenderPipelineState:pipeline];
            [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
            [encoder setFragmentTexture:texture atIndex:0];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:indices.size()
                                 indexType:MTLIndexTypeUInt32 indexBuffer:indexUpload.buffer
                         indexBufferOffset:indexUpload.offset];
        };

        if (clearBase) {
            // Clear water, before the level: the water's own opaque colour as a backdrop, without depth, so the
            // sea floor and fish still draw over it and the clear layer later blends over one or the other. With
            // nothing under the water (open sea, no floor) that is what shows through, not the sky.
            [encoder setDepthStencilState:depthAlwaysNoWrite];
            if (list.mid) {
                draw(list.indices[0], oceanOpaque, oceanTexture, 3);
            } else {
                draw(list.indices[0], oceanOpaque, oceanTexture, 6);
            }
        } else if (list.mid && clearMid) {
            // Clear water: the mid ocean (and the near/mid transition) drawn after the level, see-through like
            // the clear near ocean (shader bucket 5), so no border shows where the near ocean ends. Strictly
            // nearer + depth writes, so overlapping mid pieces blend only once.
            [encoder setDepthStencilState:depthGreaterWrite];
            draw(list.indices[0], oceanAlphaBlend, oceanTexture, 5);
            [encoder setDepthStencilState:depthGequalNoWrite];
            draw(list.indices[1], oceanDestAlphaAdd, envmap, 4);
        } else if (list.mid) {
            // CommonOceanRenderer::flush_mid: depth ALWAYS with writes; ocean opaque, then envmap.
            [encoder setDepthStencilState:depthAlwaysWrite];
            draw(list.indices[0], oceanOpaque, oceanTexture, 3);
            draw(list.indices[1], oceanDestAlphaAdd, envmap, 4);
        } else {
            // CommonOceanRenderer::flush_near: GEQUAL, no depth writes, blended.
            [encoder setDepthStencilState:depthGequalNoWrite];
            draw(list.indices[0], oceanAlphaBlend, oceanTexture, 0);
            draw(list.indices[1], oceanAlphaOnly, oceanTexture, 1);
            draw(list.indices[2], oceanDestAlphaAdd, envmap, 2);
        }
    }
};

Ocean::Ocean(id<MTLDevice> device, id<MTLLibrary> library) : _impl(std::make_unique<Impl>()) {
    Impl &impl = *_impl;
    impl.device = device;
    impl.far = std::make_unique<DirectRenderer>(device, library);

    impl.texturePipeline = impl.makePipeline(library, @"jak1_ocean_texture_vertex", @"jak1_ocean_texture_fragment",
                                             MTLPixelFormatRGBA8Unorm, false, nil);
    impl.mipmapPipeline = impl.makePipeline(library, @"jak1_ocean_mipmap_vertex", @"jak1_ocean_mipmap_fragment",
                                            MTLPixelFormatRGBA8Unorm, false, nil);
    auto blendSeparate = [](MTLBlendFactor src, MTLBlendFactor dst) {
        return ^(MTLRenderPipelineColorAttachmentDescriptor *color) {
            color.blendingEnabled = YES;
            color.sourceRGBBlendFactor = src;
            color.destinationRGBBlendFactor = dst;
            color.sourceAlphaBlendFactor = MTLBlendFactorOne;  // glBlendFuncSeparate(..., GL_ONE, GL_ZERO)
            color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        };
    };
    impl.oceanOpaque = impl.makePipeline(library, @"jak1_ocean_vertex", @"jak1_ocean_fragment",
                                         MTLPixelFormatBGRA8Unorm, true, nil);
    impl.oceanAlphaBlend = impl.makePipeline(library, @"jak1_ocean_vertex", @"jak1_ocean_fragment",
                                             MTLPixelFormatBGRA8Unorm, true,
                                             blendSeparate(MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha));
    impl.oceanAlphaOnly = impl.makePipeline(library, @"jak1_ocean_vertex", @"jak1_ocean_fragment",
                                            MTLPixelFormatBGRA8Unorm, true,
                                            blendSeparate(MTLBlendFactorZero, MTLBlendFactorOne));
    impl.oceanDestAlphaAdd = impl.makePipeline(library, @"jak1_ocean_vertex", @"jak1_ocean_fragment",
                                               MTLPixelFormatBGRA8Unorm, true,
                                               blendSeparate(MTLBlendFactorDestinationAlpha, MTLBlendFactorOne));

    MTLDepthStencilDescriptor *depth = [[MTLDepthStencilDescriptor alloc] init];
    depth.depthCompareFunction = MTLCompareFunctionAlways;
    depth.depthWriteEnabled = YES;
    impl.depthAlwaysWrite = [device newDepthStencilStateWithDescriptor:depth];
    depth.depthCompareFunction = MTLCompareFunctionGreaterEqual;
    depth.depthWriteEnabled = NO;
    impl.depthGequalNoWrite = [device newDepthStencilStateWithDescriptor:depth];
    depth.depthCompareFunction = MTLCompareFunctionGreater;
    depth.depthWriteEnabled = YES;
    impl.depthGreaterWrite = [device newDepthStencilStateWithDescriptor:depth];
    depth.depthCompareFunction = MTLCompareFunctionAlways;
    depth.depthWriteEnabled = NO;
    impl.depthAlwaysNoWrite = [device newDepthStencilStateWithDescriptor:depth];

    MTLSamplerDescriptor *sampler = [[MTLSamplerDescriptor alloc] init];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    impl.linearClamp = [device newSamplerStateWithDescriptor:sampler];
    sampler.mipFilter = MTLSamplerMipFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeRepeat;
    sampler.tAddressMode = MTLSamplerAddressModeRepeat;
    impl.linearRepeatMip = [device newSamplerStateWithDescriptor:sampler];

    auto makeTarget = [&](bool mipmapped) {
        MTLTextureDescriptor *texture =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:kOceanTextureSize
                                                              height:kOceanTextureSize
                                                           mipmapped:mipmapped];
        if (mipmapped) texture.mipmapLevelCount = kOceanTextureMips;
        texture.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
            (mipmapped ? MTLTextureUsageShaderWrite : 0);
        texture.storageMode = MTLStorageModePrivate;
        return [device newTextureWithDescriptor:texture];
    };
    impl.midTemp = makeTarget(false);
    impl.midTexture = makeTarget(true);
    impl.nearTexture = makeTarget(false);
    // One single-level view per mip, so a single compute dispatch can write every level.
    for (int level = 0; level < kOceanTextureMips; level++) {
        impl.midMipViews[level] = [impl.midTexture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                     textureType:MTLTextureType2D
                                                                          levels:NSMakeRange(level, 1)
                                                                          slices:NSMakeRange(0, 1)];
    }
    {
        NSError *error = nil;
        id<MTLFunction> kernel = [library newFunctionWithName:@"jak1_ocean_mipmap_kernel"];
        impl.mipmapCompute = kernel == nil ? nil : [device newComputePipelineStateWithFunction:kernel error:&error];
        if (impl.mipmapCompute == nil) {
            NSLog(@"Jak1Ocean mipmap kernel unavailable (%@); using per-level passes",
                  error.localizedDescription);
        }
    }

    const auto &positions = impl.midTextureProgram.positions();
    impl.texturePositions = [device newBufferWithBytes:positions.data() length:positions.size() * sizeof(math::Vector2f)
                                               options:MTLResourceStorageModeShared];
    const auto &indices = impl.midTextureProgram.indices();
    impl.textureIndices = [device newBufferWithBytes:indices.data() length:indices.size() * sizeof(u32)
                                             options:MTLResourceStorageModeShared];

    MTLTextureDescriptor *placeholder = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:1 height:1 mipmapped:NO];
    impl.placeholder = [device newTextureWithDescriptor:placeholder];
    const uint32_t texel = 0x80808080;
    [impl.placeholder replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&texel bytesPerRow:4];
}

Ocean::~Ocean() = default;

void Ocean::prepare(id<MTLCommandBuffer> commandBuffer, const uint8_t *trace, size_t traceLength,
                    const std::vector<uint32_t> &bucketOffsets) {
    Impl &impl = *_impl;
    impl.haveMid = impl.haveNear = impl.haveFar = false;
    if (trace == nullptr) return;

    // ---- OceanMidAndFar::render_jak1 ----
    std::vector<Entry> entries = BucketEntries(trace, traceLength, bucketOffsets, kMidAndFarBucket);
    if (entries.size() > 2 && entries[1].kind != kTagCall) {
        size_t at = 1;
        const int used = impl.runTexture(impl.midTextureProgram, entries, at);
        if (used > 0) {
            impl.renderTexture(commandBuffer, impl.midTextureProgram, impl.midTexture, true);
            // move_existing_to_vram(m_tex0_gpu, OCEAN_TEX_TBP_JAK1)
            PoolSetVramTexture(kOceanTextureTbp, impl.midTexture);
            at += used;

            // handle_ocean_far: a 160-byte GS setup (ta0 patched to 0), then direct packets.
            if (at < entries.size() && entries[at].size() == 160) {
                uint8_t init[160];
                memcpy(init, entries[at].payload, 160);
                init[80] = 0;
                impl.far->resetState();
                impl.far->renderGif(init, 160);
                at++;
                while (at < entries.size() && entries[at].kind == kTagCnt && entries[at].vifKind(0) == kVifNop &&
                       entries[at].vifKind(1) == kVifDirect) {
                    impl.far->renderGif(entries[at].payload, entries[at].size());
                    at++;
                }
                impl.far->flushPending();
                impl.haveFar = true;
            }

            // handle_ocean_mid: BASE/OFFSET, constants, MSCALF 0, then the VU program's data.
            if (at + 2 < entries.size() && entries[at].vifKind(0) == kVifBase &&
                entries[at + 1].size() == 0x240) {
                impl.mid.begin(entries[at + 1].payload);
                at += 3;
                auto isEnd = [](const Entry &e) {
                    return e.qwc == 2 && e.kind == kTagCnt && e.vifKind(0) == kVifNop && e.vifKind(1) == kVifDirect;
                };
                bool ok = true;
                while (at < entries.size() && !isEnd(entries[at]) && ok) {
                    ok = impl.mid.transfer(entries[at].vif0, entries[at].vif1, entries[at].payload, entries[at].size());
                    at++;
                }
                impl.mid.renderer().flush_mid(&impl.midDraws);
                impl.haveMid = ok;
            }
        }
    }

    // ---- OceanNear::render_jak1 ----
    entries = BucketEntries(trace, traceLength, bucketOffsets, kNearBucket);
    if (entries.size() > 2 && entries[1].kind != kTagCall) {
        size_t at = 1;
        const int used = impl.runTexture(impl.nearTextureProgram, entries, at);
        if (used > 0) {
            impl.renderTexture(commandBuffer, impl.nearTextureProgram, impl.nearTexture, false);
            at += used;
            // direct setup (2 qw), then BASE/OFFSET, then the VU program's data.
            if (at + 1 < entries.size() && entries[at].qwc == 2 && entries[at + 1].vifKind(0) == kVifBase) {
                impl.near.renderer().init_for_near();
                at += 2;
                auto isEnd = [](const Entry &e) {
                    return e.qwc == 2 && e.kind == kTagCnt && e.vifKind(0) == kVifNop && e.vifKind(1) == kVifDirect;
                };
                bool ok = true;
                while (at < entries.size() && !isEnd(entries[at]) && ok) {
                    ok = impl.near.transfer(entries[at].vif0, entries[at].vif1, entries[at].payload,
                                            entries[at].size());
                    at++;
                }
                impl.near.renderer().flush_near(&impl.nearDraws);
                impl.haveNear = ok;
            }
        }
    }

    static int logged = 0;
    if (logged < 3 && (impl.haveMid || impl.haveNear || impl.haveFar)) {
        NSLog(@"jakIOS: ocean far=%d mid=%d (%zu verts) near=%d (%zu verts)", impl.haveFar, impl.haveMid,
              impl.midDraws.vertices.size(), impl.haveNear, impl.nearDraws.vertices.size());
        logged++;
    }
}

static std::atomic<float> gOceanFogScale{1.0f};

void SetOceanClearWater(bool clear) {
    gOceanClearWater.store(clear, std::memory_order_relaxed);
}

void SetOceanFogScale(float scale) {
    gOceanFogScale.store(scale, std::memory_order_relaxed);
}

void Ocean::submitBucket(id<MTLRenderCommandEncoder> encoder, int bucket, const DirectViewport &viewport,
                         const float fogColor[4]) {
    Impl &impl = *_impl;
    // The far ocean keeps full fog so it still meets the horizon.
    const float waterFog[4] = {fogColor[0], fogColor[1], fogColor[2],
                               fogColor[3] * gOceanFogScale.load(std::memory_order_relaxed)};
    if (bucket == kMidAndFarBucket) {
        if (impl.haveFar) impl.far->submit(encoder, viewport, fogColor);
        // Clear water (when this frame has a near ocean; camera 48 m up: as usual). The opaque mid ocean drawn
        // here writes depth at the surface and hides everything under it past the near ocean's edge. Instead
        // both mid and near are drawn here as an opaque backdrop without depth, and again translucent with the
        // near ocean, after the level.
        impl.clearFrame = impl.haveNear && gOceanClearWater.load(std::memory_order_relaxed);
        if (impl.clearFrame) {
            if (impl.haveMid) impl.drawList(encoder, impl.midDraws, impl.midTexture, waterFog, false, true);
            impl.drawList(encoder, impl.nearDraws, impl.nearTexture, waterFog, false, true);
        } else if (impl.haveMid) {
            impl.drawList(encoder, impl.midDraws, impl.midTexture, waterFog);
        }
    } else if (bucket == kNearBucket) {
        if (impl.clearFrame && impl.haveMid) impl.drawList(encoder, impl.midDraws, impl.midTexture, waterFog, true);
        impl.clearFrame = false;
        if (impl.haveNear) impl.drawList(encoder, impl.nearDraws, impl.nearTexture, waterFog);
    }
}

}  // namespace jak1
