#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float3 position  [[attribute(0)]];
    float4 color     [[attribute(1)]];
    float2 texCoord  [[attribute(2)]];
    float3 normal    [[attribute(3)]];
};

struct VertexOutput {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
    float3 normal;
};

struct Uniforms {
    float4x4 projectionMatrix;
    float4x4 modelViewMatrix;
    float4 colorMultiplier;
    uint flags; // bit 0: enable texturing, bit 1: enable lighting
};

vertex VertexOutput jak1_vertex_main(
    VertexInput in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOutput out;
    float4 pos = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * pos;
    out.color = in.color * uniforms.colorMultiplier;
    out.texCoord = in.texCoord;
    out.normal = (uniforms.modelViewMatrix * float4(in.normal, 0.0)).xyz;
    return out;
}

fragment float4 jak1_fragment_main(
    VertexOutput in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    texture2d<float> colorTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float4 outColor = in.color;
    if ((uniforms.flags & 1u) != 0u) {
        float4 texColor = colorTexture.sample(textureSampler, in.texCoord);
        outColor *= texColor;
    }
    return outColor;
}

// Jak 1 generic renderer. Port of OpenGOAL's generic.vert: reproduces the projection the
// generic VU1 microprogram performs, then maps GS coordinates to Metal clip space.
struct Generic2Vertex {
    packed_float3 xyz;
    uchar4 rgba;
    float2 st;
    uchar4 byteInfo; // tex unit, flags, adc, pad
    uint pad;
};

struct Generic2Uniforms {
    float4 scale;        // xyz: projection scale
    float4 hvdfOffset;
    float4 fogConstants; // x: pfog0, y: fog min, z: fog max
    float mat23;
    float mat32;
    float mat33;
    float colorMultiplier;
    float alphaReject;
    float pad[3];
    float4 fogColor;     // rgb / 255, a = fog intensity / 255
};

struct Generic2Output {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
    float fog;
    uint flags [[flat]]; // bit 0: tcc, bit 1: decal, bit 2: fog
};

constant float kJak1ScissorAdjust = 512.0 / 448.0;

vertex Generic2Output jak1_generic_vertex(
    uint vertexID [[vertex_id]],
    const device Generic2Vertex *vertices [[buffer(0)]],
    constant Generic2Uniforms &uniforms [[buffer(1)]]
) {
    Generic2Vertex vtx = vertices[vertexID];
    float3 position = float3(vtx.xyz);

    float4 transformed;
    transformed.xyz = position * uniforms.scale.xyz;
    transformed.z += uniforms.mat32;
    transformed.w = uniforms.mat23 * position.z + uniforms.mat33;
    transformed *= -1.0;

    // Perspective divide and HVDF offset, as done by the VU program.
    float q = uniforms.fogConstants.x / transformed.w;
    const float fog = 255.0 - clamp(-transformed.w + uniforms.hvdfOffset.w,
                                    uniforms.fogConstants.y, uniforms.fogConstants.z);
    transformed.xyz *= q;
    transformed.xyz += uniforms.hvdfOffset.xyz;

    // GS window coordinates (centered at 2048) to NDC. GS depth is 24-bit with greater
    // values closer; Metal's NDC depth range is [0, 1].
    transformed.xy -= 2048.0;
    // OpenGL maps GS depth to [-1, 1]. Metal uses [0, 1], so the equivalent
    // conversion is GS depth divided by the full 24-bit range.
    transformed.z /= 16777216.0;
    transformed.x /= 256.0;
    transformed.y /= -128.0;
    transformed.xyz *= transformed.w;
    transformed.y *= kJak1ScissorAdjust;

    Generic2Output out;
    out.position = transformed;
    // As in generic.vert: normalized color with doubled alpha (0x80 is full alpha).
    out.color = float4(vtx.rgba) / 255.0;
    out.color.a *= 2.0;
    out.texCoord = vtx.st / 4096.0;
    out.fog = fog;
    out.flags = vtx.byteInfo.y;
    return out;
}

// Port of generic.frag: GS modulate or decal, with or without texture alpha (TCC).
fragment float4 jak1_generic_fragment(
    Generic2Output in [[stage_in]],
    constant Generic2Uniforms &uniforms [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    float4 t0 = tex.sample(texSampler, in.texCoord);
    const bool tcc = (in.flags & 1u) != 0u;
    const bool decal = (in.flags & 2u) != 0u;
    float4 color;
    color.rgb = decal ? t0.rgb * 0.5 : in.color.rgb * t0.rgb;
    if (tcc) {
        color.a = decal ? t0.a : in.color.a * t0.a;
    } else {
        color.a = in.color.a;
    }
    color *= 2.0;
    if (color.a < uniforms.alphaReject) {
        discard_fragment();
    }
    color = saturate(color);
    // generic.frag: fogged vertices (PRIM.FGE) blend toward the fog color.
    if ((in.flags & 4u) != 0u) {
        color.rgb = mix(color.rgb, uniforms.fogColor.rgb, saturate(uniforms.fogColor.a * in.fog));
    }
    color.rgb *= uniforms.colorMultiplier;
    return color;
}

// Jak 1 sprite renderer. Port of OpenGOAL's sprite3_3d.vert: each sprite is four vertices
// with identical data except the corner index, and the quad is built here.
struct Sprite3Vertex {
    float4 xyzSx;
    float4 quatSy;
    float4 rgba;
    uint flag;
    uint matrix;
    uchar4 info; // [1]: tcc, [2]: corner, [3]: mode (1 = 2D, 2 = HUD, 3 = 3D)
    uint slot;   // premultiplied batches: bits 0-7 texture slot, bit 8 additive
};

struct Sprite3Uniforms {
    float4 hvdfOffset;
    float4x4 camera;
    float4x4 hudMatrix;
    float4 hudHvdfOffset;
    float4 hudHvdfUser[75];
    float4 basisX;
    float4 basisY;
    float4 xyArray[8];
    float4 xyzArray[4];
    float4 stArray[4];
    float pfog0;
    float fogMin;
    float fogMax;
    float minScale;
    float maxScale;
    float degToRad;
    float invArea;
    float colorMultiplier;
};

struct Sprite3Output {
    float4 position [[position]];
    float4 color [[flat]];
    float2 texCoord;
    uint tcc [[flat]];
    uint slot [[flat]];
};

static float4 sprite_matrix_transform(float4x4 mtx, float3 pt) {
    return mtx[3] + mtx[0] * pt.x + mtx[1] * pt.y + mtx[2] * pt.z;
}

static float3x3 sprite_quat_to_rot(float3 quat) {
    float3x3 result;
    float qr = sqrt(abs(1.0 - (quat.x * quat.x + quat.y * quat.y + quat.z * quat.z)));
    result[0][0] = 1.0 - 2.0 * (quat.y * quat.y + quat.z * quat.z);
    result[1][0] = 2.0 * (quat.x * quat.y - quat.z * qr);
    result[2][0] = 2.0 * (quat.x * quat.z + quat.y * qr);
    result[0][1] = 2.0 * (quat.x * quat.y + quat.z * qr);
    result[1][1] = 1.0 - 2.0 * (quat.x * quat.x + quat.z * quat.z);
    result[2][1] = 2.0 * (quat.y * quat.z - quat.x * qr);
    result[0][2] = 2.0 * (quat.x * quat.z - quat.y * qr);
    result[1][2] = 2.0 * (quat.y * quat.z + quat.x * qr);
    result[2][2] = 1.0 - 2.0 * (quat.x * quat.x + quat.y * quat.y);
    return result;
}

vertex Sprite3Output jak1_sprite_vertex(
    uint vertexID [[vertex_id]],
    const device Sprite3Vertex *vertices [[buffer(0)]],
    constant Sprite3Uniforms &u [[buffer(1)]]
) {
    Sprite3Vertex vtx = vertices[vertexID];
    float3 position = vtx.xyzSx.xyz;
    float sx = vtx.xyzSx.w;
    float sy = vtx.quatSy.w;
    float4 color = vtx.rgba;
    uint corner = vtx.info.z;
    uint mode = vtx.info.w;
    float3 quat = vtx.quatSy.xyz;

    // Perspective transform for distance.
    float4 transformedPos = sprite_matrix_transform(mode == 2 ? u.hudMatrix : u.camera, position);
    float q = u.pfog0 / transformedPos.w;

    // Fade out sprites that shrink below one pixel of area.
    float4 scales = vtx.xyzSx;
    scales.z = sy;
    scales.zw *= q;
    scales.x = scales.z * scales.w * u.invArea;
    color.w *= min(scales.x, 1.0);

    float4 transformed;
    if (mode == 3) {
        float3x3 rot = sprite_quat_to_rot(quat);
        float4 off = u.xyzArray[corner];
        float3 pos = position + rot[0] * off.x * sx + rot[1] * off.y + rot[2] * off.z * sy;
        transformed = -sprite_matrix_transform(u.camera, pos);
        float q3 = u.pfog0 / transformed.w;
        transformed.xyz *= q3;
        transformed.xyz += u.hvdfOffset.xyz;
    } else {
        transformedPos.xyz *= q;
        float4 offsetPos;
        if (mode == 1) {
            offsetPos = transformedPos + u.hvdfOffset;
            offsetPos.w = max(offsetPos.w, u.fogMin);
            scales.z = clamp(scales.z, u.minScale, u.maxScale);
            scales.w = clamp(scales.w, u.minScale, u.maxScale);
        } else {
            offsetPos = transformedPos +
                (vtx.matrix == 0 ? u.hudHvdfOffset : u.hudHvdfUser[min(vtx.matrix - 1, 74u)]);
            // No max scale for the HUD.
            scales.z = max(scales.z, u.minScale);
            scales.w = max(scales.w, u.minScale);
        }
        float angle = quat.z * u.degToRad;
        float spSin = sin(angle);
        float spCos = cos(angle);
        float4 xy0 = u.xyArray[min(corner + (vtx.flag & 15u), 7u)];
        float4 rotated = (u.basisX * spCos - u.basisY * spSin) * scales.w;
        float4 rotatedTrans = (u.basisX * spSin + u.basisY * spCos) * scales.z;
        transformed = offsetPos + rotated * xy0.x + rotatedTrans * xy0.y;
    }

    // GS window coordinates to Metal clip space (see jak1_generic_vertex).
    transformed.xy -= 2048.0;
    transformed.z /= 16777216.0;
    transformed.x /= 256.0;
    transformed.y /= -128.0;
    transformed.xyz *= transformed.w;
    transformed.y *= kJak1ScissorAdjust;

    Sprite3Output out;
    out.position = transformed;
    out.color = color * 2.0;
    out.color.w *= 2.0;
    out.texCoord = u.stArray[corner].xy;
    out.tcc = vtx.info.y;
    out.slot = vtx.slot;
    return out;
}

// Port of sprite3_3d.frag: modulate by the adgif texture; without TCC the texture alpha is ignored.
// alphaRange = (alpha_min, alpha_max), set per draw by Sprite3::flush_sprites.
fragment float4 jak1_sprite_fragment(
    Sprite3Output in [[stage_in]],
    constant Sprite3Uniforms &u [[buffer(1)]],
    constant float2 &alphaRange [[buffer(2)]],
    texture2d<float> tex [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    float4 t0 = tex.sample(texSampler, in.texCoord);
    if (in.tcc == 0) {
        t0.a = 1.0;
    }
    float4 color = in.color * t0;
    if (color.a < alphaRange.x || color.a > alphaRange.y) {
        discard_fragment();
    }
    color = saturate(color);
    color.rgb *= u.colorMultiplier;
    return color;
}

// Depth-sorted world sprites: alpha and additive sprites share one draw by outputting
// premultiplied color (blend ONE, ONE_MINUS_SRC_ALPHA). Alpha: Cs*As + Cd*(1-As);
// additive: Cs*As + Cd (output alpha 0). Each sprite picks one of eight bound textures.
fragment float4 jak1_sprite_premultiplied_fragment(
    Sprite3Output in [[stage_in]],
    constant Sprite3Uniforms &u [[buffer(1)]],
    constant float2 &alphaRange [[buffer(2)]],
    array<texture2d<float>, 8> textures [[texture(0)]],
    array<sampler, 8> samplers [[sampler(0)]]
) {
    const uint slot = in.slot & 0xffu;
    float4 t0;
    switch (slot) {
        case 0: t0 = textures[0].sample(samplers[0], in.texCoord); break;
        case 1: t0 = textures[1].sample(samplers[1], in.texCoord); break;
        case 2: t0 = textures[2].sample(samplers[2], in.texCoord); break;
        case 3: t0 = textures[3].sample(samplers[3], in.texCoord); break;
        case 4: t0 = textures[4].sample(samplers[4], in.texCoord); break;
        case 5: t0 = textures[5].sample(samplers[5], in.texCoord); break;
        case 6: t0 = textures[6].sample(samplers[6], in.texCoord); break;
        default: t0 = textures[7].sample(samplers[7], in.texCoord); break;
    }
    if (in.tcc == 0) {
        t0.a = 1.0;
    }
    float4 color = in.color * t0;
    if (color.a < alphaRange.x || color.a > alphaRange.y) {
        discard_fragment();
    }
    color = saturate(color);
    color.rgb *= u.colorMultiplier * color.a;
    if ((in.slot & 0x100u) != 0u) {
        color.a = 0.0;
    }
    return color;
}

struct MercVertex {
    float4 position;
    float4 normal;
    float4 weights;
    float2 texCoord;
    uchar4 rgba;
    // xyz = bone indices, w = pad. (uchar3 is 4-byte sized/aligned in MSL, so uchar3 + uchar
    // would grow the stride to 80 bytes and mismatch the 64-byte C++ MercVertex.)
    uchar4 matrices;
};

struct MercMatrix {
    float4 transform[4];
    float4 normal[3];
    float4 pad;
};

struct MercUniforms {
    float4 hvdfOffset;
    float4 perspective[4];
    float4 fog;
    float4 colorParams;
    float4 fogColor;
};

struct MercOutput {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
    float fog;
};

static float4 merc_transform(const device MercMatrix &bone, float4 position) {
    return bone.transform[0] * position.x + bone.transform[1] * position.y +
        bone.transform[2] * position.z + bone.transform[3] * position.w;
}

struct MercLights {
    float4 dir0Fade;        // light_dir0_fade
    float4 dir1FadeEnable;  // light_dir1_fade_en
    float4 dir2;
    float4 color0, color1, color2;
    float4 ambient;
};

static float3 merc_rotate_normal(const device MercMatrix &bone, float3 normal) {
    return bone.normal[0].xyz * normal.x + bone.normal[1].xyz * normal.y + bone.normal[2].xyz * normal.z;
}

vertex MercOutput jak1_merc_vertex(
    uint vertexID [[vertex_id]],
    const device MercVertex *vertices [[buffer(0)]],
    const device MercMatrix *bones [[buffer(1)]],
    constant MercUniforms &u [[buffer(2)]],
    constant MercLights &lights [[buffer(3)]]) {
    MercVertex vtx = vertices[vertexID];
    float4 inputPosition = float4(vtx.position.xyz, 1.0);
    float4 position = -merc_transform(bones[vtx.matrices.x], inputPosition) * vtx.weights.x;
    float3 rotatedNormal = merc_rotate_normal(bones[vtx.matrices.x], vtx.normal.xyz) * vtx.weights.x;
    // The game may send garbage bones when the weight is 0; don't let NaNs in.
    if (vtx.weights.y > 0.0) {
        position += -merc_transform(bones[vtx.matrices.y], inputPosition) * vtx.weights.y;
        rotatedNormal += merc_rotate_normal(bones[vtx.matrices.y], vtx.normal.xyz) * vtx.weights.y;
    }
    if (vtx.weights.z > 0.0) {
        position += -merc_transform(bones[vtx.matrices.z], inputPosition) * vtx.weights.z;
        rotatedNormal += merc_rotate_normal(bones[vtx.matrices.z], vtx.normal.xyz) * vtx.weights.z;
    }

    // merc2.vert lighting: three directional lights plus ambient. A degenerate normal would make
    // normalize() return NaN and turn the whole vertex black, so fall back to ambient only.
    const float normalLength = length(rotatedNormal);
    rotatedNormal = normalLength > 1e-6 ? rotatedNormal / normalLength : float3(0.0);
    float3 intensity = lights.dir0Fade.xyz * rotatedNormal.x + lights.dir1FadeEnable.xyz * rotatedNormal.y +
        lights.dir2.xyz * rotatedNormal.z;
    intensity = max(intensity, float3(0.0));
    float4 lightColor = lights.ambient + intensity.x * lights.color0 + intensity.y * lights.color1 +
        intensity.z * lights.color2;
    if (any(isnan(lightColor))) {
        lightColor = float4(1.0);
    }
    float4 transformed = u.perspective[0] * position.x + u.perspective[1] * position.y +
        u.perspective[2] * position.z + u.perspective[3] * position.w;
    float q = u.fog.x / transformed.w;
    // merc2.vert fog, from the pre-divide w.
    const float fog = 255.0 - clamp(-transformed.w + u.hvdfOffset.w, u.fog.y, u.fog.z);
    transformed.xyz *= q;
    transformed.xyz += u.hvdfOffset.xyz;
    transformed.xy -= 2048.0;
    transformed.z /= 16777216.0;
    transformed.x /= 256.0;
    transformed.y /= -128.0;
    transformed.xyz *= transformed.w;
    transformed.y *= kJak1ScissorAdjust;

    MercOutput out;
    out.position = transformed;
    out.fog = fog;
    // vtx_color = rgba * light_color; rgba / 128 also folds in merc2.frag's * 2.
    out.color = float4(vtx.rgba) / 128.0 * lightColor;
    out.color.rgb *= u.colorParams.x;
    out.texCoord = vtx.texCoord;
    return out;
}

struct MercFragmentFlags {
    uint decal;
    uint ignoreAlpha;
};

fragment float4 jak1_merc_fragment(
    MercOutput in [[stage_in]],
    constant MercFragmentFlags &flags [[buffer(0)]],
    constant MercUniforms &u [[buffer(2)]],
    constant MercLights &lights [[buffer(3)]],
    texture2d<float> colorTexture [[texture(0)]],
    sampler colorSampler [[sampler(0)]]) {
    // merc2.frag: all Merc is tcc=rgba modulate (vtx_color * T0 * 2), or the bare texture for
    // decal draws. in.color is rgba / 128 * light, which already carries the * 2.
    float4 texel = colorTexture.sample(colorSampler, in.texCoord);
    float4 color = flags.decal != 0 ? texel : in.color * texel;
    color.a *= 2.0;
    // Fade (light_dir1_fade_en.w): > 0 replaces alpha, < 0 scales it.
    if (lights.dir1FadeEnable.w > 0.0) {
        color.a = lights.dir0Fade.w;
    } else if (lights.dir1FadeEnable.w < 0.0) {
        color.a *= lights.dir0Fade.w;
    }
    if (flags.ignoreAlpha == 0 && color.a < 0.128) {
        discard_fragment();
    }
    color = saturate(color);
    // Boat summon glow (Jak1RendererSetBoatFade): dir2.w is not used by the lighting.
    color.rgb = mix(color.rgb, float3(0.55, 0.95, 1.0), saturate(lights.dir2.w));
    color.rgb = mix(color.rgb, u.fogColor.rgb, clamp(u.fogColor.a * in.fog, 0.0, 1.0));
    return color;
}

struct EyeOutput {
    float4 position [[position]];
    float2 st;
};

// eye.vert: GS eye-texture coordinates (centered at 768, +-256) to clip space. y is negated
// so the eye lands in the same texel rows as OpenGOAL's bottom-up GL framebuffer.
vertex EyeOutput jak1_eye_vertex(uint vertexID [[vertex_id]],
                                 const device float4 *xyst [[buffer(0)]]) {
    const float4 v = xyst[vertexID];
    EyeOutput out;
    out.position = float4((v.x - 768.0) / 256.0, -(v.y - 768.0) / 256.0, 0.0, 1.0);
    out.st = v.zw;
    return out;
}

// ---------------------------------------------------------------------------------------------
// TFrag (tfrag3.vert / tfrag3.frag): level background geometry, lit by the game's time of day.

struct TfragVertex {  // tfrag3::PreloadedVertex
    float x, y, z;
    uchar4 envmapTint;
    float s, t;
    uint normal;
    ushort colorIndex;
    ushort pad;
};

struct TfragUniforms {
    float4 pcCamera[4];
    float4 hvdfOffset;
    float4 camTrans;
    float4 fogColor;
    float fogConstant;
    float fogMin;
    float fogMax;
    uint decal;
    float alphaMin;
    float alphaMax;
    float2 pad;
};

struct TfragOutput {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
    float fogginess;
};

vertex TfragOutput jak1_tfrag3_vertex(uint vertexID [[vertex_id]],
                                      const device TfragVertex *vertices [[buffer(0)]],
                                      constant TfragUniforms &u [[buffer(1)]],
                                      const device uchar4 *timeOfDayColors [[buffer(2)]]) {
    const TfragVertex v = vertices[vertexID];
    const float3 vert = float3(v.x, v.y, v.z) - u.camTrans.xyz;
    float4 transformed = -u.pcCamera[3];
    transformed.w = 0;
    transformed -= u.pcCamera[0] * vert.x;
    transformed -= u.pcCamera[1] * vert.y;
    transformed -= u.pcCamera[2] * vert.z;

    TfragOutput out;
    out.fogginess = 255.0 - clamp(-transformed.w + u.hvdfOffset.w, u.fogMin, u.fogMax);
    transformed.y *= kJak1ScissorAdjust;
    // pc_camera yields OpenGL clip depth ([-w, w]); Metal clips depth to [0, w].
    transformed.z = (transformed.z + transformed.w) * 0.5;
    out.position = transformed;

    // Time-of-day color, then the PS2 2x color convention.
    out.color = float4(timeOfDayColors[v.colorIndex]) / 255.0 * 2.0;
    out.color.a *= 2.0;
    if (u.decal == 1) {
        // tfrag/tie always use TCC=RGB, so even with decal, alpha comes from the vertex.
        out.color.rgb = float3(1.0);
    }
    out.texCoord = float2(v.s, v.t);
    return out;
}

// tie_wind.vert: wind-swayed TIE instances. u.pcCamera carries the per-instance `camera`
// (game camera * swayed instance matrix), applied with the game's perspective divide.
vertex TfragOutput jak1_tie_wind_vertex(uint vertexID [[vertex_id]],
                                        const device TfragVertex *vertices [[buffer(0)]],
                                        constant TfragUniforms &u [[buffer(1)]],
                                        const device uchar4 *timeOfDayColors [[buffer(2)]]) {
    const TfragVertex v = vertices[vertexID];
    float4 transformed = -u.pcCamera[3];
    transformed -= u.pcCamera[0] * v.x;
    transformed -= u.pcCamera[1] * v.y;
    transformed -= u.pcCamera[2] * v.z;
    const float q = u.fogConstant / transformed.w;

    TfragOutput out;
    out.fogginess = 255.0 - clamp(-transformed.w + u.hvdfOffset.w, u.fogMin, u.fogMax);
    transformed.xyz *= q;
    transformed.xyz += u.hvdfOffset.xyz;
    transformed.xy -= 2048.0;
    transformed.z /= 16777216.0;  // GS depth to Metal's [0, 1] (GL: / 8388608 - 1)
    transformed.x /= 256.0;
    transformed.y /= -128.0;
    transformed.xyz *= transformed.w;
    transformed.y *= kJak1ScissorAdjust;
    out.position = transformed;

    out.color = float4(timeOfDayColors[v.colorIndex]) / 255.0 * 2.0;
    out.color.a *= 2.0;
    if (u.decal == 1) {
        out.color.rgb = float3(1.0);
    }
    out.texCoord = float2(v.s, v.t);
    return out;
}

// shrub.vert: grass/bush geometry; color = base vertex rgb * time-of-day * 4.
struct ShrubVertex {  // tfrag3::ShrubGpuVertex
    float x, y, z;
    float s, t;
    uint pad0;
    ushort colorIndex;
    ushort pad1;
    uchar rgbaBase[3];
    uchar pad2;
};

vertex TfragOutput jak1_shrub_vertex(uint vertexID [[vertex_id]],
                                     const device ShrubVertex *vertices [[buffer(0)]],
                                     constant TfragUniforms &u [[buffer(1)]],
                                     const device uchar4 *timeOfDayColors [[buffer(2)]]) {
    const ShrubVertex v = vertices[vertexID];
    const float3 vert = float3(v.x, v.y, v.z) - u.camTrans.xyz;
    float4 transformed = -u.pcCamera[3];
    transformed -= u.pcCamera[0] * vert.x;
    transformed -= u.pcCamera[1] * vert.y;
    transformed -= u.pcCamera[2] * vert.z;

    TfragOutput out;
    out.fogginess = 255.0 - clamp(-transformed.w + u.hvdfOffset.w, u.fogMin, u.fogMax);
    transformed.y *= kJak1ScissorAdjust;
    transformed.z = (transformed.z + transformed.w) * 0.5;  // GL clip depth -> Metal
    out.position = transformed;

    const float4 base = float4(float(v.rgbaBase[0]), float(v.rgbaBase[1]), float(v.rgbaBase[2]), 255.0) / 255.0;
    out.color = base * (float4(timeOfDayColors[v.colorIndex]) / 255.0) * 4.0;
    if (u.decal == 1) {
        out.color.rgb = float3(1.0);
    }
    out.texCoord = float2(v.s, v.t) / 4096.0;
    return out;
}

fragment float4 jak1_tfrag3_fragment(TfragOutput in [[stage_in]],
                                     constant TfragUniforms &u [[buffer(1)]],
                                     texture2d<float> colorTexture [[texture(0)]],
                                     sampler colorSampler [[sampler(0)]]) {
    float4 color = in.color * colorTexture.sample(colorSampler, in.texCoord);
    if (color.a < u.alphaMin || color.a > u.alphaMax) {
        discard_fragment();
    }
    color.rgb = mix(color.rgb, u.fogColor.rgb, clamp(in.fogginess * u.fogColor.a, 0.0, 1.0));
    return color;
}

// ---------------------------------------------------------------------------------------------
// Direct renderer (direct_basic.vert/frag, direct_basic_textured.vert/frag).

struct DirectVertex {
    float4 xyzf;
    packed_float3 stq;
    uchar4 rgba;
    uchar texUnit;
    uchar tcc;
    uchar decal;
    uchar fogEnable;
    uchar useUv;
    uchar pad[11];
    float4 scissor;
};

struct DirectUniforms {
    float4 fogColor;
    float4 gameSizes;  // game width, game height, viewport width, viewport height
    float2 viewportOrigin;
    float alphaMin;
    float alphaMax;
    float colorMult;
    float alphaMult;
    float ta0;
    uint greater;
    uint scissorEnable;
    uint textured;
    float2 pad;
};

struct DirectOutput {
    float4 position [[position]];
    float4 color;
    float3 stq;
    float fog;
    float4 scissor [[flat]];
    uint tcc [[flat]];
    uint decal [[flat]];
    uint fogEnable [[flat]];
    uint useUv [[flat]];
};

vertex DirectOutput jak1_direct_vertex(uint vertexID [[vertex_id]],
                                       const device DirectVertex *vertices [[buffer(0)]]) {
    const DirectVertex v = vertices[vertexID];
    DirectOutput out;
    // GS coordinates (normalized over 4096 px, centered at 2048) to clip space. GL's
    // `z * 2 - 1` lands at window depth z, which is Metal's clip depth.
    out.position = float4((v.xyzf.x - 0.5) * 16.0, -(v.xyzf.y - 0.5) * 32.0, v.xyzf.z, 1.0);
    out.position.y *= kJak1ScissorAdjust;
    out.color = float4(float3(v.rgba.xyz) / 255.0, float(v.rgba.w) / 255.0 * 2.0);
    out.stq = float3(v.stq);
    out.fog = 255.0 - v.xyzf.w;
    out.scissor = v.scissor;
    out.tcc = v.tcc;
    out.decal = v.decal;
    out.fogEnable = v.fogEnable;
    out.useUv = v.useUv;
    return out;
}

// GS scissor in game pixels, tested in OpenGL's bottom-up window coordinates.
static bool jak1_direct_scissored(float4 fragPosition, float4 scissor, constant DirectUniforms &u) {
    if (u.scissorEnable == 0) return false;
    const float x = fragPosition.x - u.viewportOrigin.x;
    const float y = u.gameSizes.w - (fragPosition.y - u.viewportOrigin.y);
    const float w = u.gameSizes.z / u.gameSizes.x;
    const float h = u.gameSizes.w / u.gameSizes.y;
    const float scax0 = scissor.x * w + 0.5;
    const float scax1 = scissor.y * w + 0.5;
    const float scay0 = (u.gameSizes.y - scissor.w) * h + 0.5;
    const float scay1 = (u.gameSizes.y - scissor.z) * h + 0.5;
    return x < scax0 || x > scax1 || y < scay0 || y > scay1;
}

fragment float4 jak1_direct_fragment(DirectOutput in [[stage_in]],
                                     constant DirectUniforms &u [[buffer(0)]]) {
    if (jak1_direct_scissored(in.position, in.scissor, u)) discard_fragment();
    return in.color;
}

fragment float4 jak1_direct_textured_fragment(DirectOutput in [[stage_in]],
                                              constant DirectUniforms &u [[buffer(0)]],
                                              texture2d<float> colorTexture [[texture(0)]],
                                              sampler colorSampler [[sampler(0)]]) {
    if (jak1_direct_scissored(in.position, in.scissor, u)) discard_fragment();
    float4 T0;
    if (in.useUv == 1) {
        // UV mode: texel coordinates in 1/16 texels, no perspective correction.
        const float2 size = float2(colorTexture.get_width(), colorTexture.get_height());
        T0 = colorTexture.sample(colorSampler, (in.stq.xy / 16.0) / size);
    } else {
        T0 = colorTexture.sample(colorSampler, in.stq.xy / in.stq.z);
    }
    if (T0.w == 0) {
        T0.w = u.ta0;
    }
    float4 color;
    if (in.tcc == 0) {
        color.xyz = in.decal == 0 ? in.color.xyz * T0.xyz : T0.xyz * 0.5;
        color.w = in.color.w;
    } else {
        if (in.decal == 0) {
            color = in.color * T0;
        } else {
            color.xyz = T0.xyz * 0.5;
            color.w = T0.w;
        }
    }
    color *= 2.0;
    color.xyz *= u.colorMult;
    color.w *= u.alphaMult;
    if (u.greater != 0) {
        if (color.a <= u.alphaMin || color.a > u.alphaMax) discard_fragment();
    } else {
        if (color.a < u.alphaMin || color.a >= u.alphaMax) discard_fragment();
    }
    if (in.fogEnable == 1) {
        color.xyz = mix(color.xyz, u.fogColor.rgb, clamp(u.fogColor.a * in.fog, 0.0, 1.0));
    }
    return color;
}

// sky_blend.vert/frag: one additive full-target quad per sky/cloud layer. y is flipped so texel
// rows land as in OpenGOAL's bottom-up GL framebuffer.
struct SkyBlendOutput {
    float4 position [[position]];
    float3 texCoord;
};

vertex SkyBlendOutput jak1_sky_blend_vertex(uint vertexID [[vertex_id]],
                                            constant float &intensity [[buffer(0)]]) {
    const float2 corners[6] = {float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(0, 1), float2(1, 1)};
    const float2 p = corners[vertexID];
    SkyBlendOutput out;
    out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    out.texCoord = float3(p, intensity);
    return out;
}

fragment float4 jak1_sky_blend_fragment(SkyBlendOutput in [[stage_in]],
                                        texture2d<float> colorTexture [[texture(0)]],
                                        sampler colorSampler [[sampler(0)]]) {
    return colorTexture.sample(colorSampler, in.texCoord.xy) * in.texCoord.z;
}

// ---------------------------------------------------------------------------------------------
// Ocean (ocean_texture.*, ocean_texture_mipmap.*, ocean_common.*).

struct OceanTextureVertex {  // OceanTexture::Vertex
    float s, t;
    uchar4 rgba;
    uint pad;
};

struct OceanTextureOutput {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
};

vertex OceanTextureOutput jak1_ocean_texture_vertex(uint vertexID [[vertex_id]],
                                                    const device float2 *positions [[buffer(0)]],
                                                    const device OceanTextureVertex *dynamic [[buffer(1)]]) {
    // inputs are 0 - 2048; y flipped so texel rows match OpenGOAL's GL render target.
    const float2 p = positions[vertexID];
    OceanTextureOutput out;
    out.position = float4((p.x - 1024.0) / 1024.0, -(p.y - 1024.0) / 1024.0, 0.5, 1.0);
    out.color = float4(float3(dynamic[vertexID].rgba.rgb) / 255.0 * 2.0, 1.0);
    out.texCoord = float2(dynamic[vertexID].s, dynamic[vertexID].t);
    return out;
}

fragment float4 jak1_ocean_texture_fragment(OceanTextureOutput in [[stage_in]],
                                            texture2d<float> colorTexture [[texture(0)]],
                                            sampler colorSampler [[sampler(0)]]) {
    return in.color * colorTexture.sample(colorSampler, in.texCoord);
}

struct OceanMipmapOutput {
    float4 position [[position]];
    float2 texCoord;
};

vertex OceanMipmapOutput jak1_ocean_mipmap_vertex(uint vertexID [[vertex_id]]) {
    // Full-target quad (the GL version scales a quad into the mip's corner of a 128x128 viewport).
    const float2 corners[4] = {float2(-1, -1), float2(-1, 1), float2(1, -1), float2(1, 1)};
    const float2 st[4] = {float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1)};
    OceanMipmapOutput out;
    out.position = float4(corners[vertexID].x, -corners[vertexID].y, 0.5, 1.0);
    out.texCoord = st[vertexID];
    return out;
}

fragment float4 jak1_ocean_mipmap_fragment(OceanMipmapOutput in [[stage_in]],
                                           constant float &alphaIntensity [[buffer(0)]],
                                           texture2d<float> colorTexture [[texture(0)]],
                                           sampler colorSampler [[sampler(0)]]) {
    float4 tex = colorTexture.sample(colorSampler, in.texCoord);
    tex.w *= alphaIntensity;
    return tex;
}

// All 8 ocean mips in one dispatch, matching jak1_ocean_mipmap_fragment per level: each texel of
// level L bilinearly samples the 128x128 render at its center, alpha scaled by 1 - 0.51 L.
kernel void jak1_ocean_mipmap_kernel(texture2d<float, access::sample> source [[texture(0)]],
                                     array<texture2d<float, access::write>, 8> levels [[texture(1)]],
                                     sampler colorSampler [[sampler(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    for (uint mip = 0; mip < 8; mip++) {
        const uint size = levels[mip].get_width();
        if (gid.x >= size || gid.y >= size) return;  // smaller levels need fewer threads
        float4 tex = source.sample(colorSampler, (float2(gid) + 0.5) / float(size), level(0));
        tex.w *= max(0.0, 1.0 - 0.51 * float(mip));
        levels[mip].write(tex, gid);
    }
}

struct OceanVertex {  // OceanDrawList::Vertex
    packed_float3 xyz;
    uchar4 rgba;
    packed_float3 stq;
    uchar fog;
    uchar pad[3];
};

struct OceanUniforms {
    float4 fogColor;
    int bucket;
    float clearWater;  // 1: near ocean at its clearest everywhere (Fish in Ocean, SetOceanClearWater)
    float pad[2];  // not float3: that is 16-byte sized/aligned and would make this 48 bytes
};

struct OceanOutput {
    float4 position [[position]];
    float4 color;
    float3 stq;
    float fog;
};

vertex OceanOutput jak1_ocean_vertex(uint vertexID [[vertex_id]],
                                     const device OceanVertex *vertices [[buffer(0)]],
                                     constant OceanUniforms &u [[buffer(1)]]) {
    const OceanVertex v = vertices[vertexID];
    OceanOutput out;
    out.position = float4((v.xyz[0] - 0.5) * 16.0, -(v.xyz[1] - 0.5) * 32.0, v.xyz[2], 1.0);
    out.position.y *= kJak1ScissorAdjust;
    out.color = float4(float3(v.rgba.rgb) / 255.0, float(v.rgba.a) / 255.0 * 2.0);
    out.stq = float3(v.stq);
    out.fog = 255.0 - float(v.fog);
    if (u.bucket == 0) {
        out.color.rgb *= 2.0;
        if (u.clearWater > 0.5) {
            // The ocean-near VU program fades the see-through pass with camera distance:
            // a = clamp(dist * 1.0172526e-5, 0.5, 1.0), alpha = 128 * a, rgb *= 3 - 2a (clear within 12 m,
            // opaque from 24 m). Undo that so every vertex looks like it does next to the camera (a = 0.5).
            const float a = clamp(float(v.rgba.a) / 128.0, 0.5, 1.0);
            out.color.rgb *= 2.0 / (3.0 - 2.0 * a);
            out.color.a = 64.0 / 255.0 * 2.0;
        }
    } else if (u.bucket == 1 || u.bucket == 3) {
        out.color *= 2.0;
    } else if (u.bucket == 6) {
        // Clear water backdrop: the near ocean as it looks far from the camera (a = 1: rgb * 1, opaque), the
        // same colour as the stock mid ocean it meets.
        const float a = clamp(float(v.rgba.a) / 128.0, 0.5, 1.0);
        out.color.rgb *= 2.0 / (3.0 - 2.0 * a);
        out.color.a = 1.0;
    } else if (u.bucket == 5) {
        // Clear water mid ocean: the same colour and alpha as the clear near ocean (bucket 0 at a = 0.5:
        // rgb * 2 * (3 - 2a) / (3 - 2a) * 2 on the mid's undistanced colours), drawn alpha blended.
        out.color.rgb *= 4.0;
        out.color.a = 64.0 / 255.0 * 2.0;
    } else if (u.bucket == 4) {
        out.color.a = 0.0;
    }
    return out;
}

fragment float4 jak1_ocean_fragment(OceanOutput in [[stage_in]],
                                    constant OceanUniforms &u [[buffer(1)]],
                                    texture2d<float> colorTexture [[texture(0)]],
                                    sampler colorSampler [[sampler(0)]]) {
    const float4 T0 = colorTexture.sample(colorSampler, in.stq.xy / in.stq.z);
    float4 color;
    if (u.bucket == 0 || u.bucket == 5 || u.bucket == 6) {
        color.rgb = in.color.rgb * T0.rgb;
        color.a = in.color.a;
        color.rgb = mix(color.rgb, u.fogColor.rgb, clamp(u.fogColor.a * in.fog, 0.0, 1.0));
    } else if (u.bucket == 3) {
        color = in.color * T0;
        color.rgb = mix(color.rgb, u.fogColor.rgb, clamp(u.fogColor.a * in.fog, 0.0, 1.0));
    } else {
        color = in.color * T0;
    }
    return color;
}

// eye.frag
fragment float4 jak1_eye_fragment(EyeOutput in [[stage_in]],
                                  texture2d<float> colorTexture [[texture(0)]],
                                  sampler colorSampler [[sampler(0)]]) {
    float4 color = colorTexture.sample(colorSampler, in.st);
    color.a *= 2.0;
    return color;
}

// PCRTC blackout/fade (port of OpenGOAL's do_pcrtc_effects): a full-screen triangle whose
// blend state (src * 0 + dst * blendAlpha) scales the finished frame by pmode.alp.
vertex float4 jak1_pcrtc_vertex(uint vertexID [[vertex_id]]) {
    const float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    return float4(uv * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 jak1_pcrtc_fragment() {
    return float4(0.0);
}

// Shadow volumes (port of shadow.vert/shadow.frag): GS-space positions normalized to 0..1, as in
// ShadowRenderer::xgkick. y is scaled by 32 instead of 16 to undo the half-height interlace setup.
struct ShadowVertex {  // ShadowRenderer::Vertex
    packed_float3 xyz;
    uint flag;
};

vertex float4 jak1_shadow_vertex(uint vertexID [[vertex_id]],
                                 const device ShadowVertex *vertices [[buffer(0)]]) {
    const ShadowVertex v = vertices[vertexID];
    float4 position = float4((v.xyz[0] - 0.5) * 16.0, -(v.xyz[1] - 0.5) * 32.0, v.xyz[2], 1.0);
    position.y *= kJak1ScissorAdjust;
    return position;
}

fragment float4 jak1_shadow_fragment(constant float4 &color [[buffer(0)]]) {
    return color * 2.0;
}
