#pragma once

// Jak 1 background (level geometry) renderers, ported from OpenGOAL's opengl_renderer/background.
// Geometry comes from the level's FR3 file (bundled as LZFSE .fr3z); each frame the game's DMA
// supplies the camera, time-of-day weights and level name per bucket (TfragPcPortData).

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace jak1 {

// Sets the imported content root used to find generated FR3 level archives that are not bundled
// with the app. Passing an empty path restores bundle-only lookup. Thread-safe.
void ConfigureBackgroundContentPath(const std::string &contentPath);

// __pc-set-levels: the game announces the levels it is loading so the renderer can start
// reading their FR3 data early (Loader::set_want_levels). Thread-safe.
void RequestBackgroundLevels(const std::vector<std::string> &levels);

// A level's Merc (foreground model) data, published when its FR3 finishes loading, so the Merc
// renderer can draw that level's actors (Loader::get_merc_model searches every loaded level).
struct LoadedMercLevel {
    std::string name;
    std::vector<uint8_t> vertices;  // tfrag3::MercVertex, 64 bytes each
    std::vector<uint32_t> indices;
    struct Draw {
        uint32_t firstIndex, indexCount;
        int32_t texture;
        uint32_t mode, eyeId;
    };
    // tfrag3::MercEffect. When the game sends blend shape (blerc) weights or asks for vertex
    // updates (ripple, texture scroll), effects with mod draws are drawn as fixDraws from the
    // level buffers plus modDraws from modVertices after they are updated
    // (Merc2::model_mod_blerc_draws / model_mod_draws).
    struct Effect {
        std::vector<Draw> draws;  // all_draws
        bool hasModDraw = false;
        std::vector<Draw> fixDraws, modDraws;
        std::vector<uint8_t> modVertices;  // tfrag3::MercVertex, 64 bytes each
        std::vector<float> blercFloats;    // tfrag3::BlercFloatData, 8 floats each
        std::vector<uint32_t> blercInts;
        std::vector<uint16_t> vertexLump4Addr;  // mod vertex -> index in unpacked game fragments
        std::vector<uint8_t> fragmentMask;      // fragments that hold mod vertices
        uint32_t expectVidxEnd = 0;
    };
    struct Model {
        std::string name;
        uint32_t maxBones;
        std::vector<Effect> effects;
        // Merc fragment unpack constants (tfrag3::MercModel), for game-updated vertices.
        uint32_t stVifAdd = 0;
        float xyzScale = 0.f;
        float stMagic = 0.f;
    };
    std::vector<Model> models;
    std::vector<id<MTLTexture>> textures;  // the level's textures (tree_tex_id order)
};
// Returns (and clears) the levels loaded since the last call. Thread-safe.
std::vector<std::shared_ptr<LoadedMercLevel>> TakeLoadedMercLevels();
// Returns (and clears) the names of levels unloaded since the last call. Apply these before
// TakeLoadedMercLevels' results: a level can be unloaded and then loaded again. Thread-safe.
std::vector<std::string> TakeUnloadedMercLevels();

// Driveable-boat stand-in coastline (Jak1Level-ios-coast.fr3z, built at import by Jak1CustomLevelBuilder from tools/coast/): drawn with village1's tfrag while
// enabled. The host sets it from GOAL *ios-coast-visible*. Thread-safe.
void SetCoastTerrainEnabled(bool enabled);

// Expanded Flut Flut option: keeps the flut saddle's Merc model (Jak1Level-ios-flut.fr3z, built at import by Jak1CustomLevelBuilder) loaded
// whatever level is active, since the flut art lives in the GOAL global heap. Thread-safe.
void SetExpandedFlutModelEnabled(bool enabled);

// Driveable Boat option: keeps the fisherman's boat Merc models (Jak1Level-ios-boat.fr3z, built at import by Jak1CustomLevelBuilder) loaded
// whatever level is active, since the boat art lives in the GOAL global heap. Thread-safe.
void SetResidentBoatModelEnabled(bool enabled);

// Fish in Ocean option: keeps the ocean fish Merc models (Jak1Level-ios-fish.fr3z, built at import by Jak1CustomLevelBuilder) loaded whatever
// level is active, since the fish art lives in the GOAL global heap. Thread-safe.
void SetResidentFishModelEnabled(bool enabled);

// Where the flut spawner's pad is drawn (pad top, game units); the host mirrors GOAL *ios-flut-pad*. Thread-safe.
void SetFlutPad(bool visible, float x, float y, float z);

// Expanded Green Eco option: keeps the vent ring (Jak1Level-ios-vents.fr3z, built at import by Jak1CustomLevelBuilder)
// loaded while enabled and draws it at each extra green vent (x y z w per vent, game units; drawn when w != 0).
// The host mirrors GOAL *ios-green-vent-props*. Thread-safe.
constexpr int kMaxGreenVentProps = 8;
void SetGreenVentProps(bool enabled, const float (&props)[kMaxGreenVentProps][4]);

class Background {
public:
    Background(id<MTLDevice> device, id<MTLLibrary> library);
    ~Background();

    // Jak 1 bucket ids this class draws.
    static const std::vector<int> &buckets();

    // Call once per frame before drawing, on the render thread: starts loads the game asked for
    // and unloads levels it no longer uses (Loader::update), including on iOS memory warnings.
    void beginFrame();

    // Draws one background bucket of this frame's DMA trace into `encoder`.
    // `bucketOffsets` holds the trace offset of each bucket (UINT32_MAX = not reached).
    void renderBucket(id<MTLRenderCommandEncoder> encoder,
                      int bucket,
                      const uint8_t *trace,
                      size_t traceLength,
                      const std::vector<uint32_t> &bucketOffsets);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

}  // namespace jak1
