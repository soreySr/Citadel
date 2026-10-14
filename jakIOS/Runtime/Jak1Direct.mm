#import "Jak1Direct.h"

#define FMT_HEADER_ONLY 1
#include "common/dma/gs.h"
#include "common/math/Vector.h"

#import <Foundation/Foundation.h>
#include <simd/simd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <mutex>
#include <unordered_map>

// Defined in Jak1MetalRenderer.mm: GS VRAM block -> PC texture combo id, from texture uploads.
bool Jak1TexturePoolLookup(uint32_t tbp, uint32_t *comboId);
bool Jak1TexturePoolLookupInSnapshot(int slot, uint32_t tbp, uint32_t *comboId);
bool Jak1TexturePoolLookupAtTraceOffset(size_t traceOffset, uint32_t tbp, uint32_t *comboId);

namespace jak1 {

// ---------------------------------------------------------------------------------------------
// Texture pool

namespace {
std::mutex gPoolMutex;
// combo id -> textures of every loaded level providing it; the first one is used. Several levels
// can carry the same texture, so unloading one falls back to another (TexturePool::unload_texture).
std::unordered_map<uint32_t, std::vector<id<MTLTexture>>> gPoolTextures;
std::unordered_map<uint32_t, id<MTLTexture>> gPoolVramOverrides;  // tbp -> PC-generated texture

id<MTLTexture> PoolTextureForCombo(uint32_t comboId) {
    auto found = gPoolTextures.find(comboId);
    return found == gPoolTextures.end() || found->second.empty() ? nil : found->second.front();
}
}  // namespace

void PoolRegisterTexture(uint32_t comboId, id<MTLTexture> texture) {
    if (texture == nil) return;
    std::lock_guard<std::mutex> lock(gPoolMutex);
    gPoolTextures[comboId].push_back(texture);
}

void PoolUnregisterTexture(uint32_t comboId, id<MTLTexture> texture) {
    std::lock_guard<std::mutex> lock(gPoolMutex);
    auto found = gPoolTextures.find(comboId);
    if (found == gPoolTextures.end()) return;
    auto &providers = found->second;
    providers.erase(std::remove(providers.begin(), providers.end(), texture), providers.end());
    if (providers.empty()) gPoolTextures.erase(found);
}

void PoolSetVramTexture(uint32_t tbp, id<MTLTexture> texture) {
    std::lock_guard<std::mutex> lock(gPoolMutex);
    gPoolVramOverrides[tbp] = texture;
}

id<MTLTexture> PoolTextureForTbp(uint32_t tbp) {
    std::lock_guard<std::mutex> lock(gPoolMutex);
    auto overridden = gPoolVramOverrides.find(tbp);
    if (overridden != gPoolVramOverrides.end()) return overridden->second;
    uint32_t comboId = 0;
    if (!Jak1TexturePoolLookup(tbp, &comboId)) return nil;
    return PoolTextureForCombo(comboId);
}

// Like PoolTextureForTbp, but in the VRAM layout saved at a point in the chain.
static id<MTLTexture> PoolTextureForTbpInSnapshot(int slot, uint32_t tbp) {
    uint32_t comboId = 0;
    if (!Jak1TexturePoolLookupInSnapshot(slot, tbp, &comboId)) return nil;
    std::lock_guard<std::mutex> lock(gPoolMutex);
    return PoolTextureForCombo(comboId);
}

id<MTLTexture> PoolTextureForTbpAtEyes(uint32_t tbp) {
    {
        std::lock_guard<std::mutex> lock(gPoolMutex);
        auto overridden = gPoolVramOverrides.find(tbp);
        if (overridden != gPoolVramOverrides.end()) return overridden->second;
    }
    return PoolTextureForTbpInSnapshot(kEyeTexturePoolSnapshot, tbp);
}

id<MTLTexture> PoolTextureForTbpAtTraceOffset(uint32_t tbp, size_t traceOffset) {
    {
        std::lock_guard<std::mutex> lock(gPoolMutex);
        auto overridden = gPoolVramOverrides.find(tbp);
        if (overridden != gPoolVramOverrides.end()) return overridden->second;
    }
    uint32_t comboId = 0;
    if (!Jak1TexturePoolLookupAtTraceOffset(traceOffset, tbp, &comboId)) return nil;
    std::lock_guard<std::mutex> lock(gPoolMutex);
    return PoolTextureForCombo(comboId);
}

// ---------------------------------------------------------------------------------------------
// Per-frame uploads

namespace {
struct FrameUploadRing {
    id<MTLDevice> device = nil;
    __strong id<MTLBuffer> buffers[3] = {nil, nil, nil};
    uint32_t slot = 0;
    NSUInteger cursor = 0;
};
FrameUploadRing gFrameUploads;
constexpr NSUInteger kFrameUploadAlignment = 256;
constexpr NSUInteger kFrameUploadInitialSize = 1u << 20;
}  // namespace

void FrameUploadsBeginFrame(id<MTLDevice> device) {
    gFrameUploads.device = device;
    gFrameUploads.slot = (gFrameUploads.slot + 1) % 3;
    gFrameUploads.cursor = 0;
}

FrameUpload FrameUploadBytes(const void *bytes, size_t length) {
    FrameUploadRing &ring = gFrameUploads;
    if (length == 0 || ring.device == nil) return {};
    __strong id<MTLBuffer> &buffer = ring.buffers[ring.slot];
    const NSUInteger offset = (ring.cursor + kFrameUploadAlignment - 1) & ~(kFrameUploadAlignment - 1);
    if (buffer == nil || offset + length > buffer.length) {
        // Replace this slot with a larger buffer. Encoders retain the buffers they reference, so
        // earlier uploads this frame stay valid in the old one.
        const NSUInteger previous = buffer == nil ? 0 : buffer.length;
        const NSUInteger size = std::max<NSUInteger>({kFrameUploadInitialSize, previous * 2, length * 2});
        buffer = [ring.device newBufferWithLength:size options:MTLResourceStorageModeShared];
        memcpy(buffer.contents, bytes, length);
        ring.cursor = length;
        return {buffer, 0};
    }
    memcpy(static_cast<uint8_t *>(buffer.contents) + offset, bytes, length);
    ring.cursor = offset + length;
    return {buffer, offset};
}

// ---------------------------------------------------------------------------------------------
// Direct renderer

namespace {

// DirectRenderer::Vertex (mirrored as DirectVertex in Jak1Shaders.metal).
struct DirectVertex {
    math::Vector<float, 4> xyzf;
    math::Vector<float, 3> stq;
    math::Vector<u8, 4> rgba;
    u8 texUnit;
    u8 tcc;
    u8 decal;
    u8 fogEnable;
    u8 useUv;
    u8 pad[11];
    math::Vector<float, 4> scissor;
};
static_assert(sizeof(DirectVertex) == 64, "DirectVertex layout");

// Fragment uniforms (DirectUniforms in Jak1Shaders.metal).
struct DirectUniforms {
    simd_float4 fogColor;
    simd_float4 gameSizes;  // game width, game height, viewport width, viewport height
    simd_float2 viewportOrigin;
    float alphaMin;
    float alphaMax;
    float colorMult;
    float alphaMult;
    float ta0;
    uint32_t greater;
    uint32_t scissorEnable;
    uint32_t textured;
    float pad[2];
};

// GS blend equations DirectRenderer::update_gl_blend supports.
enum class DirectBlend : uint8_t { None, Alpha, AddSrcAlpha, ReverseSubtract, Fixed, DestAlphaAdd };

// One flush_pending: a vertex range with the GL state OpenGOAL would have bound.
struct DirectDraw {
    uint32_t firstVertex = 0;
    uint32_t vertexCount = 0;
    DirectBlend blend = DirectBlend::None;
    float blendFix = 0;
    bool writeRgb = true;
    bool depthTest = true;
    GsTest::ZTest ztest = GsTest::ZTest::GEQUAL;
    bool depthWrite = true;
    bool doubleDraw = false;
    bool textured = false;
    uint32_t tbp = 0;
    bool clampS = true, clampT = true, filter = true;
    DirectUniforms uniforms {};
};

}  // namespace

struct DirectRenderer::Impl {
    id<MTLDevice> device;
    id<MTLFunction> vertexFunction, texturedFragment, untexturedFragment;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> pipelines;
    id<MTLDepthStencilState> depthStates[4][2];  // [ztest][write]
    id<MTLDepthStencilState> depthDisabled;
    id<MTLSamplerState> samplers[8];             // [filter][clampS][clampT]
    id<MTLTexture> placeholder;

    std::vector<DirectVertex> vertices;  // all batches of this submit, back to back
    std::vector<DirectDraw> draws;
    uint32_t batchStart = 0;

    // ---- GS state (DirectRenderer.h) ----
    struct TestState {
        GsTest currentRegister;
        bool alphaTestEnable = false;
        GsTest::AlphaTest alphaTest = GsTest::AlphaTest::NOTEQUAL;
        u8 aref = 0;
        GsTest::AlphaFail afail = GsTest::AlphaFail::KEEP;
        bool zte = true;
        GsTest::ZTest ztst = GsTest::ZTest::GEQUAL;
        bool writeRgb = true;
        bool depthWrites = true;
        void fromRegister(GsTest reg) {
            currentRegister = reg;
            alphaTestEnable = reg.alpha_test_enable();
            if (alphaTestEnable) {
                alphaTest = reg.alpha_test();
                aref = reg.aref();
                afail = reg.afail();
            }
            zte = reg.zte();
            ztst = reg.ztest();
        }
    } test;

    struct BlendState {
        GsAlpha currentRegister;
        GsAlpha::BlendMode a = GsAlpha::BlendMode::SOURCE, b = GsAlpha::BlendMode::DEST,
                           c = GsAlpha::BlendMode::SOURCE, d = GsAlpha::BlendMode::DEST;
        bool alphaBlendEnable = false;
        u8 fix = 0;
        void fromRegister(GsAlpha reg) {
            currentRegister = reg;
            a = reg.a_mode();
            b = reg.b_mode();
            c = reg.c_mode();
            d = reg.d_mode();
            fix = reg.fix();
        }
    } blend;

    struct PrimState {
        GsPrim currentRegister;
        bool gouraud = false, texture = false, fogging = false, useUv = false;
        u32 ta0 = 0;
        void fromRegister(GsPrim reg) {
            currentRegister = reg;
            gouraud = reg.gouraud();
            texture = reg.tme();
            fogging = reg.fge();
            useUv = reg.fst();
        }
    } prim;

    struct TextureState {
        GsTex0 currentRegister;
        u32 tbp = 0;
        bool tcc = false, decal = false, filter = true;
        u64 clampRegister = 0b101;
        bool clampS = true, clampT = true;
    } texFromRegister, batchTexture;
    bool batchTextureValid = false;

    struct BuildState {
        GsPrim::Kind kind = GsPrim::Kind::PRIM_7;
        math::Vector<u8, 4> rgba{0, 0, 0, 0};
        math::Vector<float, 2> st{0, 0};
        std::array<math::Vector<u8, 4>, 3> buildRgba;
        std::array<math::Vector<u32, 4>, 3> buildVert;
        std::array<math::Vector<float, 3>, 3> buildStq;
        int buildIndex = 0;
        int stripStartup = 0;
        float q = 1.0f;
    } build;

    struct Scissor {
        u16 x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    } scissor;
    bool scissorEnable = false;

    id<MTLRenderPipelineState> pipelineFor(bool textured, DirectBlend blendMode, bool writeRgb) {
        const uint32_t key = (textured ? 1u : 0u) | (static_cast<uint32_t>(blendMode) << 1) | (writeRgb ? 0x100u : 0u);
        auto found = pipelines.find(key);
        if (found != pipelines.end()) return found->second;
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = textured ? texturedFragment : untexturedFragment;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        SetMainPassDepthFormats(descriptor);
        MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
        color.writeMask = writeRgb ? MTLColorWriteMaskAll : MTLColorWriteMaskAlpha;
        color.blendingEnabled = blendMode != DirectBlend::None;
        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        color.rgbBlendOperation = MTLBlendOperationAdd;
        switch (blendMode) {
            case DirectBlend::Alpha:  // (Cs - Cd) * As + Cd
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                break;
            case DirectBlend::AddSrcAlpha:  // Cs * As + Cd
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                break;
            case DirectBlend::ReverseSubtract:  // Cd - Cs * As
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                color.rgbBlendOperation = MTLBlendOperationReverseSubtract;
                break;
            case DirectBlend::Fixed:  // (Cs - Cd) * fix + Cd
                color.sourceRGBBlendFactor = MTLBlendFactorBlendAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOneMinusBlendAlpha;
                break;
            case DirectBlend::DestAlphaAdd:  // Cs * Ad + Cd
                color.sourceRGBBlendFactor = MTLBlendFactorDestinationAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                break;
            case DirectBlend::None:
                break;
        }
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (error != nil) NSLog(@"Jak1Direct pipeline error: %@", error.localizedDescription);
        pipelines[key] = state;
        return state;
    }

    // ---- flush_pending: capture the batch with the state OpenGOAL would bind ----
    void flushPending() {
        const uint32_t count = static_cast<uint32_t>(vertices.size()) - batchStart;
        if (count == 0) {
            batchTextureValid = false;
            return;
        }
        DirectDraw draw;
        draw.firstVertex = batchStart;
        draw.vertexCount = count;

        // update_gl_blend
        float colorMult = 1.f;
        if (blend.alphaBlendEnable) {
            using M = GsAlpha::BlendMode;
            if (blend.a == M::SOURCE && blend.b == M::DEST && blend.c == M::SOURCE && blend.d == M::DEST) {
                draw.blend = DirectBlend::Alpha;
            } else if (blend.a == M::SOURCE && blend.b == M::ZERO_OR_FIXED && blend.c == M::SOURCE &&
                       blend.d == M::DEST) {
                draw.blend = DirectBlend::AddSrcAlpha;
            } else if (blend.a == M::ZERO_OR_FIXED && blend.b == M::SOURCE && blend.c == M::SOURCE &&
                       blend.d == M::DEST) {
                draw.blend = DirectBlend::ReverseSubtract;
            } else if (blend.a == M::SOURCE && blend.b == M::DEST && blend.c == M::ZERO_OR_FIXED &&
                       blend.d == M::DEST) {
                draw.blend = DirectBlend::Fixed;
                draw.blendFix = blend.fix / 127.f;
            } else if (blend.a == M::SOURCE && blend.b == M::ZERO_OR_FIXED && blend.c == M::DEST &&
                       blend.d == M::DEST) {
                draw.blend = DirectBlend::DestAlphaAdd;
                colorMult = 0.5f;
            }
        }

        // update_gl_test
        draw.depthTest = test.zte;
        draw.ztest = test.ztst;
        const bool alphaTrickDisable = test.alphaTestEnable && test.alphaTest == GsTest::AlphaTest::NEVER &&
                                       test.afail == GsTest::AlphaFail::FB_ONLY;
        draw.depthWrite = test.depthWrites && !alphaTrickDisable;
        draw.writeRgb = test.writeRgb;

        // update_gl_prim
        draw.textured = prim.texture;
        DirectUniforms &u = draw.uniforms;
        u.alphaMin = 0.f;
        u.alphaMax = 10.f;
        u.colorMult = colorMult;
        u.alphaMult = 1.f;
        u.ta0 = prim.ta0 / 255.f;
        u.textured = prim.texture ? 1 : 0;
        u.scissorEnable = scissorEnable ? 1 : 0;
        if (prim.texture && test.alphaTestEnable) {
            switch (test.alphaTest) {
                case GsTest::AlphaTest::GEQUAL:
                    u.alphaMin = test.aref / 128.f;
                    break;
                case GsTest::AlphaTest::GREATER:
                    u.alphaMin = (1 + test.aref) / 128.f;
                    u.greater = 1;
                    break;
                default:
                    break;
            }
        }
        draw.doubleDraw = prim.texture && (test.afail == GsTest::AlphaFail::FB_ONLY ||
                                           test.afail == GsTest::AlphaFail::RGB_ONLY);

        // update_gl_texture (one texture unit per batch)
        if (prim.texture && batchTextureValid) {
            draw.tbp = batchTexture.tbp;
            draw.clampS = batchTexture.clampS;
            draw.clampT = batchTexture.clampT;
            draw.filter = batchTexture.filter;
        }

        draws.push_back(draw);
        batchStart = static_cast<uint32_t>(vertices.size());
        batchTextureValid = false;
    }

    // get_texture_unit_for_current_reg with TEXTURE_STATE_COUNT == 1.
    void useCurrentTexture() {
        if (batchTextureValid) {
            const bool same = batchTexture.currentRegister == texFromRegister.currentRegister &&
                              batchTexture.clampRegister == texFromRegister.clampRegister &&
                              batchTexture.filter == texFromRegister.filter;
            if (same) return;
            flushPending();
        }
        batchTexture = texFromRegister;
        batchTextureValid = true;
    }

    void push(const math::Vector<u8, 4> &rgba, const math::Vector<u32, 4> &vert,
              const math::Vector<float, 3> &stq, bool tcc, bool decal, bool fog, bool useUv) {
        DirectVertex v {};
        v.rgba = rgba;
        v.xyzf[0] = static_cast<float>(vert[0]) / static_cast<float>(UINT32_MAX);
        v.xyzf[1] = static_cast<float>(vert[1]) / static_cast<float>(UINT32_MAX);
        v.xyzf[2] = static_cast<float>(vert[2]) / static_cast<float>(0xffffff);
        v.xyzf[3] = static_cast<float>(vert[3]);
        v.stq = stq;
        v.tcc = tcc;
        v.decal = decal;
        v.fogEnable = fog;
        v.useUv = useUv;
        v.scissor = math::Vector<float, 4>(scissor.x0, scissor.x1, scissor.y0, scissor.y1);
        vertices.push_back(v);
    }

    // ---- register handlers (DirectRenderer.cpp) ----
    void handlePrim(u64 value) {
        if (build.stripStartup) {
            build.stripStartup = 0;
            build.buildIndex = 0;
        }
        GsPrim reg(value);
        if (prim.currentRegister != reg || blend.alphaBlendEnable != reg.abe()) {
            flushPending();
            prim.fromRegister(reg);
            blend.alphaBlendEnable = reg.abe();
        }
        build.kind = reg.kind();
    }

    void handleTest1(u64 value) {
        GsTest reg(value);
        if (test.currentRegister != reg) {
            flushPending();
            test.fromRegister(reg);
        }
    }

    void handleAlpha1(u64 value) {
        GsAlpha reg(value);
        if (blend.currentRegister != reg) {
            flushPending();
            blend.fromRegister(reg);
        }
    }

    void handleZbuf1(u64 value) {
        const bool write = !GsZbuf(value).zmsk();
        if (write != test.depthWrites) {
            flushPending();
            test.depthWrites = write;
        }
    }

    void handleTexa(u64 value) {
        GsTexa reg(value);
        if (prim.ta0 != reg.ta0()) {
            flushPending();
            prim.ta0 = reg.ta0();
        }
    }

    void handleTex0(u64 value) {
        GsTex0 reg(value);
        if (texFromRegister.currentRegister != reg) {
            // using_mt4hh: PSMT4HH textures are looked up as tbp | 0x8000 (lookup_mt4hh).
            texFromRegister.tbp = reg.tbp0() | (reg.psm() == GsTex0::PSM::PSMT4HH ? 0x8000u : 0u);
            texFromRegister.currentRegister = reg;
            texFromRegister.tcc = reg.tcc();
            texFromRegister.decal = reg.tfx() == GsTex0::TextureFunction::DECAL;
        }
    }

    void handleTex1(u64 value) { texFromRegister.filter = GsTex1(value).mmag(); }

    void handleClamp1(u64 value) {
        texFromRegister.clampRegister = value;
        texFromRegister.clampS = value & 0b001;
        texFromRegister.clampT = value & 0b100;
    }

    void handleScissor(u64 value) {
        scissor.x0 = value & 0x7ff;
        scissor.x1 = (value >> 16) & 0x7ff;
        scissor.y0 = (value >> 32) & 0x7ff;
        scissor.y1 = (value >> 48) & 0x7ff;
        scissorEnable = true;
    }

    void handleAd(const u8 *data) {
        u64 value;
        memcpy(&value, data, 8);
        const u8 address = data[8];
        switch (static_cast<GsRegisterAddress>(address)) {
            case GsRegisterAddress::ZBUF_1: handleZbuf1(value); break;
            case GsRegisterAddress::TEST_1: handleTest1(value); break;
            case GsRegisterAddress::ALPHA_1: handleAlpha1(value); break;
            case GsRegisterAddress::CLAMP_1: handleClamp1(value); break;
            case GsRegisterAddress::PRIM: handlePrim(value); break;
            case GsRegisterAddress::TEX1_1: handleTex1(value); break;
            case GsRegisterAddress::TEXA: handleTexa(value); break;
            case GsRegisterAddress::TEX0_1: handleTex0(value); break;
            case GsRegisterAddress::SCISSOR_1: handleScissor(value); break;
            case GsRegisterAddress::RGBAQ:
                for (int i = 0; i < 4; i++) build.rgba[i] = data[i];
                memcpy(&build.q, data + 4, 4);
                break;
            default:
                break;  // FRAME, TEXCLUT, FOGCOL, MIPTBP, TEXFLUSH, ...: nothing to do for drawing
        }
    }

    void handleXyzf2Common(u32 x, u32 y, u32 z, u8 f, bool advance) {
        build.buildStq.at(build.buildIndex) = math::Vector<float, 3>(build.st.x(), build.st.y(), build.q);
        build.buildRgba.at(build.buildIndex) = build.rgba;
        build.buildVert.at(build.buildIndex) = math::Vector<u32, 4>{x, y, z, f};
        build.buildIndex++;

        useCurrentTexture();
        const bool tcc = batchTexture.tcc, decal = batchTexture.decal;
        const bool fog = prim.fogging, useUv = prim.useUv;

        switch (build.kind) {
            case GsPrim::Kind::SPRITE:
                if (build.buildIndex == 2) {
                    const auto &v1 = build.buildVert[0], &v2 = build.buildVert[1];
                    const auto &s1 = build.buildStq[0], &s2 = build.buildStq[1];
                    const auto &c1 = build.buildRgba[0], &c2 = build.buildRgba[1];
                    math::Vector<u32, 4> v3{v1[0], v2[1], v2[2], 0};
                    math::Vector<u32, 4> v4{v2[0], v1[1], v2[2], 0};
                    math::Vector<float, 3> s3{s1[0], s2[1], s2[2]};
                    math::Vector<float, 3> s4{s2[0], s1[1], s2[2]};
                    push(c1, v1, s1, tcc, decal, fog, useUv);
                    push(c2, v3, s3, tcc, decal, fog, useUv);
                    push(c2, v2, s2, tcc, decal, fog, useUv);
                    push(c2, v2, s2, tcc, decal, fog, useUv);
                    push(c2, v4, s4, tcc, decal, fog, useUv);
                    push(c1, v1, s1, tcc, decal, fog, useUv);
                    build.buildIndex = 0;
                }
                break;
            case GsPrim::Kind::TRI_STRIP:
                if (build.buildIndex == 3) build.buildIndex = 0;
                if (build.stripStartup < 3) build.stripStartup++;
                if (build.stripStartup >= 3 && advance) {
                    for (int i = 0; i < 3; i++) {
                        push(build.buildRgba[i], build.buildVert[i], build.buildStq[i], tcc, decal, fog, useUv);
                    }
                }
                break;
            case GsPrim::Kind::TRI:
                if (build.buildIndex == 3) {
                    build.buildIndex = 0;
                    for (int i = 0; i < 3; i++) {
                        push(build.buildRgba[i], build.buildVert[i], build.buildStq[i], tcc, decal, fog, useUv);
                    }
                }
                break;
            case GsPrim::Kind::TRI_FAN:
                if (build.stripStartup < 2) {
                    build.stripStartup++;
                } else {
                    if (build.buildIndex == 3) build.buildIndex = 1;
                    for (int i = 0; i < 3; i++) {
                        push(build.buildRgba[i], build.buildVert[i], build.buildStq[i], tcc, decal, fog, useUv);
                    }
                }
                break;
            case GsPrim::Kind::LINE:
            case GsPrim::Kind::LINE_STRIP: {
                const bool strip = build.kind == GsPrim::Kind::LINE_STRIP;
                if (build.buildIndex == 2) {
                    if (strip) {
                        build.buildIndex = 0;
                        if (build.stripStartup < 2) build.stripStartup++;
                        if (build.stripStartup < 2 || !advance) break;
                    } else {
                        build.buildIndex = 0;
                    }
                    // Lines become thin quads, as in OpenGOAL.
                    const math::Vector<double, 3> p0 = build.buildVert[0].xyz().cast<double>();
                    const math::Vector<double, 3> p1 = build.buildVert[1].xyz().cast<double>();
                    const auto normal = (p1 - p0).normalized().cross(math::Vector<double, 3>{0, 0, 1});
                    const double width = (1 << 19);
                    auto toU = [](const math::Vector<double, 3> &p) {
                        return math::Vector<u32, 4>{static_cast<u32>(p.x()), static_cast<u32>(p.y()),
                                                    static_cast<u32>(p.z()), 0};
                    };
                    const auto a = toU(p0 + normal * width), b = toU(p1 + normal * width);
                    const auto c = toU(p0 - normal * width), d = toU(p1 - normal * width);
                    const math::Vector<float, 3> none{0, 0, 0};
                    push(build.buildRgba[0], a, none, false, false, false, false);
                    push(build.buildRgba[0], c, none, false, false, false, false);
                    push(build.buildRgba[1], b, none, false, false, false, false);
                    push(build.buildRgba[1], b, none, false, false, false, false);
                    push(build.buildRgba[0], c, none, false, false, false, false);
                    push(build.buildRgba[1], d, none, false, false, false, false);
                }
                break;
            }
            default:
                build.buildIndex = 0;
                break;
        }
    }

    void renderGif(const u8 *data, u32 size) {
        bool eop = false;
        u32 offset = 0;
        while (!eop) {
            if (offset + 16 > size) return;
            GifTag tag(data + offset);
            offset += 16;
            eop = tag.eop();
            GifTag::RegisterDescriptor descriptors[16];
            const u32 nreg = tag.nreg();
            for (u32 i = 0; i < nreg; i++) descriptors[i] = tag.reg(i);

            const auto format = tag.flg();
            if (format == GifTag::Format::PACKED) {
                if (offset + static_cast<u64>(tag.nloop()) * nreg * 16 > size) return;
                if (tag.pre()) handlePrim(tag.prim());
                for (u32 loop = 0; loop < tag.nloop(); loop++) {
                    for (u32 reg = 0; reg < nreg; reg++, offset += 16) {
                        const u8 *value = data + offset;
                        switch (descriptors[reg]) {
                            case GifTag::RegisterDescriptor::AD: handleAd(value); break;
                            case GifTag::RegisterDescriptor::ST:
                                memcpy(&build.st.x(), value, 4);
                                memcpy(&build.st.y(), value + 4, 4);
                                memcpy(&build.q, value + 8, 4);
                                break;
                            case GifTag::RegisterDescriptor::RGBAQ:
                                build.rgba[0] = value[0];
                                build.rgba[1] = value[4];
                                build.rgba[2] = value[8];
                                build.rgba[3] = value[12];
                                break;
                            case GifTag::RegisterDescriptor::XYZF2:
                            case GifTag::RegisterDescriptor::XYZ2: {
                                u32 x, y;
                                u64 upper;
                                memcpy(&x, value, 4);
                                memcpy(&y, value + 4, 4);
                                memcpy(&upper, value + 8, 8);
                                const bool xyzf = descriptors[reg] == GifTag::RegisterDescriptor::XYZF2;
                                const u32 z = xyzf ? (upper >> 4) & 0xffffff : static_cast<u32>(upper);
                                const u8 f = xyzf ? static_cast<u8>(upper >> 36) : 0;
                                const bool adc = upper & (1ull << 47);
                                handleXyzf2Common(x << 16, y << 16, z, f, !adc);
                                break;
                            }
                            case GifTag::RegisterDescriptor::PRIM: {
                                u64 v;
                                memcpy(&v, value, 8);
                                handlePrim(v);
                                break;
                            }
                            case GifTag::RegisterDescriptor::TEX0_1: {
                                u64 v;
                                memcpy(&v, value, 8);
                                handleTex0(v);
                                break;
                            }
                            case GifTag::RegisterDescriptor::UV: {
                                u32 uu, vv;
                                memcpy(&uu, value, 4);
                                memcpy(&vv, value + 4, 4);
                                build.st.x() = uu;
                                build.st.y() = vv;
                                build.q = 1;
                                break;
                            }
                            default:
                                break;
                        }
                    }
                }
            } else if (format == GifTag::Format::REGLIST) {
                if (offset + static_cast<u64>(tag.nloop()) * nreg * 8 > size) return;
                for (u32 loop = 0; loop < tag.nloop(); loop++) {
                    for (u32 reg = 0; reg < nreg; reg++, offset += 8) {
                        u64 v;
                        memcpy(&v, data + offset, 8);
                        switch (descriptors[reg]) {
                            case GifTag::RegisterDescriptor::PRIM: handlePrim(v); break;
                            case GifTag::RegisterDescriptor::RGBAQ: memcpy(build.rgba.data(), &v, 4); break;
                            case GifTag::RegisterDescriptor::XYZF2:
                                handleXyzf2Common((v & 0xffff) << 16, ((v >> 16) & 0xffff) << 16,
                                                  (v >> 32) & 0xffffff, (v >> 56) & 0xff, true);
                                break;
                            default:
                                break;
                        }
                    }
                }
                offset = (offset + 15) & ~15u;
            } else {
                return;  // IMAGE transfers (texture uploads) aren't drawn
            }
        }
    }

    // DirectRenderer::render_vif: follow DIRECT codes, skipping NOP/FLUSHA.
    void renderVif(u32 vif0, u32 vif1, const u8 *data, u32 size) {
        auto directQwc = [](u32 vif, bool *ignorable) -> u32 {
            const u32 kind = (vif >> 24) & 0x7f;
            *ignorable = kind == 0x00 || kind == 0x13;
            if (kind == 0x50 || kind == 0x51) return (vif & 0xffff) == 0 ? 65536 : (vif & 0xffff);
            return 0;
        };
        bool ignorable = false;
        u32 gifQwc = directQwc(vif0, &ignorable);
        if (gifQwc == 0) {
            if (!ignorable) return;
            gifQwc = directQwc(vif1, &ignorable);
            if (gifQwc == 0 && !ignorable) return;
        }
        u32 offset = 0;
        while (offset < size) {
            if (gifQwc) {
                if (offset & 0xf) {
                    offset += 4;
                } else {
                    renderGif(data + offset, std::min<u32>(gifQwc * 16, size - offset));
                    offset += gifQwc * 16;
                    gifQwc = 0;
                }
            } else {
                if (offset + 4 > size) return;
                u32 vif;
                memcpy(&vif, data + offset, 4);
                offset += 4;
                gifQwc = directQwc(vif, &ignorable);
                if (gifQwc == 0 && !ignorable) return;
            }
        }
    }
};

DirectRenderer::DirectRenderer(id<MTLDevice> device, id<MTLLibrary> library) : _impl(std::make_unique<Impl>()) {
    Impl &impl = *_impl;
    impl.device = device;
    impl.vertexFunction = [library newFunctionWithName:@"jak1_direct_vertex"];
    impl.texturedFragment = [library newFunctionWithName:@"jak1_direct_textured_fragment"];
    impl.untexturedFragment = [library newFunctionWithName:@"jak1_direct_fragment"];

    const MTLCompareFunction functions[4] = {MTLCompareFunctionNever, MTLCompareFunctionAlways,
                                             MTLCompareFunctionGreaterEqual, MTLCompareFunctionGreater};
    for (int z = 0; z < 4; z++) {
        for (int write = 0; write < 2; write++) {
            MTLDepthStencilDescriptor *depth = [[MTLDepthStencilDescriptor alloc] init];
            depth.depthCompareFunction = functions[z];
            depth.depthWriteEnabled = write;
            impl.depthStates[z][write] = [device newDepthStencilStateWithDescriptor:depth];
        }
    }
    MTLDepthStencilDescriptor *off = [[MTLDepthStencilDescriptor alloc] init];
    off.depthCompareFunction = MTLCompareFunctionAlways;
    off.depthWriteEnabled = NO;
    impl.depthDisabled = [device newDepthStencilStateWithDescriptor:off];

    for (int i = 0; i < 8; i++) {
        MTLSamplerDescriptor *sampler = [[MTLSamplerDescriptor alloc] init];
        const bool filter = i & 4;
        sampler.minFilter = filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler.magFilter = sampler.minFilter;
        sampler.sAddressMode = (i & 2) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        sampler.tAddressMode = (i & 1) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        impl.samplers[i] = [device newSamplerStateWithDescriptor:sampler];
    }

    MTLTextureDescriptor *placeholder = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:1 height:1 mipmapped:NO];
    impl.placeholder = [device newTextureWithDescriptor:placeholder];
    const uint32_t texel = 0x80808080;
    [impl.placeholder replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&texel bytesPerRow:4];
}

DirectRenderer::~DirectRenderer() = default;

void DirectRenderer::resetState() {
    Impl &impl = *_impl;
    impl.flushPending();
    impl.test = Impl::TestState();
    impl.blend = Impl::BlendState();
    impl.prim = Impl::PrimState();
    impl.texFromRegister = Impl::TextureState();
    impl.batchTextureValid = false;
    impl.build = Impl::BuildState();
}

void DirectRenderer::renderVif(uint32_t vif0, uint32_t vif1, const uint8_t *data, uint32_t size) {
    _impl->renderVif(vif0, vif1, data, size);
}

void DirectRenderer::renderGif(const uint8_t *data, uint32_t size) {
    _impl->renderGif(data, size);
}

void DirectRenderer::flushPending() {
    _impl->flushPending();
}

void DirectRenderer::submit(id<MTLRenderCommandEncoder> encoder, const DirectViewport &viewport,
                            const float fogColor[4]) {
    Impl &impl = *_impl;
    impl.flushPending();
    if (impl.draws.empty()) {
        impl.vertices.clear();
        impl.batchStart = 0;
        return;
    }
    const FrameUpload upload = FrameUploadBytes(impl.vertices.data(), impl.vertices.size() * sizeof(DirectVertex));
    [encoder setVertexBuffer:upload.buffer offset:upload.offset atIndex:0];
    for (DirectDraw &draw : impl.draws) {
        DirectUniforms &u = draw.uniforms;
        u.fogColor = simd_make_float4(fogColor[0], fogColor[1], fogColor[2], fogColor[3]);
        u.gameSizes = simd_make_float4(512.0f, 448.0f, viewport.width, viewport.height);
        u.viewportOrigin = simd_make_float2(viewport.x, viewport.y);

        [encoder setRenderPipelineState:impl.pipelineFor(draw.textured, draw.blend, draw.writeRgb)];
        if (draw.blend == DirectBlend::Fixed) {
            [encoder setBlendColorRed:0 green:0 blue:0 alpha:draw.blendFix];
        }
        if (draw.textured) {
            id<MTLTexture> texture = PoolTextureForTbp(draw.tbp);
            [encoder setFragmentTexture:texture != nil ? texture : impl.placeholder atIndex:0];
            [encoder setFragmentSamplerState:impl.samplers[(draw.filter ? 4 : 0) | (draw.clampS ? 2 : 0) |
                                                           (draw.clampT ? 1 : 0)]
                                     atIndex:0];
        }
        const int ztest = std::clamp(static_cast<int>(draw.ztest), 0, 3);
        auto depthFor = [&](bool write) {
            return draw.depthTest ? impl.depthStates[ztest][write ? 1 : 0] : impl.depthDisabled;
        };
        if (draw.doubleDraw) {
            // The usual atest FB_ONLY trick: passing pixels write depth, failing ones don't.
            const float aref = u.alphaMin;
            u.alphaMax = 10.f;
            [encoder setDepthStencilState:depthFor(true)];
            [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:draw.firstVertex vertexCount:draw.vertexCount];
            u.alphaMin = -10.f;
            u.alphaMax = aref;
            [encoder setDepthStencilState:depthFor(false)];
            [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:draw.firstVertex vertexCount:draw.vertexCount];
        } else {
            [encoder setDepthStencilState:depthFor(draw.depthWrite)];
            [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:draw.firstVertex vertexCount:draw.vertexCount];
        }
    }
    impl.draws.clear();
    impl.vertices.clear();
    impl.batchStart = 0;
}

// ---------------------------------------------------------------------------------------------
// Sky blend

namespace {
constexpr int kSkyTextureVramAddresses[2] = {8064, 8096};  // TexturePool.h SKY_TEXTURE_VRAM_ADDRS
constexpr int kSkyTextureSizes[2] = {32, 64};
constexpr int kSkyBlendBuckets[2] = {32, 39};  // TFRAG_TRANS0_AND_SKY_BLEND_LEVEL0 / LEVEL1
}  // namespace

struct SkyBlender::Impl {
    id<MTLDevice> device;
    id<MTLRenderPipelineState> pipeline;
    id<MTLSamplerState> sampler;
    id<MTLTexture> textures[2];
};

SkyBlender::SkyBlender(id<MTLDevice> device, id<MTLLibrary> library) : _impl(std::make_unique<Impl>()) {
    Impl &impl = *_impl;
    impl.device = device;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"jak1_sky_blend_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"jak1_sky_blend_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    // glBlendFunc(GL_ONE, GL_ONE): each layer adds.
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    NSError *error = nil;
    impl.pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (error != nil) NSLog(@"Jak1 sky blend pipeline error: %@", error.localizedDescription);

    MTLSamplerDescriptor *sampler = [[MTLSamplerDescriptor alloc] init];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    impl.sampler = [device newSamplerStateWithDescriptor:sampler];

    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor *texture =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:kSkyTextureSizes[i]
                                                              height:kSkyTextureSizes[i]
                                                           mipmapped:NO];
        texture.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        texture.storageMode = MTLStorageModePrivate;
        impl.textures[i] = [device newTextureWithDescriptor:texture];
    }
}

SkyBlender::~SkyBlender() = default;

// SkyBlendHandler::render -> SkyBlendGPU::do_sky_blends.
void SkyBlender::encode(id<MTLCommandBuffer> commandBuffer, const uint8_t *trace, size_t traceLength,
                        const std::vector<uint32_t> &bucketOffsets) {
    Impl &impl = *_impl;
    if (trace == nullptr || impl.pipeline == nil) return;
    for (int level = 0; level < 2; level++) {
        const int bucket = kSkyBlendBuckets[level];
        if (bucket >= static_cast<int>(bucketOffsets.size()) || bucketOffsets[bucket] == UINT32_MAX) continue;
        size_t offset = bucketOffsets[bucket];
        auto entryAt = [&](size_t at, uint32_t *qwc, const uint8_t **payload) -> bool {
            if (at + 16 > traceLength) return false;
            uint64_t tag;
            memcpy(&tag, trace + at, 8);
            *qwc = tag & 0xffff;
            *payload = trace + at + 16;
            return *qwc * 16ull <= traceLength - at - 16;
        };
        uint32_t qwc = 0;
        const uint8_t *payload = nullptr;
        // data0 (empty NEXT), then set-display-gs-state (8 qw) if the blend ran this frame.
        if (!entryAt(offset, &qwc, &payload)) continue;
        offset += 16 + qwc * 16;
        if (!entryAt(offset, &qwc, &payload) || qwc != 8) continue;
        offset += 16 + qwc * 16;

        while (entryAt(offset, &qwc, &payload) && qwc == 6) {
            const uint8_t *setup = payload;
            offset += 16 + qwc * 16;
            if (!entryAt(offset, &qwc, &payload) || qwc != 6) break;
            const uint8_t *drawData = payload;
            offset += 16 + qwc * 16;

            // adgif tex0 (first A+D after the GIF tag) names the source texture.
            uint64_t tex0 = 0;
            memcpy(&tex0, setup + 16, 8);
            const uint32_t sourceTbp = static_cast<uint32_t>(tex0 & 0x3fff);
            GifTag drawTag(drawData);
            const bool firstDraw = !GsPrim(drawTag.prim()).abe();
            uint32_t coord = 0, intensity = 0;
            memcpy(&coord, drawData + 5 * 16, 4);
            memcpy(&intensity, drawData + 16, 4);
            const int target = coord == 0x200 ? 0 : coord == 0x400 ? 1 : -1;
            if (target < 0) continue;
            // Sources are the level's alpha tpage, uploaded just before this bucket; later
            // uploads (other level, HUD, menus) reuse those blocks, so use the layout from here.
            id<MTLTexture> source = PoolTextureForTbpInSnapshot(level, sourceTbp);
            if (source == nil) continue;

            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = impl.textures[target];
            pass.colorAttachments[0].loadAction = firstDraw ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:impl.pipeline];
            const float intensityFloat = std::min<uint32_t>(intensity, 255) / 128.f;
            [encoder setVertexBytes:&intensityFloat length:sizeof(intensityFloat) atIndex:0];
            [encoder setFragmentTexture:source atIndex:0];
            [encoder setFragmentSamplerState:impl.sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [encoder endEncoding];
            // texture_pool->move_existing_to_vram(tex, SKY_TEXTURE_VRAM_ADDRS[i])
            PoolSetVramTexture(kSkyTextureVramAddresses[target], impl.textures[target]);
        }
    }
}

}  // namespace jak1
