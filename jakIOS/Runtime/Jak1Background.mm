#import "Jak1Background.h"
#import "Jak1Direct.h"

#define FMT_HEADER_ONLY 1
#include "common/custom_data/Tfrag3Data.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <compression.h>
#include <simd/simd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>

namespace jak1 {
namespace {

// ---------------------------------------------------------------------------------------------
// Game -> renderer data (game/graphics/opengl_renderer/background/background_common.h).

struct GoalBackgroundCameraData {
    math::Vector4f planes[4];
    math::Vector<s32, 4> itimes[4];
    math::Vector4f camera[4];
    math::Vector4f hvdf_off;
    math::Vector4f fog;
    math::Vector4f trans;
    math::Vector4f rot[4];
    math::Vector4f perspective[4];
};

struct TfragPcPortData {
    GoalBackgroundCameraData camera;
    char level_name[32];
};
static_assert(sizeof(TfragPcPortData) == 16 * 25, "TfragPcPortData layout");
static_assert(sizeof(tfrag3::PreloadedVertex) == 32, "PreloadedVertex layout (mirrored in Metal)");

// FR3 geometry LOD drawn for every level, like Gfx::g_global_settings.lod_tfrag / lod_tie
// (0 = full detail). The level itself comes from the bucket's PC-port camera block.
constexpr int kTfragLod = 0;
constexpr int kTieLod = 0;
static_assert(kTfragLod < tfrag3::TFRAG_GEOS && kTieLod < tfrag3::TIE_GEOS, "LOD out of range");

// Jak 1 buckets (game/graphics/opengl_renderer/buckets.h) with the tfrag trees each one draws.
struct TfragBucket {
    int bucket;
    std::vector<tfrag3::TFragmentTreeKind> kinds;
};

const std::vector<TfragBucket> &TfragBuckets() {
    using K = tfrag3::TFragmentTreeKind;
    static const std::vector<TfragBucket> buckets = {
        {6, {K::NORMAL, K::LOWRES}},        {13, {K::NORMAL, K::LOWRES}},
        {32, {K::TRANS, K::LOWRES_TRANS}},  {39, {K::TRANS, K::LOWRES_TRANS}},
        {34, {K::DIRT}},                    {41, {K::DIRT}},
        {36, {K::ICE}},                     {43, {K::ICE}},
    };
    return buckets;
}

// Shader-side uniforms (mirrors TfragUniforms in Jak1Shaders.metal).
struct TfragUniforms {
    simd_float4 pcCamera[4];
    simd_float4 hvdfOffset;
    simd_float4 camTrans;
    simd_float4 fogColor;
    float fogConstant;
    float fogMin;
    float fogMax;
    uint32_t decal;
    float alphaMin;
    float alphaMax;
    float pad[2];
};

// ---------------------------------------------------------------------------------------------
// Ports of background_common.cpp helpers.

// make_new_cam_mat: game camera + perspective folded into one matrix for the GPU.
std::array<math::Vector4f, 4> MakeNewCamMat(const math::Vector4f camTw[4], const math::Vector4f persp[4],
                                            float fogConstant, float hvdfZ) {
    const float pcPxx = fogConstant * persp[0][0] / 256.f;
    const float pcPyy = -fogConstant * persp[1][1] / 128.f;
    const float gamePzw = persp[2][3];
    const float gameDepthOffset = persp[3][2];
    math::Vector3f perspScale(pcPxx, pcPyy, fogConstant * persp[2][2] / 8388608);
    perspScale.z() += (hvdfZ / 8388608.f - 1.f) * gamePzw;

    std::array<math::Vector4f, 4> result;
    for (auto &x : result) x.set_zero();
    for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
            result[row][col] = camTw[row][col] * perspScale[col];
        }
        result[row][3] = camTw[row][2] * gamePzw;
    }
    result[3][2] = fogConstant * gameDepthOffset / 8388608;
    return result;
}

// interp_time_of_day_slow: blend the 8 time-of-day palettes with the game's weights.
void InterpTimeOfDay(const math::Vector<s32, 4> itimes[4], const tfrag3::PackedTimeOfDay &in,
                     math::Vector<u8, 4> *out) {
    math::Vector<u16, 4> weights[8];
    for (int component = 0; component < 8; component++) {
        const int quad = component / 2;
        const int wordOffset = component % 2 * 2;
        for (int channel = 0; channel < 4; channel++) {
            const u32 word = itimes[quad][wordOffset + channel / 2];
            weights[component][channel] = ((channel % 2) ? (word >> 16) : word) & 0xff;
        }
    }
    for (u32 colorQuad = 0; colorQuad < (in.color_count + 3) / 4; colorQuad++) {
        math::Vector<u16, 4> temp[4];
        for (auto &x : temp) x.set_zero();
        const u8 *input = in.data.data() + colorQuad * 128;
        for (u32 component = 0; component < 8; component++) {
            for (u32 color = 0; color < 4; color++) {
                for (u32 channel = 0; channel < 4; channel++) {
                    temp[color][channel] += weights[component][channel] * (*input++);
                }
            }
        }
        for (u32 color = 0; color < 4; color++) {
            auto &o = out[colorQuad * 4 + color];
            for (u32 channel = 0; channel < 3; channel++) {
                o[channel] = std::min(255, temp[color][channel] >> 6);
            }
            o[3] = std::min(128, temp[color][3] >> 6);
        }
    }
}

bool SphereInView(const math::Vector4f &sphere, const math::Vector4f *planes) {
    const math::Vector4f acc =
        planes[0] * sphere.x() + planes[1] * sphere.y() + planes[2] * sphere.z() - planes[3];
    return acc.x() > -sphere.w() && acc.y() > -sphere.w() && acc.z() > -sphere.w() &&
           acc.w() > -sphere.w();
}

// make_index_list_from_vis_string: indices of the visible groups of each draw.
u32 MakeIndexListFromVis(std::pair<int, int> *groupOut, u32 *indexOut,
                         const std::vector<tfrag3::StripDraw> &draws, const std::vector<u8> &vis,
                         const u32 *indexIn) {
    int out = 0;
    for (size_t i = 0; i < draws.size(); i++) {
        const auto &draw = draws[i];
        int vertex = 0;
        std::pair<int, int> ds;
        ds.first = out;
        bool building = false;
        int runStartOut = 0, runStartIn = 0;
        for (const auto &group : draw.vis_groups) {
            const bool visible = group.vis_idx_in_pc_bvh == UINT16_MAX || vis[group.vis_idx_in_pc_bvh];
            if (building) {
                if (visible) {
                    out += group.num_inds;
                } else {
                    building = false;
                    memcpy(&indexOut[runStartOut],
                           indexIn + draw.unpacked.idx_of_first_idx_in_full_buffer + runStartIn,
                           (out - runStartOut) * sizeof(u32));
                }
            } else if (visible) {
                building = true;
                runStartOut = out;
                runStartIn = vertex;
                out += group.num_inds;
            }
            vertex += group.num_inds;
        }
        if (building) {
            memcpy(&indexOut[runStartOut], indexIn + draw.unpacked.idx_of_first_idx_in_full_buffer + runStartIn,
                   (out - runStartOut) * sizeof(u32));
        }
        ds.second = out - ds.first;
        groupOut[i] = ds;
    }
    return out;
}

// DrawMode bits (common/dma/gs.h).
bool ModeDepthWrite(uint32_t m) { return m & 1; }
bool ModeDepthTest(uint32_t m) { return m & (1u << 19); }
bool ModeBlend(uint32_t m) { return m & (1u << 20); }
uint32_t ModeAlphaBlend(uint32_t m) { return (m >> 24) & 0b111; }
bool ModeDecal(uint32_t m) { return !(m & (1u << 28)); }
bool ModeAlphaTestEnable(uint32_t m) { return m & (1u << 18); }
uint32_t ModeAlphaTest(uint32_t m) { return (m >> 16) & 0b11; }   // 0 never, 1 always, 2 gequal
uint32_t ModeAlphaFail(uint32_t m) { return (m >> 21) & 0b11; }   // 0 keep, 1 fb only, ...
uint32_t ModeAref(uint32_t m) { return (m >> 8) & 0xff; }
bool ModeClampS(uint32_t m) { return m & (1u << 5); }
bool ModeClampT(uint32_t m) { return m & (1u << 23); }
bool ModeFilter(uint32_t m) { return m & (1u << 6); }

// ---------------------------------------------------------------------------------------------
// Level loading.

struct LoadedTfragTree {
    const tfrag3::TfragTree *tree = nullptr;
    id<MTLBuffer> vertexBuffer = nil;
    id<MTLBuffer> indexBuffer = nil;
};

struct LoadedTieTree {
    const tfrag3::TieTree *tree = nullptr;
    id<MTLBuffer> vertexBuffer = nil;
    id<MTLBuffer> indexBuffer = nil;
    // All instanced_wind_draws' vertex_index_streams back to back, with each draw's start.
    id<MTLBuffer> windIndexBuffer = nil;
    std::vector<u32> windIndexOffsets;
};

struct LoadedShrubTree {
    const tfrag3::ShrubTree *tree = nullptr;
    id<MTLBuffer> vertexBuffer = nil;  // tfrag3::ShrubGpuVertex
    id<MTLBuffer> indexBuffer = nil;
};

struct LoadedLevel {
    std::unique_ptr<tfrag3::Level> level;
    std::vector<id<MTLTexture>> textures;
    std::vector<LoadedTfragTree> tfragTrees[tfrag3::TFRAG_GEOS];
    std::vector<LoadedTieTree> tieTrees[tfrag3::TIE_GEOS];
    std::vector<LoadedShrubTree> shrubTrees;
    u16 maxWindIndex = 0;
    // LevelData::frames_since_last_used: reset whenever a bucket draws this level.
    u32 framesSinceLastUsed = 0;
};

// Frees the CPU copies of data that now lives in Metal buffers, keeping only what drawing reads
// (draw lists, BVHs, time-of-day colors, wind instances). Vertex data would otherwise be held
// twice, packed and unpacked, next to its GPU copy.
void TrimUploadedLevelData(tfrag3::Level &level) {
    for (auto &geom : level.tfrag_trees) {
        for (auto &tree : geom) {
            tree.packed_vertices = {};
            tree.unpacked.vertices = {};
            tree.unpacked.indices = {};
            for (auto &draw : tree.draws) {
                draw.runs = {};
                draw.plain_indices = {};
            }
        }
    }
    for (auto &geom : level.tie_trees) {
        for (auto &tree : geom) {
            tree.packed_vertices = {};
            tree.unpacked.vertices = {};
            tree.unpacked.indices = {};
            for (auto &draw : tree.static_draws) {
                draw.runs = {};
                draw.plain_indices = {};
            }
            for (auto &draw : tree.instanced_wind_draws) draw.vertex_index_stream = {};
        }
    }
    for (auto &tree : level.shrub_trees) {
        tree.packed_vertices = {};
        tree.unpacked.vertices = {};
        tree.indices = {};
    }
    // Not drawn by this port (no hfrag/collision renderers).
    level.hfrag = {};
    level.collision = {};
}

std::mutex gBackgroundContentPathMutex;
std::string gBackgroundContentPath;

NSString *FindLevelPath(const std::string &name) {
    NSString *resource = [NSString stringWithFormat:@"Jak1Level-%s", name.c_str()];
    NSString *path = [[NSBundle mainBundle] pathForResource:resource ofType:@"fr3z"];
    if (path != nil) return path;

    std::string contentPath;
    {
        std::lock_guard<std::mutex> lock(gBackgroundContentPathMutex);
        contentPath = gBackgroundContentPath;
    }
    if (contentPath.empty()) return nil;

    NSString *root = [NSString stringWithUTF8String:contentPath.c_str()];
    NSString *fileName = [resource stringByAppendingPathExtension:@"fr3z"];
    NSArray<NSString *> *directories = @[@"level-data", @"levels", @"fr3", @""];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *directory in directories) {
        NSString *candidate = directory.length == 0
            ? [root stringByAppendingPathComponent:fileName]
            : [[root stringByAppendingPathComponent:directory] stringByAppendingPathComponent:fileName];
        if ([fileManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

// Reads "Jak1Level-<name>.fr3z" (FR3Z header + LZFSE stream of the serialized level).
std::unique_ptr<LoadedLevel> LoadLevel(id<MTLDevice> device, id<MTLCommandQueue> queue, const std::string &name) {
    NSString *path = FindLevelPath(name);
    NSData *file = path == nil ? nil : [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (file == nil || file.length < 12) {
        NSLog(@"jakIOS: no FR3 archive found for requested level %s", name.c_str());
        return nullptr;
    }
    uint32_t magic = 0;
    uint64_t rawSize = 0;
    memcpy(&magic, file.bytes, 4);
    memcpy(&rawSize, static_cast<const uint8_t *>(file.bytes) + 4, 8);
    if (magic != 0x5a335246 || rawSize == 0 || rawSize > (1ull << 31)) return nullptr;
    std::vector<uint8_t> raw(rawSize);
    const size_t decoded = compression_decode_buffer(raw.data(), raw.size(),
                                                     static_cast<const uint8_t *>(file.bytes) + 12,
                                                     file.length - 12, nullptr, COMPRESSION_LZFSE);
    if (decoded != rawSize) {
        NSLog(@"jakIOS: FR3 decode failed for %s (%zu of %llu bytes)", name.c_str(), decoded, rawSize);
        return nullptr;
    }

    auto loaded = std::make_unique<LoadedLevel>();
    loaded->level = std::make_unique<tfrag3::Level>();
    {
        Serializer serializer(raw.data(), raw.size());
        loaded->level->serialize(serializer);
    }
    raw.clear();
    raw.shrink_to_fit();

    for (auto &geom : loaded->level->tfrag_trees) {
        for (auto &tree : geom) tree.unpack();
    }
    for (auto &geom : loaded->level->tie_trees) {
        for (auto &tree : geom) tree.unpack();
    }
    for (auto &tree : loaded->level->shrub_trees) tree.unpack();

    // Textures, with mipmaps (OpenGOAL samples level textures with mipmapped filtering).
    id<MTLCommandBuffer> blitCommands = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [blitCommands blitCommandEncoder];
    for (auto &texture : loaded->level->textures) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:texture.w height:texture.h mipmapped:YES];
        id<MTLTexture> metalTexture = [device newTextureWithDescriptor:descriptor];
        metalTexture.label = [NSString stringWithUTF8String:texture.debug_name.c_str()];
        [metalTexture replaceRegion:MTLRegionMake2D(0, 0, texture.w, texture.h)
                        mipmapLevel:0 withBytes:texture.data.data() bytesPerRow:texture.w * 4];
        [blit generateMipmapsForTexture:metalTexture];
        loaded->textures.push_back(metalTexture);
        // Like the loader's texture pool: textures become addressable by VRAM once uploaded.
        if (texture.combo_id != 0) PoolRegisterTexture(texture.combo_id, metalTexture);
        texture.data.clear();
        texture.data.shrink_to_fit();
    }
    [blit endEncoding];
    [blitCommands commit];

    for (int geom = 0; geom < tfrag3::TFRAG_GEOS; geom++) {
        for (const auto &tree : loaded->level->tfrag_trees[geom]) {
            LoadedTfragTree out;
            out.tree = &tree;
            if (!tree.unpacked.vertices.empty()) {
                out.vertexBuffer = [device newBufferWithBytes:tree.unpacked.vertices.data()
                                                       length:tree.unpacked.vertices.size() * sizeof(tfrag3::PreloadedVertex)
                                                      options:MTLResourceStorageModeShared];
            }
            if (!tree.unpacked.indices.empty()) {
                out.indexBuffer = [device newBufferWithBytes:tree.unpacked.indices.data()
                                                       length:tree.unpacked.indices.size() * sizeof(u32)
                                                      options:MTLResourceStorageModeShared];
            }
            loaded->tfragTrees[geom].push_back(out);
        }
    }
    for (int geom = 0; geom < tfrag3::TIE_GEOS; geom++) {
        for (const auto &tree : loaded->level->tie_trees[geom]) {
            LoadedTieTree out;
            out.tree = &tree;
            if (!tree.unpacked.vertices.empty()) {
                out.vertexBuffer = [device newBufferWithBytes:tree.unpacked.vertices.data()
                                                       length:tree.unpacked.vertices.size() * sizeof(tfrag3::PreloadedVertex)
                                                      options:MTLResourceStorageModeShared];
            }
            if (!tree.unpacked.indices.empty()) {
                out.indexBuffer = [device newBufferWithBytes:tree.unpacked.indices.data()
                                                       length:tree.unpacked.indices.size() * sizeof(u32)
                                                      options:MTLResourceStorageModeShared];
            }
            std::vector<u32> windIndices;
            for (const auto &draw : tree.instanced_wind_draws) {
                out.windIndexOffsets.push_back(static_cast<u32>(windIndices.size()));
                windIndices.insert(windIndices.end(), draw.vertex_index_stream.begin(), draw.vertex_index_stream.end());
            }
            if (!windIndices.empty()) {
                out.windIndexBuffer = [device newBufferWithBytes:windIndices.data()
                                                          length:windIndices.size() * sizeof(u32)
                                                         options:MTLResourceStorageModeShared];
            }
            for (const auto &instance : tree.wind_instance_info) {
                loaded->maxWindIndex = std::max(loaded->maxWindIndex, instance.wind_idx);
            }
            loaded->tieTrees[geom].push_back(std::move(out));
        }
    }

    for (const auto &tree : loaded->level->shrub_trees) {
        LoadedShrubTree out;
        out.tree = &tree;
        if (!tree.unpacked.vertices.empty() && !tree.indices.empty()) {
            out.vertexBuffer = [device newBufferWithBytes:tree.unpacked.vertices.data()
                                                   length:tree.unpacked.vertices.size() * sizeof(tfrag3::ShrubGpuVertex)
                                                  options:MTLResourceStorageModeShared];
            out.indexBuffer = [device newBufferWithBytes:tree.indices.data()
                                                  length:tree.indices.size() * sizeof(u32)
                                                 options:MTLResourceStorageModeShared];
        }
        loaded->shrubTrees.push_back(out);
    }
    TrimUploadedLevelData(*loaded->level);

    size_t tfragTreeCount = 0, tieTreeCount = 0;
    for (const auto &geom : loaded->tfragTrees) tfragTreeCount += geom.size();
    for (const auto &geom : loaded->tieTrees) tieTreeCount += geom.size();
    NSLog(@"jakIOS: loaded FR3 level %s: %zu textures, %zu tfrag trees, %zu tie trees", name.c_str(),
          loaded->textures.size(), tfragTreeCount, tieTreeCount);
    return loaded;
}

// Walks the linear DMA trace (16-byte tag + payload per entry).
struct TraceEntry {
    size_t offset;
    uint32_t qwc;
    uint32_t vif0, vif1;
    const uint8_t *payload;
    size_t size() const { return static_cast<size_t>(qwc) * 16; }
    uint32_t vifKind(int i) const { return ((i == 0 ? vif0 : vif1) >> 24) & 0x7f; }
};

std::vector<TraceEntry> EntriesInRange(const uint8_t *trace, size_t length, size_t begin, size_t end) {
    std::vector<TraceEntry> entries;
    size_t offset = begin;
    while (offset + 16 <= std::min(end, length)) {
        TraceEntry entry {};
        uint64_t tag = 0;
        memcpy(&tag, trace + offset, 8);
        memcpy(&entry.vif0, trace + offset + 8, 4);
        memcpy(&entry.vif1, trace + offset + 12, 4);
        entry.offset = offset;
        entry.qwc = tag & 0xffff;
        entry.payload = trace + offset + 16;
        if (entry.size() > length - offset - 16) break;
        entries.push_back(entry);
        offset += 16 + entry.size();
    }
    return entries;
}

constexpr uint32_t kVifNop = 0x00;
constexpr uint32_t kVifDirect = 0x50;
constexpr uint32_t kVifPcPort = 0x08;

// Jak 1 TIE buckets (Tie3WithEnvmapJak1 "l0-tfrag-tie" / "l1-tfrag-tie").
constexpr int kTieBucketLevel0 = 9;
constexpr int kTieBucketLevel1 = 16;
// Jak 1 shrub buckets (SHRUB_NORMAL_LEVEL0 / LEVEL1).
constexpr int kShrubBucketLevel0 = 20;
constexpr int kShrubBucketLevel1 = 26;

// Tie3::WindWork, sent by the game after the TIE PC-port camera block.
struct WindWork {
    u32 paused;
    u32 pad[3];
    math::Vector4f wind_array[64];
    math::Vector4f wind_normal;
    math::Vector4f wind_temp;
    float wind_force[64];
    u32 wind_time;
    u32 pad2[3];
};
static_assert(sizeof(WindWork) == 1344, "WindWork layout");

// Tie3.cpp do_wind_math: sway an instance matrix and advance its wind state.
void DoWindMath(u16 windIndex, float *windVectors, const WindWork &work, float stiffness,
                std::array<math::Vector4f, 4> &matrix) {
    float *state = windVectors + 4 * windIndex;
    const math::Vector4f &workVector = work.wind_array[(work.wind_time + windIndex) & 63];
    constexpr float cx = 0.5f, cy = 100.0f, cz = 0.0166f, cw = -1.0f;
    math::Vector4f vf16 = workVector;
    vf16.x() -= cx * state[2] + cy * state[0];
    vf16.z() -= cx * state[3] + cy * state[1];
    math::Vector4f vf18(state[2], 0.f, state[3], 0.f);
    vf18 += vf16 * cz;
    math::Vector4f vf17(state[0], 0.f, state[1], 0.f);
    vf17 += vf18 * cz;
    for (int i = 0; i < 4; i++) vf17[i] = std::min(vf17[i], 1.f);
    math::Vector4f vf27;
    for (int i = 0; i < 4; i++) vf27[i] = std::max(cw, vf17[i]);
    vf27 *= stiffness;
    for (int row = 0; row < 3; row++) {
        matrix[row].x() += vf27.x() * matrix[row].y();
        matrix[row].z() += vf27.z() * matrix[row].y();
    }
    if (!work.paused) {
        state[0] = vf27.x();
        state[1] = vf27.z();
        state[2] = vf18.x();
        state[3] = vf18.z();
    }
}

}  // namespace

// ---------------------------------------------------------------------------------------------

namespace {
std::mutex gWantedLevelsMutex;
std::vector<std::string> gWantedLevels;   // not yet passed to the loader
std::vector<std::string> gDesiredLevels;  // Loader::m_desired_levels: the game's latest set

// Set by the iOS memory warning; the next frame unloads every level the game doesn't want
// without waiting for the unused-frame grace period.
std::atomic<bool> gMemoryWarning {false};

// Expanded Flut Flut: the flut saddle's Merc model (Jak1Level-ios-flut.fr3z) stays loaded while enabled.
std::atomic<bool> gExpandedFlutModelEnabled {false};
// The flut spawner's pad (Sandover's zoomer pad, a tfrag tree in Jak1Level-ios-flut.fr3z in pad-local coordinates):
// drawn once per frame at this position (pad top, game units) while visible.
std::atomic<bool> gFlutPadVisible {false};
std::atomic<float> gFlutPadX {0.f}, gFlutPadY {0.f}, gFlutPadZ {0.f};
// Expanded Green Eco: the vent ring (a tfrag tree in Jak1Level-ios-vents.fr3z, vent-local) stays loaded while
// enabled and is drawn once per frame at every visible extra vent.
std::atomic<bool> gGreenVentPropsEnabled {false};
std::mutex gGreenVentPropsMutex;
float gGreenVentProps[kMaxGreenVentProps][4] {};
// Driveable Boat: the boat's Merc models (Jak1Level-ios-boat.fr3z) stay loaded while enabled.
std::atomic<bool> gResidentBoatModelEnabled {false};
// Fish in Ocean: the ocean fish Merc models (Jak1Level-ios-fish.fr3z) stay loaded while enabled.
std::atomic<bool> gResidentFishModelEnabled {false};

std::mutex gLoadedMercMutex;
std::vector<std::shared_ptr<LoadedMercLevel>> gLoadedMercLevels;
std::vector<std::string> gUnloadedMercLevels;

// Merc side of an unload. A still-unclaimed load of the same level is dropped, so a pending
// unload always precedes any later reload in TakeUnloadedMercLevels/TakeLoadedMercLevels.
void PublishMercLevelUnload(const std::string &name) {
    std::lock_guard<std::mutex> lock(gLoadedMercMutex);
    gLoadedMercLevels.erase(std::remove_if(gLoadedMercLevels.begin(), gLoadedMercLevels.end(),
                                           [&](const auto &level) { return level->name == name; }),
                            gLoadedMercLevels.end());
    gUnloadedMercLevels.push_back(name);
}

void PublishMercLevel(const std::string &name, const LoadedLevel &level) {
    const auto &merc = level.level->merc_data;
    if (merc.models.empty()) return;
    auto out = std::make_shared<LoadedMercLevel>();
    out->name = name;
    static_assert(sizeof(tfrag3::MercVertex) == 64, "MercVertex layout");
    out->vertices.resize(merc.vertices.size() * sizeof(tfrag3::MercVertex));
    memcpy(out->vertices.data(), merc.vertices.data(), out->vertices.size());
    out->indices = merc.indices;
    for (const auto &model : merc.models) {
        LoadedMercLevel::Model m;
        m.name = model.name;
        m.maxBones = model.max_bones;
        m.stVifAdd = model.st_vif_add;
        m.xyzScale = model.xyz_scale;
        m.stMagic = model.st_magic;
        auto convertDraws = [](const std::vector<tfrag3::MercDraw> &draws) {
            std::vector<LoadedMercLevel::Draw> out;
            for (const auto &draw : draws) {
                out.push_back({draw.first_index, draw.index_count, draw.tree_tex_id, draw.mode.as_int(),
                               static_cast<uint32_t>(draw.eye_id)});
            }
            return out;
        };
        static_assert(sizeof(tfrag3::BlercFloatData) == 8 * sizeof(float), "BlercFloatData layout");
        for (const auto &effect : model.effects) {
            LoadedMercLevel::Effect e;
            e.draws = convertDraws(effect.all_draws);
            e.hasModDraw = effect.has_mod_draw;
            if (e.hasModDraw) {
                const auto &mod = effect.mod;
                e.fixDraws = convertDraws(mod.fix_draw);
                e.modDraws = convertDraws(mod.mod_draw);
                e.modVertices.resize(mod.vertices.size() * sizeof(tfrag3::MercVertex));
                memcpy(e.modVertices.data(), mod.vertices.data(), e.modVertices.size());
                e.blercFloats.resize(mod.blerc.float_data.size() * 8);
                memcpy(e.blercFloats.data(), mod.blerc.float_data.data(), e.blercFloats.size() * sizeof(float));
                e.blercInts = mod.blerc.int_data;
                e.vertexLump4Addr = mod.vertex_lump4_addr;
                e.fragmentMask = mod.fragment_mask;
                e.expectVidxEnd = mod.expect_vidx_end;
            }
            m.effects.push_back(std::move(e));
        }
        out->models.push_back(std::move(m));
    }
    out->textures = level.textures;
    std::lock_guard<std::mutex> lock(gLoadedMercMutex);
    gLoadedMercLevels.push_back(std::move(out));
}
}  // namespace

std::vector<std::shared_ptr<LoadedMercLevel>> TakeLoadedMercLevels() {
    std::lock_guard<std::mutex> lock(gLoadedMercMutex);
    std::vector<std::shared_ptr<LoadedMercLevel>> result;
    result.swap(gLoadedMercLevels);
    return result;
}

std::vector<std::string> TakeUnloadedMercLevels() {
    std::lock_guard<std::mutex> lock(gLoadedMercMutex);
    std::vector<std::string> result;
    result.swap(gUnloadedMercLevels);
    return result;
}

void ConfigureBackgroundContentPath(const std::string &contentPath) {
    std::lock_guard<std::mutex> lock(gBackgroundContentPathMutex);
    gBackgroundContentPath = contentPath;
}

void RequestBackgroundLevels(const std::vector<std::string> &levels) {
    std::lock_guard<std::mutex> lock(gWantedLevelsMutex);
    gDesiredLevels = levels;
    for (const std::string &level : levels) {
        if (std::find(gWantedLevels.begin(), gWantedLevels.end(), level) == gWantedLevels.end()) {
            gWantedLevels.push_back(level);
        }
    }
}

struct Background::Impl {
    struct DynamicTreeBuffers {
        __strong id<MTLBuffer> colors[3] = {nil, nil, nil};
        __strong id<MTLBuffer> indices[3] = {nil, nil, nil};
        size_t colorCapacity = 0;
        size_t indexCapacity = 0;
        uint32_t cursor = 0;
        // Time-of-day weights the colors in colors[lastSlot] were blended with. The weights
        // change only every few frames, and the blend is the costliest CPU step of the background.
        math::Vector<s32, 4> lastItimes[4];
        uint32_t lastSlot = 0;
        bool haveColors = false;
    };

    // Time-of-day colors for a tree: reuses the last blend while the weights are unchanged
    // (the GPU only reads that buffer, so it can stay bound across frames).
    id<MTLBuffer> timeOfDayColors(DynamicTreeBuffers &dynamic, const tfrag3::PackedTimeOfDay &todColors,
                                  const math::Vector<s32, 4> itimes[4]) {
        if (dynamic.haveColors && memcmp(dynamic.lastItimes, itimes, sizeof(dynamic.lastItimes)) == 0) {
            return dynamic.colors[dynamic.lastSlot];
        }
        const uint32_t slot = dynamic.cursor++ % 3;
        colorScratch.resize(std::max<size_t>(todColors.color_count + 4, 4));
        InterpTimeOfDay(itimes, todColors, colorScratch.data());
        id<MTLBuffer> colors = updateDynamicBuffer(
            dynamic.colors, dynamic.colorCapacity, slot, colorScratch.data(),
            colorScratch.size() * sizeof(math::Vector<u8, 4>));
        memcpy(dynamic.lastItimes, itimes, sizeof(dynamic.lastItimes));
        dynamic.lastSlot = slot;
        dynamic.haveColors = colors != nil;
        return colors;
    }

    id<MTLDevice> device;
    id<MTLCommandQueue> loadQueue;
    id<NSObject> memoryWarningObserver = nil;
    id<MTLRenderPipelineState> tfragPipelines[8];  // indexed by DrawMode::AlphaBlend (0 = none)
    id<MTLRenderPipelineState> windPipelines[8];   // tie_wind.vert with the tfrag fragment shader
    id<MTLRenderPipelineState> shrubPipelines[8];  // shrub.vert with the tfrag fragment shader
    id<MTLDepthStencilState> depthWrite, depthNoWrite, depthAlways;
    id<MTLSamplerState> samplers[8];               // [filter][clampS][clampT]
    id<MTLTexture> whiteTexture;

    // Shared with in-flight background loads, which hold only a weak reference: the renderer (and
    // this Impl) can be destroyed while LoadLevel is still running on a global queue.
    struct LevelCache {
        std::mutex mutex;
        std::unordered_map<std::string, std::shared_ptr<LoadedLevel>> levels;
        std::unordered_set<std::string> requested;
    };
    std::shared_ptr<LevelCache> levelCache = std::make_shared<LevelCache>();
    std::mutex &levelMutex = levelCache->mutex;
    std::unordered_map<std::string, std::shared_ptr<LoadedLevel>> &levels = levelCache->levels;
    std::unordered_set<std::string> &requestedLevels = levelCache->requested;

    // Tie3::m_wind_vectors: persistent per-wind-index sway state (4 floats each).
    std::vector<float> windVectors;

    std::vector<math::Vector<u8, 4>> colorScratch;
    std::vector<u8> visScratch;
    std::vector<u32> indexScratch;
    std::vector<std::pair<int, int>> groupScratch;
    std::unordered_map<const void *, DynamicTreeBuffers> dynamicTreeBuffers;
    bool loggedFirstTfrag = false;
    bool drewFlutPad = false;  // the Expanded Flut Flut pad was drawn this frame
    bool drewGreenVents = false;  // the Expanded Green Eco vent rings were drawn this frame
    bool drewCoast = false;    // the driveable boat's stand-in coastline was drawn this frame
    bool loggedFirstTie = false;

    id<MTLBuffer> updateDynamicBuffer(__strong id<MTLBuffer> (&buffers)[3], size_t &capacity,
                                      uint32_t slot, const void *bytes, size_t length) {
        if (length == 0) return nil;
        if (capacity < length) {
            // Grow all ring entries together. Three copies prevent the CPU from overwriting data
            // still consumed by either of the two preceding command buffers.
            const size_t newCapacity = std::max(length, capacity + capacity / 2);
            for (size_t i = 0; i < 3; i++) {
                buffers[i] = [device newBufferWithLength:newCapacity
                                                 options:MTLResourceStorageModeShared];
            }
            capacity = newCapacity;
        }
        id<MTLBuffer> buffer = buffers[slot];
        if (buffer != nil) memcpy(buffer.contents, bytes, length);
        return buffer;
    }

    std::shared_ptr<LoadedLevel> levelNamed(const std::string &name) {
        std::lock_guard<std::mutex> lock(levelMutex);
        auto found = levels.find(name);
        if (found != levels.end()) {
            found->second->framesSinceLastUsed = 0;
            return found->second;
        }
        if (requestedLevels.insert(name).second) {
            // Like the OpenGOAL loader thread: deserialize off the render thread.
            id<MTLDevice> loadDevice = device;
            id<MTLCommandQueue> queue = loadQueue;
            const std::string levelName = name;  // blocks capture C++ references by reference
            const std::weak_ptr<LevelCache> weakCache = levelCache;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (weakCache.expired()) return;
                std::shared_ptr<LoadedLevel> level(LoadLevel(loadDevice, queue, levelName));
                if (!level) return;
                // The background renderer was torn down mid-load; drop the result.
                std::shared_ptr<LevelCache> cache = weakCache.lock();
                if (!cache) return;
                PublishMercLevel(levelName, *level);
                // The Merc renderer keeps its own copy; drawing tfrag/TIE/shrub never reads it.
                level->level->merc_data = {};
                std::lock_guard<std::mutex> loadedLock(cache->mutex);
                cache->levels[levelName] = std::move(level);
            });
        }
        return nullptr;
    }

    // Loader::update's unload pass, on the render thread between frames. Unlike OpenGOAL, which
    // keeps up to LEVEL_TOTAL levels cached, a level is dropped as soon as the game stops listing
    // it in __pc-set-levels and nothing has drawn it for kUnloadAfterFrames: the game itself never
    // holds more than two levels, and the FR3 reloads in the background while a revisited level's
    // DGO loads. GAME (common Merc art and blend shapes) stays loaded.
    static constexpr u32 kUnloadAfterFrames = 180;

    static bool isPinnedLevel(const std::string &name) {
        return name == "game" ||
            (name == "ios-flut" && gExpandedFlutModelEnabled.load(std::memory_order_relaxed)) ||
            (name == "ios-boat" && gResidentBoatModelEnabled.load(std::memory_order_relaxed)) ||
            (name == "ios-fish" && gResidentFishModelEnabled.load(std::memory_order_relaxed)) ||
            (name == "ios-vents" && gGreenVentPropsEnabled.load(std::memory_order_relaxed));
    }

    void updateResidency() {
        std::vector<std::string> desired;
        {
            std::lock_guard<std::mutex> lock(gWantedLevelsMutex);
            desired = gDesiredLevels;
        }
        const bool memoryWarning = gMemoryWarning.exchange(false);

        std::vector<std::pair<std::string, std::shared_ptr<LoadedLevel>>> unloaded;
        {
            std::lock_guard<std::mutex> lock(levelMutex);
            for (auto it = levels.begin(); it != levels.end();) {
                LoadedLevel &level = *it->second;
                level.framesSinceLastUsed++;
                const bool wanted = isPinnedLevel(it->first) ||
                    std::find(desired.begin(), desired.end(), it->first) != desired.end();
                if (!wanted && (memoryWarning || level.framesSinceLastUsed > kUnloadAfterFrames)) {
                    requestedLevels.erase(it->first);
                    unloaded.emplace_back(it->first, std::move(it->second));
                    it = levels.erase(it);
                } else {
                    ++it;
                }
            }
        }

        for (auto &[name, level] : unloaded) {
            for (size_t i = 0; i < level->level->textures.size() && i < level->textures.size(); i++) {
                const uint32_t comboId = level->level->textures[i].combo_id;
                if (comboId != 0) PoolUnregisterTexture(comboId, level->textures[i]);
            }
            // Time-of-day rings are keyed by vertex buffer address, which a later allocation can reuse.
            auto forgetBuffer = [&](id<MTLBuffer> buffer) {
                if (buffer != nil) dynamicTreeBuffers.erase((__bridge const void *)buffer);
            };
            for (const auto &geom : level->tfragTrees) for (const auto &tree : geom) forgetBuffer(tree.vertexBuffer);
            for (const auto &geom : level->tieTrees) for (const auto &tree : geom) forgetBuffer(tree.vertexBuffer);
            for (const auto &tree : level->shrubTrees) forgetBuffer(tree.vertexBuffer);
            PublishMercLevelUnload(name);
            NSLog(@"jakIOS: unloaded FR3 level %s%s", name.c_str(), memoryWarning ? " (memory warning)" : "");
            // Metal objects are freed here, once in-flight command buffers release them.
        }
    }

    TfragUniforms baseUniforms(const GoalBackgroundCameraData &camera, const simd_float4 &fogColor) const {
        const auto pcCamera = MakeNewCamMat(camera.rot, camera.perspective, camera.fog.x(), camera.hvdf_off.z());
        TfragUniforms uniforms {};
        for (int c = 0; c < 4; c++) {
            uniforms.pcCamera[c] = simd_make_float4(pcCamera[c][0], pcCamera[c][1], pcCamera[c][2], pcCamera[c][3]);
        }
        uniforms.hvdfOffset = simd_make_float4(camera.hvdf_off[0], camera.hvdf_off[1], camera.hvdf_off[2], camera.hvdf_off[3]);
        uniforms.camTrans = simd_make_float4(camera.trans[0], camera.trans[1], camera.trans[2], camera.trans[3]);
        uniforms.fogColor = fogColor;
        uniforms.fogConstant = camera.fog.x();
        uniforms.fogMin = camera.fog.y();
        uniforms.fogMax = camera.fog.z();
        return uniforms;
    }

    // setup_opengl_from_draw_mode + setup_tfrag_shader for one draw. Returns whether the
    // AFAIL_NO_DEPTH_WRITE second draw is needed.
    bool applyDrawMode(id<MTLRenderCommandEncoder> encoder, __strong id<MTLRenderPipelineState> const *pipelines,
                       uint32_t mode, int textureId, const LoadedLevel &level, TfragUniforms *uniforms) {
        float alphaMin = 0.f;
        bool doubleDraw = false;
        bool writesDepth = ModeDepthWrite(mode);
        if (ModeAlphaTestEnable(mode)) {
            if (ModeAlphaTest(mode) == 2) {
                alphaMin = ModeAref(mode) / 127.f;
                if (ModeAlphaFail(mode) == 1) {
                    if (writesDepth) doubleDraw = true;
                    else alphaMin = 0.f;
                }
            } else if (ModeAlphaTest(mode) == 0 && ModeAlphaFail(mode) == 1) {
                writesDepth = false;  // atest NEVER + FB_ONLY disables z writes
            }
        }
        const uint32_t blend = ModeBlend(mode) ? ModeAlphaBlend(mode) : 0;
        [encoder setRenderPipelineState:pipelines[blend]];
        [encoder setDepthStencilState:!ModeDepthTest(mode) ? depthAlways
                                                           : (writesDepth ? depthWrite : depthNoWrite)];
        id<MTLTexture> texture = whiteTexture;
        if (textureId >= 0 && static_cast<size_t>(textureId) < level.textures.size()) {
            texture = level.textures[textureId];
        }
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder setFragmentSamplerState:samplers[(ModeFilter(mode) ? 4 : 0) | (ModeClampS(mode) ? 2 : 0) |
                                                  (ModeClampT(mode) ? 1 : 0)]
                                 atIndex:0];
        uniforms->decal = ModeDecal(mode) ? 1 : 0;
        uniforms->alphaMin = alphaMin;
        uniforms->alphaMax = 10.f;
        [encoder setVertexBytes:uniforms length:sizeof(*uniforms) atIndex:1];
        [encoder setFragmentBytes:uniforms length:sizeof(*uniforms) atIndex:1];
        return doubleDraw;
    }

    void secondDrawUniforms(id<MTLRenderCommandEncoder> encoder, uint32_t mode, TfragUniforms *uniforms) {
        uniforms->alphaMin = -10.f;
        uniforms->alphaMax = ModeAref(mode) / 127.f;
        [encoder setDepthStencilState:depthNoWrite];
        [encoder setVertexBytes:uniforms length:sizeof(*uniforms) atIndex:1];
        [encoder setFragmentBytes:uniforms length:sizeof(*uniforms) atIndex:1];
    }

    // Shared by TFragment::render_tree and Tie3::setup_tree/draw_matching_draws_for_tree:
    // time of day, frustum culling, visible index list, then the draws in `ranges`.
    // Returns the time-of-day color buffer (for wind draws) or nil if nothing was set up.
    id<MTLBuffer> drawStripTree(id<MTLRenderCommandEncoder> encoder, const LoadedLevel &level,
                                id<MTLBuffer> vertexBuffer, id<MTLBuffer> indexBuffer,
                                const std::vector<tfrag3::StripDraw> &draws,
                                const tfrag3::PackedTimeOfDay &todColors, const tfrag3::BVH &bvh,
                                bool useStrips, const std::vector<std::pair<size_t, size_t>> &ranges,
                                const GoalBackgroundCameraData &camera, const simd_float4 &fogColor) {
        if (vertexBuffer == nil || indexBuffer == nil) return nil;
        DynamicTreeBuffers &dynamic = dynamicTreeBuffers[(__bridge const void *)vertexBuffer];
        id<MTLBuffer> colors = timeOfDayColors(dynamic, todColors, camera.itimes);
        visScratch.resize(bvh.vis_nodes.size());
        for (size_t n = 0; n < bvh.vis_nodes.size(); n++) {
            visScratch[n] = SphereInView(bvh.vis_nodes[n].bsphere, camera.planes);
        }
        if (draws.empty()) return colors;

        TfragUniforms uniforms = baseUniforms(camera, fogColor);
        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
        [encoder setVertexBuffer:colors offset:0 atIndex:2];
        [encoder setBlendColorRed:0.5f green:0.5f blue:0.5f alpha:0.5f];
        const MTLPrimitiveType primitive = useStrips ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle;
        for (const auto &range : ranges) {
            for (size_t d = range.first; d < range.second && d < draws.size(); d++) {
                const auto &draw = draws[d];
                bool hasVisibleGroup = false;
                for (const auto &group : draw.vis_groups) {
                    if (group.vis_idx_in_pc_bvh == UINT16_MAX || visScratch[group.vis_idx_in_pc_bvh]) {
                        hasVisibleGroup = true;
                        break;
                    }
                }
                if (!hasVisibleGroup) continue;
                const uint32_t mode = draw.mode.as_int();
                const bool doubleDraw = applyDrawMode(encoder, tfragPipelines, mode, draw.tree_tex_id, level, &uniforms);
                const auto drawVisibleRuns = [&]() {
                    uint32_t first = draw.unpacked.idx_of_first_idx_in_full_buffer;
                    uint32_t runFirst = 0;
                    uint32_t runCount = 0;
                    const auto flush = [&]() {
                        if (runCount != 0) {
                            [encoder drawIndexedPrimitives:primitive indexCount:runCount
                                                 indexType:MTLIndexTypeUInt32 indexBuffer:indexBuffer
                                         indexBufferOffset:(first + runFirst) * sizeof(u32)];
                        }
                    };
                    uint32_t cursor = 0;
                    for (const auto &group : draw.vis_groups) {
                        const bool visible = group.vis_idx_in_pc_bvh == UINT16_MAX ||
                            visScratch[group.vis_idx_in_pc_bvh];
                        if (visible) {
                            if (runCount == 0) runFirst = cursor;
                            runCount += group.num_inds;
                        } else if (runCount != 0) {
                            flush();
                            runCount = 0;
                        }
                        cursor += group.num_inds;
                    }
                    flush();
                };
                drawVisibleRuns();
                if (doubleDraw) {
                    secondDrawUniforms(encoder, mode, &uniforms);
                    drawVisibleRuns();
                }
            }
        }
        return colors;
    }

    void renderTfragBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                           const std::vector<tfrag3::TFragmentTreeKind> &kinds, const simd_float4 &fogColor);
    void renderTieBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                         const simd_float4 &fogColor);
    void renderShrubBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                           const simd_float4 &fogColor);
    void renderTieWind(id<MTLRenderCommandEncoder> encoder, const LoadedLevel &level, const LoadedTieTree &tree,
                       id<MTLBuffer> colors, const GoalBackgroundCameraData &camera, const WindWork &wind,
                       const simd_float4 &fogColor);
};

Background::Background(id<MTLDevice> device, id<MTLLibrary> library) : _impl(std::make_unique<Impl>()) {
    Impl &impl = *_impl;
    impl.device = device;
    impl.loadQueue = [device newCommandQueue];

    id<MTLFunction> fragment = [library newFunctionWithName:@"jak1_tfrag3_fragment"];
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    SetMainPassDepthFormats(descriptor);
    MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    auto makePipelines = [&](NSString *vertexName, __strong id<MTLRenderPipelineState> *out) {
        descriptor.vertexFunction = [library newFunctionWithName:vertexName];
        // GS alpha blend modes as in setup_opengl_from_draw_mode; alpha channel ONE, ZERO.
        for (uint32_t blend = 0; blend < 8; blend++) {
            color.blendingEnabled = blend != 0 && blend != 6;
            color.rgbBlendOperation = blend == 5 ? MTLBlendOperationReverseSubtract : MTLBlendOperationAdd;
            color.alphaBlendOperation = MTLBlendOperationAdd;
            color.sourceAlphaBlendFactor = MTLBlendFactorOne;
            color.destinationAlphaBlendFactor = MTLBlendFactorZero;
            switch (blend) {
                case 1: color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; break;
                case 2: color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                        color.destinationRGBBlendFactor = MTLBlendFactorOne; break;
                case 3: color.sourceRGBBlendFactor = MTLBlendFactorOne;
                        color.destinationRGBBlendFactor = MTLBlendFactorOne; break;
                case 4: color.sourceRGBBlendFactor = MTLBlendFactorBlendColor;
                        color.destinationRGBBlendFactor = MTLBlendFactorBlendColor; break;
                case 5: color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                        color.destinationRGBBlendFactor = MTLBlendFactorOne; break;
                case 7: color.sourceRGBBlendFactor = MTLBlendFactorDestinationAlpha;
                        color.destinationRGBBlendFactor = MTLBlendFactorOne; break;
                default: color.sourceRGBBlendFactor = MTLBlendFactorOne;
                         color.destinationRGBBlendFactor = MTLBlendFactorZero; break;
            }
            NSError *error = nil;
            out[blend] = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            if (error != nil) NSLog(@"Jak1Background %@ pipeline error: %@", vertexName, error.localizedDescription);
        }
    };
    makePipelines(@"jak1_tfrag3_vertex", impl.tfragPipelines);
    makePipelines(@"jak1_tie_wind_vertex", impl.windPipelines);
    makePipelines(@"jak1_shrub_vertex", impl.shrubPipelines);

    // GS depth is greater-is-closer; the main pass clears depth to 0.
    MTLDepthStencilDescriptor *depth = [[MTLDepthStencilDescriptor alloc] init];
    depth.depthCompareFunction = MTLCompareFunctionGreaterEqual;
    depth.depthWriteEnabled = YES;
    impl.depthWrite = [device newDepthStencilStateWithDescriptor:depth];
    depth.depthWriteEnabled = NO;
    impl.depthNoWrite = [device newDepthStencilStateWithDescriptor:depth];
    depth.depthCompareFunction = MTLCompareFunctionAlways;
    impl.depthAlways = [device newDepthStencilStateWithDescriptor:depth];

    for (int i = 0; i < 8; i++) {
        MTLSamplerDescriptor *sampler = [[MTLSamplerDescriptor alloc] init];
        const bool filter = i & 4;
        sampler.minFilter = filter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler.magFilter = sampler.minFilter;
        sampler.mipFilter = filter ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNotMipmapped;
        sampler.sAddressMode = (i & 2) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        sampler.tAddressMode = (i & 1) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        impl.samplers[i] = [device newSamplerStateWithDescriptor:sampler];
    }

    MTLTextureDescriptor *white = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:1 height:1 mipmapped:NO];
    impl.whiteTexture = [device newTextureWithDescriptor:white];
    const uint32_t texel = 0x80808080;
    [impl.whiteTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&texel bytesPerRow:4];

    impl.memoryWarningObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *) { gMemoryWarning = true; }];
}

Background::~Background() {
    if (_impl->memoryWarningObserver != nil) {
        [NSNotificationCenter.defaultCenter removeObserver:_impl->memoryWarningObserver];
    }
}

static std::atomic<bool> gCoastTerrainEnabled{false};

void SetCoastTerrainEnabled(bool enabled) {
    gCoastTerrainEnabled.store(enabled, std::memory_order_relaxed);
}

void SetExpandedFlutModelEnabled(bool enabled) {
    gExpandedFlutModelEnabled.store(enabled, std::memory_order_relaxed);
}

void SetResidentBoatModelEnabled(bool enabled) {
    gResidentBoatModelEnabled.store(enabled, std::memory_order_relaxed);
}

void SetResidentFishModelEnabled(bool enabled) {
    gResidentFishModelEnabled.store(enabled, std::memory_order_relaxed);
}

void SetFlutPad(bool visible, float x, float y, float z) {
    gFlutPadX.store(x, std::memory_order_relaxed);
    gFlutPadY.store(y, std::memory_order_relaxed);
    gFlutPadZ.store(z, std::memory_order_relaxed);
    gFlutPadVisible.store(visible, std::memory_order_relaxed);
}

void SetGreenVentProps(bool enabled, const float (&props)[kMaxGreenVentProps][4]) {
    {
        std::lock_guard<std::mutex> lock(gGreenVentPropsMutex);
        memcpy(gGreenVentProps, props, sizeof(gGreenVentProps));
    }
    gGreenVentPropsEnabled.store(enabled, std::memory_order_relaxed);
}

const std::vector<int> &Background::buckets() {
    static const std::vector<int> ids = [] {
        std::vector<int> result;
        for (const TfragBucket &bucket : TfragBuckets()) result.push_back(bucket.bucket);
        result.push_back(kTieBucketLevel0);
        result.push_back(kTieBucketLevel1);
        result.push_back(kShrubBucketLevel0);
        result.push_back(kShrubBucketLevel1);
        return result;
    }();
    return ids;
}

void Background::beginFrame() {
    // Start loading levels the game announced via __pc-set-levels.
    std::vector<std::string> wanted;
    {
        std::lock_guard<std::mutex> lock(gWantedLevelsMutex);
        wanted.swap(gWantedLevels);
    }
    for (const std::string &level : wanted) _impl->levelNamed(level);
    if (gExpandedFlutModelEnabled.load(std::memory_order_relaxed)) _impl->levelNamed("ios-flut");
    if (gResidentBoatModelEnabled.load(std::memory_order_relaxed)) _impl->levelNamed("ios-boat");
    if (gResidentFishModelEnabled.load(std::memory_order_relaxed)) _impl->levelNamed("ios-fish");
    if (gGreenVentPropsEnabled.load(std::memory_order_relaxed)) _impl->levelNamed("ios-vents");
    _impl->drewFlutPad = false;
    _impl->drewGreenVents = false;
    _impl->drewCoast = false;
    _impl->updateResidency();
}

void Background::renderBucket(id<MTLRenderCommandEncoder> encoder, int bucketId, const uint8_t *trace,
                              size_t traceLength, const std::vector<uint32_t> &bucketOffsets) {
    if (trace == nullptr || bucketOffsets.empty()) return;
    if (bucketId >= static_cast<int>(bucketOffsets.size()) || bucketOffsets[bucketId] == UINT32_MAX) return;

    // Fog color comes from the default-registers packet at the head of the chain
    // (OpenGLRenderer::dispatch_buckets_jak1: CNT qwc 10, fog color at byte 144).
    simd_float4 fogColor = simd_make_float4(0, 0, 0, 1.0f / 255.0f);
    for (const TraceEntry &entry : EntriesInRange(trace, traceLength, 0, std::min<size_t>(traceLength, 512))) {
        if (entry.qwc == 10) {
            const uint8_t *rgba = entry.payload + 144;
            fogColor = simd_make_float4(rgba[0] / 255.f, rgba[1] / 255.f, rgba[2] / 255.f, 1.0f / 255.0f);
            break;
        }
    }

    // A bucket runs until the next bucket's chain starts.
    const size_t begin = bucketOffsets[bucketId];
    size_t end = traceLength;
    for (size_t next = bucketId + 1; next < bucketOffsets.size(); next++) {
        if (bucketOffsets[next] != UINT32_MAX && bucketOffsets[next] > begin) {
            end = bucketOffsets[next];
            break;
        }
    }
    const std::vector<TraceEntry> entries = EntriesInRange(trace, traceLength, begin, end);

    if (bucketId == kTieBucketLevel0 || bucketId == kTieBucketLevel1) {
        _impl->renderTieBucket(encoder, entries, fogColor);
        return;
    }
    if (bucketId == kShrubBucketLevel0 || bucketId == kShrubBucketLevel1) {
        _impl->renderShrubBucket(encoder, entries, fogColor);
        return;
    }
    for (const TfragBucket &bucket : TfragBuckets()) {
        if (bucket.bucket == bucketId) {
            _impl->renderTfragBucket(encoder, entries, bucket.kinds, fogColor);
        }
    }
}

// TFragment::render: each tfrag init (NOP + DIRECT imm 2) is followed by matrix/data uploads,
// an MSCAL, then the PC-port camera block naming the level.
void Background::Impl::renderTfragBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                                         const std::vector<tfrag3::TFragmentTreeKind> &kinds,
                                         const simd_float4 &fogColor) {
    for (size_t i = 0; i + 5 < entries.size(); i++) {
        const TraceEntry &init = entries[i];
        if (!(init.vifKind(0) == kVifNop && init.vifKind(1) == kVifDirect && (init.vif1 & 0xffff) == 2 &&
              init.size() == 32)) continue;
        const TraceEntry &pc = entries[i + 5];
        if (pc.size() != sizeof(TfragPcPortData)) continue;
        TfragPcPortData data;
        memcpy(&data, pc.payload, sizeof(data));
        data.level_name[sizeof(data.level_name) - 1] = 0;
        const std::string levelName(data.level_name);
        if (levelName.empty()) continue;
        std::shared_ptr<LoadedLevel> level = levelNamed(levelName);
        if (!level) continue;
        // The driveable boat's stand-in coastline rides along with the first opaque tfrag pass of the frame,
        // whichever level it belongs to, so it gets that pass's camera, fog and time of day (it has no bucket of
        // its own; its textures are its own). It used to need village1's pass, but at sea the boat no longer keeps
        // village1 loaded (free-boat-plan.md phase 4).
        std::shared_ptr<LoadedLevel> coast;
        if (!drewCoast && gCoastTerrainEnabled.load(std::memory_order_relaxed) &&
            std::find(kinds.begin(), kinds.end(), tfrag3::TFragmentTreeKind::NORMAL) != kinds.end()) {
            coast = levelNamed("ios-coast");
            if (coast) drewCoast = true;
        }
        for (const LoadedTfragTree &loaded : level->tfragTrees[kTfragLod]) {
            const tfrag3::TfragTree &tree = *loaded.tree;
            if (std::find(kinds.begin(), kinds.end(), tree.kind) == kinds.end()) continue;
            drawStripTree(encoder, *level, loaded.vertexBuffer, loaded.indexBuffer, tree.draws,
                          tree.colors, tree.bvh, tree.use_strips, {{0, tree.draws.size()}},
                          data.camera, fogColor);
            if (!loggedFirstTfrag) {
                NSLog(@"jakIOS: drawing tfrag for %s", data.level_name);
                loggedFirstTfrag = true;
            }
        }
        if (coast) {
            for (const LoadedTfragTree &loaded : coast->tfragTrees[kTfragLod]) {
                const tfrag3::TfragTree &tree = *loaded.tree;
                drawStripTree(encoder, *coast, loaded.vertexBuffer, loaded.indexBuffer, tree.draws,
                              tree.colors, tree.bvh, tree.use_strips, {{0, tree.draws.size()}},
                              data.camera, fogColor);
            }
        }
        // Expanded Flut Flut pad: once per frame, with the first opaque tfrag pass's camera, fog and time of
        // day. Its vertices are pad-local, so moving the camera by -pad places it at the spawner.
        if (!drewFlutPad && gFlutPadVisible.load(std::memory_order_relaxed) &&
            std::find(kinds.begin(), kinds.end(), tfrag3::TFragmentTreeKind::NORMAL) != kinds.end()) {
            if (std::shared_ptr<LoadedLevel> flut = levelNamed("ios-flut")) {
                drewFlutPad = true;
                GoalBackgroundCameraData camera = data.camera;
                camera.trans.x() -= gFlutPadX.load(std::memory_order_relaxed);
                camera.trans.y() -= gFlutPadY.load(std::memory_order_relaxed);
                camera.trans.z() -= gFlutPadZ.load(std::memory_order_relaxed);
                for (const LoadedTfragTree &loaded : flut->tfragTrees[kTfragLod]) {
                    const tfrag3::TfragTree &tree = *loaded.tree;
                    drawStripTree(encoder, *flut, loaded.vertexBuffer, loaded.indexBuffer, tree.draws,
                                  tree.colors, tree.bvh, tree.use_strips, {{0, tree.draws.size()}},
                                  camera, fogColor);
                }
            }
        }
        // Expanded Green Eco vent rings: same as the flut pad, once per visible vent.
        if (!drewGreenVents && gGreenVentPropsEnabled.load(std::memory_order_relaxed) &&
            std::find(kinds.begin(), kinds.end(), tfrag3::TFragmentTreeKind::NORMAL) != kinds.end()) {
            if (std::shared_ptr<LoadedLevel> vents = levelNamed("ios-vents")) {
                drewGreenVents = true;
                float props[kMaxGreenVentProps][4];
                {
                    std::lock_guard<std::mutex> lock(gGreenVentPropsMutex);
                    memcpy(props, gGreenVentProps, sizeof(props));
                }
                for (const auto &prop : props) {
                    if (prop[3] == 0.f) continue;
                    GoalBackgroundCameraData camera = data.camera;
                    camera.trans.x() -= prop[0];
                    camera.trans.y() -= prop[1];
                    camera.trans.z() -= prop[2];
                    for (const LoadedTfragTree &loaded : vents->tfragTrees[kTfragLod]) {
                        const tfrag3::TfragTree &tree = *loaded.tree;
                        drawStripTree(encoder, *vents, loaded.vertexBuffer, loaded.indexBuffer, tree.draws,
                                      tree.colors, tree.bvh, tree.use_strips, {{0, tree.draws.size()}},
                                      camera, fogColor);
                    }
                }
            }
        }
        i += 5;
    }
}

// Tie3::set_up_common_data_from_dma (Jak 1): ... PC-port camera block, then WindWork, then the
// envmap color. Draws the NORMAL category, the NORMAL_ENVMAP base pass (Tie3WithEnvmapJak1) and wind.
void Background::Impl::renderTieBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                                       const simd_float4 &fogColor) {
    for (size_t i = 0; i + 1 < entries.size(); i++) {
        const TraceEntry &pc = entries[i];
        if (pc.vifKind(1) != kVifPcPort || pc.size() != sizeof(TfragPcPortData)) continue;
        const TraceEntry &windEntry = entries[i + 1];
        if (windEntry.size() != sizeof(WindWork)) return;
        TfragPcPortData data;
        memcpy(&data, pc.payload, sizeof(data));
        data.level_name[sizeof(data.level_name) - 1] = 0;
        WindWork wind;
        memcpy(&wind, windEntry.payload, sizeof(wind));
        const std::string levelName(data.level_name);
        if (levelName.empty()) return;
        std::shared_ptr<LoadedLevel> level = levelNamed(levelName);
        if (!level) return;
        if (windVectors.size() < 4u * level->maxWindIndex + 4) windVectors.resize(4u * level->maxWindIndex + 4, 0.f);

        for (const LoadedTieTree &loaded : level->tieTrees[kTieLod]) {
            const tfrag3::TieTree &tree = *loaded.tree;
            const auto &cdi = tree.category_draw_indices;
            const int normal = static_cast<int>(tfrag3::TieCategory::NORMAL);
            const int envmap = static_cast<int>(tfrag3::TieCategory::NORMAL_ENVMAP);
            id<MTLBuffer> colors = drawStripTree(
                encoder, *level, loaded.vertexBuffer, loaded.indexBuffer, tree.static_draws,
                tree.colors, tree.bvh, tree.use_strips,
                {{cdi[normal], cdi[normal + 1]}, {cdi[envmap], cdi[envmap + 1]}}, data.camera, fogColor);
            if (colors != nil) renderTieWind(encoder, *level, loaded, colors, data.camera, wind, fogColor);
        }
        if (!loggedFirstTie) {
            NSLog(@"jakIOS: drawing tie for %s (%zu trees)", data.level_name,
                  level->tieTrees[kTieLod].size());
            loggedFirstTie = true;
        }
        return;
    }
}

// Shrub::render: a PC-port camera block, then every tree drawn without culling.
void Background::Impl::renderShrubBucket(id<MTLRenderCommandEncoder> encoder, const std::vector<TraceEntry> &entries,
                                         const simd_float4 &fogColor) {
    for (const TraceEntry &pc : entries) {
        if (pc.vifKind(1) != kVifPcPort || pc.size() != sizeof(TfragPcPortData)) continue;
        TfragPcPortData data;
        memcpy(&data, pc.payload, sizeof(data));
        data.level_name[sizeof(data.level_name) - 1] = 0;
        std::shared_ptr<LoadedLevel> level = levelNamed(data.level_name);
        if (!level) return;
        TfragUniforms uniforms = baseUniforms(data.camera, fogColor);
        [encoder setBlendColorRed:0.5f green:0.5f blue:0.5f alpha:0.5f];
        for (const LoadedShrubTree &loaded : level->shrubTrees) {
            if (loaded.vertexBuffer == nil) continue;
            const tfrag3::ShrubTree &tree = *loaded.tree;
            DynamicTreeBuffers &dynamic =
                dynamicTreeBuffers[(__bridge const void *)loaded.vertexBuffer];
            id<MTLBuffer> colors = timeOfDayColors(dynamic, tree.time_of_day_colors, data.camera.itimes);
            [encoder setVertexBuffer:loaded.vertexBuffer offset:0 atIndex:0];
            [encoder setVertexBuffer:colors offset:0 atIndex:2];
            for (const auto &draw : tree.static_draws) {
                if (draw.num_indices == 0) continue;
                const uint32_t mode = draw.mode.as_int();
                const bool doubleDraw =
                    applyDrawMode(encoder, shrubPipelines, mode, static_cast<int>(draw.tree_tex_id), *level, &uniforms);
                [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:draw.num_indices
                                     indexType:MTLIndexTypeUInt32 indexBuffer:loaded.indexBuffer
                             indexBufferOffset:draw.first_index_index * sizeof(u32)];
                if (doubleDraw) {
                    secondDrawUniforms(encoder, mode, &uniforms);
                    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangleStrip indexCount:draw.num_indices
                                         indexType:MTLIndexTypeUInt32 indexBuffer:loaded.indexBuffer
                                 indexBufferOffset:draw.first_index_index * sizeof(u32)];
                }
            }
        }
        return;
    }
}

// Tie3::render_tree_wind: per-instance matrices swayed by do_wind_math, drawn with tie_wind.vert.
// Relies on visScratch from the drawStripTree call for this tree.
void Background::Impl::renderTieWind(id<MTLRenderCommandEncoder> encoder, const LoadedLevel &level,
                                     const LoadedTieTree &loaded, id<MTLBuffer> colors,
                                     const GoalBackgroundCameraData &camera, const WindWork &wind,
                                     const simd_float4 &fogColor) {
    const tfrag3::TieTree &tree = *loaded.tree;
    if (tree.instanced_wind_draws.empty() || loaded.windIndexBuffer == nil) return;

    std::vector<std::array<math::Vector4f, 4>> instanceCameras(tree.wind_instance_info.size());
    for (size_t instance = 0; instance < tree.wind_instance_info.size(); instance++) {
        const auto &info = tree.wind_instance_info[instance];
        auto matrix = info.matrix;
        if (info.wind_idx * 4u + 4 > windVectors.size()) continue;
        DoWindMath(info.wind_idx, windVectors.data(), wind, info.stiffness, matrix);
        auto &out = instanceCameras[instance];
        const auto &cam = camera.camera;
        out[0] = cam[0] * matrix[0].x() + cam[1] * matrix[0].y() + cam[2] * matrix[0].z();
        out[1] = cam[0] * matrix[1].x() + cam[1] * matrix[1].y() + cam[2] * matrix[1].z();
        out[2] = cam[0] * matrix[2].x() + cam[1] * matrix[2].y() + cam[2] * matrix[2].z();
        out[3] = cam[0] * matrix[3].x() + cam[1] * matrix[3].y() + cam[2] * matrix[3].z() + cam[3];
    }

    TfragUniforms uniforms = baseUniforms(camera, fogColor);
    [encoder setVertexBuffer:loaded.vertexBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:colors offset:0 atIndex:2];
    const MTLPrimitiveType primitive = tree.use_strips ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle;
    for (size_t d = 0; d < tree.instanced_wind_draws.size(); d++) {
        const auto &draw = tree.instanced_wind_draws[d];
        const uint32_t mode = draw.mode.as_int();
        u32 offset = 0;
        for (const auto &group : draw.instance_groups) {
            const bool visible = group.vis_idx < visScratch.size() && visScratch[group.vis_idx];
            if (visible && group.instance_idx < instanceCameras.size()) {
                // tie_wind.vert takes the instance camera as `camera`; carried in pcCamera here.
                const auto &m = instanceCameras[group.instance_idx];
                for (int c = 0; c < 4; c++) uniforms.pcCamera[c] = simd_make_float4(m[c][0], m[c][1], m[c][2], m[c][3]);
                const bool doubleDraw = applyDrawMode(encoder, windPipelines, mode, draw.tree_tex_id, level, &uniforms);
                const NSUInteger start = (offset + loaded.windIndexOffsets[d]) * sizeof(u32);
                [encoder drawIndexedPrimitives:primitive indexCount:group.num indexType:MTLIndexTypeUInt32
                                   indexBuffer:loaded.windIndexBuffer indexBufferOffset:start];
                if (doubleDraw) {
                    secondDrawUniforms(encoder, mode, &uniforms);
                    [encoder drawIndexedPrimitives:primitive indexCount:group.num indexType:MTLIndexTypeUInt32
                                       indexBuffer:loaded.windIndexBuffer indexBufferOffset:start];
                }
            }
            offset += group.num;
        }
    }
}

}  // namespace jak1
