#import "OpenGOALRuntimeBridge.h"
#import "Jak1MetalRenderer.h"
#import "Jak1Background.h"
#import "Jak1Ocean.h"
#import "Jak1AudioManager.h"
#include "Sound989/Jak1OverlordSound.h"
#import "Jak1MemoryCardManager.h"
#import "Jak1Kernel.h"

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#include <compression.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

#include "third-party/xdelta3/xdelta3.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <memory>
#include <mutex>
#include <sys/stat.h>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <unistd.h>
#include <vector>

extern "C" {
extern const uint8_t og_jak1_aot_signed_image_begin[];
extern const uint8_t og_jak1_aot_signed_image_end[];
extern const uint8_t og_jak1_level_code_begin[];
extern const uint8_t og_jak1_level_code_end[];
extern const uint8_t og_jak1_goal_nothing[];
extern const uint8_t og_jak1_goal_zero[];
extern const uint8_t og_jak1_native_thunks_begin[];
extern const uint8_t og_jak1_native_thunks_end[];
extern const uint8_t og_jak1_mips2c_setup_blerc[];
extern const uint8_t og_jak1_mips2c_ripple_execute_init[];
extern const uint8_t og_jak1_mips2c_ocean_interp_wave[];
extern const uint8_t og_jak1_mips2c_ocean_generate_verts[];
extern const uint8_t og_jak1_mips2c_sp_launch_particles_var[];
extern const uint8_t og_jak1_mips2c_particle_adgif[];
extern const uint8_t og_jak1_mips2c_sp_process_block_3d[];
extern const uint8_t og_jak1_mips2c_sp_process_block_2d[];
extern const uint8_t og_jak1_mips2c_adgif_shader_texture_with_update[];
extern const uint8_t og_jak1_mips2c_indexed_thunks_begin[];
extern const uint8_t og_jak1_mips2c_indexed_thunks_end[];
extern uint64_t og_jak1_mips2c_slot_table[];
uint32_t og_jak1_mips2c_link_all(uint32_t (*resolveSymbol)(const char *));
bool og_jak1_mips2c_registered(uint32_t index,
                               const char **name,
                               uint64_t (**execute)(void *),
                               uint32_t *stackSize);
void og_jak1_configure_mips2c(void *goalMemory,
                              void *signedCodeBase,
                              uint32_t blercGlobalsSymbol,
                              uint32_t fakeScratchpadSymbol,
                              uint32_t cosPolyVecSymbol,
                              uint32_t oceanWaveFramesSymbol,
                              uint32_t oceanWorkSymbol);
void og_jak1_configure_ocean_generate_verts(
    uint32_t oceanVu0WorkSymbol,
    uint32_t timeOfDayContextSymbol,
    uint32_t oceanVu0BlockSymbol,
    uint32_t uploadVu0ProgramSymbol,
    uint32_t vectorSymbol,
    uint32_t vuLightsLightGroupSymbol,
    uint32_t oceanGenerateVertsVectorSymbol);
void og_jak1_configure_sp_launch_particles_var(const uint32_t *symbols);
uint64_t og_jak1_call_goal_arm64(uint64_t a0,
                                  uint64_t a1,
                                  uint64_t a2,
                                  void *function,
                                  void *symbolTableGoalOffset,
                                  void *writableGoalBase,
                                  void *signedCodeBase);
uint64_t og_jak1_call_goal_on_stack_arm64(uint64_t stackTop,
                                           uint64_t unused0,
                                           uint64_t unused1,
                                           void *function,
                                           void *symbolTableGoalOffset,
                                           void *writableGoalBase,
                                           void *signedCodeBase);
uint64_t og_jak1_call_goal_on_stack_with_arg_arm64(uint64_t stackTop,
                                                    uint64_t a0,
                                                    uint64_t unused,
                                                    void *function,
                                                    void *symbolTableGoalOffset,
                                                    void *writableGoalBase,
                                                    void *signedCodeBase);
uint64_t og_jak1_call_goal_on_stack_with_args_arm64(uint64_t stackTop,
                                                     uint64_t a0,
                                                     uint64_t a1,
                                                     void *function,
                                                     void *symbolTableGoalOffset,
                                                     void *writableGoalBase,
                                                     void *signedCodeBase,
                                                     uint64_t a2);
uint64_t og_jak1_dispatch_native_helper(uint64_t index, const uint64_t *arguments);
}

uint64_t CallGoalFromNative(uint32_t function, uint64_t a0, uint64_t a1, uint64_t a2);
void NormalizePendingStateHandlers();

namespace {

constexpr uint32_t kGoalMemorySize = 128 * 1024 * 1024;
constexpr uintptr_t kFloatOnePointerOffset = 0x3F800000;
constexpr uint32_t kCapturedS7GoalOffset = 0x0018FE04;
constexpr uint32_t kCapturedCodeBaseOffset = 0x001C0000;
constexpr uint32_t kCapturedCodeImageSize = 34619392;
constexpr uint32_t kCapturedCodeRangeCount = 262;
constexpr uint32_t kCapturedKernelDispatcherGoalOffset = 0x001CAAB4;
// Prelinked level code (LevelCode/, tools/ios/aot_level_code_link.py) lives at this fixed GOAL
// range, just above the captured global heap. The native helper heap starts after it.
constexpr uint32_t kLevelCodeRegionBase = 0x03EBC000;
constexpr uint32_t kLevelCodeRegionLimit = 0x04800000;

class GoalBumpHeap {
public:
    bool initialize(uint32_t start, uint32_t end) {
        if (start >= end) {
            return false;
        }
        _start = start;
        _end = end;
        _cursor = start;
        return true;
    }

    uint32_t allocate(uint32_t size, uint32_t alignment) {
        if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
            return 0;
        }
        const uint64_t aligned = (_cursor + alignment - 1) & ~(static_cast<uint64_t>(alignment) - 1);
        const uint64_t end = aligned + size;
        if (aligned > UINT32_MAX || end > _end) {
            return 0;
        }
        _cursor = static_cast<uint32_t>(end);
        return static_cast<uint32_t>(aligned);
    }

    uint32_t capacity() const {
        return _end - _start;
    }

private:
    uint32_t _start = 0;
    uint32_t _end = 0;
    uint32_t _cursor = 0;
};

class GoalAddressSpace {
public:
    bool addRegion(uint32_t goalStart, NSMutableData *storage) {
        if (storage == nil || storage.length > UINT32_MAX) {
            return false;
        }
        const uint64_t end = static_cast<uint64_t>(goalStart) + storage.length;
        if (end > UINT32_MAX + 1ULL) {
            return false;
        }
        for (const Region &region : _regions) {
            const uint64_t regionEnd = static_cast<uint64_t>(region.goalStart) + region.length;
            if (goalStart < regionEnd && region.goalStart < end) {
                return false;
            }
        }
        _regions.push_back({goalStart, static_cast<uint32_t>(storage.length),
                            static_cast<uint8_t *>(storage.mutableBytes)});
        return true;
    }

    uint8_t *pointerForGoal(uint32_t goalOffset, uint32_t length) const {
        for (const Region &region : _regions) {
            if (goalOffset >= region.goalStart &&
                static_cast<uint64_t>(goalOffset) + length <=
                    static_cast<uint64_t>(region.goalStart) + region.length) {
                return region.bytes + (goalOffset - region.goalStart);
            }
        }
        return nullptr;
    }

    size_t regionCount() const {
        return _regions.size();
    }

private:
    struct Region {
        uint32_t goalStart;
        uint32_t length;
        uint8_t *bytes;
    };
    std::vector<Region> _regions;
};

struct NativeHelperContext {
    GoalAddressSpace *addressSpace = nullptr;
    GoalBumpHeap *heap = nullptr;
    uint32_t s7GoalOffset = 0x0014FD24;
    uint32_t drawableWidth = 0;
    uint32_t drawableHeight = 0;
    uint32_t controllerCount = 0;
    uint32_t language = 0;
    bool keyboardEnabled = false;
    bool waitingForBind = false;
    std::string contentPath;
    std::string settingsPath;
    float leftX = 0;
    float leftY = 0;
    float rightX = 0;
    float rightY = 0;
    // DualShock 2 button0 bits, active-high: OpenGOAL's scePadRead dropped the PS2 inversion and
    // pad.gc derives button0-rel (newly pressed) directly from these bits.
    std::atomic<uint16_t> buttons{0};
    // Buttons seen pressed since the last cpad-get-data, so a tap that starts and ends between two
    // GOAL frames (kernel thread runs independently of the UI) still reaches the game for one frame.
    std::atomic<uint16_t> latchedButtons{0};
    // Buttons whose touch went down since the last cpad-get-data. If that read already showed
    // the button down, it was released and pressed again in between: see cpad-get-data.
    std::atomic<uint16_t> pressEdges{0};
    std::unordered_map<std::string, uint32_t> symbols;
    // State constructors in prelinked level code can leave absent optional handlers as raw zero.
    // Track freshly allocated states so those fields can be normalized to GOAL #f after startup.
    std::vector<uint32_t> pendingStateObjects;
    struct PendingProcessReturn {
        uint32_t function;
        uint32_t pool;
        uint32_t process;
    };
    // A native helper must not recycle a process while its GOAL caller still has it in registers.
    std::vector<PendingProcessReturn> pendingProcessReturns;
    // Native kernel services for level loading (symbol interning, kheaps, linker, RPC-DGO).
    std::unique_ptr<jak1::Kernel> kernel;
    uint8_t *goalMemory = nullptr;
    uint32_t goalMemorySize = 0;
    uintptr_t signedCodeBase = 0;
    bool pressureSensitivity = true;
    bool triggerEffects = false;
    float axisScale = 1.33f;
    bool vsync = true;
    int32_t msaaSamples = 1;
    std::atomic<int32_t> displayRefreshRate{60};
    std::atomic<int32_t> targetFPS{60};
    // The game's title plays under the app's start screen (the game gets no input then).
    std::atomic<bool> titleAttract{false};
    // title-obs *ios-title-gate* is 'waiting: village loaded, the title is held on black.
    std::atomic<bool> titleIntroReady{false};
    // The app asked to start the held title (written to *ios-title-gate* on the kernel thread).
    std::atomic<bool> titleIntroReleaseRequested{false};
    // *target* is in target-title-wait: the title shows "press start".
    std::atomic<bool> titleWaitingForStart{false};
    // *progress-process* is live: the pause/progress menu is open.
    std::atomic<bool> menuOpen{false};
    // *target* is in a title state (target-title, -play, -wait): logo intro or "press start".
    std::atomic<bool> onTitleScreen{false};
    // Jak exists and the screen isn't faded to black (loading, blackout): the game is showing.
    std::atomic<bool> gameVisible{false};
    // A warp gate (teleporter) is choosing a destination: Left/Right pick, Circle warps.
    std::atomic<bool> warpGateActive{false};
    // A cutscene is playing (the game's movie?): only Pause is shown.
    std::atomic<bool> cutsceneActive{false};
    // Jak is riding the zoomer (a target-racing state other than getting off): R1 moves left.
    std::atomic<bool> onZoomer{false};
    // The active camera slave is in cam-string, which takes swipe camera movement directly.
    std::atomic<bool> directCameraLookAvailable{false};
    // The camera is in an aiming mode (first-person look, Billy's game) that the left stick drives.
    std::atomic<bool> cameraAimingMode{false};
    // Zero means the original iOS default: render at the capped native drawable size.
    std::atomic<int32_t> gameWidth{0};
    std::atomic<int32_t> gameHeight{0};
    // Graphics > Resolution choice, delivered (and restored from pc-settings) as the windowed
    // pc-set-window-size!. Matched against the scale list when the game resolution is set.
    int64_t selectedWindowWidth = 0;
    int64_t selectedWindowHeight = 0;
    uint64_t collisionMask = 0;
    bool screenshotRequested = false;
    bool removedDesktopGraphicsOptions = false;
    // iOS-ordered graphics option objects and the value-to-modify each one must keep.
    uint32_t iosGraphicsOptions[6] {};
    uint32_t iosGraphicsOptionTargets[6] {};
    uint32_t alwaysDisabledOptionFunction = 0;
    bool promotedInputOptions = false;
    uint32_t iosTitleOptions = 0;
    uint32_t iosGameOptions[9] {};
    uint32_t iosGameOptionTargets[7] {};
    bool capturedIOSGameOptionTargets = false;
    bool removedUnsupportedAspectRatios = false;
    bool removedDesktopInputOptions = false;
    // Misc options without Discord Rich Presence, and the targets of its two shifted rows.
    bool removedDiscordOption = false;
    uint32_t iosMiscOptions[4] {};
    uint32_t iosMiscOptionTargets[2] {};
    bool capturedIOSMiscOptionTargets = false;
    bool removedIOSControllerOptions = false;
    uint32_t iosTouchOptions[4] {};
    bool restoredIOSTouchOptions = false;
    std::atomic<bool> swipeCameraEnabled{true};
    std::atomic<bool> floatingRightJoystick{true};
    std::atomic<bool> floatingLeftJoystick{true};
    std::atomic<bool> hapticFeedback{true};
    bool installedIOSExperimentalOptions = false;
    uint32_t iosDriveableBoatOption = 0;  // reused Controller LED for Heat toggle
    uint32_t iosDriveableBoatValue = 0;   // GOAL boolean the toggle edits (host-allocated)
    uint32_t iosExpandedFlutOption = 0;   // reused Controller LED for HP toggle
    uint32_t iosExpandedFlutValue = 0;    // GOAL boolean the toggle edits (host-allocated)
    std::atomic<bool> expandedFlutEnabled{false};
    uint32_t iosDynamicSaveOption = 0;    // reused Ignore If Window Unfocused toggle
    uint32_t iosDynamicSaveValue = 0;     // GOAL boolean the toggle edits (host-allocated)
    std::atomic<bool> dynamicSaveEnabled{false};
    uint32_t iosOceanFishOption = 0;      // reused desktop Track Camera (mouse) toggle
    uint32_t iosOceanFishValue = 0;       // GOAL boolean the toggle edits (host-allocated)
    std::atomic<bool> oceanFishEnabled{false};
    // Fish in Ocean: the fish art groups resident in the global heap (once per session).
    std::atomic<bool> oceanFishArtLoaded{false};
    uint32_t iosExpandedGreenEcoOption = 0;  // reused Controller LED for Eco toggle
    uint32_t iosExpandedGreenEcoValue = 0;   // GOAL boolean the toggle edits (host-allocated)
    std::atomic<bool> expandedGreenEcoEnabled{false};
    uint32_t iosExperimentalMenuOld = 0;  // static *reassign-binds-options* array (4 rows)
    uint32_t iosExperimentalMenu = 0;     // host-allocated Experimental Options array replacing it
    // Pause menu Secrets > Dev Menu (host-allocated rows and arrays, see InstallIOSDevMenu).
    bool installedIOSDevMenu = false;
    uint32_t iosDevMenu = 0;              // Dev Menu options array (screen 45)
    uint32_t iosDevMenuGiveAllOption = 0; // its Give 100% Items button
    uint32_t iosDevMenuRow = 0;           // the Secrets row that opens it (grayed out)
    // Mirror mode (per save, see SyncMirrorMode): no longer a cheat, picked on the New Game screen.
    bool removedMirrorCheatOption = false;
    bool sessionMirrorMode = false;                 // the save being played (or about to be made)
    std::atomic<bool> mirrorModeActive{false};      // pc-settings cheats mirror bit, as last written
    std::atomic<bool> newGameMirrorVisible{false};  // the New Game slot screen shows the checkbox
    std::atomic<bool> newGameMirrorChecked{false};
    uint32_t fileSelectSlotsDrawn = 0;              // file-select slot lines formatted this frame
    // Expanded Flut Flut: flut code linked and flut art resident in the global heap (once per session).
    std::atomic<bool> expandedFlutLoaded{false};
    // Driveable Boat: the fisherman's boat art resident in the global heap (once per session).
    uint32_t residentBoatArt = 0;
    bool configuredIOSFrameRateOptions = false;
    bool renamedIOSFrameRateText = false;
    uint64_t soundFlava = 0;
    uint64_t soundFade = 0;
    uint32_t displayAlpha = 255;
    uint32_t gsIMR = 0;
    uint64_t lastDMAChain = 0;
    uint32_t lastDMABank = 0;
    uint64_t dmaSubmissionSerial = 0;
    uint64_t lastTextureUpload = 0;
    uint32_t lastTextureUploadMode = 0;
    uint64_t lastTextureRelocation = 0;
    uint64_t lastTextureRelocationSource = 0;
    uint32_t lastTextureRelocationFormat = 0;
    std::atomic<bool> shutdownRequested = false;
    uint32_t screenshotSettings = 0;
};

NativeHelperContext gNativeHelperContext;
std::vector<std::string> gStartupLevelCodeOverrides;
std::mutex gDMASubmissionMutex;

struct DmaChainCapture {
    struct VifCommand {
        uint32_t tagIndex;
        uint32_t slot;
        uint32_t word;
    };

    std::vector<uint8_t> bytes;
    // Trace byte offset where each Jak 1 bucket's chain begins (UINT32_MAX if never reached).
    // Buckets are the NEXT tags at buckets_base + 16 * id (OpenGLRenderer::dispatch_buckets_jak1).
    std::vector<uint32_t> bucketTraceOffsets;
    std::vector<VifCommand> vifCommands;
    uint32_t tagCount = 0;
    uint32_t payloadBytes = 0;
    uint32_t directCommandCount = 0;
    uint32_t unpackCommandCount = 0;
    uint32_t gifTagCount = 0;
    uint32_t gifADWrites = 0;
    uint32_t gifVertexWrites = 0;
    uint32_t gifImageBytes = 0;
    uint64_t fingerprint = 1469598103934665603ULL;
    bool ended = false;
    std::string error;
};

std::string DescribeVifCommands(const DmaChainCapture &capture) {
    std::string result;
    char description[128] {};
    for (const DmaChainCapture::VifCommand &command : capture.vifCommands) {
        const uint32_t kind = (command.word >> 24) & 0x7f;
        const uint32_t immediate = command.word & 0xffff;
        const uint32_t count = (command.word >> 16) & 0xff;
        const char *name = nullptr;
        if ((kind & 0x60) == 0x60) {
            name = "UNPACK";
            const uint32_t vectorSize = ((kind >> 2) & 0x3) + 1;
            const uint32_t elementFormat = kind & 0x3;
            const uint32_t unpackCount = count == 0 ? 256 : count;
            snprintf(description, sizeof(description),
                     "%s%s V%u-%s addr=0x%03x n=%u%s%s@t%u.%u",
                     result.empty() ? "" : ",", name,
                     vectorSize,
                     elementFormat == 0 ? "32" : elementFormat == 1 ? "16" :
                         elementFormat == 2 ? "8" : "5",
                     immediate & 0x3ff, unpackCount,
                     (immediate & 0x4000) != 0 ? " usn" : "",
                     (kind & 0x10) != 0 ? " mask" : "",
                     command.tagIndex, command.slot);
        } else if (kind == 0x14 || kind == 0x15) {
            name = kind == 0x14 ? "MSCAL" : "MSCALF";
            snprintf(description, sizeof(description), "%s%s 0x%03x@t%u.%u",
                     result.empty() ? "" : ",", name, immediate & 0x3ff,
                     command.tagIndex, command.slot);
        } else if (kind == 0x17) {
            name = "MSCNT";
            snprintf(description, sizeof(description), "%s%s@t%u.%u",
                     result.empty() ? "" : ",", name, command.tagIndex, command.slot);
        } else if (kind == 0x4a) {
            name = "MPG";
            snprintf(description, sizeof(description), "%s%s addr=0x%03x n=%u@t%u.%u",
                     result.empty() ? "" : ",", name, immediate & 0x3ff,
                     count == 0 ? 256 : count, command.tagIndex, command.slot);
        }
        if (name != nullptr) {
            result += description;
        }
    }
    return result.empty() ? "none" : result;
}

bool AnalyzeGifPacket(const uint8_t *bytes, uint32_t length, DmaChainCapture *capture) {
    if (bytes == nullptr || capture == nullptr) {
        return false;
    }
    uint32_t offset = 0;
    while (offset + 16 <= length) {
        uint64_t low = 0;
        uint64_t high = 0;
        memcpy(&low, bytes + offset, sizeof(low));
        memcpy(&high, bytes + offset + 8, sizeof(high));
        const uint32_t loopCount = static_cast<uint32_t>(low & 0x7fff);
        const uint32_t format = static_cast<uint32_t>((low >> 58) & 0x3);
        const uint32_t encodedRegisterCount = static_cast<uint32_t>((low >> 60) & 0xf);
        const uint32_t registerCount = encodedRegisterCount == 0 ? 16 : encodedRegisterCount;
        uint64_t dataQuadwords = 0;
        switch (format) {
            case 0: // PACKED
                dataQuadwords = static_cast<uint64_t>(loopCount) * registerCount;
                break;
            case 1: // REGLIST: one 64-bit register value per entry
                dataQuadwords = (static_cast<uint64_t>(loopCount) * registerCount + 1) / 2;
                break;
            case 2: // IMAGE
            case 3: // IMAGE2
                dataQuadwords = loopCount;
                capture->gifImageBytes += loopCount * 16;
                break;
        }
        const uint64_t packetLength = 16 + dataQuadwords * 16;
        if (packetLength > length - offset) {
            return false;
        }
        capture->gifTagCount++;
        if (format == 0) {
            for (uint32_t reg = 0; reg < registerCount; reg++) {
                const uint32_t descriptor = static_cast<uint32_t>((high >> (reg * 4)) & 0xf);
                if (descriptor == 0xe) { // A+D
                    capture->gifADWrites += loopCount;
                } else if (descriptor == 0x4 || descriptor == 0x5) { // XYZF2 / XYZ2
                    capture->gifVertexWrites += loopCount;
                }
            }
        }
        offset += static_cast<uint32_t>(packetLength);
    }
    return offset == length;
}

// Produces a linear trace of the DMA chain: every tag is followed by the payload it
// transferred. REF/REFE payloads are copied from their referenced GOAL address, so
// this is intentionally not a byte-for-byte copy of the chain's backing allocation.
// It is the stable input for the forthcoming VIF/GIF decoder.
// `diagnostics` additionally hashes every byte (fingerprint) and records VIF commands; both
// exist only for the first-ingestion log and are far too slow to run on every frame.
bool CaptureDMAChain(const GoalAddressSpace *addressSpace,
                     uint32_t startOffset,
                     DmaChainCapture *capture,
                     bool diagnostics) {
    constexpr uint32_t kMaxTags = 16384;
    constexpr uint32_t kMaxBytes = 4 * 1024 * 1024;
    if (addressSpace == nullptr || capture == nullptr) {
        return false;
    }

    constexpr uint32_t kJak1BucketCount = 70;
    const uint32_t bucketsBase = startOffset + 16;  // after the initial CALL to default regs
    capture->bucketTraceOffsets.assign(kJak1BucketCount, UINT32_MAX);
    uint32_t tagOffset = startOffset;
    uint32_t returnOffsets[2] {};
    uint32_t returnDepth = 0;
    while (capture->tagCount < kMaxTags) {
        uint8_t *tagBytes = addressSpace->pointerForGoal(tagOffset, 16);
        if (tagBytes == nullptr) {
            capture->error = "tag address is outside GOAL memory";
            return false;
        }
        if (tagOffset >= bucketsBase && (tagOffset - bucketsBase) % 16 == 0 &&
            (tagOffset - bucketsBase) / 16 < kJak1BucketCount) {
            uint32_t &bucketStart = capture->bucketTraceOffsets[(tagOffset - bucketsBase) / 16];
            if (bucketStart == UINT32_MAX) {
                bucketStart = static_cast<uint32_t>(capture->bytes.size());
            }
        }

        uint64_t tagWord = 0;
        memcpy(&tagWord, tagBytes, sizeof(tagWord));
        const uint32_t qwc = static_cast<uint32_t>(tagWord & 0xffff);
        const uint32_t kind = static_cast<uint32_t>((tagWord >> 28) & 0x7);
        const uint32_t address = static_cast<uint32_t>((tagWord >> 32) & 0x7fffffff);
        const uint64_t payloadLength64 = static_cast<uint64_t>(qwc) * 16;
        if (payloadLength64 > kMaxBytes || capture->bytes.size() + 16 + payloadLength64 > kMaxBytes) {
            capture->error = "chain exceeds the 4 MB capture limit";
            return false;
        }

        uint32_t payloadOffset = tagOffset + 16;
        uint32_t nextTagOffset = tagOffset + 16 + static_cast<uint32_t>(payloadLength64);
        bool completesChain = false;
        switch (kind) {
            case 0: // REFE
                payloadOffset = address;
                completesChain = true;
                break;
            case 1: // CNT
                break;
            case 2: // NEXT
                nextTagOffset = address;
                break;
            case 3: // REF
            case 4: // REFS
                payloadOffset = address;
                nextTagOffset = tagOffset + 16;
                break;
            case 5: // CALL
                if (returnDepth == 2) {
                    capture->error = "DMA CALL nesting exceeds two levels";
                    return false;
                }
                returnOffsets[returnDepth++] = nextTagOffset;
                nextTagOffset = address;
                break;
            case 6: // RET
                if (returnDepth == 0) {
                    capture->error = "DMA RET has no matching CALL";
                    return false;
                }
                nextTagOffset = returnOffsets[--returnDepth];
                break;
            case 7: // END
                completesChain = true;
                break;
            default:
                capture->error = "unknown DMA tag kind";
                return false;
        }

        uint8_t *payload = addressSpace->pointerForGoal(payloadOffset, static_cast<uint32_t>(payloadLength64));
        if (payload == nullptr) {
            capture->error = "payload address is outside GOAL memory";
            return false;
        }
        capture->bytes.insert(capture->bytes.end(), tagBytes, tagBytes + 16);
        capture->bytes.insert(capture->bytes.end(), payload, payload + payloadLength64);
        if (diagnostics) {
            for (uint32_t index = 0; index < 16; index++) {
                capture->fingerprint = (capture->fingerprint ^ tagBytes[index]) * 1099511628211ULL;
            }
            for (uint32_t index = 0; index < payloadLength64; index++) {
                capture->fingerprint = (capture->fingerprint ^ payload[index]) * 1099511628211ULL;
            }
        }
        uint32_t vif0 = 0;
        uint32_t vif1 = 0;
        memcpy(&vif0, tagBytes + 8, sizeof(vif0));
        memcpy(&vif1, tagBytes + 12, sizeof(vif1));
        const uint32_t vifKinds[] = {(vif0 >> 24) & 0x7f, (vif1 >> 24) & 0x7f};
        const uint32_t vifImmediates[] = {vif0 & 0xffff, vif1 & 0xffff};
        for (uint32_t vifIndex = 0; vifIndex < 2; vifIndex++) {
            const uint32_t vifKind = vifKinds[vifIndex];
            if (diagnostics && ((vifKind & 0x60) == 0x60 || vifKind == 0x14 || vifKind == 0x15 ||
                                vifKind == 0x17 || vifKind == 0x4a)) {
                capture->vifCommands.push_back({capture->tagCount, vifIndex,
                                                vifIndex == 0 ? vif0 : vif1});
            }
            capture->directCommandCount += vifKind == 0x50 || vifKind == 0x51;
            capture->unpackCommandCount += (vifKind & 0x60) == 0x60;
            if ((vifKind == 0x50 || vifKind == 0x51) &&
                vifImmediates[vifIndex] == qwc &&
                !AnalyzeGifPacket(payload, static_cast<uint32_t>(payloadLength64), capture)) {
                capture->error = "DIRECT payload contains a truncated GIF packet";
                return false;
            }
        }
        capture->tagCount++;
        capture->payloadBytes += static_cast<uint32_t>(payloadLength64);
        if (completesChain) {
            capture->ended = true;
            return true;
        }
        tagOffset = nextTagOffset;
    }
    capture->error = "chain exceeds the 16K-tag safety limit";
    return false;
}

uint64_t GoalBoolean(bool value) {
    return gNativeHelperContext.s7GoalOffset + (value ? 8 : 0);
}

const char *GoalString(uint32_t goalOffset) {
    if (gNativeHelperContext.addressSpace == nullptr || goalOffset == 0) {
        return nullptr;
    }
    return reinterpret_cast<const char *>(
        gNativeHelperContext.addressSpace->pointerForGoal(goalOffset + sizeof(uint32_t), 1)
    );
}

const char *GoalCString(uint32_t goalOffset) {
    if (gNativeHelperContext.addressSpace == nullptr || goalOffset == 0) {
        return nullptr;
    }
    return reinterpret_cast<const char *>(
        gNativeHelperContext.addressSpace->pointerForGoal(goalOffset, 1)
    );
}

bool ReadGoalValue(uint32_t goalOffset, void *value, uint32_t size);

const char *GoalSymbolName(uint32_t symbolOffset) {
    // jak1 info(sym) = sym + SYM_INFO_OFFSET (16384 * 8 - 4) -> {u32 hash, Ptr<String> str},
    // so the name pointer is at sym + 0x20000.
    uint32_t stringOffset = 0;
    if (!ReadGoalValue(symbolOffset + 0x20000, &stringOffset, sizeof(stringOffset)) ||
        stringOffset == 0) {
        return nullptr;
    }
    return GoalString(stringOffset);
}

bool WriteGoalValue(uint32_t goalOffset, const void *value, uint32_t size) {
    uint8_t *destination = gNativeHelperContext.addressSpace == nullptr ? nullptr :
        gNativeHelperContext.addressSpace->pointerForGoal(goalOffset, size);
    if (destination == nullptr) {
        return false;
    }
    memcpy(destination, value, size);
    return true;
}

bool ReadGoalValue(uint32_t goalOffset, void *value, uint32_t size) {
    uint8_t *source = gNativeHelperContext.addressSpace == nullptr ? nullptr :
        gNativeHelperContext.addressSpace->pointerForGoal(goalOffset, size);
    if (source == nullptr || value == nullptr) {
        return false;
    }
    memcpy(value, source, size);
    return true;
}

// game-option (basic): option-type u64 @ +4, name @ +12, scale, param1, param2, param3,
// then value-to-modify @ +32 (offsets from the object pointer, which follows the type tag).
constexpr uint32_t kGameOptionValueToModifyOffset = 32;

// Promote Input Options from Game Options to General Options. The captured boxed arrays have
// fixed capacities, so rotate their backing stores instead of writing past the eight-entry main
// array. This also keeps the Secrets and demo variants intact.
void PromoteIOSInputOptions() {
    if (gNativeHelperContext.promotedInputOptions) return;
    struct MenuArray {
        uint32_t symbol = 0;
        uint32_t storage = 0;
        int32_t length = 0;
        int32_t capacity = 0;
        uint32_t elementType = 0;
        std::vector<uint32_t> entries;
    };
    constexpr uint32_t kHeaderSize = 12;
    constexpr uint32_t kNameOffset = 12;
    auto readMenu = [&](const char *name, int32_t expectedLength, int32_t minimumCapacity,
                        const std::vector<uint32_t> &expectedNames, MenuArray *menu) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        if (symbol == gNativeHelperContext.symbols.end() || menu == nullptr) return false;
        menu->symbol = symbol->second;
        if (!ReadGoalValue(menu->symbol, &menu->storage, sizeof(menu->storage)) ||
            menu->storage == 0 || menu->storage == gNativeHelperContext.s7GoalOffset ||
            !ReadGoalValue(menu->storage, &menu->length, sizeof(menu->length)) ||
            !ReadGoalValue(menu->storage + 4, &menu->capacity, sizeof(menu->capacity)) ||
            !ReadGoalValue(menu->storage + 8, &menu->elementType, sizeof(menu->elementType)) ||
            menu->length != expectedLength || menu->capacity < minimumCapacity ||
            menu->elementType == 0 || expectedNames.size() != size_t(expectedLength)) return false;
        menu->entries.resize(expectedLength);
        if (!ReadGoalValue(menu->storage + kHeaderSize, menu->entries.data(),
                           uint32_t(menu->entries.size() * sizeof(uint32_t)))) return false;
        for (size_t index = 0; index < menu->entries.size(); index++) {
            uint32_t optionName = 0;
            if (menu->entries[index] == 0 ||
                !ReadGoalValue(menu->entries[index] + kNameOffset,
                               &optionName, sizeof(optionName)) ||
                optionName != expectedNames[index]) return false;
        }
        return true;
    };
    MenuArray titleOptionsMenu, titleMainMenu, mainMenu, secretsMenu, demoMenu, gameMenu, aspectMenu;
    if (!readMenu("*options*", 4, 4,
                  {0x0127, 0x0128, 0x0129, 0x013e}, &titleOptionsMenu) ||
        !readMenu("*main-options*", 7, 7,
                  {0x0127, 0x0128, 0x0129, 0x014b, 0x014c, 0x016f, 0x013e},
                  &titleMainMenu) ||
        !readMenu("*main-options-pc*", 8, 8,
                  {0x0127, 0x0128, 0x0129, 0x014b, 0x014c, 0x100e, 0x016f, 0x013e},
                  &mainMenu) ||
        !readMenu("*main-options-secrets*", 9, 9,
                  {0x0127, 0x0128, 0x0129, 0x014b, 0x014c, 0x100e, 0x1081, 0x016f, 0x013e},
                  &secretsMenu) ||
        !readMenu("*main-options-demo*", 4, 4,
                  {0x0127, 0x0128, 0x0129, 0x013e}, &demoMenu) ||
        !readMenu("*game-options-pc*", 10, 10,
                  {0x1600, 0x010f, 0x1078, 0x1079, 0x010d,
                   0x107a, 0x1042, 0x107b, 0x100f, 0x013e}, &gameMenu) ||
        !readMenu("*aspect-ratio-options*", 9, 9,
                  {0x103a, 0x103e, 0x103e, 0x103c, 0x103d,
                   0x103e, 0x103e, 0x103e, 0x013e}, &aspectMenu)) return;

    const std::vector<uint32_t> iosTitleMain = {
        titleMainMenu.entries[0], gameMenu.entries[0], titleMainMenu.entries[1],
        titleMainMenu.entries[2], titleMainMenu.entries[3], titleMainMenu.entries[4],
        titleMainMenu.entries[5], titleMainMenu.entries[6],
    };
    const std::vector<uint32_t> iosTitleOptions = {
        titleOptionsMenu.entries[0], // Game Options
        gameMenu.entries[0],         // Input Options
        titleOptionsMenu.entries[1], // Graphic Options
        titleOptionsMenu.entries[2], // Sound Options
        titleOptionsMenu.entries[3], // Back
    };
    const std::vector<uint32_t> iosMain = {
        mainMenu.entries[0], gameMenu.entries[0], mainMenu.entries[1], mainMenu.entries[2],
        mainMenu.entries[3], mainMenu.entries[4], mainMenu.entries[5], mainMenu.entries[6],
        mainMenu.entries[7],
    };
    const std::vector<uint32_t> iosSecrets = {
        secretsMenu.entries[0], gameMenu.entries[0], secretsMenu.entries[1],
        secretsMenu.entries[2], secretsMenu.entries[3], secretsMenu.entries[4],
        secretsMenu.entries[5], secretsMenu.entries[6], secretsMenu.entries[7],
        secretsMenu.entries[8],
    };
    const std::vector<uint32_t> iosGame(gameMenu.entries.begin() + 1, gameMenu.entries.end());
    const std::vector<uint32_t> iosAspect = {
        aspectMenu.entries[0], aspectMenu.entries[1], aspectMenu.entries[2], aspectMenu.entries[8],
    };
    auto writeMenu = [&](uint32_t storage, const std::vector<uint32_t> &entries) {
        const int32_t length = int32_t(entries.size());
        return WriteGoalValue(storage, &length, sizeof(length)) &&
            WriteGoalValue(storage + kHeaderSize, entries.data(),
                           uint32_t(entries.size() * sizeof(uint32_t)));
    };
    // pause main -> aspect(9), title main -> old pause main(8), title Options -> old title
    // main(7), demo -> old title Options(4), aspect -> old demo(4), secrets -> game(10),
    // and game -> old secrets(9).
    if (!writeMenu(aspectMenu.storage, iosMain) ||
        !writeMenu(mainMenu.storage, iosTitleMain) ||
        !writeMenu(titleMainMenu.storage, iosTitleOptions) ||
        !writeMenu(gameMenu.storage, iosSecrets) ||
        !writeMenu(secretsMenu.storage, iosGame) ||
        !writeMenu(demoMenu.storage, iosAspect) ||
        !writeMenu(titleOptionsMenu.storage, demoMenu.entries) ||
        !WriteGoalValue(titleOptionsMenu.symbol, &titleMainMenu.storage,
                        sizeof(titleMainMenu.storage)) ||
        !WriteGoalValue(titleMainMenu.symbol, &mainMenu.storage, sizeof(mainMenu.storage)) ||
        !WriteGoalValue(mainMenu.symbol, &aspectMenu.storage, sizeof(aspectMenu.storage)) ||
        !WriteGoalValue(secretsMenu.symbol, &gameMenu.storage, sizeof(gameMenu.storage)) ||
        !WriteGoalValue(gameMenu.symbol, &secretsMenu.storage, sizeof(secretsMenu.storage)) ||
        !WriteGoalValue(aspectMenu.symbol, &demoMenu.storage, sizeof(demoMenu.storage)) ||
        !WriteGoalValue(demoMenu.symbol, &titleOptionsMenu.storage,
                        sizeof(titleOptionsMenu.storage))) return;

    static_assert(std::size(gNativeHelperContext.iosGameOptions) == 9);
    memcpy(gNativeHelperContext.iosGameOptions, iosGame.data(),
           sizeof(gNativeHelperContext.iosGameOptions));
    gNativeHelperContext.iosTitleOptions = titleMainMenu.storage;
    gNativeHelperContext.removedUnsupportedAspectRatios = true;
    gNativeHelperContext.promotedInputOptions = true;
    NSLog(@"jakIOS: promoted Input Options into General Options");
}

// init-game-options caches *options* in *options-remap* before the host rotates the captured
// arrays. Update the cached settings-title entry as well as the symbol so the already-running
// title progress process displays the iOS list.
void SyncIOSTitleOptionsRemap() {
    if (!gNativeHelperContext.promotedInputOptions ||
        gNativeHelperContext.iosTitleOptions == 0) return;
    const auto remapSymbol = gNativeHelperContext.symbols.find("*options-remap*");
    if (remapSymbol == gNativeHelperContext.symbols.end()) return;
    uint32_t remap = 0;
    if (!ReadGoalValue(remapSymbol->second, &remap, sizeof(remap)) ||
        remap == 0 || remap == gNativeHelperContext.s7GoalOffset) return;
    constexpr uint32_t kArrayDataOffset = 12;
    constexpr uint32_t kSettingsTitleScreen = 0x1c;
    const uint32_t slot = remap + kArrayDataOffset + kSettingsTitleScreen * sizeof(uint32_t);
    uint32_t current = 0;
    if (ReadGoalValue(slot, &current, sizeof(current)) &&
        current != gNativeHelperContext.iosTitleOptions) {
        WriteGoalValue(slot, &gNativeHelperContext.iosTitleOptions,
                       sizeof(gNativeHelperContext.iosTitleOptions));
    }
}

// The Game Options initializer uses its original fixed indices. Once it has populated the shifted
// array, capture those seven value pointers from their temporary carriers and restore them to the
// corresponding retained rows every frame.
void RepairIOSGameOptionTargets() {
    if (!gNativeHelperContext.promotedInputOptions) return;
    if (!gNativeHelperContext.capturedIOSGameOptionTargets) {
        uint32_t targets[7] {};
        bool initialized = false;
        for (size_t index = 0; index < std::size(targets); index++) {
            ReadGoalValue(gNativeHelperContext.iosGameOptions[index + 1] +
                              kGameOptionValueToModifyOffset,
                          &targets[index], sizeof(targets[index]));
            initialized = initialized || targets[index] != 0;
        }
        if (!initialized) return;
        memcpy(gNativeHelperContext.iosGameOptionTargets, targets, sizeof(targets));
        gNativeHelperContext.capturedIOSGameOptionTargets = true;
    }
    for (size_t index = 0; index < std::size(gNativeHelperContext.iosGameOptionTargets); index++) {
        const uint32_t target = gNativeHelperContext.iosGameOptionTargets[index];
        WriteGoalValue(gNativeHelperContext.iosGameOptions[index] +
                           kGameOptionValueToModifyOffset,
                       &target, sizeof(target));
    }
}

// Rebuild the captured desktop graphics array into the exact order supported by iOS.
void RemoveIOSDesktopGraphicsOptions() {
    if (gNativeHelperContext.removedDesktopGraphicsOptions) return;
    const auto symbol = gNativeHelperContext.symbols.find("*graphic-options-pc*");
    uint32_t options = 0;
    int32_t length = 0;
    int32_t capacity = 0;
    uint32_t elementType = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) ||
        !ReadGoalValue(options + sizeof(length), &capacity, sizeof(capacity)) ||
        !ReadGoalValue(options + sizeof(length) + sizeof(capacity),
                       &elementType, sizeof(elementType)) ||
        length != 9 || capacity < length || elementType == 0) {
        return;
    }

    // The captured boxed array is length, capacity, element type, then nine object pointers:
    // Resolution, Display Mode, Display, V-Sync, Aspect Ratio, MSAA, Frame Rate,
    // PS2 Options, Back. Copy the retained pointers before rewriting in place.
    constexpr uint32_t kBoxedArrayDataOffset =
        sizeof(length) + sizeof(capacity) + sizeof(elementType);
    uint32_t desktopOptions[9] {};
    if (!ReadGoalValue(options + kBoxedArrayDataOffset,
                       desktopOptions, sizeof(desktopOptions))) return;
    constexpr uint32_t kGameOptionNameOffset = 12;
    constexpr uint32_t kExpectedNames[] = {
        0x1035, // Resolution
        0x1031, // Display Mode
        0x1043, // Display
        0x103b, // V-Sync
        0x0125, // Aspect Ratio
        0x1050, // MSAA
        0x1060, // Frame Rate
        0x1020, // PS2 Options
        0x013e, // Back
    };
    for (size_t index = 0; index < std::size(desktopOptions); index++) {
        uint32_t name = 0;
        if (desktopOptions[index] == 0 ||
            !ReadGoalValue(desktopOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedNames[index]) {
            return;
        }
    }
    constexpr uint32_t kGameOptionDisabledFunctionOffset = 36;
    ReadGoalValue(desktopOptions[2] + kGameOptionDisabledFunctionOffset,
                  &gNativeHelperContext.alwaysDisabledOptionFunction,
                  sizeof(gNativeHelperContext.alwaysDisabledOptionFunction));
    const uint32_t iosOptions[] = {
        desktopOptions[0], // Resolution
        desktopOptions[4], // Aspect Ratio
        desktopOptions[3], // V-Sync
        desktopOptions[5], // MSAA
        desktopOptions[6], // Frame Rate
        desktopOptions[8], // Back
    };
    if (!WriteGoalValue(options + kBoxedArrayDataOffset, iosOptions, sizeof(iosOptions))) return;
    const int32_t newLength = static_cast<int32_t>(std::size(iosOptions));
    WriteGoalValue(options, &newLength, sizeof(newLength));
    static_assert(std::size(iosOptions) == std::size(gNativeHelperContext.iosGraphicsOptions));
    memcpy(gNativeHelperContext.iosGraphicsOptions, iosOptions, sizeof(iosOptions));
    gNativeHelperContext.removedDesktopGraphicsOptions = true;
    NSLog(@"jakIOS: installed iOS graphics options order");
}

// The progress menu's init assigns value-to-modify by fixed desktop index (1 display mode,
// 3 V-Sync, 5 MSAA, 6 Frame Rate), so on the reordered array it wires the wrong rows: Frame
// Rate edits nothing (so confirming re-applies the old rate) and MSAA edits vsync?. Re-point
// every row after each kernel frame. The carousels edit *progress-carousell* int-backup (its
// first field); &vsync? is learned from the first init, which stores it in desktop slot 3.
void RepairIOSGraphicsOptionTargets() {
    if (!gNativeHelperContext.removedDesktopGraphicsOptions) return;
    enum { kResolution, kAspectRatio, kVSync, kMSAA, kFrameRate, kBack };
    uint32_t *targets = gNativeHelperContext.iosGraphicsOptionTargets;
    const auto carouselSymbol = gNativeHelperContext.symbols.find("*progress-carousell*");
    uint32_t intBackup = 0;
    if (carouselSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(carouselSymbol->second, &intBackup, sizeof(intBackup)) || intBackup == 0) {
        return;
    }
    targets[kMSAA] = intBackup;
    targets[kFrameRate] = intBackup;
    if (targets[kVSync] == 0) {
        uint32_t slot3 = 0;  // desktop index 3 is now the MSAA row
        ReadGoalValue(gNativeHelperContext.iosGraphicsOptions[kMSAA] + kGameOptionValueToModifyOffset,
                      &slot3, sizeof(slot3));
        if (slot3 == 0 || slot3 == intBackup) return;  // menu init hasn't run yet
        targets[kVSync] = slot3;
        NSLog(@"jakIOS: graphics options re-pointed (vsync? 0x%x, int-backup 0x%x)",
              slot3, intBackup);
    }
    for (size_t index = 0; index < std::size(gNativeHelperContext.iosGraphicsOptions); index++) {
        const uint32_t field =
            gNativeHelperContext.iosGraphicsOptions[index] + kGameOptionValueToModifyOffset;
        const uint32_t wanted = gNativeHelperContext.iosGraphicsOptionTargets[index];
        uint32_t current = 0;
        if (ReadGoalValue(field, &current, sizeof(current)) && current != wanted) {
            WriteGoalValue(field, &wanted, sizeof(wanted));
        }
    }
}

// Drop the Discord Rich Presence row from Miscellaneous Options (shared by the title and pause
// menus). Discord isn't available on iOS.
void RemoveIOSDiscordOption() {
    if (gNativeHelperContext.removedDiscordOption) return;
    const auto symbol = gNativeHelperContext.symbols.find("*misc-options*");
    uint32_t options = 0;
    int32_t length = 0;
    int32_t capacity = 0;
    uint32_t elementType = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) ||
        !ReadGoalValue(options + sizeof(length), &capacity, sizeof(capacity)) ||
        !ReadGoalValue(options + sizeof(length) + sizeof(capacity),
                       &elementType, sizeof(elementType)) ||
        length != 5 || capacity < length || elementType == 0) {
        return;
    }

    constexpr uint32_t kBoxedArrayDataOffset =
        sizeof(length) + sizeof(capacity) + sizeof(elementType);
    uint32_t miscOptions[5] {};
    if (!ReadGoalValue(options + kBoxedArrayDataOffset,
                       miscOptions, sizeof(miscOptions))) return;

    constexpr uint32_t kGameOptionNameOffset = 12;
    constexpr uint32_t kExpectedNames[] = {
        0x1011, // Money Starburst
        0x1030, // Discord Rich Presence
        0x1501, // Cutscene Skips
        0x1500, // Speedrunner Mode
        0x013e, // Back
    };
    for (size_t index = 0; index < std::size(miscOptions); index++) {
        uint32_t name = 0;
        if (miscOptions[index] == 0 ||
            !ReadGoalValue(miscOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedNames[index]) {
            return;
        }
    }

    const uint32_t iosOptions[] = {
        miscOptions[0], // Money Starburst
        miscOptions[2], // Cutscene Skips
        miscOptions[3], // Speedrunner Mode
        miscOptions[4], // Back
    };
    if (!WriteGoalValue(options + kBoxedArrayDataOffset, iosOptions, sizeof(iosOptions))) return;
    const int32_t newLength = static_cast<int32_t>(std::size(iosOptions));
    if (!WriteGoalValue(options, &newLength, sizeof(newLength))) return;
    static_assert(std::size(iosOptions) == std::size(gNativeHelperContext.iosMiscOptions));
    memcpy(gNativeHelperContext.iosMiscOptions, iosOptions, sizeof(iosOptions));
    gNativeHelperContext.removedDiscordOption = true;
    NSLog(@"jakIOS: removed Discord Rich Presence from misc options");
}

// init-game-options assigns misc value-to-modify by fixed desktop index (1 discord-rpc?,
// 2 skip-movies?, 3 speedrunner-mode?). On the shortened array, the row after each shifted row
// receives its intended target: learn those from the first init, then restore them every frame.
void RepairIOSMiscOptionTargets() {
    if (!gNativeHelperContext.removedDiscordOption) return;
    enum { kStarburst, kCutsceneSkips, kSpeedrunner, kBack };
    uint32_t *targets = gNativeHelperContext.iosMiscOptionTargets;
    if (!gNativeHelperContext.capturedIOSMiscOptionTargets) {
        uint32_t cutsceneTarget = 0;  // desktop index 2 is now the Speedrunner row
        uint32_t speedrunnerTarget = 0;  // desktop index 3 is now the Back row
        ReadGoalValue(gNativeHelperContext.iosMiscOptions[kSpeedrunner] +
                          kGameOptionValueToModifyOffset,
                      &cutsceneTarget, sizeof(cutsceneTarget));
        ReadGoalValue(gNativeHelperContext.iosMiscOptions[kBack] +
                          kGameOptionValueToModifyOffset,
                      &speedrunnerTarget, sizeof(speedrunnerTarget));
        if (cutsceneTarget == 0 || speedrunnerTarget == 0) return;  // menu init hasn't run yet
        targets[0] = cutsceneTarget;
        targets[1] = speedrunnerTarget;
        gNativeHelperContext.capturedIOSMiscOptionTargets = true;
    }
    const uint32_t wanted[] = {targets[0], targets[1], 0};
    const uint32_t rows[] = {
        gNativeHelperContext.iosMiscOptions[kCutsceneSkips],
        gNativeHelperContext.iosMiscOptions[kSpeedrunner],
        gNativeHelperContext.iosMiscOptions[kBack],
    };
    for (size_t index = 0; index < std::size(rows); index++) {
        const uint32_t field = rows[index] + kGameOptionValueToModifyOffset;
        uint32_t current = 0;
        if (ReadGoalValue(field, &current, sizeof(current)) && current != wanted[index]) {
            WriteGoalValue(field, &wanted[index], sizeof(wanted[index]));
        }
    }
}

// Limit the aspect-ratio submenu to the three modes supported in the iOS UI.
void RemoveUnsupportedIOSAspectRatios() {
    if (gNativeHelperContext.removedUnsupportedAspectRatios) return;
    const auto symbol = gNativeHelperContext.symbols.find("*aspect-ratio-options*");
    uint32_t options = 0;
    int32_t length = 0;
    int32_t capacity = 0;
    uint32_t elementType = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) ||
        !ReadGoalValue(options + sizeof(length), &capacity, sizeof(capacity)) ||
        !ReadGoalValue(options + sizeof(length) + sizeof(capacity),
                       &elementType, sizeof(elementType)) ||
        length != 9 || capacity < length || elementType == 0) {
        return;
    }

    constexpr uint32_t kBoxedArrayDataOffset =
        sizeof(length) + sizeof(capacity) + sizeof(elementType);
    uint32_t aspectOptions[9] {};
    if (!ReadGoalValue(options + kBoxedArrayDataOffset,
                       aspectOptions, sizeof(aspectOptions))) return;

    // Text IDs and ratio payloads from the captured objects identify entries 0, 1, and 2 as
    // Fit to Screen, 4x3, and 16x9. Back remains the final navigation row.
    constexpr uint32_t kGameOptionNameOffset = 12;
    constexpr uint32_t kExpectedNames[] = {
        0x103a, 0x103e, 0x103e, 0x103c, 0x103d, 0x103e, 0x103e, 0x103e, 0x013e,
    };
    for (size_t index = 0; index < std::size(aspectOptions); index++) {
        uint32_t name = 0;
        if (aspectOptions[index] == 0 ||
            !ReadGoalValue(aspectOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedNames[index]) {
            return;
        }
    }

    const uint32_t iosOptions[] = {
        aspectOptions[0], // Fit to Screen
        aspectOptions[1], // 4x3
        aspectOptions[2], // 16x9
        aspectOptions[8], // Back
    };
    if (!WriteGoalValue(options + kBoxedArrayDataOffset, iosOptions, sizeof(iosOptions))) return;
    const int32_t newLength = static_cast<int32_t>(std::size(iosOptions));
    if (!WriteGoalValue(options, &newLength, sizeof(newLength))) return;
    gNativeHelperContext.removedUnsupportedAspectRatios = true;
    NSLog(@"jakIOS: installed iOS aspect-ratio options");
}

// Replace the desktop-only input rows with a native Touch Options submenu. The reused desktop
// callbacks are incomplete on iOS, so SyncIOSTouchOptions persists their values separately.
void RemoveIOSDesktopInputOptions() {
    if (gNativeHelperContext.removedDesktopInputOptions) return;
    const auto symbol = gNativeHelperContext.symbols.find("*input-options*");
    uint32_t options = 0;
    int32_t length = 0;
    int32_t capacity = 0;
    uint32_t elementType = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) ||
        !ReadGoalValue(options + sizeof(length), &capacity, sizeof(capacity)) ||
        !ReadGoalValue(options + sizeof(length) + sizeof(capacity),
                       &elementType, sizeof(elementType)) ||
        length != 9 || capacity < length || elementType == 0) {
        return;
    }

    constexpr uint32_t kBoxedArrayDataOffset =
        sizeof(length) + sizeof(capacity) + sizeof(elementType);
    uint32_t inputOptions[9] {};
    if (!ReadGoalValue(options + kBoxedArrayDataOffset,
                       inputOptions, sizeof(inputOptions))) return;

    constexpr uint32_t kGameOptionNameOffset = 12;
    constexpr uint32_t kExpectedNames[] = {
        0x1000, // Camera Options
        0x160d, // Controller Options
        0x160e, // Enable Keyboard
        0x160f, // Enable Mouse
        0x1610, // Mouse Options
        0x1613, // Auto Hide Cursor
        0x1611, // Reassign Binds
        0x1007, // Restore Defaults
        0x013e, // Back
    };
    for (size_t index = 0; index < std::size(inputOptions); index++) {
        uint32_t name = 0;
        if (inputOptions[index] == 0 ||
            !ReadGoalValue(inputOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedNames[index]) {
            return;
        }
    }

    const auto touchMenuSymbol = gNativeHelperContext.symbols.find("*mouse-options*");
    uint32_t touchMenu = 0;
    int32_t touchMenuLength = 0;
    int32_t touchMenuCapacity = 0;
    uint32_t touchMenuType = 0;
    uint32_t desktopTouchOptions[6] {};
    if (touchMenuSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(touchMenuSymbol->second, &touchMenu, sizeof(touchMenu)) ||
        !ReadGoalValue(touchMenu, &touchMenuLength, sizeof(touchMenuLength)) ||
        !ReadGoalValue(touchMenu + sizeof(touchMenuLength),
                       &touchMenuCapacity, sizeof(touchMenuCapacity)) ||
        !ReadGoalValue(touchMenu + sizeof(touchMenuLength) + sizeof(touchMenuCapacity),
                       &touchMenuType, sizeof(touchMenuType)) ||
        touchMenuLength != 6 || touchMenuCapacity < touchMenuLength || touchMenuType == 0 ||
        !ReadGoalValue(touchMenu + kBoxedArrayDataOffset,
                       desktopTouchOptions, sizeof(desktopTouchOptions))) {
        return;
    }
    constexpr uint32_t kExpectedTouchMenuNames[] = {
        0x1606, 0x1607, 0x1608, 0x1609, 0x1007, 0x013e,
    };
    for (size_t index = 0; index < std::size(desktopTouchOptions); index++) {
        uint32_t name = 0;
        if (desktopTouchOptions[index] == 0 ||
            !ReadGoalValue(desktopTouchOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedTouchMenuNames[index]) {
            return;
        }
    }

    const uint32_t iosInputOptions[] = {
        inputOptions[0], // Camera Options
        inputOptions[1], // Controller Options
        inputOptions[4], // Touch Options (formerly Mouse Options)
        inputOptions[8], // Back
    };
    if (!WriteGoalValue(options + kBoxedArrayDataOffset,
                        iosInputOptions, sizeof(iosInputOptions))) return;
    const int32_t newInputLength = static_cast<int32_t>(std::size(iosInputOptions));
    if (!WriteGoalValue(options, &newInputLength, sizeof(newInputLength))) return;
    constexpr uint32_t kDisabledFunctionOffset = 36;
    const uint32_t enabled = 0;
    if (!WriteGoalValue(inputOptions[4] + kDisabledFunctionOffset,
                        &enabled, sizeof(enabled))) return;

    const uint32_t iosTouchOptions[] = {
        inputOptions[2],        // Swipe Camera (formerly Enable Keyboard)
        inputOptions[3],        // Floating Right Joystick (formerly Enable Mouse)
        inputOptions[5],        // Floating Left Joystick (formerly Auto Hide Cursor)
        // Haptic Feedback (formerly Player Movement). It stays at index 3, so progress init's
        // `*mouse-options* 3` assignment still gives it its own on/off target.
        desktopTouchOptions[3],
        desktopTouchOptions[5], // Back
    };
    if (!WriteGoalValue(touchMenu + kBoxedArrayDataOffset,
                        iosTouchOptions, sizeof(iosTouchOptions))) return;
    const int32_t newTouchLength = static_cast<int32_t>(std::size(iosTouchOptions));
    if (!WriteGoalValue(touchMenu, &newTouchLength, sizeof(newTouchLength))) return;
    memcpy(gNativeHelperContext.iosTouchOptions,
           iosTouchOptions, sizeof(gNativeHelperContext.iosTouchOptions));
    // The dropped Track Camera row becomes the Experimental Options > Fish in Ocean toggle.
    gNativeHelperContext.iosOceanFishOption = desktopTouchOptions[0];
    gNativeHelperContext.removedDesktopInputOptions = true;
    NSLog(@"jakIOS: installed iOS input and touch options");
}

// Remove desktop window-focus and controller-LED behaviors that do not apply on iOS.
void RemoveUnsupportedIOSControllerOptions() {
    if (gNativeHelperContext.removedIOSControllerOptions) return;
    const auto symbol = gNativeHelperContext.symbols.find("*controller-options*");
    uint32_t options = 0;
    int32_t length = 0;
    int32_t capacity = 0;
    uint32_t elementType = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) ||
        !ReadGoalValue(options + 4, &capacity, sizeof(capacity)) ||
        !ReadGoalValue(options + 8, &elementType, sizeof(elementType)) ||
        length != 11 || capacity < length || elementType == 0) return;

    constexpr uint32_t kBoxedArrayDataOffset = 12;
    constexpr uint32_t kGameOptionNameOffset = 12;
    uint32_t controllerOptions[11] {};
    if (!ReadGoalValue(options + kBoxedArrayDataOffset,
                       controllerOptions, sizeof(controllerOptions))) return;
    constexpr uint32_t kExpectedNames[] = {
        0x1601, // Select Controller
        0x010e, // Vibration
        0x1602, // Analog Deadzone
        0x1619, // Analog Sensitivity
        0x1603, // Ignore If Window Unfocused
        0x1604, // Controller LED for HP
        0x1605, // Controller LED for Eco
        0x1617, // Controller LED for Heat
        0x1618, // Pressure Sensitivity
        0x1007, // Restore Defaults
        0x013e, // Back
    };
    for (size_t index = 0; index < std::size(controllerOptions); index++) {
        uint32_t name = 0;
        if (controllerOptions[index] == 0 ||
            !ReadGoalValue(controllerOptions[index] + kGameOptionNameOffset,
                           &name, sizeof(name)) ||
            name != kExpectedNames[index]) return;
    }
    // Preserve the HP LED option object before the compacted iOS array overwrites its old slot.
    // Experimental Options reuses this object for the Expanded Flut Flut toggle.
    gNativeHelperContext.iosExpandedFlutOption = controllerOptions[5];
    // And Ignore If Window Unfocused: the Dynamic Save Points toggle.
    gNativeHelperContext.iosDynamicSaveOption = controllerOptions[4];
    // And Controller LED for Eco: the Expanded Green Eco toggle.
    gNativeHelperContext.iosExpandedGreenEcoOption = controllerOptions[6];

    const uint32_t iosControllerOptions[] = {
        controllerOptions[0], // Select Controller
        controllerOptions[1], // Vibration
        controllerOptions[2], // Analog Deadzone
        controllerOptions[3], // Analog Sensitivity
        controllerOptions[8], // Pressure Sensitivity
        controllerOptions[9], // Restore Defaults
        controllerOptions[10], // Back
    };
    if (!WriteGoalValue(options + kBoxedArrayDataOffset,
                        iosControllerOptions, sizeof(iosControllerOptions))) return;
    const int32_t newLength = static_cast<int32_t>(std::size(iosControllerOptions));
    if (!WriteGoalValue(options, &newLength, sizeof(newLength))) return;
    gNativeHelperContext.removedIOSControllerOptions = true;
    NSLog(@"jakIOS: removed unsupported iOS controller options");
}

static NSString *const kDriveableBoatDefaultsKey = @"experimental.driveableBoatEnabled";
static NSString *const kExpandedFlutDefaultsKey = @"experimental.expandedFlutEnabled";
static NSString *const kDynamicSaveDefaultsKey = @"experimental.dynamicSavePointsEnabled";
static NSString *const kOceanFishDefaultsKey = @"experimental.oceanFishEnabled";
static NSString *const kExpandedGreenEcoDefaultsKey = @"experimental.expandedGreenEcoEnabled";

// init-game-options caches *reassign-binds-options* in *options-remap*; if it already ran with the
// static array, point the cached slot at the host-allocated Experimental Options array.
void SyncIOSExperimentalMenuRemap() {
    if (gNativeHelperContext.iosExperimentalMenu == 0) return;
    const auto remapSymbol = gNativeHelperContext.symbols.find("*options-remap*");
    if (remapSymbol == gNativeHelperContext.symbols.end()) return;
    uint32_t remap = 0;
    if (!ReadGoalValue(remapSymbol->second, &remap, sizeof(remap)) ||
        remap == 0 || remap == gNativeHelperContext.s7GoalOffset) return;
    constexpr uint32_t kArrayDataOffset = 12;
    constexpr uint32_t kReassignBindsOptionsScreen = 42;  // progress-screen reassign-binds-options
    const uint32_t slot = remap + kArrayDataOffset + kReassignBindsOptionsScreen * sizeof(uint32_t);
    uint32_t current = 0;
    if (ReadGoalValue(slot, &current, sizeof(current)) &&
        current == gNativeHelperContext.iosExperimentalMenuOld) {
        WriteGoalValue(slot, &gNativeHelperContext.iosExperimentalMenu,
                       sizeof(gNativeHelperContext.iosExperimentalMenu));
    }
}

// Title-screen Options only (the pause menu's list is a different array): add an Experimental Options
// submenu with experimental toggles. Reuses rows iOS already dropped: Reassign Binds (a menu row
// that opens the reassign-binds-options screen, text 0x1611 relabelled EXPERIMENTAL OPTIONS),
// Controller LED for Heat/HP (on/off rows, relabelled DRIVEABLE BOAT/EXPANDED FLUT FLUT SPAWNING),
// Ignore If Window Unfocused (relabelled DYNAMIC SAVE POINTS),
// the desktop Track Camera mouse row (relabelled FISH IN OCEAN) and
// Controller LED for Eco (relabelled EXPANDED GREEN ECO).
// Back pops the screen stack, so it returns to the title Options list.
void InstallIOSExperimentalOptions() {
    if (gNativeHelperContext.installedIOSExperimentalOptions ||
        !gNativeHelperContext.promotedInputOptions ||
        !gNativeHelperContext.removedDesktopInputOptions ||
        !gNativeHelperContext.removedIOSControllerOptions ||
        gNativeHelperContext.iosTitleOptions == 0 || gNativeHelperContext.heap == nullptr) return;
    constexpr uint32_t kHeaderSize = 12;
    constexpr uint32_t kNameOffset = 12;
    constexpr uint32_t kDisabledFunctionOffset = 36;
    auto optionName = [](uint32_t option) -> uint32_t {
        uint32_t name = 0;
        if (option == 0 || !ReadGoalValue(option + kNameOffset, &name, sizeof(name))) return 0;
        return name;
    };
    auto arrayStorage = [](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        uint32_t storage = 0;
        if (symbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(symbol->second, &storage, sizeof(storage)) ||
            storage == gNativeHelperContext.s7GoalOffset) return 0;
        return storage;
    };
    auto slot = [](uint32_t storage, uint32_t index) -> uint32_t {
        uint32_t option = 0;
        if (storage == 0 ||
            !ReadGoalValue(storage + kHeaderSize + index * sizeof(uint32_t), &option, sizeof(option))) {
            return 0;
        }
        return option;
    };

    // Title Options: Game, Input, Graphic, Sound, Back (PromoteIOSInputOptions).
    const uint32_t titleOptions = gNativeHelperContext.iosTitleOptions;
    int32_t titleLength = 0;
    int32_t titleCapacity = 0;
    if (!ReadGoalValue(titleOptions, &titleLength, sizeof(titleLength)) ||
        !ReadGoalValue(titleOptions + 4, &titleCapacity, sizeof(titleCapacity)) ||
        titleLength != 5 || titleCapacity < 6) return;
    uint32_t titleEntries[5] {};
    for (uint32_t index = 0; index < 5; index++) titleEntries[index] = slot(titleOptions, index);
    if (optionName(titleEntries[4]) != 0x013e) return;

    // Leftover slots past the rewritten lengths still hold the dropped rows.
    const uint32_t experimentalRow = slot(arrayStorage("*input-options*"), 6);
    const uint32_t boatToggle = slot(arrayStorage("*controller-options*"), 7);
    const uint32_t expandedFlutToggle = gNativeHelperContext.iosExpandedFlutOption;
    const uint32_t dynamicSaveToggle = gNativeHelperContext.iosDynamicSaveOption;
    const uint32_t oceanFishToggle = gNativeHelperContext.iosOceanFishOption;
    const uint32_t greenEcoToggle = gNativeHelperContext.iosExpandedGreenEcoOption;
    const uint32_t submenu = arrayStorage("*reassign-binds-options*");
    int32_t submenuLength = 0;
    if (optionName(experimentalRow) != 0x1611 || optionName(boatToggle) != 0x1617 ||
        optionName(expandedFlutToggle) != 0x1604 ||
        optionName(dynamicSaveToggle) != 0x1603 || optionName(oceanFishToggle) != 0x1606 ||
        optionName(greenEcoToggle) != 0x1605 || submenu == 0 ||
        !ReadGoalValue(submenu, &submenuLength, sizeof(submenuLength)) || submenuLength != 4) return;
    const uint32_t submenuBack = slot(submenu, 3);
    if (optionName(submenuBack) != 0x013e) return;

    // The toggle edits a host-owned GOAL boolean, restored from the saved setting.
    const uint32_t value = gNativeHelperContext.heap->allocate(16, 16);
    const uint32_t expandedFlutValue = gNativeHelperContext.heap->allocate(16, 16);
    const uint32_t dynamicSaveValue = gNativeHelperContext.heap->allocate(16, 16);
    const uint32_t oceanFishValue = gNativeHelperContext.heap->allocate(16, 16);
    const uint32_t greenEcoValue = gNativeHelperContext.heap->allocate(16, 16);
    if (value == 0 || expandedFlutValue == 0 || dynamicSaveValue == 0 || oceanFishValue == 0 ||
        greenEcoValue == 0) return;
    const uint32_t savedValue = static_cast<uint32_t>(
        GoalBoolean([NSUserDefaults.standardUserDefaults boolForKey:kDriveableBoatDefaultsKey]));
    if (!WriteGoalValue(value, &savedValue, sizeof(savedValue))) return;
    const uint32_t savedExpandedFlutValue = static_cast<uint32_t>(
        GoalBoolean([NSUserDefaults.standardUserDefaults boolForKey:kExpandedFlutDefaultsKey]));
    if (!WriteGoalValue(expandedFlutValue, &savedExpandedFlutValue,
                        sizeof(savedExpandedFlutValue))) return;
    const uint32_t savedDynamicSaveValue = static_cast<uint32_t>(
        GoalBoolean([NSUserDefaults.standardUserDefaults boolForKey:kDynamicSaveDefaultsKey]));
    if (!WriteGoalValue(dynamicSaveValue, &savedDynamicSaveValue,
                        sizeof(savedDynamicSaveValue))) return;
    const uint32_t savedOceanFishValue = static_cast<uint32_t>(
        GoalBoolean([NSUserDefaults.standardUserDefaults boolForKey:kOceanFishDefaultsKey]));
    if (!WriteGoalValue(oceanFishValue, &savedOceanFishValue, sizeof(savedOceanFishValue))) return;
    const uint32_t savedGreenEcoValue = static_cast<uint32_t>(
        GoalBoolean([NSUserDefaults.standardUserDefaults boolForKey:kExpandedGreenEcoDefaultsKey]));
    if (!WriteGoalValue(greenEcoValue, &savedGreenEcoValue, sizeof(savedGreenEcoValue))) return;

    // Its LED predicate disables the row on iOS (no controller LED).
    const uint32_t enabled = 0;
    if (!WriteGoalValue(boatToggle + kDisabledFunctionOffset, &enabled, sizeof(enabled))) return;
    if (!WriteGoalValue(expandedFlutToggle + kDisabledFunctionOffset,
                        &enabled, sizeof(enabled))) return;
    if (!WriteGoalValue(dynamicSaveToggle + kDisabledFunctionOffset,
                        &enabled, sizeof(enabled))) return;
    if (!WriteGoalValue(greenEcoToggle + kDisabledFunctionOffset,
                        &enabled, sizeof(enabled))) return;
    // Its old on-change (set-ignore-controller-in-bg!) fights the toggle and flips it back off;
    // the LED rows have none.
    constexpr uint32_t kOnChangeOffset = 44;
    const uint32_t noOnChange = 0;
    if (!WriteGoalValue(dynamicSaveToggle + kOnChangeOffset,
                        &noOnChange, sizeof(noOnChange))) return;
    // Same for Track Camera (it set *pc-settings* mouse-camera?).
    if (!WriteGoalValue(oceanFishToggle + kDisabledFunctionOffset, &enabled, sizeof(enabled)) ||
        !WriteGoalValue(oceanFishToggle + kOnChangeOffset, &noOnChange, sizeof(noOnChange))) return;

    const uint32_t experimentalMenu[] = {
        boatToggle, expandedFlutToggle, dynamicSaveToggle, oceanFishToggle, greenEcoToggle, submenuBack,
    };
    const int32_t experimentalLength = static_cast<int32_t>(std::size(experimentalMenu));
    // The static reassign-binds array only holds 4 rows: build a bigger copy in the host heap
    // (basic type tag just before the object, then length, allocated-length, content type, data)
    // and point *reassign-binds-options* and its *options-remap* slot at it.
    constexpr uint32_t kBasicTypeTagSize = 4;
    uint32_t arrayTypeTag = 0;
    uint32_t contentType = 0;
    if (!ReadGoalValue(submenu - kBasicTypeTagSize, &arrayTypeTag, sizeof(arrayTypeTag)) ||
        !ReadGoalValue(submenu + 8, &contentType, sizeof(contentType))) return;
    const uint32_t experimentalBlock = gNativeHelperContext.heap->allocate(
        kBasicTypeTagSize + kHeaderSize + sizeof(experimentalMenu), 16);
    if (experimentalBlock == 0) return;
    const uint32_t experimentalStorage = experimentalBlock + kBasicTypeTagSize;
    if (!WriteGoalValue(experimentalBlock, &arrayTypeTag, sizeof(arrayTypeTag)) ||
        !WriteGoalValue(experimentalStorage, &experimentalLength, sizeof(experimentalLength)) ||
        !WriteGoalValue(experimentalStorage + 4, &experimentalLength, sizeof(experimentalLength)) ||
        !WriteGoalValue(experimentalStorage + 8, &contentType, sizeof(contentType)) ||
        !WriteGoalValue(experimentalStorage + kHeaderSize,
                        experimentalMenu, sizeof(experimentalMenu))) return;
    const auto submenuSymbol = gNativeHelperContext.symbols.find("*reassign-binds-options*");
    if (submenuSymbol == gNativeHelperContext.symbols.end() ||
        !WriteGoalValue(submenuSymbol->second, &experimentalStorage,
                        sizeof(experimentalStorage))) return;
    gNativeHelperContext.iosExperimentalMenuOld = submenu;
    gNativeHelperContext.iosExperimentalMenu = experimentalStorage;
    SyncIOSExperimentalMenuRemap();

    const uint32_t iosTitleOptions[] = {
        titleEntries[0], // Game Options
        titleEntries[1], // Input Options
        titleEntries[2], // Graphic Options
        titleEntries[3], // Sound Options
        experimentalRow, // Experimental Options
        titleEntries[4], // Back
    };
    const int32_t newTitleLength = static_cast<int32_t>(std::size(iosTitleOptions));
    if (!WriteGoalValue(titleOptions + kHeaderSize, iosTitleOptions, sizeof(iosTitleOptions)) ||
        !WriteGoalValue(titleOptions, &newTitleLength, sizeof(newTitleLength))) return;

    gNativeHelperContext.iosDriveableBoatOption = boatToggle;
    gNativeHelperContext.iosDriveableBoatValue = value;
    gNativeHelperContext.iosExpandedFlutOption = expandedFlutToggle;
    gNativeHelperContext.iosExpandedFlutValue = expandedFlutValue;
    gNativeHelperContext.expandedFlutEnabled.store(
        savedExpandedFlutValue == GoalBoolean(true), std::memory_order_relaxed);
    gNativeHelperContext.iosDynamicSaveOption = dynamicSaveToggle;
    gNativeHelperContext.iosDynamicSaveValue = dynamicSaveValue;
    gNativeHelperContext.dynamicSaveEnabled.store(
        savedDynamicSaveValue == GoalBoolean(true), std::memory_order_relaxed);
    gNativeHelperContext.iosOceanFishOption = oceanFishToggle;
    gNativeHelperContext.iosOceanFishValue = oceanFishValue;
    gNativeHelperContext.oceanFishEnabled.store(
        savedOceanFishValue == GoalBoolean(true), std::memory_order_relaxed);
    gNativeHelperContext.iosExpandedGreenEcoOption = greenEcoToggle;
    gNativeHelperContext.iosExpandedGreenEcoValue = greenEcoValue;
    gNativeHelperContext.expandedGreenEcoEnabled.store(
        savedGreenEcoValue == GoalBoolean(true), std::memory_order_relaxed);
    gNativeHelperContext.installedIOSExperimentalOptions = true;
    NSLog(@"jakIOS: installed Experimental Options (Driveable Boat %s, "
          @"Expanded Flut Flut %s, Dynamic Save Points %s, Fish in Ocean %s, Expanded Green Eco %s)",
          savedValue == GoalBoolean(true) ? "on" : "off",
          savedExpandedFlutValue == GoalBoolean(true) ? "on" : "off",
          savedDynamicSaveValue == GoalBoolean(true) ? "on" : "off",
          savedOceanFishValue == GoalBoolean(true) ? "on" : "off",
          savedGreenEcoValue == GoalBoolean(true) ? "on" : "off");
}

// The controller-options init writes &controller-led-heat? into the reused toggle by its old index,
// so point it back at our value every frame, and save changes.
void SyncIOSExperimentalOptions() {
    if (!gNativeHelperContext.installedIOSExperimentalOptions) return;
    SyncIOSExperimentalMenuRemap();
    constexpr uint32_t kValueToModifyOffset = 32;
    const uint32_t value = gNativeHelperContext.iosDriveableBoatValue;
    uint32_t current = 0;
    const uint32_t field = gNativeHelperContext.iosDriveableBoatOption + kValueToModifyOffset;
    if (ReadGoalValue(field, &current, sizeof(current)) && current != value) {
        WriteGoalValue(field, &value, sizeof(value));
    }
    uint32_t goalValue = 0;
    if (!ReadGoalValue(value, &goalValue, sizeof(goalValue))) return;
    const bool enabled = goalValue != gNativeHelperContext.s7GoalOffset;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kDriveableBoatDefaultsKey] == nil ||
        [defaults boolForKey:kDriveableBoatDefaultsKey] != enabled) {
        [defaults setBool:enabled forKey:kDriveableBoatDefaultsKey];
    }

    const uint32_t expandedFlutValue = gNativeHelperContext.iosExpandedFlutValue;
    const uint32_t expandedFlutField =
        gNativeHelperContext.iosExpandedFlutOption + kValueToModifyOffset;
    if (ReadGoalValue(expandedFlutField, &current, sizeof(current)) &&
        current != expandedFlutValue) {
        WriteGoalValue(expandedFlutField, &expandedFlutValue, sizeof(expandedFlutValue));
    }
    if (!ReadGoalValue(expandedFlutValue, &goalValue, sizeof(goalValue))) return;
    const bool expandedFlutEnabled = goalValue != gNativeHelperContext.s7GoalOffset;
    gNativeHelperContext.expandedFlutEnabled.store(expandedFlutEnabled, std::memory_order_relaxed);
    if ([defaults objectForKey:kExpandedFlutDefaultsKey] == nil ||
        [defaults boolForKey:kExpandedFlutDefaultsKey] != expandedFlutEnabled) {
        [defaults setBool:expandedFlutEnabled forKey:kExpandedFlutDefaultsKey];
    }

    const uint32_t dynamicSaveValue = gNativeHelperContext.iosDynamicSaveValue;
    const uint32_t dynamicSaveField =
        gNativeHelperContext.iosDynamicSaveOption + kValueToModifyOffset;
    if (ReadGoalValue(dynamicSaveField, &current, sizeof(current)) &&
        current != dynamicSaveValue) {
        WriteGoalValue(dynamicSaveField, &dynamicSaveValue, sizeof(dynamicSaveValue));
    }
    if (!ReadGoalValue(dynamicSaveValue, &goalValue, sizeof(goalValue))) return;
    const bool dynamicSaveEnabled = goalValue != gNativeHelperContext.s7GoalOffset;
    gNativeHelperContext.dynamicSaveEnabled.store(dynamicSaveEnabled, std::memory_order_relaxed);
    if ([defaults objectForKey:kDynamicSaveDefaultsKey] == nil ||
        [defaults boolForKey:kDynamicSaveDefaultsKey] != dynamicSaveEnabled) {
        [defaults setBool:dynamicSaveEnabled forKey:kDynamicSaveDefaultsKey];
    }

    const uint32_t oceanFishValue = gNativeHelperContext.iosOceanFishValue;
    const uint32_t oceanFishField = gNativeHelperContext.iosOceanFishOption + kValueToModifyOffset;
    if (ReadGoalValue(oceanFishField, &current, sizeof(current)) && current != oceanFishValue) {
        WriteGoalValue(oceanFishField, &oceanFishValue, sizeof(oceanFishValue));
    }
    if (!ReadGoalValue(oceanFishValue, &goalValue, sizeof(goalValue))) return;
    const bool oceanFishEnabled = goalValue != gNativeHelperContext.s7GoalOffset;
    gNativeHelperContext.oceanFishEnabled.store(oceanFishEnabled, std::memory_order_relaxed);
    if ([defaults objectForKey:kOceanFishDefaultsKey] == nil ||
        [defaults boolForKey:kOceanFishDefaultsKey] != oceanFishEnabled) {
        [defaults setBool:oceanFishEnabled forKey:kOceanFishDefaultsKey];
    }

    const uint32_t greenEcoValue = gNativeHelperContext.iosExpandedGreenEcoValue;
    const uint32_t greenEcoField =
        gNativeHelperContext.iosExpandedGreenEcoOption + kValueToModifyOffset;
    if (ReadGoalValue(greenEcoField, &current, sizeof(current)) && current != greenEcoValue) {
        WriteGoalValue(greenEcoField, &greenEcoValue, sizeof(greenEcoValue));
    }
    if (!ReadGoalValue(greenEcoValue, &goalValue, sizeof(goalValue))) return;
    const bool greenEcoEnabled = goalValue != gNativeHelperContext.s7GoalOffset;
    gNativeHelperContext.expandedGreenEcoEnabled.store(greenEcoEnabled, std::memory_order_relaxed);
    if ([defaults objectForKey:kExpandedGreenEcoDefaultsKey] == nil ||
        [defaults boolForKey:kExpandedGreenEcoDefaultsKey] != greenEcoEnabled) {
        [defaults setBool:greenEcoEnabled forKey:kExpandedGreenEcoDefaultsKey];
    }
}

// Experimental "Expanded Green Eco" option -> GOAL *ios-expanded-green-eco* (pc/ios/ios-green-eco.gc,
// a startup object). Written before every kernel frame; before the menu is installed the saved setting is used.
// GOAL answers with *ios-green-vent-props* (the extra green vents' positions), mirrored to the renderer, which
// draws the vent ring there.
void SyncExpandedGreenEcoOption() {
    static uint32_t symbol = 0;
    static uint32_t propsSymbol = 0;
    static uint32_t framesUntilRead = 0;
    const bool enabled = gNativeHelperContext.expandedGreenEcoEnabled.load(std::memory_order_relaxed);
    float props[jak1::kMaxGreenVentProps][4] {};
    if (propsSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-green-vent-props*");
        if (found != gNativeHelperContext.symbols.end()) propsSymbol = found->second;
    }
    uint32_t propsAddress = 0;
    if (enabled && propsSymbol != 0 && ReadGoalValue(propsSymbol, &propsAddress, sizeof(propsAddress)) &&
        propsAddress != 0 && propsAddress != gNativeHelperContext.s7GoalOffset &&
        !ReadGoalValue(propsAddress, props, sizeof(props))) {
        memset(props, 0, sizeof(props));
    }
    jak1::SetGreenVentProps(enabled, props);
    if (!gNativeHelperContext.installedIOSExperimentalOptions) {
        if (framesUntilRead == 0) {
            gNativeHelperContext.expandedGreenEcoEnabled.store(
                [NSUserDefaults.standardUserDefaults boolForKey:kExpandedGreenEcoDefaultsKey],
                std::memory_order_relaxed);
            framesUntilRead = 30;
        }
        framesUntilRead--;
    }
    if (symbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-expanded-green-eco*");
        if (found == gNativeHelperContext.symbols.end()) return;
        symbol = found->second;
    }
    const uint32_t value = static_cast<uint32_t>(GoalBoolean(enabled));
    WriteGoalValue(symbol, &value, sizeof(value));
}

// Experimental "Dynamic Save Points" option -> GOAL *ios-dynamic-save-points* (pc/ios/ios-dynamic-save.gc,
// a startup object). Written before every kernel frame; before the menu is installed (or when its value
// can't be read) the saved setting is used, so loading a save from the title already sees it.
void SyncDynamicSavePointsOption() {
    static uint32_t symbol = 0;
    static uint32_t framesUntilRead = 0;
    if (!gNativeHelperContext.installedIOSExperimentalOptions) {
        if (framesUntilRead == 0) {
            gNativeHelperContext.dynamicSaveEnabled.store(
                [NSUserDefaults.standardUserDefaults boolForKey:kDynamicSaveDefaultsKey],
                std::memory_order_relaxed);
            framesUntilRead = 30;
        }
        framesUntilRead--;
    }
    if (symbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-dynamic-save-points*");
        if (found == gNativeHelperContext.symbols.end()) return;
        symbol = found->second;
    }
    const uint32_t value = static_cast<uint32_t>(
        GoalBoolean(gNativeHelperContext.dynamicSaveEnabled.load(std::memory_order_relaxed)));
    WriteGoalValue(symbol, &value, sizeof(value));
}

// The collectibles menu's level list (get-next-level-up/down), calculate-completion's totals and
// make-levels-with-tasks-available-to-progress all walk (length *level-task-data*). The relinked
// progress-static still ends with the Eroded Coast entry, but the level is removed from this build
// (parked in Parked/ErodedCoast), so shrink the array's length by one to hide it from all three.
// The save's Eroded Coast state (level-opened, money-per-level, task and fly perms in *game-info*)
// is never touched.
void SyncErodedCoastProgressTotals() {
    constexpr int32_t kErodedCoastTaskDataIndex = 16;
    constexpr int32_t kLengthWithErodedCoast = kErodedCoastTaskDataIndex + 1;
    constexpr uint32_t kBoxedArrayAllocatedLengthOffset = 4;
    // progress (process) fields, offsets from the object pointer (deftype offset - 4).
    constexpr uint32_t kProgressDisplayLevelIndexOffset = 156;
    constexpr uint32_t kProgressNextLevelIndexOffset = 160;
    constexpr uint32_t kProgressTaskIndexOffset = 164;
    // game-info level-opened uint8[32] (deftype offset 116 - 4).
    constexpr uint32_t kGameInfoLevelOpenedOffset = 112;

    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbol = gNativeHelperContext.symbols.find("*level-task-data*");
    uint32_t taskDataArray = 0;
    int32_t length = 0;
    int32_t allocatedLength = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &taskDataArray, sizeof(taskDataArray)) ||
        taskDataArray == 0 || taskDataArray == s7 ||
        !ReadGoalValue(taskDataArray, &length, sizeof(length)) ||
        !ReadGoalValue(taskDataArray + kBoxedArrayAllocatedLengthOffset,
                       &allocatedLength, sizeof(allocatedLength)) ||
        allocatedLength != kLengthWithErodedCoast) {
        return;
    }

    const int32_t wanted = kErodedCoastTaskDataIndex;
    if (length != wanted && WriteGoalValue(taskDataArray, &wanted, sizeof(wanted))) {
        NSLog(@"jakIOS: Eroded Coast removed from collectibles menu and progress totals");
    }

    // A save that was last on Eroded Coast can leave the collectibles screen pointing at it. Move it
    // to the nearest opened level below, as get-next-level-down would.
    uint32_t progressPointer = 0;
    uint32_t progress = 0;
    int32_t displayLevel = 0;
    int32_t nextLevel = 0;
    const auto progressSymbol = gNativeHelperContext.symbols.find("*progress-process*");
    if (progressSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(progressSymbol->second, &progressPointer, sizeof(progressPointer)) ||
        progressPointer == 0 || progressPointer == s7 ||
        !ReadGoalValue(progressPointer, &progress, sizeof(progress)) ||
        progress == 0 || progress == s7 ||
        !ReadGoalValue(progress + kProgressDisplayLevelIndexOffset, &displayLevel, sizeof(displayLevel)) ||
        !ReadGoalValue(progress + kProgressNextLevelIndexOffset, &nextLevel, sizeof(nextLevel)) ||
        (displayLevel < kErodedCoastTaskDataIndex && nextLevel < kErodedCoastTaskDataIndex)) {
        return;
    }
    int32_t fallbackLevel = 0;
    uint32_t gameInfo = 0;
    const auto gameInfoSymbol = gNativeHelperContext.symbols.find("*game-info*");
    if (gameInfoSymbol != gNativeHelperContext.symbols.end() &&
        ReadGoalValue(gameInfoSymbol->second, &gameInfo, sizeof(gameInfo)) &&
        gameInfo != 0 && gameInfo != s7) {
        for (int32_t level = kErodedCoastTaskDataIndex - 1; level > 0; level--) {
            uint8_t opened = 0;
            if (ReadGoalValue(gameInfo + kGameInfoLevelOpenedOffset + level, &opened, sizeof(opened)) &&
                opened == 1) {
                fallbackLevel = level;
                break;
            }
        }
    }
    const int32_t firstTask = 0;
    WriteGoalValue(progress + kProgressDisplayLevelIndexOffset, &fallbackLevel, sizeof(fallbackLevel));
    WriteGoalValue(progress + kProgressNextLevelIndexOffset, &fallbackLevel, sizeof(fallbackLevel));
    WriteGoalValue(progress + kProgressTaskIndexOffset, &firstTask, sizeof(firstTask));
}

void SyncIOSTouchOptions() {
    if (!gNativeHelperContext.removedDesktopInputOptions) return;
    constexpr uint32_t kValueToModifyOffset = 32;
    constexpr uint32_t kDisabledFunctionOffset = 36;

    // progress init still assigns the old desktop indices: after our reorder it writes the
    // keyboard target into Touch Options and the mouse target into Back. Recover those two target
    // pointers and put them on the reused toggle objects.
    const auto inputSymbol = gNativeHelperContext.symbols.find("*input-options*");
    uint32_t inputArray = 0;
    uint32_t keyboardCarrier = 0;
    uint32_t mouseCarrier = 0;
    uint32_t keyboardTarget = 0;
    uint32_t mouseTarget = 0;
    constexpr uint32_t kBoxedArrayDataOffset = 12;
    if (inputSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(inputSymbol->second, &inputArray, sizeof(inputArray)) ||
        !ReadGoalValue(inputArray + kBoxedArrayDataOffset + 2 * sizeof(uint32_t),
                       &keyboardCarrier, sizeof(keyboardCarrier)) ||
        !ReadGoalValue(inputArray + kBoxedArrayDataOffset + 3 * sizeof(uint32_t),
                       &mouseCarrier, sizeof(mouseCarrier)) ||
        !ReadGoalValue(keyboardCarrier + kValueToModifyOffset,
                       &keyboardTarget, sizeof(keyboardTarget)) ||
        !ReadGoalValue(mouseCarrier + kValueToModifyOffset,
                       &mouseTarget, sizeof(mouseTarget)) ||
        keyboardTarget == 0 || mouseTarget == 0) {
        return;
    }
    WriteGoalValue(gNativeHelperContext.iosTouchOptions[0] + kValueToModifyOffset,
                   &keyboardTarget, sizeof(keyboardTarget));
    WriteGoalValue(gNativeHelperContext.iosTouchOptions[1] + kValueToModifyOffset,
                   &mouseTarget, sizeof(mouseTarget));

    static NSString *const kSwipeCameraKey = @"touchOptions.swipeCameraEnabled";
    static NSString *const kFloatingRightJoystickKey = @"touchOptions.floatingRightJoystickEnabled";
    static NSString *const kFloatingLeftJoystickKey = @"touchOptions.floatingLeftJoystickEnabled";
    static NSString *const kHapticFeedbackKey = @"touchOptions.hapticFeedbackEnabled";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *keys[] = {
        kSwipeCameraKey,
        kFloatingRightJoystickKey,
        kFloatingLeftJoystickKey,
        kHapticFeedbackKey,
    };
    if (!gNativeHelperContext.restoredIOSTouchOptions) {
        const bool fallbackValues[] = {true, true, true, true};
        for (size_t index = 0; index < std::size(gNativeHelperContext.iosTouchOptions); index++) {
            const bool savedValue = [defaults objectForKey:keys[index]] == nil ?
                fallbackValues[index] : [defaults boolForKey:keys[index]];
            const uint32_t goalValue = static_cast<uint32_t>(GoalBoolean(savedValue));
            uint32_t target = 0;
            if (ReadGoalValue(gNativeHelperContext.iosTouchOptions[index] + kValueToModifyOffset,
                              &target, sizeof(target)) && target != 0) {
                WriteGoalValue(target, &goalValue, sizeof(goalValue));
            }
        }
        gNativeHelperContext.restoredIOSTouchOptions = true;
    }

    bool values[4] {};
    for (size_t index = 0; index < std::size(gNativeHelperContext.iosTouchOptions); index++) {
        uint32_t target = 0;
        uint32_t value = 0;
        if (!ReadGoalValue(gNativeHelperContext.iosTouchOptions[index] + kValueToModifyOffset,
                           &target, sizeof(target)) || target == 0 ||
            !ReadGoalValue(target, &value, sizeof(value))) {
            return;
        }
        values[index] = value != gNativeHelperContext.s7GoalOffset;
    }
    gNativeHelperContext.swipeCameraEnabled.store(values[0], std::memory_order_relaxed);
    gNativeHelperContext.floatingRightJoystick.store(values[1], std::memory_order_relaxed);
    gNativeHelperContext.floatingLeftJoystick.store(values[2], std::memory_order_relaxed);
    gNativeHelperContext.hapticFeedback.store(values[3], std::memory_order_relaxed);
    for (size_t index = 0; index < std::size(values); index++) {
        if ([defaults objectForKey:keys[index]] == nil ||
            [defaults boolForKey:keys[index]] != values[index]) {
            [defaults setBool:values[index] forKey:keys[index]];
        }
    }

    // The captured Display predicate always returns true on iOS (display mode is windowed), so it
    // gives the native menu its normal gray/non-selectable treatment while swipe camera is active.
    const uint32_t disabledFunction = values[0] ?
        gNativeHelperContext.alwaysDisabledOptionFunction : 0;
    WriteGoalValue(gNativeHelperContext.iosTouchOptions[1] + kDisabledFunctionOffset,
                   &disabledFunction, sizeof(disabledFunction));
}

void ConfigureIOSFrameRateOptions() {
    if (!gNativeHelperContext.configuredIOSFrameRateOptions) {
        const auto carouselSymbol =
            gNativeHelperContext.symbols.find("*carousell-frame-rate-150fps*");
        uint32_t carousel = 0;
        int32_t length = 0;
        if (carouselSymbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(carouselSymbol->second, &carousel, sizeof(carousel)) &&
            carousel != 0 && carousel != gNativeHelperContext.s7GoalOffset &&
            ReadGoalValue(carousel, &length, sizeof(length)) && length == 3) {
            const int32_t twoOptions = 2;
            WriteGoalValue(carousel, &twoOptions, sizeof(twoOptions));
            gNativeHelperContext.configuredIOSFrameRateOptions = true;
        }
    }

    if (!gNativeHelperContext.renamedIOSFrameRateText) {
        const auto textSymbol = gNativeHelperContext.symbols.find("*common-text*");
        uint32_t textInfo = 0;
        int32_t length = 0;
        if (textSymbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(textSymbol->second, &textInfo, sizeof(textInfo)) ||
            textInfo == 0 || textInfo == gNativeHelperContext.s7GoalOffset ||
            !ReadGoalValue(textInfo, &length, sizeof(length)) || length <= 0 || length > 10000) {
            return;
        }
        constexpr uint32_t kGameTextDataOffset = 12;
        constexpr uint32_t kOneHundredFPSTextID = 0x1062;
        for (int32_t index = 0; index < length; index++) {
            uint32_t id = 0;
            uint32_t string = 0;
            const uint32_t entry = textInfo + kGameTextDataOffset + index * 8;
            if (!ReadGoalValue(entry, &id, sizeof(id)) ||
                !ReadGoalValue(entry + 4, &string, sizeof(string)) ||
                id != kOneHundredFPSTextID) {
                continue;
            }
            char *label = reinterpret_cast<char *>(
                gNativeHelperContext.addressSpace->pointerForGoal(string + sizeof(uint32_t), 4)
            );
            if (label != nullptr && strncmp(label, "100", 3) == 0) {
                memcpy(label, "120", 3);
                gNativeHelperContext.renamedIOSFrameRateText = true;
            }
            break;
        }
    }
}

// True if a warp-gate process is in its `active` state (choosing a destination). Walks the
// *active-pool* process tree like ParkLiveViewerProcesses.
bool IsWarpGateChoosing() {
    constexpr uint32_t kProcessTreeBrotherOffset = 12;
    constexpr uint32_t kProcessTreeChildOffset = 16;
    constexpr uint32_t kProcessStateOffset = 52;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto activePool = gNativeHelperContext.symbols.find("*active-pool*");
    const auto warpGateSymbol = gNativeHelperContext.symbols.find("warp-gate");
    uint32_t root = 0;
    uint32_t warpGateType = 0;
    if (activePool == gNativeHelperContext.symbols.end() || warpGateSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(activePool->second, &root, sizeof(root)) || root == 0 || root == s7 ||
        !ReadGoalValue(warpGateSymbol->second, &warpGateType, sizeof(warpGateType)) ||
        warpGateType == 0 || warpGateType == s7) {
        return false;  // warp-gate's type only exists while a village level is loaded
    }
    const auto deref = [s7](uint32_t slot) -> uint32_t {
        uint32_t node = 0;
        if (slot == 0 || slot == s7 || !ReadGoalValue(slot, &node, sizeof(node)) || node == s7) return 0;
        return node;
    };
    std::vector<uint32_t> pending {root};
    for (int visited = 0; !pending.empty() && visited < 4096; visited++) {
        const uint32_t node = pending.back();
        pending.pop_back();
        uint32_t type = 0, brother = 0, child = 0;
        if (node < 4 || !ReadGoalValue(node - 4, &type, sizeof(type)) ||
            !ReadGoalValue(node + kProcessTreeBrotherOffset, &brother, sizeof(brother)) ||
            !ReadGoalValue(node + kProcessTreeChildOffset, &child, sizeof(child))) {
            continue;
        }
        if (type == warpGateType) {
            uint32_t state = 0, stateName = 0;
            if (ReadGoalValue(node + kProcessStateOffset, &state, sizeof(state)) && state != 0 && state != s7 &&
                ReadGoalValue(state, &stateName, sizeof(stateName))) {
                const char *name = GoalSymbolName(stateName);
                if (name != nullptr && std::strcmp(name, "active") == 0) return true;
            }
        }
        if (const uint32_t next = deref(brother)) pending.push_back(next);
        if (const uint32_t next = deref(child)) pending.push_back(next);
    }
    return false;
}

void DisableViewerFallback();

// Runs every frame before GOAL. The iOS title (title-obs, iOS-modified prelinked level code) skips
// the Naughty Dog logo: target-title loads the village, sets *ios-title-gate* to 'waiting and holds
// on black until released with #t, then target-title-play runs the logo sequence and
// target-title-wait shows "press start".
void SyncTitleState() {
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolAddress = [](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol == gNativeHelperContext.symbols.end() ? 0 : symbol->second;
    };
    const uint32_t gateSymbol = symbolAddress("*ios-title-gate*");
    const uint32_t waitingSymbol = symbolAddress("waiting");
    uint32_t gate = 0;
    const bool gateWaiting = gateSymbol != 0 && waitingSymbol != 0 &&
        ReadGoalValue(gateSymbol, &gate, sizeof(gate)) && gate == waitingSymbol;
    // The title sets its gate while the village DGO is still streaming. Releasing it immediately
    // lets target-title-play perform its one-shot setup before the title actors and beach-vis are
    // linked, leaving the state waiting forever. Require several fully idle kernel frames so a
    // momentary gap between DGO requests cannot release the sequence early.
    static uint32_t idleTitleLoadFrames = 0;
    const bool dgoLoading = gNativeHelperContext.kernel != nullptr &&
        gNativeHelperContext.kernel->isDgoLoading();
    if (!gateWaiting || dgoLoading) {
        idleTitleLoadFrames = 0;
    } else if (idleTitleLoadFrames < 8) {
        idleTitleLoadFrames++;
    }
    const bool introReady = gateWaiting && idleTitleLoadFrames >= 8;
    // Some village entities can temporarily fall through to the desktop debug viewer while their
    // level code is still linking. Once all title loads are idle those viewers are never valid game
    // actors; leaving them alive lets them execute through freed animation data as the title removes
    // its setup entities. Retire them before the gate can advance to target-title-play.
    static bool retiredTitleViewers = false;
    if (!gateWaiting) {
        retiredTitleViewers = false;
    } else if (introReady && !retiredTitleViewers) {
        DisableViewerFallback();
        retiredTitleViewers = true;
    }
    if (introReady && gNativeHelperContext.titleIntroReleaseRequested.load(std::memory_order_relaxed)) {
        const uint32_t release = s7 + 8;  // jak1 #t = s7 + FIX_SYM_TRUE (8)
        WriteGoalValue(gateSymbol, &release, sizeof(release));
    }
    gNativeHelperContext.titleIntroReady.store(introReady, std::memory_order_relaxed);

    // Process state is at +52; a state's first field is its name symbol.
    const uint32_t targetSymbol = symbolAddress("*target*");
    uint32_t target = 0, state = 0, stateName = 0;
    const bool hasState = targetSymbol != 0 &&
        ReadGoalValue(targetSymbol, &target, sizeof(target)) && target != s7 && target != 0 &&
        ReadGoalValue(target + 52, &state, sizeof(state)) && state != 0 && state != s7 &&
        ReadGoalValue(state, &stateName, sizeof(stateName)) && stateName != 0;
    const uint32_t waitState = symbolAddress("target-title-wait");
    const bool waiting = hasState && waitState != 0 && stateName == waitState;
    gNativeHelperContext.titleWaitingForStart.store(waiting, std::memory_order_relaxed);
    const char *stateText = hasState ? GoalSymbolName(stateName) : nullptr;
    const bool onTitleScreen = stateText != nullptr && std::strncmp(stateText, "target-title", 12) == 0;
    gNativeHelperContext.onTitleScreen.store(onTitleScreen, std::memory_order_relaxed);

    // The zoomer (racer) drives Jak through target-racing-* states; the get-off states count as
    // off, so R1 goes back as soon as he starts to dismount.
    const bool onZoomer = stateText != nullptr && std::strncmp(stateText, "target-racing", 13) == 0 &&
        std::strncmp(stateText, "target-racing-get-off", 21) != 0;
    gNativeHelperContext.onZoomer.store(onZoomer, std::memory_order_relaxed);

    // Loading a game shows a black screen: the fade (*setting-control* current bg-a, or bg-a-force
    // during blackout-time) holds at 1.0 and Jak may not exist yet. The game counts as showing once
    // Jak exists and the fade starts lifting. setting-control: current (setting-data) inline @ +12
    // from the object pointer; bg-a @ +108 and bg-a-force @ +116 within it.
    const uint32_t settingControlSymbol = symbolAddress("*setting-control*");
    uint32_t settingControl = 0;
    float fade[3] {};  // bg-a, bg-a-speed, bg-a-force
    const bool faded = settingControlSymbol != 0 &&
        ReadGoalValue(settingControlSymbol, &settingControl, sizeof(settingControl)) &&
        settingControl != 0 && settingControl != s7 &&
        ReadGoalValue(settingControl + 12 + 108, fade, sizeof(fade)) &&
        std::max(fade[0], fade[2]) >= 0.95f;
    const bool hasTarget = target != 0 && target != s7;
    gNativeHelperContext.gameVisible.store(hasTarget && !faded, std::memory_order_relaxed);

    // movie? (main.gc): the movie bit (11) of *kernel-context* prevent-from-run, set for every
    // cutscene through the 'movie / 'process-mask settings. prevent-from-run is the first field.
    const uint32_t kernelContextSymbol = symbolAddress("*kernel-context*");
    uint32_t kernelContext = 0, preventFromRun = 0;
    const bool inCutscene = kernelContextSymbol != 0 &&
        ReadGoalValue(kernelContextSymbol, &kernelContext, sizeof(kernelContext)) &&
        kernelContext != 0 && kernelContext != s7 &&
        ReadGoalValue(kernelContext, &preventFromRun, sizeof(preventFromRun)) &&
        (preventFromRun & (1u << 11)) != 0;
    gNativeHelperContext.cutsceneActive.store(inCutscene, std::memory_order_relaxed);

    const uint32_t progressSymbol = symbolAddress("*progress-process*");
    uint32_t progress = 0;
    const bool menuOpen = progressSymbol != 0 &&
        ReadGoalValue(progressSymbol, &progress, sizeof(progress)) && progress != 0 && progress != s7;
    if (gNativeHelperContext.menuOpen.exchange(menuOpen, std::memory_order_relaxed) != menuOpen) {
        NSLog(@"jakIOS: progress menu %@ (*progress-process*=0x%x)", menuOpen ? @"open" : @"closed", progress);
    }

    // Warp gate destination picker (villagep-obs.gc warp-gate state `active`): it grabs Jak
    // (target-grab) and reads D-pad Left/Right. Only while Jak is grabbed, and only every few
    // frames, look through the active processes for a warp-gate in that state.
    static uint32_t warpScanCountdown = 0;
    const bool grabbed = stateText != nullptr && std::strcmp(stateText, "target-grab") == 0;
    if (!grabbed) {
        warpScanCountdown = 0;
        if (gNativeHelperContext.warpGateActive.exchange(false, std::memory_order_relaxed)) {
            NSLog(@"jakIOS: warp gate closed");
        }
    } else if (warpScanCountdown-- == 0) {
        warpScanCountdown = 5;
        const bool active = IsWarpGateChoosing();
        if (gNativeHelperContext.warpGateActive.exchange(active, std::memory_order_relaxed) != active) {
            NSLog(@"jakIOS: warp gate %@", active ? @"choosing a destination" : @"closed");
        }
    }
}

// Swipe camera movement from the app (main thread), applied on the kernel thread before each frame.
std::mutex gCameraLookMutex;
double gPendingCameraLookYaw = 0;   // degrees, positive = stick right
double gPendingCameraLookZoom = 0;  // view-off-param units, positive = stick up
bool gCameraLookTouching = false;   // a finger is on the swipe camera area

// cam-string's camera doesn't sit at its target (string-trans): it travels along a smoothing
// spline of past targets, at a speed that builds up while the player moves the camera. After a
// fast swipe that left the camera gliding on well after the thumb lifted. While a finger is down,
// collapse the spline onto the latest target each frame (tracking-spline-method-10), so the camera
// stays with the thumb and has nothing left to travel when it lifts.
void ResetCameraSlaveSpline(uint32_t slave) {
    // Offsets within camera-slave, verified against goalc output (field offset minus type tag).
    constexpr uint32_t kSlaveStringTrans = 476;
    constexpr uint32_t kSpline = 492;                   // position-spline: tracking-point[32], 48 bytes each
    constexpr uint32_t kPointStride = 48;
    constexpr uint32_t kPointNext = 36;
    constexpr uint32_t kSplineSummedLen = 2028;
    constexpr uint32_t kSplineFreePoint = 2032;
    constexpr uint32_t kSplineUsedPoint = 2036;
    constexpr uint32_t kSplinePartialPoint = 2040;
    constexpr uint32_t kSplineEndPoint = 2044;
    constexpr uint32_t kSplineNextToLastPoint = 2048;
    constexpr uint32_t kSplineMaxMove = 2052;
    constexpr uint32_t kSplineSampleLen = 2056;
    constexpr uint32_t kSplineUsedCount = 2060;
    constexpr uint32_t kSplineOldPosition = 2076;
    constexpr int32_t kNoPoint = -134250495;
    constexpr int32_t kPointCount = 32;

    float target[4] {};
    if (!ReadGoalValue(slave + kSlaveStringTrans, target, sizeof(target))) return;
    const float zero = 0;
    const int32_t noPoint = kNoPoint, one = 1, first = 0;
    WriteGoalValue(slave + kSpline, target, sizeof(target));
    WriteGoalValue(slave + kSpline + kPointNext, &noPoint, sizeof(noPoint));
    WriteGoalValue(slave + kSplineSummedLen, &zero, sizeof(zero));
    WriteGoalValue(slave + kSplineFreePoint, &one, sizeof(one));
    WriteGoalValue(slave + kSplineUsedPoint, &first, sizeof(first));
    WriteGoalValue(slave + kSplinePartialPoint, &zero, sizeof(zero));
    WriteGoalValue(slave + kSplineEndPoint, &first, sizeof(first));
    WriteGoalValue(slave + kSplineNextToLastPoint, &noPoint, sizeof(noPoint));
    WriteGoalValue(slave + kSplineMaxMove, &zero, sizeof(zero));
    WriteGoalValue(slave + kSplineSampleLen, &zero, sizeof(zero));
    WriteGoalValue(slave + kSplineUsedCount, &one, sizeof(one));
    WriteGoalValue(slave + kSplineOldPosition, target, sizeof(target));
    // Points 1...31 become the free list.
    for (int32_t point = 1; point < kPointCount; point++) {
        const int32_t next = point + 1 < kPointCount ? point + 1 : kNoPoint;
        WriteGoalValue(slave + kSpline + point * kPointStride + kPointNext, &next, sizeof(next));
    }
}

// Keeps Jak centred during fast pans. The camera's aim (the combiner's tracking matrix) turns
// toward Jak through slave-matrix-blend-2, which allows at most 2 degrees per 60 Hz frame (and a
// quarter of the remaining angle), so on a quick swipe the aim fell behind the camera's orbit and
// Jak slid off-centre. While the spline is pinned, next frame's camera position is known (the
// current string-trans), so turn the aim ahead of time by the angle the camera is about to orbit
// around Jak. A camera aimed at Jak that orbits him by an angle turns by that same angle; the
// blend is then left with only a small correction, well within its limit.
void PreRotateCombinerAim(uint32_t camera, uint32_t slave, uint32_t combiner) {
    // Offsets verified against goalc output (field offset minus type tag).
    constexpr uint32_t kSlaveTrans = 108;
    constexpr uint32_t kSlaveStringTrans = 476;
    constexpr uint32_t kMasterLocalDown = 300;
    constexpr uint32_t kMasterTposCurrAdj = 572;
    constexpr uint32_t kCombinerTrackingStatus = 252;
    constexpr uint32_t kCombinerTrackingInvMat = 268;  // matrix rows 0-2, 16 bytes apart
    constexpr double kMinOrbitRadius = 2048.0;         // half a meter; closer than that, leave it

    uint64_t trackingStatus = 0;
    float current[4] {}, next[4] {}, target[4] {}, down[4] {};
    // Status 1 = the combiner aims the camera itself (single slave, no blend between slaves).
    if (combiner == 0 ||
        !ReadGoalValue(combiner + kCombinerTrackingStatus, &trackingStatus, sizeof(trackingStatus)) ||
        trackingStatus != 1 ||
        !ReadGoalValue(slave + kSlaveTrans, current, sizeof(current)) ||
        !ReadGoalValue(slave + kSlaveStringTrans, next, sizeof(next)) ||
        !ReadGoalValue(camera + kMasterTposCurrAdj, target, sizeof(target)) ||
        !ReadGoalValue(camera + kMasterLocalDown, down, sizeof(down))) {
        return;
    }
    const auto dot = [](const double *a, const double *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; };
    const auto cross = [](const double *a, const double *b, double *out) {
        out[0] = a[1] * b[2] - a[2] * b[1];
        out[1] = a[2] * b[0] - a[0] * b[2];
        out[2] = a[0] * b[1] - a[1] * b[0];
    };
    double up[3] = {-down[0], -down[1], -down[2]};
    const double upLength = std::sqrt(dot(up, up));
    if (upLength < 0.5) return;
    for (double &component : up) component /= upLength;

    // Camera positions relative to Jak, flattened onto the ground plane.
    double from[3], to[3];
    for (int i = 0; i < 3; i++) {
        from[i] = current[i] - target[i];
        to[i] = next[i] - target[i];
    }
    const double fromUp = dot(from, up), toUp = dot(to, up);
    for (int i = 0; i < 3; i++) {
        from[i] -= up[i] * fromUp;
        to[i] -= up[i] * toUp;
    }
    if (std::sqrt(dot(from, from)) < kMinOrbitRadius || std::sqrt(dot(to, to)) < kMinOrbitRadius) return;
    double axis[3];
    cross(from, to, axis);
    const double angle = std::atan2(dot(up, axis), dot(from, to));
    if (std::fabs(angle) < 1e-5) return;

    // Rotate the aim's right/up/forward rows about the vertical by the same angle (Rodrigues).
    const double c = std::cos(angle), s = std::sin(angle);
    for (uint32_t row = 0; row < 3; row++) {
        float stored[4] {};
        const uint32_t address = combiner + kCombinerTrackingInvMat + row * 16;
        if (!ReadGoalValue(address, stored, sizeof(stored))) return;
        const double v[3] = {stored[0], stored[1], stored[2]};
        double upCrossV[3];
        cross(up, v, upCrossV);
        const double along = dot(up, v) * (1.0 - c);
        for (int i = 0; i < 3; i++) {
            stored[i] = static_cast<float>(v[i] * c + upCrossV[i] * s + up[i] * along);
        }
        WriteGoalValue(address, stored, sizeof(stored));
    }
}

// Runs every frame before GOAL. Swipe camera without the right stick's limits: the main
// third-person camera state (cam-string) has a "phony joystick" that cam-string-joystick uses in
// place of the right stick, with no dead zone and no top speed (the 'joystick event sets it;
// cam-string's code clears it after every frame). Writing it right before the frame turns the
// camera by exactly the swiped angle, however fast. Other camera states ignore it, so the app
// falls back to the emulated right stick when directCameraLookAvailable is false.
void SyncCameraLook() {
    // Field offsets: all-types.gc offset-assert minus the 4-byte basic type tag.
    constexpr uint32_t kProcessState = 52;
    constexpr uint32_t kMasterNumSlaves = 112;
    constexpr uint32_t kMasterSlave = 116;              // (pointer camera-slave) x2
    constexpr uint32_t kSlaveViewFlat = 444;
    constexpr uint32_t kSlaveHavePhonyJoystick = 2508;
    constexpr uint32_t kSlavePhonyJoystickX = 2512;
    constexpr uint32_t kSlavePhonyJoystickY = 2516;
    constexpr uint32_t kSlaveStringMinVal = 2524;
    constexpr uint32_t kSlaveStringMaxVal = 2540;
    constexpr uint32_t kDisplaySecondsPerFrame = 904;
    constexpr uint32_t kDisplayTimeAdjustRatio = 916;
    constexpr uint32_t kPCSettingsThirdCameraHInverted = 340;  // computed from pckernel-h.gc layout
    constexpr uint32_t kPCSettingsThirdCameraVInverted = 344;
    constexpr double kRotationUnitsPerDegree = 65536.0 / 360.0;
    constexpr double kPhonyRotationUnitsPerSecond = 21845.334;  // cam-string-joystick
    constexpr double kZoomStepFraction = 0.05;                   // cam-string-joystick's step cap

    double yaw = 0;
    double zoom = 0;
    bool touching = false;
    {
        std::lock_guard<std::mutex> lock(gCameraLookMutex);
        yaw = gPendingCameraLookYaw;
        gPendingCameraLookYaw = 0;
        zoom = gPendingCameraLookZoom;
        gPendingCameraLookZoom = 0;
        touching = gCameraLookTouching;
    }

    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        uint32_t value = 0;
        if (symbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(symbol->second, &value, sizeof(value)) || value == s7) {
            return 0;
        }
        return value;
    };
    const auto symbolAddress = [](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol == gNativeHelperContext.symbols.end() ? 0 : symbol->second;
    };

    // The newest slave is the one being blended to (slave 1 while two are active).
    const uint32_t camera = symbolValue("*camera*");
    int32_t slaveCount = 0;
    uint32_t slavePointer = 0, slave = 0, state = 0, stateName = 0;
    const bool hasSlaveState = camera != 0 &&
        ReadGoalValue(camera + kMasterNumSlaves, &slaveCount, sizeof(slaveCount)) &&
        slaveCount >= 1 && slaveCount <= 2 &&
        ReadGoalValue(camera + kMasterSlave + 4 * (slaveCount - 1), &slavePointer, sizeof(slavePointer)) &&
        slavePointer != 0 && slavePointer != s7 &&
        ReadGoalValue(slavePointer, &slave, sizeof(slave)) && slave != 0 && slave != s7 &&
        ReadGoalValue(slave + kProcessState, &state, sizeof(state)) && state != 0 && state != s7 &&
        ReadGoalValue(state, &stateName, sizeof(stateName)) && stateName != 0;
    const bool inCamString = hasSlaveState && stateName == symbolAddress("cam-string");
    // First-person look (target-look-around -> cam-eye) and Billy's shooting game (cam-billy) aim
    // with the left stick added to the right stick; swipes are switched off there.
    const bool aiming = hasSlaveState &&
        (stateName == symbolAddress("cam-eye") || stateName == symbolAddress("cam-billy"));
    gNativeHelperContext.cameraAimingMode.store(aiming, std::memory_order_relaxed);
    if (gNativeHelperContext.directCameraLookAvailable.exchange(inCamString, std::memory_order_relaxed) !=
        inCamString) {
        NSLog(@"jakIOS: swipe camera %@", inCamString ? @"direct (cam-string)" : @"via right stick");
    }

    // Swipe movement not yet played out. Touch samples and display frames don't line up with game
    // frames, so the raw per-frame amounts arrive in uneven bursts; easing them in over a few frames
    // turns that into a steady pan. After release the short tail plays out, then the camera stops.
    constexpr double kSmoothingSeconds = 0.045;
    static double smoothYaw = 0;
    static double smoothZoom = 0;
    static bool wasActive = false;
    if (!inCamString) {
        smoothYaw = 0;
        smoothZoom = 0;
        wasActive = false;
        return;
    }
    smoothYaw += yaw;
    smoothZoom += zoom;

    const uint32_t display = symbolValue("*display*");
    float secondsPerFrame = 0, timeAdjustRatio = 0;
    if (display == 0 ||
        !ReadGoalValue(display + kDisplaySecondsPerFrame, &secondsPerFrame, sizeof(secondsPerFrame)) ||
        !ReadGoalValue(display + kDisplayTimeAdjustRatio, &timeAdjustRatio, sizeof(timeAdjustRatio)) ||
        !(secondsPerFrame > 0 && secondsPerFrame < 0.2f) || !(timeAdjustRatio > 0 && timeAdjustRatio < 10)) {
        return;
    }

    const double ease = 1.0 - std::exp(-secondsPerFrame / kSmoothingSeconds);
    yaw = smoothYaw * ease;
    zoom = smoothZoom * ease;
    smoothYaw -= yaw;
    smoothZoom -= zoom;
    if (!touching) {
        // Finish the tail outright once it's too small to see.
        if (std::fabs(smoothYaw) < 0.05) {
            yaw += smoothYaw;
            smoothYaw = 0;
        }
        if (std::fabs(smoothZoom) < 0.0005) {
            zoom += smoothZoom;
            smoothZoom = 0;
        }
    }

    // While the swipe is in play (and once more after, so its last frame doesn't glide), pin the
    // camera to its target and keep its aim on Jak.
    const bool active = touching || yaw != 0 || zoom != 0 || smoothYaw != 0 || smoothZoom != 0;
    if (active || wasActive) {
        if (slaveCount == 1) {
            PreRotateCombinerAim(camera, slave, symbolValue("*camera-combiner*"));
        }
        ResetCameraSlaveSpline(slave);
    }
    wasActive = active;
    if (yaw == 0 && zoom == 0) return;

    // The right stick goes through the third-person invert settings and the phony joystick doesn't,
    // so apply them here to keep a swipe turning the same way as the stick. Both default to #t.
    bool horizontalInverted = true, verticalInverted = true;
    if (const uint32_t settings = symbolValue("*pc-settings*")) {
        uint32_t h = 0, v = 0;
        const auto isBoolean = [s7](uint32_t value) { return value == s7 || value == s7 + 8; };
        if (ReadGoalValue(settings + kPCSettingsThirdCameraHInverted, &h, sizeof(h)) &&
            ReadGoalValue(settings + kPCSettingsThirdCameraVInverted, &v, sizeof(v)) &&
            isBoolean(h) && isBoolean(v)) {
            horizontalInverted = h != s7;
            verticalInverted = v != s7;
        }
    }

    // Mirror mode flips the picture, so cpad-get-data flips the right stick to keep turning the
    // way the player sees it; do the same for the swipe.
    const bool mirrored = gNativeHelperContext.mirrorModeActive.load(std::memory_order_relaxed);
    if (mirrored) horizontalInverted = !horizontalInverted;

    // cam-string-joystick turns by 21845.334 * phony-joystick-x * seconds-per-frame.
    const double yawUnits = (horizontalInverted ? 1.0 : -1.0) * yaw * kRotationUnitsPerDegree;
    const float phonyX = static_cast<float>(yawUnits / (kPhonyRotationUnitsPerSecond * secondsPerFrame));

    // Zoom: f28 = phony-joystick-y / 20 moves view-off-param by f28 * time-adjust-ratio, but only
    // while f28 stays within 5% of the distance to the near/far limit; beyond that the game takes a
    // fixed 5% step. Stay inside so the swipe amount is exact, and carry the rest.
    float phonyY = 0;
    float viewFlat[4] {}, minVal[4] {}, maxVal[4] {};
    if (zoom != 0 &&
        ReadGoalValue(slave + kSlaveViewFlat, viewFlat, sizeof(viewFlat)) &&
        ReadGoalValue(slave + kSlaveStringMinVal, minVal, sizeof(minVal)) &&
        ReadGoalValue(slave + kSlaveStringMaxVal, maxVal, sizeof(maxVal)) &&
        maxVal[2] > minVal[2]) {
        // Stick up gives f28 < 0 with the default (inverted) setting.
        const double direction = verticalInverted ? -1.0 : 1.0;
        const double wanted = direction * zoom;  // change in view-off-param
        const double length = std::sqrt(viewFlat[0] * viewFlat[0] + viewFlat[1] * viewFlat[1] +
                                        viewFlat[2] * viewFlat[2]);
        const double current = std::clamp((length - minVal[2]) / (maxVal[2] - minVal[2]), 0.0, 1.0);
        const double limit = kZoomStepFraction * (wanted > 0 ? 1.0 - current : current) * timeAdjustRatio;
        const double delivered = std::clamp(wanted, -limit, limit);
        phonyY = static_cast<float>(20.0 * delivered / timeAdjustRatio);
        // Keep the remainder while the thumb is down and there's room to move; at a limit, or once
        // the thumb lifts, it's dropped so the camera doesn't keep zooming.
        if (touching && limit > 0.001) smoothZoom += (wanted - delivered) * direction;
    }

    const uint32_t phonyEnabled = s7 + 8;  // #t
    WriteGoalValue(slave + kSlavePhonyJoystickX, &phonyX, sizeof(phonyX));
    WriteGoalValue(slave + kSlavePhonyJoystickY, &phonyY, sizeof(phonyY));
    WriteGoalValue(slave + kSlaveHavePhonyJoystick, &phonyEnabled, sizeof(phonyEnabled));
}

// MARK: - Touch menu input
//
// With touch controls the progress menu (title menu and pause menu) is driven by taps and swipes
// instead of an on-screen pad. The progress code is captured AOT, so rather than changing it the
// host reads the menu's state, works out what a tap hit, and plays the matching pad presses
// (D-pad, Cross, Triangle, ...) into cpad-get-data over the next frames. Selecting a list row
// writes option-index directly; scrolling writes *progress-scroll* the way the D-pad does.
//
// Coordinates: text (font-context origins, draw-options rows) uses a 512 x 224 space and the
// menu's hud particles (pause screen button icons) a 512 x 448 space, both stretched over the
// whole game viewport.

// DualShock 2 button0 bits (active-high).
constexpr uint16_t kPadUp = 1 << 4;
constexpr uint16_t kPadRight = 1 << 5;
constexpr uint16_t kPadDown = 1 << 6;
constexpr uint16_t kPadLeft = 1 << 7;
constexpr uint16_t kPadStart = 1 << 3;
constexpr uint16_t kPadTriangle = 1 << 12;
constexpr uint16_t kPadCircle = 1 << 13;
constexpr uint16_t kPadCross = 1 << 14;
constexpr uint16_t kPadSquare = 1 << 15;

struct MenuTouchEvent {
    // Press: a finger went down (highlights what it's on); PressCancel: it turned into a swipe.
    enum class Kind { Press, PressCancel, Tap, Scroll, Horizontal, Back } kind;
    double x = 0;  // game viewport, 0...1
    double y = 0;
    int steps = 0;
    bool startsSwipe = false;  // Scroll / Horizontal: the swipe's first step
};

// Filled by the app (main thread), drained before each kernel frame.
std::mutex gMenuTouchMutex;
std::vector<MenuTouchEvent> gPendingMenuTouchEvents;

// Buttons the touch menu is holding during the current kernel frame (read by cpad-get-data).
std::atomic<uint16_t> gMenuInjectedButtons{0};
// The pause menu shows a collectible page (power cells / orbs / scout flies).
std::atomic<bool> gMenuOnCollectionPage{false};
// cpad-get-data calls so far. A kernel frame doesn't always read the pad, so injected presses are
// held (and released) for a number of reads rather than frames.
std::atomic<uint32_t> gPadReadCount{0};

// Kernel thread only.
struct MenuTouchPlayback {
    std::vector<uint16_t> presses;  // each pressed for one frame, then released for one
    bool releaseFrame = false;      // a press just ended: keep buttons up for one pad read
    uint16_t heldMask = 0;          // press being delivered
    uint32_t heldReads = 0;         // pad reads it must stay down for
    uint32_t phaseStartRead = 0;    // gPadReadCount when the press / release started
    int pendingPressFrames = 0;     // frames the front press has waited for the menu to settle
    int scrollRows = 0;             // option lists: rows to scroll (positive = later rows)
    int levelSteps = 0;             // pause screen: level step queued by a swipe (-1, 0 or 1)
    int32_t cellTarget = -1;        // power cell page: tapped cell to select, or -1
    // A tapped slider is moved by holding Left/Right until it reaches the tapped value, so the
    // option's own on-change logic runs.
    bool sliderActive = false;
    uint32_t sliderValueAddress = 0;
    float sliderTarget = 0;
    float sliderLastValue = 0;
    int sliderDirection = 0;
    int sliderStuckFrames = 0;
    int sliderFrames = 0;

    void clear() {
        presses.clear();
        releaseFrame = false;
        heldMask = 0;
        pendingPressFrames = 0;
        scrollRows = 0;
        levelSteps = 0;
        cellTarget = -1;
        sliderActive = false;
    }
};
MenuTouchPlayback gMenuTouchPlayback;

// Kernel thread only. While a finger is on a menu option (and briefly after the tap engages it)
// the option is selected and drawn with the stock yellow highlight, even with touch controls.
struct MenuPressHighlight {
    bool held = false;  // the finger is still down on the option
    std::chrono::steady_clock::time_point until {};  // after lifting: highlight until then

    bool active() const { return held || std::chrono::steady_clock::now() < until; }
    void clear() {
        held = false;
        until = {};
    }
};
MenuPressHighlight gMenuPressHighlight;

// progress (process) fields, offsets from the object pointer (deftype offset - 4).
constexpr uint32_t kProcessStateOffset = 52;
constexpr uint32_t kProgressDisplayStateOffset = 124;      // progress-screen (int64)
constexpr uint32_t kProgressNextDisplayStateOffset = 132;  // progress-screen (int64)
constexpr uint32_t kProgressOptionIndexOffset = 140;       // int32
constexpr uint32_t kProgressSelectedOptionOffset = 144;    // #f, or #t while editing a value
constexpr uint32_t kProgressInTransitionOffset = 168;      // symbol
constexpr uint32_t kProgressLeftXOffset = 216;             // left-x-offset int32
constexpr uint32_t kProgressDisplayStatePosOffset = 368;   // display-state-pos: menus to go back to
constexpr uint32_t kProgressTaskIndexOffset = 164;         // task-index: selected power cell
constexpr uint32_t kProgressParticlesOffset = 408;         // hud-particle[40] references
constexpr uint32_t kProgressParticleStateOffset = 568;     // particle-state int32[40]
constexpr uint32_t kParticleInitPosOffset = 12;            // hud-particle init-pos x, y (floats)
// game-option fields beyond value-to-modify.
constexpr uint32_t kGameOptionTypeOffset = 4;              // game-option-type (u64)
constexpr uint32_t kGameOptionParam1Offset = 20;           // slider minimum
constexpr uint32_t kGameOptionParam2Offset = 24;           // slider maximum
// *progress-scroll* (structure): transition float @0, start-index int16 @4, direction int8 @8.
constexpr uint32_t kProgressScrollTransitionOffset = 0;
constexpr uint32_t kProgressScrollStartOffset = 4;
constexpr uint32_t kProgressScrollDirectionOffset = 8;
// PROGRESS_PC_PAGE_HEIGHT: longer lists show 6 rows at a time and scroll.
constexpr int kProgressPageHeight = 7;
constexpr int kProgressVisibleRows = kProgressPageHeight - 1;

// progress-screen values (PC enum order).
enum ProgressScreen : int64_t {
    kScreenFuelCell = 0,
    kScreenMoney = 1,
    kScreenBuzzer = 2,
    kScreenLoadGame = 16,
    kScreenSaveGame = 17,
    kScreenSaveGameTitle = 18,
};

// game-option-type values (PC enum order).
enum GameOptionType : uint64_t {
    kOptionSlider = 0,
    kOptionLanguage = 1,
    kOptionOnOff = 2,
    kOptionAspectRatio = 4,
    kOptionYesNo = 7,
    kOptionNormalInverted = 9,
    kOptionDisplayMode = 10,
    kOptionMsaa = 11,
    kOptionFrameRate = 12,
    kOptionLodBg = 13,
    kOptionLodFg = 14,
    kOptionLanguageSubtitles = 17,
    kOptionLanguageText = 18,
    kOptionSpeaker = 19,
    kOptionAspectNative = 20,
    kOptionCheatToggle = 23,
    kOptionBindingAssignment = 26,
    kOptionConfirmation = 27,
};

// The (y, row spacing) each screen passes to draw-options (progress-normal's post handler in
// progress-pc.gc). Spacing 0 = every row is drawn at the same place (notice screens).
struct OptionsLayout {
    int y;
    int spacing;
};

OptionsLayout OptionsLayoutForScreen(int64_t screen) {
    switch (screen) {
        case 55: case 59: return {128, 21};                    // music / flava player
        case 64: return {155, 25};                             // speedrun options
        case 7: case 8: case 9: return {195, 0};               // memcard no space / not inserted
        case 10: return {172, 0};                              // memcard format
        case 11: return {168, 0};                              // memcard data exists
        case 22: case 26: return {192, 0};                     // memcard removed, auto-save error
        case 19: case 23: case 61: return {165, 0};            // insert, no data, auto-save disabled
        case 32: case 33: return {170, 0};                     // no disc, bad disc
        case 34: case 58: case 60: return {110, 0};            // quit, quit title, disable auto-save
        case 18: return {169, 15};                             // save game (title)
        case 16: case 17: case 20: case 21: case 24: case 25: case 29: case 30: case 31:
            return {190, 0};                                   // memcard errors, load/save game
        default: return {115, 25};                             // option lists
    }
}

// Converts a point normalized to the view into the game viewport, which keeps the
// pc-set-letterbox aspect centered in the view (see the renderer's gameViewport).
bool ViewPointToGameViewport(double x, double y, double viewAspect, double *gameX, double *gameY) {
    int32_t letterboxWidth = 0, letterboxHeight = 0;
    Jak1RendererGetLetterbox(&letterboxWidth, &letterboxHeight);
    if (letterboxWidth > 0 && letterboxHeight > 0 && viewAspect > 0) {
        const double gameAspect = static_cast<double>(letterboxWidth) / letterboxHeight;
        if (gameAspect < viewAspect) {
            const double fraction = gameAspect / viewAspect;
            x = (x - (1.0 - fraction) * 0.5) / fraction;
        } else {
            const double fraction = viewAspect / gameAspect;
            y = (y - (1.0 - fraction) * 0.5) / fraction;
        }
    }
    *gameX = x;
    *gameY = y;
    return x >= 0 && x <= 1 && y >= 0 && y <= 1;
}

// A snapshot of the progress menu, read before each kernel frame.
struct ProgressMenuState {
    uint32_t progress = 0;      // process object
    int64_t screen = -1;
    int64_t nextScreen = -1;
    int32_t optionIndex = 0;
    bool editing = false;       // selected-option: an option's value is being changed
    bool normal = false;        // in progress-normal (not coming in / going out)
    bool inTransition = false;
    int32_t leftXOffset = 0;
    int32_t backDepth = 0;      // display-state-pos: screens pushed above the first one
    bool paused = false;        // *master-mode* is 'progress: the in-game pause menu
    uint32_t options = 0;       // (array game-option) for this screen, 0 if none
    int32_t optionCount = 0;
    uint32_t scroll = 0;        // *progress-scroll*
    float scrollTransition = 1;
    int16_t scrollStart = 0;

    // The menu reads input: respond-common/respond-progress skip it during transitions and scrolls.
    bool acceptsInput() const {
        return normal && !inTransition && screen == nextScreen && scrollTransition >= 1.0f;
    }
    bool isCollectionScreen() const {
        return screen == kScreenFuelCell || screen == kScreenMoney || screen == kScreenBuzzer;
    }
    bool scrolls() const { return optionCount > kProgressPageHeight; }

    uint32_t option(int32_t index) const {
        uint32_t option = 0;
        if (options == 0 || index < 0 || index >= optionCount) return 0;
        ReadGoalValue(options + 12 + static_cast<uint32_t>(index) * 4, &option, sizeof(option));
        return option;
    }
    uint64_t optionType(int32_t index) const {
        uint64_t type = ~0ull;
        const uint32_t entry = option(index);
        if (entry != 0) ReadGoalValue(entry + kGameOptionTypeOffset, &type, sizeof(type));
        return type;
    }
};

bool ReadProgressMenuState(ProgressMenuState *menu) {
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    uint32_t progressPointer = 0;
    if (!symbolValue("*progress-process*", &progressPointer) ||
        !ReadGoalValue(progressPointer, &menu->progress, sizeof(menu->progress)) ||
        menu->progress == 0 || menu->progress == s7) {
        return false;
    }
    const uint32_t progress = menu->progress;
    uint32_t state = 0, stateName = 0, selected = s7, inTransition = s7;
    ReadGoalValue(progress + kProgressDisplayStateOffset, &menu->screen, sizeof(menu->screen));
    ReadGoalValue(progress + kProgressNextDisplayStateOffset, &menu->nextScreen, sizeof(menu->nextScreen));
    ReadGoalValue(progress + kProgressOptionIndexOffset, &menu->optionIndex, sizeof(menu->optionIndex));
    ReadGoalValue(progress + kProgressSelectedOptionOffset, &selected, sizeof(selected));
    ReadGoalValue(progress + kProgressInTransitionOffset, &inTransition, sizeof(inTransition));
    ReadGoalValue(progress + kProgressLeftXOffset, &menu->leftXOffset, sizeof(menu->leftXOffset));
    ReadGoalValue(progress + kProgressDisplayStatePosOffset, &menu->backDepth, sizeof(menu->backDepth));
    uint32_t masterMode = 0;
    const auto progressSymbol = gNativeHelperContext.symbols.find("progress");
    menu->paused = symbolValue("*master-mode*", &masterMode) &&
        progressSymbol != gNativeHelperContext.symbols.end() && masterMode == progressSymbol->second;
    menu->editing = selected != s7 && selected != 0;
    menu->inTransition = inTransition != s7 && inTransition != 0;
    if (ReadGoalValue(progress + kProcessStateOffset, &state, sizeof(state)) && state != 0 && state != s7 &&
        ReadGoalValue(state, &stateName, sizeof(stateName))) {
        const char *name = GoalSymbolName(stateName);
        menu->normal = name != nullptr && std::strcmp(name, "progress-normal") == 0;
    }

    uint32_t remap = 0;
    if (menu->screen >= 0 && menu->screen < 256 && symbolValue("*options-remap*", &remap)) {
        uint32_t options = 0;
        int32_t length = 0;
        if (ReadGoalValue(remap + 12 + static_cast<uint32_t>(menu->screen) * 4, &options, sizeof(options)) &&
            options != 0 && options != s7 && ReadGoalValue(options, &length, sizeof(length)) && length > 0) {
            menu->options = options;
            menu->optionCount = length;
        }
    }
    if (symbolValue("*progress-scroll*", &menu->scroll)) {
        ReadGoalValue(menu->scroll + kProgressScrollTransitionOffset, &menu->scrollTransition,
                      sizeof(menu->scrollTransition));
        ReadGoalValue(menu->scroll + kProgressScrollStartOffset, &menu->scrollStart, sizeof(menu->scrollStart));
    }
    return true;
}

void SetProgressOptionIndex(const ProgressMenuState &menu, int32_t index) {
    if (index == menu.optionIndex) return;
    WriteGoalValue(menu.progress + kProgressOptionIndexOffset, &index, sizeof(index));
}

// Pause screen: the Cross / Square / Triangle / Circle icons on the right switch to orbs / power
// cells / scout flies / options. Each icon's row (the icon plus the collectible count beside it)
// takes taps. Returns 0 if the tap missed them.
uint16_t CollectionButtonAt(const ProgressMenuState &menu, double gameX, double gameY) {
    struct Icon {
        uint32_t particle;
        uint16_t button;
    };
    static constexpr Icon kIcons[] = {
        {27, kPadCross},     // orbs
        {28, kPadSquare},    // power cells
        {29, kPadTriangle},  // scout flies
        {30, kPadCircle},    // options
    };
    const double x = gameX * 512.0;
    const double y = gameY * 448.0;
    uint16_t best = 0;
    double bestDistance = 40.0;  // half the ~75-unit spacing between the icons
    for (const Icon &icon : kIcons) {
        uint32_t particle = 0;
        float position[2] {};
        if (!ReadGoalValue(menu.progress + kProgressParticlesOffset + icon.particle * 4, &particle, sizeof(particle)) ||
            particle == 0 || particle == gNativeHelperContext.s7GoalOffset ||
            !ReadGoalValue(particle + kParticleInitPosOffset, position, sizeof(position)) ||
            position[0] < 0) {  // hidden icons sit at x = -320
            continue;
        }
        // From a little left of the icon to the right edge, which covers the collectible counts.
        if (x < position[0] - 40.0) continue;
        const double distance = std::fabs(y - position[1]);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = icon.button;
        }
    }
    return best;
}

// A tap while an option's value is being changed (selected-option). Taps on the option's row
// change the value; anywhere else confirms it (Back cancels).
void HandleEditingMenuTap(const ProgressMenuState &menu, double fontX, bool onRow, MenuTouchPlayback &playback) {
    const uint64_t type = menu.optionType(menu.optionIndex);
    if (type == kOptionBindingAssignment) return;  // waiting for a button; nothing to tap
    const double center = 202.0 - menu.leftXOffset;  // draw-options text box: x 17 + 370 / 2
    if (!onRow) {
        playback.presses.push_back(kPadCross);
        return;
    }
    switch (type) {
        case kOptionSlider: {
            // The bar is 255 wide starting at x 75 (draw-percent-bar).
            const uint32_t entry = menu.option(menu.optionIndex);
            uint32_t valueAddress = 0;
            float minimum = 0, maximum = 0, value = 0;
            if (entry == 0 ||
                !ReadGoalValue(entry + kGameOptionValueToModifyOffset, &valueAddress, sizeof(valueAddress)) ||
                !ReadGoalValue(entry + kGameOptionParam1Offset, &minimum, sizeof(minimum)) ||
                !ReadGoalValue(entry + kGameOptionParam2Offset, &maximum, sizeof(maximum)) ||
                !ReadGoalValue(valueAddress, &value, sizeof(value)) || maximum <= minimum) {
                return;
            }
            const double fraction = std::clamp((fontX - (75.0 - menu.leftXOffset)) / 255.0, 0.0, 1.0);
            const float target = static_cast<float>(minimum + fraction * (maximum - minimum));
            playback.sliderActive = true;
            playback.sliderValueAddress = valueAddress;
            playback.sliderTarget = target;
            playback.sliderLastValue = value;
            playback.sliderDirection = target > value ? 1 : -1;
            playback.sliderStuckFrames = 0;
            playback.sliderFrames = 0;
            return;
        }
        case kOptionOnOff:
        case kOptionAspectRatio:
        case kOptionNormalInverted:
        case kOptionAspectNative:
        case kOptionCheatToggle:
        case kOptionConfirmation:
            // Two choices side by side ("ON OFF", "YES NO", "4X3 16X9"): pick the tapped one and confirm.
            playback.presses.push_back(fontX < center ? kPadLeft : kPadRight);
            playback.presses.push_back(kPadCross);
            return;
        case kOptionLanguage:
        case kOptionDisplayMode:
        case kOptionMsaa:
        case kOptionFrameRate:
        case kOptionLodBg:
        case kOptionLodFg:
        case kOptionLanguageSubtitles:
        case kOptionLanguageText:
        case kOptionSpeaker:
            // Carousels show the current value centered between its neighbours: tap a neighbour to
            // turn to it, the value itself to confirm.
            if (fontX < center - 45.0) {
                playback.presses.push_back(kPadLeft);
            } else if (fontX > center + 45.0) {
                playback.presses.push_back(kPadRight);
            } else {
                playback.presses.push_back(kPadCross);
            }
            return;
        default:
            playback.presses.push_back(kPadCross);
            return;
    }
}

// Power cell page: the level's cells sit in a row, particles 6... (draw-fuel-cell-screen), 47
// units apart. Returns the tapped cell's task index, or -1 (missed, or a cell not revealed yet,
// which Left/Right never select either: particle-state 1).
int32_t PowerCellAt(const ProgressMenuState &menu, double gameX, double gameY) {
    constexpr uint32_t kFirstCellParticle = 6;
    constexpr uint32_t kMaxCells = 8;
    const double x = gameX * 512.0;
    const double y = gameY * 448.0;
    for (uint32_t i = 0; i < kMaxCells; i++) {
        uint32_t particle = 0;
        float position[2] {};
        int32_t particleState = 0;
        if (!ReadGoalValue(menu.progress + kProgressParticlesOffset + (kFirstCellParticle + i) * 4,
                           &particle, sizeof(particle)) ||
            particle == 0 || particle == gNativeHelperContext.s7GoalOffset ||
            !ReadGoalValue(particle + kParticleInitPosOffset, position, sizeof(position)) ||
            position[0] < 0) {  // unused slots sit at x = -320
            continue;
        }
        if (std::fabs(x - position[0]) > 23.5 || std::fabs(y - position[1]) > 40.0) continue;
        ReadGoalValue(menu.progress + kProgressParticleStateOffset + (kFirstCellParticle + i) * 4,
                      &particleState, sizeof(particleState));
        return particleState == 1 ? -1 : static_cast<int32_t>(i);
    }
    return -1;
}

bool IsFileSelectScreen(const ProgressMenuState &menu) {
    return menu.screen == kScreenLoadGame || menu.screen == kScreenSaveGame || menu.screen == kScreenSaveGameTitle;
}

// Option lists: rows `spacing` apart, centered on layout.y; long lists show a 6-row window.
struct OptionListRows {
    int lineCount;
    int firstVisible;
    double top;
};

OptionListRows OptionListRowsForMenu(const ProgressMenuState &menu, const OptionsLayout &layout) {
    const int lineCount = menu.scrolls() ? kProgressVisibleRows : menu.optionCount;
    const int firstVisible = menu.scrolls() ? std::max<int>(menu.scrollStart, 0) : 0;
    const double top = layout.y - (layout.spacing * lineCount) / 2;  // GOAL integer division
    return {lineCount, firstVisible, top};
}

constexpr double kMenuRowHeight = 25.0;  // draw-options text box height; rows are centered in it
constexpr double kMenuRowMargin = 6.0;

// The option a touch at this point picks on an option list, notice or load / save screen, or -1.
// Not for collection pages or while an option is being edited.
int32_t MenuOptionAt(const ProgressMenuState &menu, double gameX, double gameY) {
    if (menu.options == 0 || menu.isCollectionScreen()) return -1;
    const double fontY = gameY * 224.0;
    const OptionsLayout layout = OptionsLayoutForScreen(menu.screen);

    // Load / save: four memory card slots 41 high from y 26 (draw-memcard-file-select), then
    // the options draw-options lays out below them (Back, Continue without saving).
    if (IsFileSelectScreen(menu)) {
        int32_t index = -1;
        if (fontY >= 26.0 && fontY < 190.0) {
            index = static_cast<int32_t>((fontY - 26.0) / 41.0);
        } else if (fontY >= 190.0) {
            if (menu.screen == kScreenSaveGameTitle) {
                index = fontY < 204.0 ? 4 : 5;  // rows centered at 196.5 and 211.5
            } else {
                index = 4;
            }
        }
        return index >= 0 && index < menu.optionCount ? index : -1;
    }

    // Notice screens: one option (OK, or YES NO) drawn at a fixed height.
    if (layout.spacing == 0) {
        const int32_t index = std::clamp(menu.optionIndex, 0, menu.optionCount - 1);
        if (menu.optionType(index) == kOptionYesNo) {
            // Only taps near the choices, so a stray tap can't answer the question.
            if (std::fabs(fontY - (layout.y + kMenuRowHeight / 2)) > 30.0) return -1;
        }
        return index;
    }

    const OptionListRows rows = OptionListRowsForMenu(menu, layout);
    if (fontY < rows.top - kMenuRowMargin ||
        fontY >= rows.top + layout.spacing * rows.lineCount + kMenuRowMargin) {
        return -1;
    }
    const int row = std::clamp(static_cast<int>(std::floor((fontY - rows.top) / layout.spacing)), 0,
                               rows.lineCount - 1);
    const int32_t index = rows.firstVisible + row;
    return index < menu.optionCount ? index : -1;
}

void HandleMenuTap(const ProgressMenuState &menu, double gameX, double gameY, MenuTouchPlayback &playback) {
    if (menu.isCollectionScreen()) {
        if (const uint16_t button = CollectionButtonAt(menu, gameX, gameY)) {
            playback.presses.push_back(button);
        } else if (menu.screen == kScreenFuelCell) {
            const int32_t cell = PowerCellAt(menu, gameX, gameY);
            int32_t current = -1;
            ReadGoalValue(menu.progress + kProgressTaskIndexOffset, &current, sizeof(current));
            if (cell >= 0 && cell != current) playback.cellTarget = cell;
        }
        return;
    }
    if (menu.options == 0) return;

    const double fontX = gameX * 512.0;
    const OptionsLayout layout = OptionsLayoutForScreen(menu.screen);
    if (menu.editing && !IsFileSelectScreen(menu) && layout.spacing != 0) {
        // The edited row also draws its value just below its name (sliders: the bar), so it
        // reaches a little further down.
        const double fontY = gameY * 224.0;
        const OptionListRows rows = OptionListRowsForMenu(menu, layout);
        const double rowTop = rows.top + (menu.optionIndex - rows.firstVisible) * layout.spacing;
        const bool onRow = fontY >= rowTop - kMenuRowMargin && fontY < rowTop + kMenuRowHeight + 10.0;
        HandleEditingMenuTap(menu, fontX, onRow, playback);
        return;
    }

    // Selects the option and presses Cross on it (Yes/No rows: the tapped side first).
    const int32_t index = MenuOptionAt(menu, gameX, gameY);
    if (index < 0) return;
    SetProgressOptionIndex(menu, index);
    if (menu.optionType(index) == kOptionYesNo) {
        const double center = 202.0 - menu.leftXOffset;
        playback.presses.push_back(fontX < center ? kPadLeft : kPadRight);
    }
    playback.presses.push_back(kPadCross);
}

// Scrolls a long option list by whole rows, the way the D-pad does when the selection reaches the
// window's edge. One row animates; several (a fast swipe) jump. The highlighted option stays
// inside the window, or respond-common would snap the window back to it.
void ApplyMenuScroll(const ProgressMenuState &menu, MenuTouchPlayback &playback) {
    const int maxStart = menu.optionCount - kProgressVisibleRows;
    int start = menu.scrollStart;
    const int wanted = std::clamp(start + playback.scrollRows, 0, maxStart);
    playback.scrollRows = 0;
    if (wanted == start) return;
    const bool animate = std::abs(wanted - start) == 1;
    const int8_t direction = animate ? (wanted > start ? 1 : -1) : 0;
    const float transition = animate ? 0.0f : 1.0f;
    start = wanted;
    const int16_t newStart = static_cast<int16_t>(start);
    WriteGoalValue(menu.scroll + kProgressScrollStartOffset, &newStart, sizeof(newStart));
    WriteGoalValue(menu.scroll + kProgressScrollDirectionOffset, &direction, sizeof(direction));
    WriteGoalValue(menu.scroll + kProgressScrollTransitionOffset, &transition, sizeof(transition));
    SetProgressOptionIndex(menu, std::clamp(menu.optionIndex, start, start + kProgressVisibleRows - 1));
}

// Touch menus have no cursor to follow, so while touch controls are in use the menu's yellow
// "selected" text (font-color progress-selected) is drawn in the default color like every other
// row. draw_string reads colors from *font-work* color-table (char-color[64] @ 1984, 16 bytes
// each: four rgba corners); the stock entry is put back when a controller takes over.
std::atomic<bool> gTouchMenuStyle{false};

void SyncMenuHighlightStyle() {
    constexpr uint32_t kFontWorkColorTableOffset = 1984;
    constexpr uint32_t kCharColorSize = 16;
    constexpr uint32_t kFontColorDefault = 0;
    constexpr uint32_t kFontColorProgressSelected = 30;
    static uint8_t stockSelected[kCharColorSize];
    static bool savedStock = false;
    static bool applied = false;
    // A pressed option shows the stock highlight, so the finger can see what it picked.
    const bool wanted = gTouchMenuStyle.load(std::memory_order_relaxed) && !gMenuPressHighlight.active();
    if (wanted == applied) return;
    const auto symbol = gNativeHelperContext.symbols.find("*font-work*");
    uint32_t fontWork = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &fontWork, sizeof(fontWork)) ||
        fontWork == 0 || fontWork == gNativeHelperContext.s7GoalOffset) {
        return;
    }
    const uint32_t table = fontWork + kFontWorkColorTableOffset;
    const uint32_t selected = table + kFontColorProgressSelected * kCharColorSize;
    if (!savedStock) {
        if (!ReadGoalValue(selected, stockSelected, kCharColorSize)) return;
        savedStock = true;
    }
    uint8_t color[kCharColorSize];
    if (wanted) {
        if (!ReadGoalValue(table + kFontColorDefault * kCharColorSize, color, kCharColorSize)) return;
    } else {
        memcpy(color, stockSelected, kCharColorSize);
    }
    if (!WriteGoalValue(selected, color, kCharColorSize)) return;
    applied = wanted;
}

// Runs every frame after GOAL. On the title screen with touch controls in use, the English
// "PRESS START" (target-title-wait draws (text-id press-start) from *common-text*) is swapped for
// "TAP TO START" by pointing its game-text entry at a host-made GOAL string; the stock string is
// put back when a controller connects or the title is left. Other languages keep their own text.
// Calls a GOAL function between GOAL frames on the arena stack (CallGoalFromNative uses the native
// stack and is only safe inside a GOAL frame). Must run on the kernel queue.
uint64_t CallGoalOnArenaStack(uint32_t function, uint64_t a0, uint64_t a1, uint64_t a2) {
    if (gNativeHelperContext.goalMemory == nullptr || gNativeHelperContext.signedCodeBase == 0) return 0;
    constexpr uint32_t goalStackTopOffset = 4096;
    const uint64_t result = og_jak1_call_goal_on_stack_with_args_arm64(
        reinterpret_cast<uintptr_t>(gNativeHelperContext.goalMemory) +
            gNativeHelperContext.goalMemorySize - goalStackTopOffset,
        a0, a1, reinterpret_cast<void *>(gNativeHelperContext.signedCodeBase + function),
        reinterpret_cast<void *>(static_cast<uintptr_t>(gNativeHelperContext.s7GoalOffset)),
        gNativeHelperContext.goalMemory, reinterpret_cast<void *>(gNativeHelperContext.signedCodeBase), a2);
    NormalizePendingStateHandlers();
    return result;
}

// Expanded Flut Flut: the flut's art group names in SWA.DGO / SNO.DGO, without the "-ag" suffix.
bool IsExpandedFlutArtName(std::string name) {
    if (name.size() > 3 && name.compare(name.size() - 3, 3, ".go") == 0) name.resize(name.size() - 3);
    if (name.size() > 3 && name.compare(name.size() - 3, 3, "-ag") == 0) name.resize(name.size() - 3);
    return name == "eichar-flut+0" || name == "flut-saddle";
}

// Links one art object from a DGO (its 64-byte DGO header = size + name, then the object) in place in the
// global heap: a private kheapinfo whose current pointer is the object makes the linker keep it there. Run
// between level loads (*level* loading-level = level-default), art-group relocate logs the group in and adds
// it to level-default's art list (like GAME.CGO art). Returns the linked object, or 0.
uint32_t LinkResidentArtObject(jak1::Kernel *kernel, const uint8_t *dgoObject, uint32_t objectSize) {
    const uint32_t padded = (objectSize + 15) & ~15u;
    const uint32_t buffer = gNativeHelperContext.heap->allocate(64 + padded + 64, 64);
    const uint32_t heapInfo = gNativeHelperContext.heap->allocate(16, 16);
    if (buffer == 0 || heapInfo == 0) return 0;
    WriteGoalValue(buffer, dgoObject, 64 + objectSize);
    const uint32_t heap[4] = {buffer + 64, buffer + 64 + padded + 64, buffer + 64,
                              buffer + 64 + padded + 64};  // base, top, current, top-base
    WriteGoalValue(heapInfo, heap, sizeof(heap));
    constexpr uint32_t kLinkFlagExecute = 4;
    kernel->linkBegin(buffer + 64, buffer + 4, objectSize, heapInfo, kLinkFlagExecute);
    return kernel->lastLinkEntry();
}

// True while *level* is between level loads (loading-level = level-default), the only time
// LinkResidentArtObject puts art into level-default.
bool IsLoadingLevelDefault() {
    const auto levelSymbol = gNativeHelperContext.symbols.find("*level*");
    uint32_t levelGroup = 0;
    uint32_t loadingLevel = 0;
    constexpr uint32_t kLoadingLevelOffset = 8;    // level-group loading-level (offset-assert 12)
    constexpr uint32_t kLevelDefaultOffset = 5312; // level-group level-default (inline basic)
    return levelSymbol != gNativeHelperContext.symbols.end() &&
        ReadGoalValue(levelSymbol->second, &levelGroup, sizeof(levelGroup)) &&
        levelGroup != 0 && levelGroup != gNativeHelperContext.s7GoalOffset &&
        ReadGoalValue(levelGroup + kLoadingLevelOffset, &loadingLevel, sizeof(loadingLevel)) &&
        loadingLevel == levelGroup + kLevelDefaultOffset;
}

// Once per session, when the Expanded Flut Flut option is first on: links the flut level code
// (flut-part, flutflut, target-flut; their statics live in the fixed level-code region, so they
// never unload) and loads Jak's flut animations + the flut saddle art from the player's SWA.DGO
// into the global heap. With *level* loading-level = level-default, art-group relocate logs the
// groups in and adds them to level-default's art list (like GAME.CGO art), so the flut can be
// drawn and ridden in any level; ios-flut-link-art (target-flut.gc) then links the animations
// into Jak's eichar group. Swamp/Snowy skip their own copies while these are resident.
bool LoadExpandedFlut() {
    jak1::Kernel *kernel = gNativeHelperContext.kernel.get();
    if (kernel == nullptr || !kernel->hasLevelCode() || kernel->isDgoLoading() ||
        gNativeHelperContext.heap == nullptr || gNativeHelperContext.contentPath.empty()) return false;

    // Only between level loads: relocate files art into the level that is loading.
    if (!IsLoadingLevelDefault()) return false;

    std::ifstream stream(gNativeHelperContext.contentPath + "/DGO/SWA.DGO", std::ios::binary);
    std::vector<uint8_t> dgo((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    if (dgo.size() < 64) {
        NSLog(@"jakIOS: Expanded Flut Flut: SWA.DGO not found in the imported game");
        return true;  // don't retry every frame
    }

    // Top-levels and relocate methods run between GOAL frames here, so on the arena stack.
    auto previousCallGoal = kernel->exchangeCallGoal(CallGoalOnArenaStack);
    struct RestoreCallGoal {
        jak1::Kernel *kernel;
        std::function<uint64_t(uint32_t, uint64_t, uint64_t, uint64_t)> callGoal;
        ~RestoreCallGoal() { kernel->exchangeCallGoal(std::move(callGoal)); }
    } restoreCallGoal {kernel, std::move(previousCallGoal)};

    for (const char *name : {"flut-part", "flutflut", "target-flut"}) {
        if (!kernel->linkPrelinkedCodeObject(name)) {
            NSLog(@"jakIOS: Expanded Flut Flut: level code object %s is missing", name);
            return true;
        }
    }

    uint32_t objectCount = 0;
    memcpy(&objectCount, dgo.data(), 4);
    size_t offset = 64;
    int loadedArt = 0;
    for (uint32_t i = 0; i < objectCount && offset + 64 <= dgo.size(); i++) {
        uint32_t objectSize = 0;
        memcpy(&objectSize, dgo.data() + offset, 4);
        char objectName[61] {};
        memcpy(objectName, dgo.data() + offset + 4, sizeof(objectName) - 1);
        const uint32_t padded = (objectSize + 15) & ~15u;
        if (IsExpandedFlutArtName(objectName) && offset + 64 + objectSize <= dgo.size()) {
            const uint32_t linked = LinkResidentArtObject(kernel, dgo.data() + offset, objectSize);
            if (linked != 0) loadedArt++;
            NSLog(@"jakIOS: Expanded Flut Flut: loaded %s (%u bytes) at 0x%x", objectName, objectSize, linked);
        }
        offset += 64 + padded;
    }
    if (loadedArt != 2) {
        NSLog(@"jakIOS: Expanded Flut Flut: found %d of 2 flut art groups in SWA.DGO", loadedArt);
        return true;
    }

    const auto linkArt = gNativeHelperContext.symbols.find("ios-flut-link-art");
    uint32_t function = 0;
    if (linkArt != gNativeHelperContext.symbols.end() &&
        ReadGoalValue(linkArt->second, &function, sizeof(function)) &&
        function != 0 && function != gNativeHelperContext.s7GoalOffset) {
        CallGoalOnArenaStack(function, 0, 0, 0);
    }
    gNativeHelperContext.expandedFlutLoaded.store(true, std::memory_order_relaxed);
    NSLog(@"jakIOS: Expanded Flut Flut resident");
    return true;
}

// Experimental "Expanded Flut Flut Spawning" option -> GOAL *ios-expanded-flut* (target-flut.gc).
// GOAL only sees #t once the flut code and art are resident (LoadExpandedFlut). Written before
// every kernel frame: target-flut's top-level resets it whenever Swamp or Snowy relink it.
void SyncExpandedFlutOption() {
    static bool attempted = false;
    static uint32_t framesUntilRead = 0;
    static uint32_t symbol = 0;
    bool enabled = gNativeHelperContext.expandedFlutEnabled.load(std::memory_order_relaxed);
    if (!gNativeHelperContext.installedIOSExperimentalOptions) {
        if (framesUntilRead == 0) {
            enabled = [NSUserDefaults.standardUserDefaults boolForKey:kExpandedFlutDefaultsKey];
            gNativeHelperContext.expandedFlutEnabled.store(enabled, std::memory_order_relaxed);
            framesUntilRead = 30;
        }
        framesUntilRead--;
    }
    jak1::SetExpandedFlutModelEnabled(enabled);
    if (enabled && !attempted) attempted = LoadExpandedFlut();
    const bool active = enabled && gNativeHelperContext.expandedFlutLoaded.load(std::memory_order_relaxed);
    if (symbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-expanded-flut*");
        if (found == gNativeHelperContext.symbols.end()) return;
        symbol = found->second;
    }
    const uint32_t value = static_cast<uint32_t>(GoalBoolean(active));
    WriteGoalValue(symbol, &value, sizeof(value));

    // The spawner's pad model (target-flut.gc *ios-flut-pad*: pad top in game units, w = 1 while it exists).
    // Hidden for now (user, 2026-10-09) until we decide how the pad should work; set true to draw it again.
    constexpr bool kDrawFlutPad = false;
    static uint32_t padSymbol = 0;
    if (padSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-flut-pad*");
        if (found != gNativeHelperContext.symbols.end()) padSymbol = found->second;
    }
    uint32_t pad = 0;
    float padTop[4] {};
    const bool padVisible = kDrawFlutPad && active && padSymbol != 0 &&
        ReadGoalValue(padSymbol, &pad, sizeof(pad)) && pad != 0 && pad != gNativeHelperContext.s7GoalOffset &&
        ReadGoalValue(pad, padTop, sizeof(padTop)) && padTop[3] > 0.5f;
    jak1::SetFlutPad(padVisible, padTop[0], padTop[1], padTop[2]);
}

// Once per session, when the Driveable Boat option is first on, makes the boat, its ocean manager and the lurker
// shark independent of Sandover (free-boat-plan.md):
// - links the fishermans-boat level code (the free boat, ocean manager and shark types and states). Its statics
//   live in the fixed level-code region, so it never unloads; VI1 loading relinks it like any level visit
//   (pristine statics + top-level), which is why the state the free boat needs is define-perm.
// - loads the boat ("fishermans-boat", the v4 art object in the player's VI1.DGO; the v3 object of the same name
//   is its code) and shark ("sharkey") art groups into the global heap, as level-default art. The free boat,
//   manager and shark have a stand-in entity whose level is level-default, so initialize-skeleton takes these;
//   Sandover's own actors keep using village1's copies (nothing skipped). Their textures are village1's, which
//   may not be loaded yet: merc login then only prints "login could not find texture" (loado returns #f), and the
//   iOS Merc renderer draws both from Jak1Level-ios-boat.fr3z (SetResidentBoatModelEnabled) by name anyway.
bool LoadResidentBoatArt() {
    jak1::Kernel *kernel = gNativeHelperContext.kernel.get();
    if (kernel == nullptr || !kernel->hasLevelCode() || kernel->isDgoLoading() ||
        gNativeHelperContext.heap == nullptr || gNativeHelperContext.contentPath.empty() ||
        !IsLoadingLevelDefault()) return false;

    std::ifstream stream(gNativeHelperContext.contentPath + "/DGO/VI1.DGO", std::ios::binary);
    std::vector<uint8_t> dgo((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    if (dgo.size() < 64) {
        NSLog(@"jakIOS: Driveable Boat: VI1.DGO not found in the imported game");
        return true;  // don't retry every frame
    }

    // Top-levels and art-group relocate methods (login) run between GOAL frames here, so on the arena stack.
    auto previousCallGoal = kernel->exchangeCallGoal(CallGoalOnArenaStack);
    struct RestoreCallGoal {
        jak1::Kernel *kernel;
        std::function<uint64_t(uint32_t, uint64_t, uint64_t, uint64_t)> callGoal;
        ~RestoreCallGoal() { kernel->exchangeCallGoal(std::move(callGoal)); }
    } restoreCallGoal {kernel, std::move(previousCallGoal)};

    if (!kernel->linkPrelinkedCodeObject("fishermans-boat")) {
        NSLog(@"jakIOS: Driveable Boat: level code object fishermans-boat is missing");
        return true;
    }

    uint32_t boatArt = 0;
    uint32_t sharkArt = 0;
    uint32_t objectCount = 0;
    memcpy(&objectCount, dgo.data(), 4);
    size_t offset = 64;
    for (uint32_t i = 0; i < objectCount && offset + 64 + 16 <= dgo.size(); i++) {
        uint32_t objectSize = 0;
        memcpy(&objectSize, dgo.data() + offset, 4);
        char objectName[61] {};
        memcpy(objectName, dgo.data() + offset + 4, sizeof(objectName) - 1);
        uint32_t linkHeader[4] {};  // v4 (art): type tag 0xffffffff, length, version 4, code size
        memcpy(linkHeader, dgo.data() + offset + 64, sizeof(linkHeader));
        const bool isArt = linkHeader[0] == 0xffffffffu && linkHeader[2] == 4 &&
            offset + 64 + objectSize <= dgo.size();
        uint32_t *target = !isArt ? nullptr :
            strcmp(objectName, "fishermans-boat") == 0 ? &boatArt :
            strcmp(objectName, "sharkey") == 0 ? &sharkArt : nullptr;
        if (target != nullptr && *target == 0) {
            *target = LinkResidentArtObject(kernel, dgo.data() + offset, objectSize);
            NSLog(@"jakIOS: Driveable Boat: %s %s art (%u bytes) at 0x%x", *target != 0 ? "resident" :
                  "FAILED to load", objectName, objectSize, *target);
        }
        offset += 64 + ((objectSize + 15) & ~15u);
    }
    if (boatArt == 0 || sharkArt == 0) {
        NSLog(@"jakIOS: Driveable Boat: boat/shark art missing from VI1.DGO; the boat stays a Sandover actor");
        return true;
    }
    gNativeHelperContext.residentBoatArt = boatArt;
    return true;
}

// Experimental "Driveable Boat" option -> GOAL *ios-driveable-boat* (fishermans-boat.gc, VI1 level code).
// Written before every kernel frame: the boat's top-level resets it to #f whenever VI1 links.
void SyncDriveableBoatOption() {
    static uint32_t symbol = 0;
    static bool enabled = false;
    static uint32_t framesUntilRead = 0;
    uint32_t menuValue = 0;
    if (gNativeHelperContext.installedIOSExperimentalOptions &&
        ReadGoalValue(gNativeHelperContext.iosDriveableBoatValue, &menuValue, sizeof(menuValue))) {
        // Experimental Options > Driveable Boat (InstallIOSExperimentalOptions)
        enabled = menuValue != gNativeHelperContext.s7GoalOffset;
    } else if (framesUntilRead == 0) {
        // Until the menu is installed, use the saved setting (NSUserDefaults is thread safe).
        enabled = [NSUserDefaults.standardUserDefaults boolForKey:kDriveableBoatDefaultsKey];
        framesUntilRead = 30;
    }
    if (framesUntilRead > 0) framesUntilRead--;
    // Boat art + model that do not depend on Sandover being loaded (free-boat-plan.md phase 1).
    static bool attemptedResidentArt = false;
    if (enabled && !attemptedResidentArt) attemptedResidentArt = LoadResidentBoatArt();
    jak1::SetResidentBoatModelEnabled(enabled && gNativeHelperContext.residentBoatArt != 0);
    if (symbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-driveable-boat*");
        if (found == gNativeHelperContext.symbols.end()) return;
        symbol = found->second;
    }
    const uint32_t value = static_cast<uint32_t>(GoalBoolean(enabled));
    WriteGoalValue(symbol, &value, sizeof(value));

    // Taking the wheel spawns the free boat (fishermans-boat.gc) only once its art is resident.
    static uint32_t artResidentSymbol = 0;
    if (artResidentSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-boat-art-resident*");
        if (found != gNativeHelperContext.symbols.end()) artResidentSymbol = found->second;
    }
    if (artResidentSymbol != 0) {
        const uint32_t resident = static_cast<uint32_t>(
            GoalBoolean(enabled && gNativeHelperContext.residentBoatArt != 0));
        WriteGoalValue(artResidentSymbol, &resident, sizeof(resident));
    }

    // While Jak is at the wheel (*ios-boat-driving*), thin the ocean fog so the hull shows through the
    // water from the high boat camera.
    static uint32_t drivingSymbol = 0;
    if (drivingSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-boat-driving*");
        if (found != gNativeHelperContext.symbols.end()) drivingSymbol = found->second;
    }
    uint32_t driving = 0;
    const bool atWheel = enabled && drivingSymbol != 0 &&
        ReadGoalValue(drivingSymbol, &driving, sizeof(driving)) && driving == GoalBoolean(true);
    jak1::SetOceanFogScale(atWheel ? 0.35f : 1.0f);

    // Boat summon fade-in (pc/ios/ios-boat-summon.gc *ios-boat-summon-fade*: x alpha, y glow, w > 0.5 = active).
    static uint32_t summonFadeSymbol = 0;
    if (summonFadeSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-boat-summon-fade*");
        if (found != gNativeHelperContext.symbols.end()) summonFadeSymbol = found->second;
    }
    uint32_t summonFade = 0;
    float fade[4] {};
    const bool fading = enabled && summonFadeSymbol != 0 &&
        ReadGoalValue(summonFadeSymbol, &summonFade, sizeof(summonFade)) && summonFade != 0 &&
        summonFade != gNativeHelperContext.s7GoalOffset && ReadGoalValue(summonFade, fade, sizeof(fade)) &&
        fade[3] > 0.5f;
    Jak1RendererSetBoatFade(fading, fading ? fade[0] : 1.0f, fading ? fade[1] : 0.0f);

    // Stand-in coastline between the jungle and Rock Village (*ios-coast-visible*, fishermans-boat.gc).
    static uint32_t coastSymbol = 0;
    if (coastSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-coast-visible*");
        if (found != gNativeHelperContext.symbols.end()) coastSymbol = found->second;
    }
    uint32_t coastVisible = 0;
    jak1::SetCoastTerrainEnabled(enabled && coastSymbol != 0 &&
        ReadGoalValue(coastSymbol, &coastVisible, sizeof(coastVisible)) &&
        coastVisible == GoalBoolean(true));
}

// Fish in Ocean: the v4 art objects (DGO entries share their name with any v3 code object, e.g. junglefish)
// of the ambient ocean fish (pc/ios/ios-ocean-fish.gc), from the jungle and Lost Precursor City DGOs.
struct OceanFishArt {
    const char *dgo;
    const char *name;
};
constexpr OceanFishArt kOceanFishArt[] = {
    {"JUN.DGO", "catch-fisha"},
    {"JUN.DGO", "catch-fishb"},
    {"JUN.DGO", "junglefish"},
    {"SUN.DGO", "sunkenfisha"},
};

// Once per session, when Fish in Ocean is first on: loads the fish art groups into the global heap as
// level-default art (like LoadResidentBoatArt), so fish whose stand-in entity is level-default can be drawn
// with no jungle/sunken level loaded. The jungle and sunken levels keep using their own copies (nothing
// skipped). Textures come from Jak1Level-ios-fish.fr3z (SetResidentFishModelEnabled).
bool LoadResidentFishArt() {
    jak1::Kernel *kernel = gNativeHelperContext.kernel.get();
    if (kernel == nullptr || !kernel->hasLevelCode() || kernel->isDgoLoading() ||
        gNativeHelperContext.heap == nullptr || gNativeHelperContext.contentPath.empty() ||
        !IsLoadingLevelDefault()) return false;

    // Art-group relocate methods (login) run between GOAL frames here, so on the arena stack.
    auto previousCallGoal = kernel->exchangeCallGoal(CallGoalOnArenaStack);
    struct RestoreCallGoal {
        jak1::Kernel *kernel;
        std::function<uint64_t(uint32_t, uint64_t, uint64_t, uint64_t)> callGoal;
        ~RestoreCallGoal() { kernel->exchangeCallGoal(std::move(callGoal)); }
    } restoreCallGoal {kernel, std::move(previousCallGoal)};

    size_t loaded = 0;
    for (const char *dgoName : {"JUN.DGO", "SUN.DGO"}) {
        std::ifstream stream(gNativeHelperContext.contentPath + "/DGO/" + dgoName, std::ios::binary);
        std::vector<uint8_t> dgo((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
        if (dgo.size() < 64) {
            NSLog(@"jakIOS: Fish in Ocean: %s not found in the imported game", dgoName);
            continue;
        }
        uint32_t objectCount = 0;
        memcpy(&objectCount, dgo.data(), 4);
        size_t offset = 64;
        for (uint32_t i = 0; i < objectCount && offset + 64 + 16 <= dgo.size(); i++) {
            uint32_t objectSize = 0;
            memcpy(&objectSize, dgo.data() + offset, 4);
            char objectName[61] {};
            memcpy(objectName, dgo.data() + offset + 4, sizeof(objectName) - 1);
            uint32_t linkHeader[4] {};  // v4 (art): type tag 0xffffffff, length, version 4, code size
            memcpy(linkHeader, dgo.data() + offset + 64, sizeof(linkHeader));
            const bool isArt = linkHeader[0] == 0xffffffffu && linkHeader[2] == 4 &&
                offset + 64 + objectSize <= dgo.size();
            for (const OceanFishArt &art : kOceanFishArt) {
                if (!isArt || strcmp(art.dgo, dgoName) != 0 || strcmp(art.name, objectName) != 0) continue;
                const uint32_t linked = LinkResidentArtObject(kernel, dgo.data() + offset, objectSize);
                if (linked != 0) loaded++;
                NSLog(@"jakIOS: Fish in Ocean: %s %s art (%u bytes) at 0x%x", linked != 0 ? "resident" :
                      "FAILED to load", objectName, objectSize, linked);
            }
            offset += 64 + ((objectSize + 15) & ~15u);
        }
    }
    if (loaded != std::size(kOceanFishArt)) {
        NSLog(@"jakIOS: Fish in Ocean: found %zu of %zu fish art groups; fish stay off", loaded,
              std::size(kOceanFishArt));
        return true;  // don't retry every frame
    }
    gNativeHelperContext.oceanFishArtLoaded.store(true, std::memory_order_relaxed);
    return true;
}

// Experimental "Fish in Ocean" option -> GOAL *ios-ocean-fish* (pc/ios/ios-ocean-fish.gc, a startup object),
// #t only once the fish art is resident. Written before every kernel frame. GOAL answers with
// *ios-clear-ocean* (Jak in the ocean with the option on): the near ocean then draws at its clearest.
void SyncOceanFishOption() {
    static uint32_t framesUntilRead = 0;
    static bool attempted = false;
    static uint32_t symbol = 0;
    static uint32_t clearSymbol = 0;
    if (!gNativeHelperContext.installedIOSExperimentalOptions) {
        if (framesUntilRead == 0) {
            gNativeHelperContext.oceanFishEnabled.store(
                [NSUserDefaults.standardUserDefaults boolForKey:kOceanFishDefaultsKey], std::memory_order_relaxed);
            framesUntilRead = 30;
        }
        framesUntilRead--;
    }
    const bool enabled = gNativeHelperContext.oceanFishEnabled.load(std::memory_order_relaxed);
    if (enabled && !attempted) attempted = LoadResidentFishArt();
    const bool active = enabled && gNativeHelperContext.oceanFishArtLoaded.load(std::memory_order_relaxed);
    jak1::SetResidentFishModelEnabled(active);
    if (symbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-ocean-fish*");
        if (found != gNativeHelperContext.symbols.end()) symbol = found->second;
    }
    if (symbol != 0) {
        const uint32_t value = static_cast<uint32_t>(GoalBoolean(active));
        WriteGoalValue(symbol, &value, sizeof(value));
    }
    if (clearSymbol == 0) {
        const auto found = gNativeHelperContext.symbols.find("*ios-clear-ocean*");
        if (found != gNativeHelperContext.symbols.end()) clearSymbol = found->second;
    }
    // Clear water is off for now (user 2026-10-14: keep the stock ocean). The renderer path (Jak1Ocean clearFrame,
    // shader buckets 5/6) only runs while this is set, so the ocean draws exactly as stock. Set to true to restore.
    constexpr bool kOceanClearWaterEnabled = false;
    uint32_t clear = 0;
    jak1::SetOceanClearWater(kOceanClearWaterEnabled && enabled && clearSymbol != 0 &&
        ReadGoalValue(clearSymbol, &clear, sizeof(clear)) && clear == GoalBoolean(true));
}

void SyncTitlePressStartText() {
    constexpr uint32_t kGameTextDataOffset = 12;  // game-text-info: length, language-id, group-name
    constexpr uint32_t kPressStartTextID = 0x16e;
    static constexpr char kStockText[] = "PRESS START";
    static constexpr char kTouchText[] = "TAP TO START";
    static uint32_t touchString = 0;  // GOAL string on the global heap, made once
    static uint32_t stockString = 0;  // the entry's original string

    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto textSymbol = gNativeHelperContext.symbols.find("*common-text*");
    uint32_t textInfo = 0;
    int32_t length = 0;
    if (textSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(textSymbol->second, &textInfo, sizeof(textInfo)) ||
        textInfo == 0 || textInfo == s7 ||
        !ReadGoalValue(textInfo, &length, sizeof(length)) || length <= 0 || length > 10000) {
        return;
    }
    uint32_t entry = 0;
    uint32_t current = 0;
    for (int32_t index = 0; index < length; index++) {
        const uint32_t candidate = textInfo + kGameTextDataOffset + index * 8;
        uint32_t id = 0;
        if (ReadGoalValue(candidate, &id, sizeof(id)) && id == kPressStartTextID) {
            entry = candidate;
            break;
        }
    }
    if (entry == 0 || !ReadGoalValue(entry + 4, &current, sizeof(current)) ||
        current == 0 || current == s7) {
        return;
    }
    // A reloaded *common-text* (language change) brings back its own stock string.
    if (current != touchString) stockString = current;

    char stockChars[sizeof(kStockText)] {};
    const bool isEnglish = stockString != 0 &&
        ReadGoalValue(stockString + 4, stockChars, sizeof(stockChars)) &&
        std::memcmp(stockChars, kStockText, sizeof(kStockText)) == 0;
    const bool wanted = isEnglish && gTouchMenuStyle.load(std::memory_order_relaxed) &&
        gNativeHelperContext.onTitleScreen.load(std::memory_order_relaxed);

    if (wanted && touchString == 0 && gNativeHelperContext.heap != nullptr) {
        // basic layout: type tag at -4, allocated-length at 0, characters from +4.
        uint32_t stringType = 0;
        if (!ReadGoalValue(stockString - 4, &stringType, sizeof(stringType))) return;
        const int32_t capacity = static_cast<int32_t>(sizeof(kTouchText));
        const uint32_t allocation = gNativeHelperContext.heap->allocate(
            static_cast<uint32_t>(8 + sizeof(kTouchText)), 16);
        if (allocation == 0) return;
        const uint32_t string = allocation + 4;
        if (!WriteGoalValue(allocation, &stringType, sizeof(stringType)) ||
            !WriteGoalValue(string, &capacity, sizeof(capacity)) ||
            !WriteGoalValue(string + 4, kTouchText, sizeof(kTouchText))) {
            return;
        }
        touchString = string;
    }
    const uint32_t desired = wanted && touchString != 0 ? touchString : stockString;
    if (desired != current) WriteGoalValue(entry + 4, &desired, sizeof(desired));
}

// Runs every frame before GOAL: turns queued menu touches into this frame's injected buttons.
void SyncMenuTouch() {
    std::vector<MenuTouchEvent> events;
    {
        std::lock_guard<std::mutex> lock(gMenuTouchMutex);
        events.swap(gPendingMenuTouchEvents);
    }
    MenuTouchPlayback &playback = gMenuTouchPlayback;
    ProgressMenuState menu;
    MenuPressHighlight &highlight = gMenuPressHighlight;
    if (!ReadProgressMenuState(&menu)) {
        playback.clear();
        highlight.clear();
        gMenuInjectedButtons.store(0, std::memory_order_relaxed);
        gMenuOnCollectionPage.store(false, std::memory_order_relaxed);
        return;
    }
    gMenuOnCollectionPage.store(menu.isCollectionScreen(), std::memory_order_relaxed);

    // Taps (and presses) only count once the menu has settled on a screen and nothing is queued,
    // so they always apply to what is on screen.
    const auto readyForTap = [&] {
        return menu.acceptsInput() && playback.presses.empty() && !playback.releaseFrame && playback.heldMask == 0;
    };
    for (const MenuTouchEvent &event : events) {
        switch (event.kind) {
            case MenuTouchEvent::Kind::Press: {
                // Finger down on an option or save slot: select it so it lights up while held.
                highlight.clear();
                if (!readyForTap() || menu.editing) break;
                const int32_t index = MenuOptionAt(menu, event.x, event.y);
                if (index < 0) break;
                SetProgressOptionIndex(menu, index);
                menu.optionIndex = index;
                highlight.held = true;
                break;
            }
            case MenuTouchEvent::Kind::PressCancel:
                highlight.clear();
                break;
            case MenuTouchEvent::Kind::Tap:
                if (highlight.held) {
                    // Keep the highlight a moment after lifting, so a quick tap still flashes it
                    // before the menu moves on.
                    highlight.held = false;
                    highlight.until = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
                }
                if (!readyForTap()) break;
                playback.sliderActive = false;
                HandleMenuTap(menu, event.x, event.y, playback);
                break;
            case MenuTouchEvent::Kind::Scroll:
                if (menu.isCollectionScreen()) {
                    // One level per swipe, however far it goes.
                    if (event.startsSwipe) playback.levelSteps = event.steps > 0 ? 1 : -1;
                } else if (menu.scrolls() && !menu.editing) {
                    playback.scrollRows += event.steps;
                }
                break;
            case MenuTouchEvent::Kind::Horizontal: {
                // The collectible pages ignore sideways swipes: power cells are picked by tapping.
                if (menu.isCollectionScreen()) break;
                // Carousels follow the finger like a swiped list: swiping left brings in the value
                // from the right (Right), so they take the opposite press from other screens.
                // The gesture sends one step per swipe; anything else is ignored.
                if (!event.startsSwipe) break;
                bool towardRight = event.steps > 0;
                if (menu.editing) {
                    switch (menu.optionType(menu.optionIndex)) {
                        case kOptionLanguage:
                        case kOptionDisplayMode:
                        case kOptionMsaa:
                        case kOptionFrameRate:
                        case kOptionLodBg:
                        case kOptionLodFg:
                        case kOptionLanguageSubtitles:
                        case kOptionLanguageText:
                        case kOptionSpeaker:
                            towardRight = !towardRight;
                            break;
                        default:
                            break;
                    }
                }
                // Only one queued at a time, so swipes can't pile up behind a slow transition.
                if (playback.presses.empty()) {
                    playback.presses.push_back(towardRight ? kPadRight : kPadLeft);
                }
                break;
            }
            case MenuTouchEvent::Kind::Back:
                playback.sliderActive = false;
                playback.scrollRows = 0;
                playback.levelSteps = 0;
                // Back resumes the game (Start) when the pause menu has nothing to go back to: the
                // collectible pages, or a first screen with nothing pushed below it. Otherwise
                // Triangle backs out (or cancels an edit); the title menu always uses Triangle.
                {
                    // The collectible pages only exist in the pause menu.
                    const bool resume = !menu.editing &&
                        (menu.isCollectionScreen() || (menu.paused && menu.backDepth <= 0));
                    playback.presses.push_back(resume ? kPadStart : kPadTriangle);
                    NSLog(@"jakIOS: menu back -> %s (screen %lld, depth %d, paused %d, editing %d, ready %d)",
                          resume ? "Start" : "Triangle", menu.screen, menu.backDepth, menu.paused,
                          menu.editing, menu.acceptsInput());
                }
                break;
        }
    }

    const uint32_t reads = gPadReadCount.load(std::memory_order_relaxed);
    // Starts delivering `mask`, held for `holdReads` pad reads, then released for one.
    const auto beginPress = [&](uint16_t mask, uint32_t holdReads) {
        playback.heldMask = mask;
        playback.heldReads = holdReads;
        playback.phaseStartRead = reads;
    };
    uint16_t inject = 0;
    if (playback.heldMask != 0) {
        if (reads - playback.phaseStartRead >= playback.heldReads) {
            playback.heldMask = 0;
            playback.releaseFrame = true;
            playback.phaseStartRead = reads;
        } else {
            inject = playback.heldMask;
        }
    } else if (playback.releaseFrame) {
        if (reads - playback.phaseStartRead >= 1) playback.releaseFrame = false;
    }

    if (playback.heldMask != 0 || playback.releaseFrame) {
        // A press (or the release after it) is still being delivered.
    } else if (playback.sliderActive) {
        float value = playback.sliderLastValue;
        ReadGoalValue(playback.sliderValueAddress, &value, sizeof(value));
        const bool reached = playback.sliderDirection > 0 ? value >= playback.sliderTarget
                                                          : value <= playback.sliderTarget;
        playback.sliderStuckFrames = value == playback.sliderLastValue ? playback.sliderStuckFrames + 1 : 0;
        playback.sliderLastValue = value;
        // The first held frame only registers the press; give up if it stops moving (at an end).
        if (reached || !menu.editing || playback.sliderStuckFrames > 20 || ++playback.sliderFrames > 600) {
            playback.sliderActive = false;
            playback.releaseFrame = true;
            playback.phaseStartRead = reads;
        } else {
            inject = playback.sliderDirection > 0 ? kPadRight : kPadLeft;
        }
    } else if (!playback.presses.empty()) {
        // Hold queued presses until the menu reads input again (e.g. Back during a transition;
        // determine-pause-mode also ignores Start until then); drop them if it never does.
        if (menu.acceptsInput()) {
            const uint16_t mask = playback.presses.front();
            playback.presses.erase(playback.presses.begin());
            playback.pendingPressFrames = 0;
            // Start is held a little longer, like a real press: closing the pause menu only
            // happens in determine-pause-mode, which mustn't miss it.
            beginPress(mask, mask == kPadStart ? 4 : 1);
            inject = mask;
        } else if (++playback.pendingPressFrames > 90) {
            playback.presses.clear();
            playback.pendingPressFrames = 0;
        }
    } else if (playback.cellTarget >= 0) {
        // Jump straight to the tapped cell but let the game make the move (and its cursor sound):
        // put the selection right next to it and press toward it in the same frame. Left/Right
        // only skip unrevealed cells, and the tapped one is revealed, so the press stops on it
        // before the frame is drawn.
        if (menu.screen != kScreenFuelCell) {
            playback.cellTarget = -1;
        } else if (menu.acceptsInput()) {
            const int32_t target = playback.cellTarget;
            const int32_t neighbour = target > 0 ? target - 1 : target + 1;
            const uint16_t mask = target > 0 ? kPadRight : kPadLeft;
            WriteGoalValue(menu.progress + kProgressTaskIndexOffset, &neighbour, sizeof(neighbour));
            playback.cellTarget = -1;
            beginPress(mask, 1);
            inject = mask;
        }
    } else if (playback.levelSteps != 0) {
        if (menu.acceptsInput()) {
            const uint16_t mask = playback.levelSteps > 0 ? kPadDown : kPadUp;
            playback.levelSteps = 0;
            beginPress(mask, 1);
            inject = mask;
        }
    } else if (playback.scrollRows != 0) {
        if (!menu.scrolls() || menu.editing) {
            playback.scrollRows = 0;
        } else if (menu.acceptsInput()) {
            ApplyMenuScroll(menu, playback);
        }
    }
    gMenuInjectedButtons.store(inject, std::memory_order_relaxed);
}

// Pause menu Secrets > Dev Menu > Give 100% Items. The Dev Menu lives on progress-screen
// game-ps2-options (45): progress-pc.gc draws and navigates it as an option list, but no stock
// array is assigned to it. Text ids 0x161a / 0x161b are new lines in game_custom_text_*.json.
constexpr int64_t kDevMenuScreen = 45;
constexpr int64_t kSettingsScreen = 3;  // pause menu options list
constexpr uint32_t kDevMenuTextId = 0x161a;
constexpr uint32_t kGiveAllItemsTextId = 0x161b;

// Adds a Dev Menu row to the in-game Secrets list (*secrets*: Cheats, Checkpoint Select, Back).
// The title screen's Secrets list is a different array (*secrets-title*), so the row only shows
// once a save is loaded. respond-common re-reads *secrets* on every Secrets frame, so pointing
// the symbol at a host-allocated copy is enough.
void InstallIOSDevMenu() {
    if (gNativeHelperContext.installedIOSDevMenu || gNativeHelperContext.heap == nullptr) return;
    constexpr uint32_t kHeaderSize = 12;
    constexpr uint32_t kNameOffset = 12;
    constexpr uint32_t kParam3Offset = 28;           // game-option-menu (int32): screen a menu row opens
    constexpr uint32_t kDisabledFunctionOffset = 36;
    constexpr uint32_t kBasicTypeTagSize = 4;
    constexpr uint32_t kGameOptionBlockSize = 96;    // type tag + PC game-option (84 bytes), rounded up
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbol = gNativeHelperContext.symbols.find("*secrets*");
    uint32_t secrets = 0;
    int32_t length = 0;
    uint32_t arrayTypeTag = 0;
    uint32_t contentType = 0;
    uint32_t entries[3] {};
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &secrets, sizeof(secrets)) || secrets == 0 || secrets == s7 ||
        !ReadGoalValue(secrets, &length, sizeof(length)) || length != 3 ||
        !ReadGoalValue(secrets - kBasicTypeTagSize, &arrayTypeTag, sizeof(arrayTypeTag)) ||
        !ReadGoalValue(secrets + 8, &contentType, sizeof(contentType)) ||
        !ReadGoalValue(secrets + kHeaderSize, entries, sizeof(entries))) return;
    constexpr uint32_t kExpectedNames[] = {
        0x1080, // Cheats (menu row)
        0x1502, // Checkpoint Select
        0x013e, // Back (button)
    };
    for (size_t index = 0; index < std::size(entries); index++) {
        uint32_t name = 0;
        if (entries[index] == 0 ||
            !ReadGoalValue(entries[index] + kNameOffset, &name, sizeof(name)) ||
            name != kExpectedNames[index]) return;
    }

    // New rows are copies of existing ones (type tag included): Cheats for the menu row, Back
    // for the button. Unknown button names do nothing in respond-progress; the press is
    // handled by SyncIOSDevMenu after the frame.
    const auto copyOption = [&](uint32_t source, uint32_t name) -> uint32_t {
        uint8_t bytes[kGameOptionBlockSize] {};
        const uint32_t block = gNativeHelperContext.heap->allocate(kGameOptionBlockSize, 16);
        if (block == 0 || !ReadGoalValue(source - kBasicTypeTagSize, bytes, sizeof(bytes)) ||
            !WriteGoalValue(block, bytes, sizeof(bytes))) return 0;
        const uint32_t option = block + kBasicTypeTagSize;
        const uint32_t noFunction = 0;
        if (!WriteGoalValue(option + kNameOffset, &name, sizeof(name)) ||
            !WriteGoalValue(option + kDisabledFunctionOffset, &noFunction, sizeof(noFunction))) return 0;
        return option;
    };
    const auto makeArray = [&](const uint32_t *options, int32_t count) -> uint32_t {
        const uint32_t block = gNativeHelperContext.heap->allocate(
            kBasicTypeTagSize + kHeaderSize + count * sizeof(uint32_t), 16);
        if (block == 0) return 0;
        const uint32_t storage = block + kBasicTypeTagSize;
        if (!WriteGoalValue(block, &arrayTypeTag, sizeof(arrayTypeTag)) ||
            !WriteGoalValue(storage, &count, sizeof(count)) ||
            !WriteGoalValue(storage + 4, &count, sizeof(count)) ||
            !WriteGoalValue(storage + 8, &contentType, sizeof(contentType)) ||
            !WriteGoalValue(storage + kHeaderSize, options, count * sizeof(uint32_t))) return 0;
        return storage;
    };

    const uint32_t devMenuRow = copyOption(entries[0], kDevMenuTextId);
    const uint32_t giveAllButton = copyOption(entries[2], kGiveAllItemsTextId);
    const int32_t devMenuScreen = static_cast<int32_t>(kDevMenuScreen);
    if (devMenuRow == 0 || giveAllButton == 0 ||
        !WriteGoalValue(devMenuRow + kParam3Offset, &devMenuScreen, sizeof(devMenuScreen))) return;
    const uint32_t devMenuOptions[] = {giveAllButton, entries[2]};
    const uint32_t secretsOptions[] = {entries[0], entries[1], devMenuRow, entries[2]};
    const uint32_t devMenu = makeArray(devMenuOptions, std::size(devMenuOptions));
    const uint32_t newSecrets = makeArray(secretsOptions, std::size(secretsOptions));
    if (devMenu == 0 || newSecrets == 0 ||
        !WriteGoalValue(symbol->second, &newSecrets, sizeof(newSecrets))) return;
    gNativeHelperContext.iosDevMenu = devMenu;
    gNativeHelperContext.iosDevMenuGiveAllOption = giveAllButton;
    gNativeHelperContext.iosDevMenuRow = devMenuRow;
    gNativeHelperContext.installedIOSDevMenu = true;
    NSLog(@"jakIOS: installed Secrets > Dev Menu");
}

// Gives the loaded game every power cell, scout fly and orb, the way picking them up would
// (game-info adjust, game-info.gc): cells set the task perm's real-complete bit, add to fuel and
// close the task's need-resolution stage via close-specific-task!; flies set the buzzer task
// perm's reminder bits (user-uint8 1); orbs fill money-per-level up to *game-counts* and add the
// difference to money-total and money. Only what isn't collected yet is added. Saving the game
// keeps it. Must run on the kernel queue, between GOAL frames.
void GiveAllCollectibles() {
    // game-info (basic) offsets from the object pointer (deftype offset - 4).
    constexpr uint32_t kGameInfoMoneyOffset = 16;
    constexpr uint32_t kGameInfoMoneyTotalOffset = 20;
    constexpr uint32_t kGameInfoMoneyPerLevelOffset = 24;  // uint8[32]
    constexpr uint32_t kGameInfoBuzzerTotalOffset = 88;
    constexpr uint32_t kGameInfoFuelOffset = 92;
    constexpr uint32_t kGameInfoTaskPermListOffset = 100;
    constexpr uint32_t kPermArrayDataOffset = 12;   // entity-perm-array: inline 16-byte entity-perms
    constexpr uint32_t kEntityPermSize = 16;
    constexpr uint32_t kEntityPermStatusOffset = 8; // entity-perm-status (u16)
    constexpr uint16_t kPermUserSetFromCstage = 1 << 5;
    constexpr uint16_t kPermRealComplete = 1 << 8;
    constexpr uint8_t kAllBuzzers = 0x7f;           // *FACT-bank* buzzer-max-default 7
    // level-tasks-info: nb-of-tasks @8, buzzer-task-index @12, task-info-data[8] @16;
    // task-info-data: task-id (u8) @0. game-count-info: count-info {money, buzzer} from @4.
    constexpr uint32_t kLevelTasksCountOffset = 8;
    constexpr uint32_t kLevelTasksBuzzerIndexOffset = 12;
    constexpr uint32_t kLevelTasksInfoOffset = 16;
    constexpr uint32_t kGameCountsDataOffset = 4;
    constexpr uint64_t kTaskStatusNeedResolution = 7;
    constexpr uint32_t kMaxGameTask = 116;

    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    uint32_t gameInfo = 0, taskPerms = 0, levelTaskData = 0, gameCounts = 0, closeTask = 0;
    int32_t levelCount = 0, countsLength = 0, permCount = 0;
    if (!symbolValue("*game-info*", &gameInfo) || !symbolValue("*level-task-data*", &levelTaskData) ||
        !symbolValue("*game-counts*", &gameCounts) || !symbolValue("close-specific-task!", &closeTask) ||
        !ReadGoalValue(gameInfo + kGameInfoTaskPermListOffset, &taskPerms, sizeof(taskPerms)) ||
        taskPerms == 0 || taskPerms == s7 ||
        !ReadGoalValue(taskPerms, &permCount, sizeof(permCount)) ||
        !ReadGoalValue(levelTaskData, &levelCount, sizeof(levelCount)) ||
        !ReadGoalValue(gameCounts, &countsLength, sizeof(countsLength))) {
        NSLog(@"jakIOS: dev menu: game state not available, nothing given");
        return;
    }
    float money = 0, moneyTotal = 0, buzzerTotal = 0, fuel = 0;
    ReadGoalValue(gameInfo + kGameInfoMoneyOffset, &money, sizeof(money));
    ReadGoalValue(gameInfo + kGameInfoMoneyTotalOffset, &moneyTotal, sizeof(moneyTotal));
    ReadGoalValue(gameInfo + kGameInfoBuzzerTotalOffset, &buzzerTotal, sizeof(buzzerTotal));
    ReadGoalValue(gameInfo + kGameInfoFuelOffset, &fuel, sizeof(fuel));

    int32_t cellsGiven = 0, fliesGiven = 0, orbsGiven = 0;
    for (int32_t level = 0; level < levelCount; level++) {
        uint32_t tasks = 0;
        int32_t taskCount = 0, buzzerIndex = -1;
        if (!ReadGoalValue(levelTaskData + 12 + level * 4, &tasks, sizeof(tasks)) ||
            tasks == 0 || tasks == s7 ||
            !ReadGoalValue(tasks + kLevelTasksCountOffset, &taskCount, sizeof(taskCount)) ||
            !ReadGoalValue(tasks + kLevelTasksBuzzerIndexOffset, &buzzerIndex, sizeof(buzzerIndex))) continue;
        for (int32_t index = 0; index < std::min(taskCount, 8); index++) {
            uint32_t info = 0;
            uint8_t task = 0;
            if (!ReadGoalValue(tasks + kLevelTasksInfoOffset + index * 4, &info, sizeof(info)) ||
                info == 0 || info == s7 || !ReadGoalValue(info, &task, sizeof(task)) ||
                task <= 1 || task >= kMaxGameTask || task >= permCount) continue;
            const uint32_t perm = taskPerms + kPermArrayDataOffset + task * kEntityPermSize;
            uint16_t status = 0;
            if (!ReadGoalValue(perm + kEntityPermStatusOffset, &status, sizeof(status))) continue;
            if (index == buzzerIndex) {
                uint8_t buzzers = 0;
                ReadGoalValue(perm + 1, &buzzers, sizeof(buzzers));
                const int32_t added = __builtin_popcount(kAllBuzzers & ~buzzers);
                if (added > 0) {
                    const uint8_t all = buzzers | kAllBuzzers;
                    status |= kPermUserSetFromCstage;
                    WriteGoalValue(perm + 1, &all, sizeof(all));
                    WriteGoalValue(perm + kEntityPermStatusOffset, &status, sizeof(status));
                    buzzerTotal += added;
                    fliesGiven += added;
                }
            }
            if ((status & kPermRealComplete) == 0) {
                status |= kPermRealComplete;
                WriteGoalValue(perm + kEntityPermStatusOffset, &status, sizeof(status));
                fuel += 1.0f;
                cellsGiven++;
                CallGoalOnArenaStack(closeTask, task, kTaskStatusNeedResolution, 0);
            }
        }
        if (level < countsLength && level < 32) {
            int32_t levelOrbs = 0;
            uint8_t collected = 0;
            if (ReadGoalValue(gameCounts + kGameCountsDataOffset + level * 8, &levelOrbs, sizeof(levelOrbs)) &&
                ReadGoalValue(gameInfo + kGameInfoMoneyPerLevelOffset + level, &collected, sizeof(collected)) &&
                levelOrbs > collected) {
                const uint8_t all = static_cast<uint8_t>(std::min(levelOrbs, 255));
                const int32_t added = all - collected;
                WriteGoalValue(gameInfo + kGameInfoMoneyPerLevelOffset + level, &all, sizeof(all));
                moneyTotal += added;
                money += added;
                orbsGiven += added;
            }
        }
    }
    WriteGoalValue(gameInfo + kGameInfoMoneyOffset, &money, sizeof(money));
    WriteGoalValue(gameInfo + kGameInfoMoneyTotalOffset, &moneyTotal, sizeof(moneyTotal));
    WriteGoalValue(gameInfo + kGameInfoBuzzerTotalOffset, &buzzerTotal, sizeof(buzzerTotal));
    WriteGoalValue(gameInfo + kGameInfoFuelOffset, &fuel, sizeof(fuel));
    NSLog(@"jakIOS: dev menu: gave %d power cells, %d scout flies, %d orbs", cellsGiven, fliesGiven, orbsGiven);
}

// After a grant the orbs still lying in the world can be picked up again, which would push a
// level's orb count past its total (and completion past 100%). Clamp to the totals, which stock
// play can never exceed anyway.
void ClampCollectedOrbsToTotals() {
    constexpr uint32_t kGameInfoMoneyTotalOffset = 20;
    constexpr uint32_t kGameInfoMoneyPerLevelOffset = 24;
    constexpr uint32_t kGameCountsDataOffset = 4;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    uint32_t gameInfo = 0, gameCounts = 0, levelTaskData = 0;
    int32_t countsLength = 0, levelCount = 0;
    uint8_t collected[32] {};
    if (!symbolValue("*game-info*", &gameInfo) || !symbolValue("*game-counts*", &gameCounts) ||
        !symbolValue("*level-task-data*", &levelTaskData) ||
        !ReadGoalValue(gameCounts, &countsLength, sizeof(countsLength)) ||
        !ReadGoalValue(levelTaskData, &levelCount, sizeof(levelCount)) ||
        !ReadGoalValue(gameInfo + kGameInfoMoneyPerLevelOffset, collected, sizeof(collected))) return;
    const int32_t levels = std::min({countsLength, levelCount, 32});
    float total = 0;
    bool clamped = false;
    for (int32_t level = 0; level < levels; level++) {
        int32_t levelOrbs = 0;
        if (!ReadGoalValue(gameCounts + kGameCountsDataOffset + level * 8, &levelOrbs, sizeof(levelOrbs))) return;
        total += levelOrbs;
        if (levelOrbs >= 0 && collected[level] > levelOrbs) {
            const uint8_t all = static_cast<uint8_t>(levelOrbs);
            WriteGoalValue(gameInfo + kGameInfoMoneyPerLevelOffset + level, &all, sizeof(all));
            clamped = true;
        }
    }
    float moneyTotal = 0;
    if (clamped && ReadGoalValue(gameInfo + kGameInfoMoneyTotalOffset, &moneyTotal, sizeof(moneyTotal)) &&
        moneyTotal > total) {
        WriteGoalValue(gameInfo + kGameInfoMoneyTotalOffset, &total, sizeof(total));
    }
}

// Runs after each kernel frame. init-game-options clears *options-remap* whenever the menu opens,
// so the Dev Menu screen's list is put back every frame, and the pause menu always uses the
// variant with the Secrets row (stock shows it only once a cheat is known) so the Dev Menu is
// reachable on any save. A Cross / Circle press GOAL saw this frame on the Give 100% Items row
// (button0-rel; buttons aren't cleared by respond-progress) runs the grant.
void SyncIOSDevMenu() {
    if (!gNativeHelperContext.installedIOSDevMenu) return;
    constexpr uint32_t kArrayDataOffset = 12;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    ClampCollectedOrbsToTotals();
    // The Dev Menu row is grayed out and can't be selected: give it the captured Display predicate,
    // which always returns true on iOS (as Touch Options does). It is learned by
    // RemoveIOSDesktopGraphicsOptions, possibly after this menu was installed, so write it every frame.
    constexpr uint32_t kDisabledFunctionOffset = 36;
    const uint32_t disabledFunction = gNativeHelperContext.alwaysDisabledOptionFunction;
    if (disabledFunction != 0) {
        WriteGoalValue(gNativeHelperContext.iosDevMenuRow + kDisabledFunctionOffset,
                       &disabledFunction, sizeof(disabledFunction));
    }
    uint32_t remap = 0;
    if (!symbolValue("*options-remap*", &remap)) return;
    const uint32_t devMenuSlot = remap + kArrayDataOffset + kDevMenuScreen * sizeof(uint32_t);
    uint32_t current = 0;
    if (ReadGoalValue(devMenuSlot, &current, sizeof(current)) && current != gNativeHelperContext.iosDevMenu) {
        WriteGoalValue(devMenuSlot, &gNativeHelperContext.iosDevMenu, sizeof(gNativeHelperContext.iosDevMenu));
    }
    // PromoteIOSInputOptions swapped the arrays' storage, so use the symbols' current values.
    uint32_t withoutSecrets = 0, withSecrets = 0;
    const uint32_t settingsSlot = remap + kArrayDataOffset + kSettingsScreen * sizeof(uint32_t);
    if (symbolValue("*main-options-pc*", &withoutSecrets) && symbolValue("*main-options-secrets*", &withSecrets) &&
        ReadGoalValue(settingsSlot, &current, sizeof(current)) && current == withoutSecrets) {
        WriteGoalValue(settingsSlot, &withSecrets, sizeof(withSecrets));
    }

    ProgressMenuState menu;
    if (!ReadProgressMenuState(&menu) || !menu.paused || !menu.acceptsInput() || menu.editing ||
        menu.screen != kDevMenuScreen ||
        menu.option(menu.optionIndex) != gNativeHelperContext.iosDevMenuGiveAllOption) return;
    // *cpad-list*: cpad-info pointers from +4; cpad-info button0-rel[0] at +56.
    uint32_t cpadList = 0, pad0 = 0, pressed = 0;
    if (!symbolValue("*cpad-list*", &cpadList) || !ReadGoalValue(cpadList + 4, &pad0, sizeof(pad0)) ||
        pad0 == 0 || pad0 == s7 || !ReadGoalValue(pad0 + 56, &pressed, sizeof(pressed)) ||
        (pressed & (kPadCross | kPadCircle)) == 0) return;
    GiveAllCollectibles();
}

// Mirror mode is chosen per save on the New Game screen (see SyncMirrorMode), so drop its row
// from the Cheats list (*cheats*). Its other rows only use their own param1 bit, and init
// re-points value-to-modify for every row but the last (Back), so they can just move up.
void RemoveIOSMirrorCheatOption() {
    if (gNativeHelperContext.removedMirrorCheatOption) return;
    constexpr uint32_t kBoxedArrayDataOffset = 12;
    constexpr uint32_t kGameOptionNameOffset = 12;
    constexpr uint32_t kCheatMirrorTextId = 0x109f;
    constexpr int32_t kMaxRows = 32;
    const auto symbol = gNativeHelperContext.symbols.find("*cheats*");
    uint32_t options = 0;
    int32_t length = 0;
    uint32_t rows[kMaxRows] {};
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &options, sizeof(options)) ||
        options == 0 || options == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(options, &length, sizeof(length)) || length < 2 || length > kMaxRows ||
        !ReadGoalValue(options + kBoxedArrayDataOffset, rows, length * sizeof(uint32_t))) {
        return;
    }
    int32_t mirrorRow = -1;
    for (int32_t index = 0; index < length; index++) {
        uint32_t name = 0;
        uint64_t type = 0;
        if (rows[index] == 0 ||
            !ReadGoalValue(rows[index] + kGameOptionNameOffset, &name, sizeof(name)) ||
            !ReadGoalValue(rows[index] + kGameOptionTypeOffset, &type, sizeof(type))) return;
        if (name == kCheatMirrorTextId && type == kOptionCheatToggle) mirrorRow = index;
    }
    if (mirrorRow < 0) return;
    std::copy(rows + mirrorRow + 1, rows + length, rows + mirrorRow);
    const int32_t newLength = length - 1;
    if (!WriteGoalValue(options + kBoxedArrayDataOffset, rows, newLength * sizeof(uint32_t)) ||
        !WriteGoalValue(options, &newLength, sizeof(newLength))) return;
    gNativeHelperContext.removedMirrorCheatOption = true;
    NSLog(@"jakIOS: removed Mirrored Mode from the cheats list");
}

// Mirror mode belongs to a save instead of being a global cheat. It unlocks by beating the game
// (the same check that unlocks the beat-the-game cheats: finalboss-movies closed), which marks the
// mirror cheat known. The New Game slot screen then shows a checkbox (drawn by the app, R1
// toggles it with a controller); the new game, and every save made from it, carries the choice in
// the save file (Jak1MemoryCardManager). Loading a save turns it on or off to match, and it is
// always off on the title screen and its menus. It is applied through the PC port's cheat bit
// (*pc-settings* cheats), which flips the camera projection, sprites, sound and analog sticks.
// Runs after each kernel frame.
void SyncMirrorMode() {
    // pc-settings-jak1 offsets from the object pointer (goalc probe).
    constexpr uint32_t kPCSettingsCheatsOffset = 396;       // pc-cheats (u64)
    constexpr uint32_t kPCSettingsCheatsKnownOffset = 404;  // pc-cheats (u64)
    constexpr uint32_t kPCSettingsSkipMoviesOffset = 412;   // skip-movies?, then subtitles?
    constexpr uint64_t kPCCheatMirror = 1ull << 8;
    constexpr uint64_t kGameTaskFinalbossMovies = 112;
    constexpr uint64_t kTaskStatusNeedReminder = 5;
    constexpr uint32_t kUnlockCheckInterval = 60;           // frames
    constexpr uint32_t kSettingCurrentVideoModeOffset = 12 + 68;
    constexpr uint32_t kSettingCurrentAspectRatioOffset = 12 + 72;

    gNativeHelperContext.fileSelectSlotsDrawn = 0;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    const auto isBoolean = [s7](uint32_t value) { return value == s7 || value == s7 + 8; };
    uint32_t settings = 0;
    uint64_t cheats = 0, known = 0;
    uint32_t afterCheats[2] {};
    if (!symbolValue("*pc-settings*", &settings) ||
        !ReadGoalValue(settings + kPCSettingsSkipMoviesOffset, afterCheats, sizeof(afterCheats)) ||
        !isBoolean(afterCheats[0]) || !isBoolean(afterCheats[1]) ||
        !ReadGoalValue(settings + kPCSettingsCheatsOffset, &cheats, sizeof(cheats)) ||
        !ReadGoalValue(settings + kPCSettingsCheatsKnownOffset, &known, sizeof(known))) {
        static bool loggedLayoutMismatch = false;
        if (!loggedLayoutMismatch && settings != 0) {
            NSLog(@"jakIOS: pc-settings cheats not at the expected offset; mirror mode unavailable");
            loggedLayoutMismatch = true;
        }
        return;
    }
    const bool onTitle = gNativeHelperContext.onTitleScreen.load(std::memory_order_relaxed);

    // Unlock: checked now and then while a game is being played.
    static uint32_t unlockCountdown = 0;
    uint32_t target = 0, taskClosed = 0;
    if ((known & kPCCheatMirror) == 0 && !onTitle && unlockCountdown-- == 0) {
        unlockCountdown = kUnlockCheckInterval;
        if (symbolValue("*target*", &target) && symbolValue("task-closed?", &taskClosed) &&
            CallGoalOnArenaStack(taskClosed, kGameTaskFinalbossMovies, kTaskStatusNeedReminder, 0) != s7) {
            known |= kPCCheatMirror;
            WriteGoalValue(settings + kPCSettingsCheatsKnownOffset, &known, sizeof(known));
            NSLog(@"jakIOS: game beaten, mirror mode unlocked");
        }
    }
    const bool unlocked = (known & kPCCheatMirror) != 0;

    // The New Game slot screen (save-game-title) decides the new game's mirror mode.
    ProgressMenuState menu;
    const bool onNewGameScreen = onTitle && ReadProgressMenuState(&menu) &&
        menu.screen == kScreenSaveGameTitle;
    const bool showCheckbox = onNewGameScreen && unlocked && menu.nextScreen == kScreenSaveGameTitle;
    if (showCheckbox && menu.acceptsInput()) {
        // R1 toggles it with a controller (Square already backs out of this screen).
        // *cpad-list*: cpad-info pointers from +4; cpad-info button0-rel[0] at +56.
        constexpr uint32_t kPadR1 = 1 << 11;
        uint32_t cpadList = 0, pad0 = 0, pressed = 0;
        if (symbolValue("*cpad-list*", &cpadList) && ReadGoalValue(cpadList + 4, &pad0, sizeof(pad0)) &&
            pad0 != 0 && pad0 != s7 && ReadGoalValue(pad0 + 56, &pressed, sizeof(pressed)) &&
            (pressed & kPadR1) != 0) {
            gNativeHelperContext.newGameMirrorChecked.store(
                !gNativeHelperContext.newGameMirrorChecked.load(std::memory_order_relaxed),
                std::memory_order_relaxed);
        }
    }
    gNativeHelperContext.newGameMirrorVisible.store(showCheckbox, std::memory_order_relaxed);
    if (!onTitle) gNativeHelperContext.newGameMirrorChecked.store(false, std::memory_order_relaxed);
    if (onNewGameScreen) {
        gNativeHelperContext.sessionMirrorMode =
            unlocked && gNativeHelperContext.newGameMirrorChecked.load(std::memory_order_relaxed);
    }
    bool loadedMirror = false;
    if (jak1::memcard::TakeLoadedMirrorMode(&loadedMirror)) {
        gNativeHelperContext.sessionMirrorMode = loadedMirror;
    }
    jak1::memcard::SetMirrorModeForSaves(gNativeHelperContext.sessionMirrorMode);

    const bool mirror = gNativeHelperContext.sessionMirrorMode && !onTitle;
    gNativeHelperContext.mirrorModeActive.store(mirror, std::memory_order_relaxed);
    if (((cheats & kPCCheatMirror) != 0) == mirror) return;
    cheats = mirror ? (cheats | kPCCheatMirror) : (cheats & ~kPCCheatMirror);
    WriteGoalValue(settings + kPCSettingsCheatsOffset, &cheats, sizeof(cheats));
    // The projection only picks up the flip in update-math-camera; don't wait for cam-update.
    uint32_t settingControl = 0, videoMode = 0, aspectMode = 0, mathCamera = 0, updateMathCamera = 0;
    if (symbolValue("*setting-control*", &settingControl) &&
        ReadGoalValue(settingControl + kSettingCurrentVideoModeOffset, &videoMode, sizeof(videoMode)) &&
        ReadGoalValue(settingControl + kSettingCurrentAspectRatioOffset, &aspectMode, sizeof(aspectMode)) &&
        symbolValue("*math-camera*", &mathCamera) && symbolValue("update-math-camera", &updateMathCamera)) {
        CallGoalOnArenaStack(updateMathCamera, mathCamera, videoMode, aspectMode);
    }
    NSLog(@"jakIOS: mirror mode %@", mirror ? @"on" : @"off");
}

// The PC menu's second frame-rate entry (relabelled "120") sets target-fps to 100, and its
// carousel only recognizes 60/100/150 when the menu opens. ProMotion can't present at 100 Hz,
// so outside the pause menu run GOAL's timing (time-adjust-ratio, ticks per frame) at the 120
// we actually present, and restore 100 while the menu is open so it still shows "120" selected.
// Saved files may hold either value; pc-set-frame-rate maps both to 120.
void SyncIOSHighFrameRateTiming() {
    constexpr uint32_t kPCSettingsTargetFPSOffset = 12;  // basic: version u64 @ +4, target-fps i16 @ +12
    constexpr int16_t kMenuHighFPS = 100;
    constexpr int16_t kIOSHighFPS = 120;
    constexpr int32_t kTimerTicksPerSecond = 585900;     // video.gc: (/ 585900 target-fps)
    auto symbolValue = [](const char *name, uint32_t *symbolAddress) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        uint32_t value = 0;
        if (symbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(symbol->second, &value, sizeof(value))) {
            return 0;
        }
        if (symbolAddress != nullptr) *symbolAddress = symbol->second;
        return value;
    };
    const uint32_t settings = symbolValue("*pc-settings*", nullptr);
    if (settings == 0 || settings == gNativeHelperContext.s7GoalOffset) return;
    int16_t targetFPS = 0;
    if (!ReadGoalValue(settings + kPCSettingsTargetFPSOffset, &targetFPS, sizeof(targetFPS)) ||
        (targetFPS != kMenuHighFPS && targetFPS != kIOSHighFPS)) {
        return;
    }
    const uint32_t progress = symbolValue("*progress-process*", nullptr);
    const bool menuOpen = progress != 0 && progress != gNativeHelperContext.s7GoalOffset;
    const int16_t wanted = menuOpen ? kMenuHighFPS : kIOSHighFPS;
    if (targetFPS == wanted) return;
    WriteGoalValue(settings + kPCSettingsTargetFPSOffset, &wanted, sizeof(wanted));
    // *ticks-per-frame* is only recomputed by set-video-mode, which won't rerun for this change.
    uint32_t ticksSymbol = 0;
    symbolValue("*ticks-per-frame*", &ticksSymbol);
    if (ticksSymbol != 0) {
        const int32_t ticks = kTimerTicksPerSecond / wanted;
        WriteGoalValue(ticksSymbol, &ticks, sizeof(ticks));
    }
}

// *pc-settings* ps2-parts? defaults to #f, and with it off sparticle-launch-control's spawn
// treats every effect as if it were at the camera: sp-item fade-after / falloff-to distance
// limits are ignored and the visibility sphere is 8x larger. Volcanic Crater's many lava pools
// (group-village3-lava-lava-20x20) then all launch their starflash/spark flashes at full rate,
// however far away, so the whole crater flickers. iOS removed the PS2 Options menu that toggles
// it, so keep it on (PS2 behaviour, also fewer particles to simulate and draw).
void ForceIOSPS2Particles() {
    // pckernel-h.gc pc-settings: ps2-read-speed? .. force-envmap? are eight consecutive symbols;
    // ps2-parts? is the second (deftype offset 280, basic object pointer + 276).
    constexpr uint32_t kPS2ReadSpeedOffset = 272;
    constexpr uint32_t kPS2PartsOffset = 276;
    constexpr uint32_t kPS2SymbolFieldCount = 8;
    static uint32_t settingsSymbol = 0;
    static bool loggedLayoutMismatch = false;
    if (settingsSymbol == 0) {
        const auto symbol = gNativeHelperContext.symbols.find("*pc-settings*");
        if (symbol == gNativeHelperContext.symbols.end()) return;
        settingsSymbol = symbol->second;
    }
    uint32_t settings = 0;
    if (!ReadGoalValue(settingsSymbol, &settings, sizeof(settings)) || settings == 0 ||
        settings == gNativeHelperContext.s7GoalOffset) {
        return;
    }
    const uint32_t falseSymbol = static_cast<uint32_t>(GoalBoolean(false));
    const uint32_t trueSymbol = static_cast<uint32_t>(GoalBoolean(true));
    uint32_t fields[kPS2SymbolFieldCount] {};
    if (!ReadGoalValue(settings + kPS2ReadSpeedOffset, fields, sizeof(fields))) return;
    // Only write if the layout matches: every ps2 field must hold #t or #f.
    for (uint32_t value : fields) {
        if (value != falseSymbol && value != trueSymbol) {
            if (!loggedLayoutMismatch) {
                NSLog(@"jakIOS: pc-settings ps2 fields not at the expected offset; ps2-parts? left unchanged");
                loggedLayoutMismatch = true;
            }
            return;
        }
    }
    const uint32_t parts = fields[(kPS2PartsOffset - kPS2ReadSpeedOffset) / 4];
    if (parts == trueSymbol) return;
    WriteGoalValue(settings + kPS2PartsOffset, &trueSymbol, sizeof(trueSymbol));
    NSLog(@"jakIOS: enabled PS2 particle distance limits (ps2-parts?)");
}

// Stock Jak 1 slides hud elements in diagonally from the screen corners: the hidden offset
// (0..128) is scaled by x-sgn/y-sgn. iOS re-lays out the HUD (HUD space ~512 wide x ~448 high):
// - health meter + green eco count (hud-health and its friend hud-pickups, top-left) rest on the
//   left edge and slide in horizontally (health y 55/76 -> 160/181, eco count text 45 -> 150);
// - eco meter (hud-power, bottom-right) rests at the same height on the right edge and slides
//   in horizontally (y 370/368 -> 172/170);
//   both meters are centred at HUD y ~171, midway between the touch overlay's R1 bottom edge
//   (88 pt) and Triangle top edge (H - 183 pt) on a 402 pt-high iPhone 17 Pro screen
//   (TouchControlsOverlay: (H - 95) / 2 pt = 38% of the height). Re-derive if that layout changes;
// - power cell count (hud-fuel-cell, top-centre) and orb count (hud-money, top-right) both drop
//   straight down from the top, with their groups (icon, then number ~20 units right, centre
//   ~icon-x + 14) centred at the thirds of the width (171 / 341) so the gaps to each edge and
//   between them are equal: power cell icon 256 -> 157, orb icon 399 -> 327.
// - scout fly count (hud-buzzers, bottom-left) drops straight down into the top row, centred
//   between them at x 256 (particle 60 -> 241, text 85 -> 266). Its draw-hud resets text-y to 362
//   every draw, so it's raised with y-offset (added to text and particle y) instead: -317 puts the
//   text at 45 and the fly at 63, level with the other counters (end of the function).
// - zoomer: heat gauge (left) and speedometer (right) share a row under the Pause button, sliding
//   in horizontally, at mirrored edge gaps; the eco meter (beside the speedometer) and the health
//   meter (beside the heat gauge, mirrored) drop from the top onto that row.
// init-particles! and set-pos-and-scale rewrite positions with the stock values, so after every
// kernel frame any value still inside its stock range is shifted; already-shifted values fall
// outside it and are left alone.
void ApplyIOSHudLayout() {
    struct AxisShift {
        float stockMin;  // values in [stockMin, stockMax) are unshifted stock positions
        float stockMax;
        int32_t delta;
        bool isStock(float value) const { return delta != 0 && value >= stockMin && value < stockMax; }
    };
    struct HudLayout {
        uint32_t hudPartsOffset;  // (pointer hud-*) field in hud-parts
        int32_t xSgn;
        int32_t ySgn;
        AxisShift x;              // applied to text-x, icon-x and particle init-pos x
        AxisShift y;              // applied to text-y and particle init-pos y
    };
    constexpr AxisShift kNoShift {0, 0, 0};
    // Centre row of the zoomer meters. Pause ends 40 pt from the top (~45 HUD units on a 402 pt
    // screen) and the heat gauge reaches ~55 units above its centre, leaving ~20 units between.
    constexpr int32_t kZoomerHudY = 120;
    static constexpr HudLayout kLayouts[] = {
        {12, -1, 0, kNoShift, {-1.0e6f, 120.0f, 105}},   // health: stock y <= 80
        {0, -1, 0, kNoShift, {-1.0e6f, 120.0f, 105}},    // pickups: stock particle y 55, text-y 45
        {20, 1, 0, kNoShift, {300.0f, 1.0e6f, -198}},    // power: stock y 368/370; unused text-y 0
        {8, 0, -1, {240.0f, 300.0f, -99}, kNoShift},     // fuel-cell: icon/particle 256, text 276
        {4, 0, -1, {380.0f, 440.0f, -72}, kNoShift},     // money: icon 399, particle 400, text 420
        {16, 0, -1, {0.0f, 120.0f, 181}, kNoShift},      // buzzers: particle 60, text 85
        // Zoomer meters (racer-part.gc, only spawned while riding): stock bottom corners at y 370,
        // raised to one row just under the touch overlay's Pause button and slid in horizontally.
        {28, -1, 0, kNoShift, {300.0f, 1.0e6f, kZoomerHudY - 370}},  // bike-heat (left)
        {24, 1, 0, kNoShift, {300.0f, 1.0e6f, kZoomerHudY - 370}},   // bike-speed (right)
    };
    // hud field offsets include the 4-byte type tag.
    constexpr uint32_t kHudXSgnOffset = 156;           // x-sgn int32
    constexpr uint32_t kHudYSgnOffset = 160;           // y-sgn int32
    constexpr uint32_t kHudTextXOffset = 164;          // text-x int32
    constexpr uint32_t kHudTextYOffset = 168;          // text-y int32
    constexpr uint32_t kHudNbIconsOffset = 216;        // nb-of-icons int32
    constexpr uint32_t kHudIconsOffset = 220;          // icons: hud-icon[6] references
    constexpr uint32_t kMaxHudIcons = 6;
    constexpr uint32_t kHudNbParticlesOffset = 248;    // nb-of-particles int32
    constexpr uint32_t kHudParticlesOffset = 252;      // particles: hud-particle[7] references
    constexpr uint32_t kMaxHudParticles = 7;
    constexpr uint32_t kIconXOffset = 12;              // hud-icon icon-x int32
    constexpr uint32_t kParticleInitPosXOffset = 16;   // hud-particle init-pos (vector @ 16) .x
    constexpr uint32_t kParticleInitPosYOffset = 20;   // .y
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbol = gNativeHelperContext.symbols.find("*hud-parts*");
    uint32_t hudParts = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &hudParts, sizeof(hudParts)) ||
        hudParts == 0 || hudParts == s7) {
        return;
    }
    // Reads a basic reference, rejecting null and #f.
    const auto readReference = [s7](uint32_t address, uint32_t *reference) {
        return ReadGoalValue(address, reference, sizeof(*reference)) && *reference != 0 && *reference != s7;
    };
    const auto setInt = [](uint32_t address, int32_t wanted) {
        int32_t value = 0;
        if (ReadGoalValue(address, &value, sizeof(value)) && value != wanted) {
            WriteGoalValue(address, &wanted, sizeof(wanted));
        }
    };
    const auto shiftInt = [](uint32_t address, const AxisShift &shift) {
        int32_t value = 0;
        if (ReadGoalValue(address, &value, sizeof(value)) && shift.isStock(value)) {
            const int32_t shifted = value + shift.delta;
            WriteGoalValue(address, &shifted, sizeof(shifted));
        }
    };
    const auto shiftFloat = [](uint32_t address, const AxisShift &shift) {
        float value = 0;
        if (ReadGoalValue(address, &value, sizeof(value)) && shift.isStock(value)) {
            const float shifted = value + shift.delta;
            WriteGoalValue(address, &shifted, sizeof(shifted));
        }
    };
    const auto readCount = [](uint32_t address, uint32_t maxCount) -> uint32_t {
        int32_t count = 0;
        if (!ReadGoalValue(address, &count, sizeof(count))) return 0;
        return std::min<uint32_t>(std::max(count, 0), maxCount);
    };
    for (const HudLayout &layout : kLayouts) {
        // (-> *hud-parts* <field> 0): pointer to the process-tree slot, #f when unspawned.
        uint32_t slot = 0;
        uint32_t hud = 0;
        if (!readReference(hudParts + layout.hudPartsOffset, &slot) || !readReference(slot, &hud)) continue;
        const uint32_t base = hud - 4;
        setInt(base + kHudXSgnOffset, layout.xSgn);
        setInt(base + kHudYSgnOffset, layout.ySgn);
        // Huds that don't draw text (health, power) have unused text fields; shifting is harmless.
        shiftInt(base + kHudTextXOffset, layout.x);
        shiftInt(base + kHudTextYOffset, layout.y);
        // Icon y is rewritten by hud-update every frame, so only icon x is relocated.
        const uint32_t iconCount = readCount(base + kHudNbIconsOffset, kMaxHudIcons);
        for (uint32_t i = 0; i < iconCount; ++i) {
            uint32_t icon = 0;
            if (readReference(base + kHudIconsOffset + i * 4, &icon)) {
                shiftInt(icon - 4 + kIconXOffset, layout.x);
            }
        }
        const uint32_t particleCount = readCount(base + kHudNbParticlesOffset, kMaxHudParticles);
        for (uint32_t i = 0; i < particleCount; ++i) {
            uint32_t particle = 0;
            if (!readReference(base + kHudParticlesOffset + i * 4, &particle)) continue;
            shiftFloat(particle - 4 + kParticleInitPosXOffset, layout.x);
            shiftFloat(particle - 4 + kParticleInitPosYOffset, layout.y);
        }
    }

    // Scout flies: y-offset is copied from next-y-offset when the hud leaves hud-hidden (the racer
    // sets next-y-offset to -120 / 0 on the zoomer), so pin both. draw-hud adds text-y-offset (-40
    // in 16:9) to the text only whenever next-y-offset is nonzero, so zero it to keep the text
    // aligned with the fly.
    constexpr uint32_t kHudPartsBuzzersOffset = 16;    // hud-parts: (pointer hud-buzzers) @ +16
    constexpr uint32_t kHudYOffsetOffset = 148;        // y-offset int32
    constexpr uint32_t kHudNextYOffsetOffset = 152;    // next-y-offset int32
    constexpr uint32_t kBuzzersTextYOffsetOffset = 284;  // hud-buzzers text-y-offset int32
    constexpr int32_t kBuzzersYOffset = -317;          // text 362 -> 45, fly 380 -> 63
    uint32_t buzzersSlot = 0;
    uint32_t buzzers = 0;
    if (readReference(hudParts + kHudPartsBuzzersOffset, &buzzersSlot) && readReference(buzzersSlot, &buzzers)) {
        const uint32_t base = buzzers - 4;
        setInt(base + kHudYOffsetOffset, kBuzzersYOffset);
        setInt(base + kHudNextYOffsetOffset, kBuzzersYOffset);
        setInt(base + kBuzzersTextYOffsetOffset, 0);
    }

    // Zoomer layout, mirrored about the screen centre. HUD x runs 0..512; the PC port narrows x
    // spacing and sprite widths by r (aspect-ratio-reciprocal). A screen-space sprite is
    // scale * r / 240 units wide per half (sprite-add-matrix-data: basis-x 0.4r, 1/48 hud scale).
    // - heat gauge (zoomerhud-main-02, 3 m = 102r wide, left-anchored by rot-x 4, particle 2) stays
    //   put; the speedometer (zoomerhud-main-03, same size, particle 1) moves to the same gap from
    //   the right edge;
    // - the eco meter (hud-power) sits kZoomerMeterGap left of the speedometer and the health meter
    //   (hud-health, with its green eco count hud-pickups) at the mirrored spot right of the heat
    //   gauge. Both drop in from the top: y-sgn -2, since the 128-unit slide alone would start them
    //   partly on screen.
    // Rows come from y-offset (pinned with next-y-offset, which the racer also sets). x has no
    // offset field, so particle x positions are written directly.
    // pckernel's update-video-hacks reruns every hud's set-pos-and-scale at the end of every frame.
    // The eco meter's and speedometer's versions derive their positions from the current ones, so
    // those get absolute positions rewritten every frame (shifting what the game left there jittered
    // them by up to a unit each frame). Health is reset to exact stock values, so a fixed shift is
    // stable; pickups is never reset. Both are moved back on dismount.
    constexpr uint32_t kHudPartsPickupsOffset = 0;
    constexpr uint32_t kHudPartsHealthOffset = 12;
    constexpr uint32_t kHudPartsPowerOffset = 20;
    constexpr uint32_t kHudPartsBikeSpeedOffset = 24;
    constexpr uint32_t kPowerScaleTimerOffset = 280;   // hud-power scale-timer float (eco ring)
    constexpr uint32_t kHudPartsBikeHeatOffset = 28;
    constexpr float kZoomerGaugeWidth = 102.0f;        // 3 m gauge sprites
    constexpr float kZoomerMeterGap = 4.0f;            // eco / health meter to their gauge
    constexpr int32_t kZoomerDropSgn = -2;
    struct ZoomerXMove {
        uint32_t hud = 0;  // hud whose x positions were moved, 0 if none
        float x0 = 0;      // its particle 0 x as last written
        float delta = 0;   // whole units, so the int text-x moves by exactly the same amount
    };
    static ZoomerXMove healthMove, pickupsMove;
    static bool zoomerLayoutApplied = false;
    static float zoomerNarrowing = 1.0f;  // r while on the zoomer, for putting the eco meter back
    const auto readHud = [&](uint32_t partsOffset) -> uint32_t {
        uint32_t slot = 0, hud = 0;
        return readReference(hudParts + partsOffset, &slot) && readReference(slot, &hud) ? hud : 0;
    };
    const auto particleAddress = [&](uint32_t hud, uint32_t index, uint32_t fieldOffset, uint32_t *address) {
        uint32_t particle = 0;
        if (!readReference(hud - 4 + kHudParticlesOffset + index * 4, &particle)) return false;
        *address = particle - 4 + fieldOffset;
        return true;
    };
    const auto readParticle = [&](uint32_t hud, uint32_t index, uint32_t fieldOffset, float *value) {
        uint32_t address = 0;
        return particleAddress(hud, index, fieldOffset, &address) && ReadGoalValue(address, value, sizeof(*value));
    };
    // Midpoint of the particles' init-pos x or y (the meters' sprites are centred on them).
    const auto particleCenter = [&](uint32_t hud, uint32_t fieldOffset, float *center) {
        const uint32_t count = readCount(hud - 4 + kHudNbParticlesOffset, kMaxHudParticles);
        float low = 1.0e9f, high = -1.0e9f;
        for (uint32_t i = 0; i < count; ++i) {
            float value = 0;
            if (!readParticle(hud, i, fieldOffset, &value)) return false;
            low = std::min(low, value);
            high = std::max(high, value);
        }
        if (count == 0) return false;
        *center = 0.5f * (low + high);
        return true;
    };
    const auto shiftX = [&](uint32_t hud, float delta, bool moveText) {
        const uint32_t count = readCount(hud - 4 + kHudNbParticlesOffset, kMaxHudParticles);
        for (uint32_t i = 0; i < count; ++i) {
            uint32_t address = 0;
            float x = 0;
            if (particleAddress(hud, i, kParticleInitPosXOffset, &address) && ReadGoalValue(address, &x, sizeof(x))) {
                x += delta;
                WriteGoalValue(address, &x, sizeof(x));
            }
        }
        int32_t textX = 0;
        if (moveText && ReadGoalValue(hud - 4 + kHudTextXOffset, &textX, sizeof(textX))) {
            textX += static_cast<int32_t>(delta);
            WriteGoalValue(hud - 4 + kHudTextXOffset, &textX, sizeof(textX));
        }
    };
    // True when the hud's x positions are stock (never moved, or reset since).
    const auto needsMove = [&](const ZoomerXMove &move, uint32_t hud) {
        float x0 = 0;
        return readParticle(hud, 0, kParticleInitPosXOffset, &x0) && (hud != move.hud || x0 != move.x0);
    };
    const auto applyMove = [&](ZoomerXMove &move, uint32_t hud, float delta, bool moveText) {
        move.delta = std::round(delta);
        shiftX(hud, move.delta, moveText);
        readParticle(hud, 0, kParticleInitPosXOffset, &move.x0);
        move.hud = hud;
    };
    const auto undoMove = [&](ZoomerXMove &move, uint32_t hud, bool moveText) {
        float x0 = 0;
        if (move.hud != 0 && hud == move.hud && readParticle(hud, 0, kParticleInitPosXOffset, &x0) && x0 == move.x0) {
            shiftX(hud, -move.delta, moveText);
        }
        move.hud = 0;
    };
    // Drop in from the top and sit on the zoomer row (centred on its particles' y).
    const auto setDropRow = [&](uint32_t hud, int32_t yOffset) {
        const uint32_t base = hud - 4;
        setInt(base + kHudXSgnOffset, 0);
        setInt(base + kHudYSgnOffset, kZoomerDropSgn);
        setInt(base + kHudYOffsetOffset, yOffset);
        setInt(base + kHudNextYOffsetOffset, yOffset);
    };
    // Writes particle x positions: x0 plus each particle's stock offset (narrowed by r).
    const auto writeX = [&](uint32_t hud, float x0, std::initializer_list<float> offsets) {
        uint32_t index = 0;
        for (const float offset : offsets) {
            uint32_t address = 0;
            const float x = x0 + offset;
            float current = 0;
            if (particleAddress(hud, index++, kParticleInitPosXOffset, &address) &&
                ReadGoalValue(address, &current, sizeof(current)) && current != x) {
                WriteGoalValue(address, &x, sizeof(x));
            }
        }
    };
    const uint32_t speed = readHud(kHudPartsBikeSpeedOffset);
    const uint32_t heat = readHud(kHudPartsBikeHeatOffset);
    const uint32_t power = readHud(kHudPartsPowerOffset);
    const uint32_t health = readHud(kHudPartsHealthOffset);
    const uint32_t pickups = readHud(kHudPartsPickupsOffset);
    float dialX = 0, mainX = 0;
    if (speed != 0 && gNativeHelperContext.onZoomer.load(std::memory_order_relaxed) &&
        readParticle(speed, 0, kParticleInitPosXOffset, &dialX) &&
        readParticle(speed, 1, kParticleInitPosXOffset, &mainX)) {
        zoomerLayoutApplied = true;
        // The speedometer's dial sits 55 units right of its main sprite at 4:3.
        const float r = std::clamp((dialX - mainX) / 55.0f, 0.2f, 1.0f);
        zoomerNarrowing = r;
        // Mirror the heat gauge's gap to the left edge (its main sprite's left edge), or its
        // settled stock gap at this narrowing if it isn't up (Fire Canyon has no heat gauge).
        float heatLeft = 0;
        if (heat == 0 || !readParticle(heat, 2, kParticleInitPosXOffset, &heatLeft)) {
            const float heatBase = r * 13.0f * r / (1.0f - r * (1.0f - r));
            heatLeft = heatBase + r * (20.0f - heatBase);
        }
        // Speedometer particles: dial 433, main 378 (its left edge), knob 415 at 4:3.
        const float speedLeft = 512.0f - heatLeft - kZoomerGaugeWidth * r;
        writeX(speed, speedLeft, {55.0f * r, 0.0f, 37.0f * r});
        float ecoCenterX = 0;
        if (power != 0) {
            float scaleTimer = 0;
            if (!ReadGoalValue(power - 4 + kPowerScaleTimerOffset, &scaleTimer, sizeof(scaleTimer)) ||
                !(scaleTimer > 4096.0f && scaleTimer < 32768.0f)) {
                scaleTimer = 11468.8f;
            }
            ecoCenterX = speedLeft - kZoomerMeterGap * r - scaleTimer * r / 240.0f;
            // Eco meter particles: backing 435, blue 432, ring 435 at 4:3.
            writeX(power, ecoCenterX, {0.0f, -3.0f * r, 0.0f});
            float centerY = 0;
            if (particleCenter(power, kParticleInitPosYOffset, &centerY)) {
                setDropRow(power, static_cast<int32_t>(std::lround(kZoomerHudY - centerY)));
            }
        }
        if (health != 0 && ecoCenterX != 0) {
            float centerX = 0, centerY = 0;
            if (needsMove(healthMove, health) && particleCenter(health, kParticleInitPosXOffset, &centerX)) {
                applyMove(healthMove, health, (512.0f - ecoCenterX) - centerX, false);
            }
            if (particleCenter(health, kParticleInitPosYOffset, &centerY)) {
                const int32_t yOffset = static_cast<int32_t>(std::lround(kZoomerHudY - centerY));
                setDropRow(health, yOffset);
                // The green eco count travels with the health meter it sits beside.
                if (pickups != 0) {
                    if (healthMove.hud == health && needsMove(pickupsMove, pickups)) {
                        applyMove(pickupsMove, pickups, healthMove.delta, true);
                    }
                    setDropRow(pickups, yOffset);
                }
            }
        }
    } else if (zoomerLayoutApplied) {
        // Off the zoomer: back to the side spots (the main loop restores the slide directions).
        zoomerLayoutApplied = false;
        // The speedometer is going away, and the eco meter's per-frame set-pos-and-scale settles
        // back to stock within a few frames from anywhere; start it at the settled spot:
        // base = 435 + (512 - 435)(1 - r) iterated, i.e. the fixed point of
        // p = (1 - r)(512(1 - r) + r p) + 435 r.
        if (power != 0) {
            const float r = zoomerNarrowing;
            const float settled = (512.0f * (1.0f - r) * (1.0f - r) + 435.0f * r) / (1.0f - r * (1.0f - r));
            writeX(power, settled, {0.0f, -3.0f * r, 0.0f});
        }
        undoMove(healthMove, health, false);
        undoMove(pickupsMove, pickups, true);
        for (const uint32_t hud : {power, health, pickups}) {
            if (hud == 0) continue;
            setInt(hud - 4 + kHudYOffsetOffset, 0);
            setInt(hud - 4 + kHudNextYOffsetOffset, 0);
        }
    }
}

// Diagnostic: Merc bone matrices are camera-space only if *math-camera* camera-rot is valid.
// Logs the camera inputs (math-camera trans/rot, look-through-other, combiner) periodically.
void LogCameraStateIfDue(uint64_t serial) {
    if (serial > 1200 || serial % 30 != 1) return;
    auto symbolValue = [](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        uint32_t value = 0;
        if (symbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(symbol->second, &value, sizeof(value))) {
            return 0;
        }
        return value;
    };
    // math-camera is a basic: type-db field offsets include the 4-byte type tag.
    const uint32_t mathCamera = symbolValue("*math-camera*") - 4;
    float trans[4] {}, camRot[16] {}, invRot[16] {}, fov = 0;
    ReadGoalValue(mathCamera + 848, trans, sizeof(trans));
    ReadGoalValue(mathCamera + 368, camRot, sizeof(camRot));
    ReadGoalValue(mathCamera + 432, invRot, sizeof(invRot));
    ReadGoalValue(mathCamera + 12, &fov, sizeof(fov));
    const uint32_t otherTrans = symbolValue("*camera-other-trans*");
    float other[4] {};
    ReadGoalValue(otherTrans, other, sizeof(other));
    NSLog(@"jakIOS: camera serial=%llu math-camera=0x%08x fov=%.1f trans=(%.1f %.1f %.1f %.1f) "
          @"look-through-other=0x%x combiner=0x%08x other-trans=(%.1f %.1f %.1f)",
          static_cast<unsigned long long>(serial), mathCamera, fov, trans[0], trans[1], trans[2],
          trans[3], symbolValue("*camera-look-through-other*"), symbolValue("*camera-combiner*"),
          other[0], other[1], other[2]);
    NSLog(@"jakIOS: camera inv-rot=(%.3f %.3f %.3f | %.3f %.3f %.3f | %.3f %.3f %.3f) "
          @"cam-rot.t=(%.1f %.1f %.1f %.1f)",
          invRot[0], invRot[1], invRot[2], invRot[4], invRot[5], invRot[6], invRot[8], invRot[9],
          invRot[10], camRot[12], camRot[13], camRot[14], camRot[15]);
}

bool WriteGoalString(uint32_t goalOffset, const char *source) {
    if (source == nullptr || gNativeHelperContext.addressSpace == nullptr) {
        return false;
    }
    uint8_t *object = gNativeHelperContext.addressSpace->pointerForGoal(
        goalOffset, sizeof(uint32_t)
    );
    if (object == nullptr) {
        return false;
    }
    uint32_t capacity = 0;
    memcpy(&capacity, object, sizeof(capacity));
    uint8_t *destination = gNativeHelperContext.addressSpace->pointerForGoal(
        goalOffset + sizeof(uint32_t), capacity + 1
    );
    if (destination == nullptr) {
        return false;
    }
    const size_t count = MIN(static_cast<size_t>(capacity), strlen(source));
    memcpy(destination, source, count);
    destination[count] = 0;
    return true;
}

struct __attribute__((packed)) NativeFileStream {
    uint32_t flags;
    uint32_t mode;
    uint32_t name;
    int32_t file;
};

NativeFileStream *GoalFileStream(uint32_t goalOffset) {
    return gNativeHelperContext.addressSpace == nullptr ? nullptr :
        reinterpret_cast<NativeFileStream *>(
            gNativeHelperContext.addressSpace->pointerForGoal(goalOffset, sizeof(NativeFileStream))
        );
}

// kprint.cpp print_object, without dispatching to GOAL print methods: bintegers, pairs,
// symbols and strings print like the original; other basics print as #<type @ #xaddr>.
void AppendGoalObject(std::string *output, uint64_t object, bool quoteStrings, int depth = 0) {
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const uint32_t offset = static_cast<uint32_t>(object);
    char buffer[64];
    switch (object & 7) {
        case 0:
            *output += std::to_string(static_cast<int64_t>(object) >> 3);
            return;
        case 2: { // pair
            if (offset == s7 - 0xa) {
                *output += "()";
                return;
            }
            if (depth > 8) {
                *output += "(...)";
                return;
            }
            *output += '(';
            uint32_t pair = offset;
            for (int count = 0; count < 64; count++) {
                uint32_t car = 0;
                uint32_t cdr = 0;
                if (!ReadGoalValue(pair - 2, &car, 4) || !ReadGoalValue(pair + 2, &cdr, 4)) {
                    break;
                }
                AppendGoalObject(output, car, quoteStrings, depth + 1);
                if (cdr == s7 - 0xa) {
                    break; // '() is FIX_SYM_EMPTY_PAIR (s7 - 0xa) in Jak 1
                }
                if ((cdr & 7) != 2) {
                    *output += " . ";
                    AppendGoalObject(output, cdr, quoteStrings, depth + 1);
                    break;
                }
                *output += ' ';
                pair = cdr;
            }
            *output += ')';
            return;
        }
        case 4: {
            if (offset == s7) {
                *output += "#f";
                return;
            }
            if (offset + 0x20000 > s7 && offset < s7 + 0x20000) {
                const char *name = GoalSymbolName(offset);
                *output += name != nullptr ? name : "#<symbol>";
                return;
            }
            uint32_t type = 0;
            uint32_t stringType = 0;
            ReadGoalValue(offset - 4, &type, 4);
            ReadGoalValue(s7 + 0x20, &stringType, 4);
            if (type != 0 && type == stringType) {
                const char *text = GoalString(offset);
                if (quoteStrings) {
                    *output += '"';
                }
                *output += text != nullptr ? text : "";
                if (quoteStrings) {
                    *output += '"';
                }
                return;
            }
            uint32_t typeName = 0;
            ReadGoalValue(type, &typeName, 4);
            const char *name = type != 0 ? GoalSymbolName(typeName) : nullptr;
            snprintf(buffer, sizeof(buffer), "#<%s @ #x%x>", name != nullptr ? name : "?", offset);
            *output += buffer;
            return;
        }
        default:
            snprintf(buffer, sizeof(buffer), "#<invalid object #x%llx>",
                     static_cast<unsigned long long>(object));
            *output += buffer;
            return;
    }
}

// kprint.cpp kitoa: base conversion with left padding to `length` (-1 = none).
std::string GoalIntegerText(int64_t value, unsigned base, int length, char pad) {
    static const char digits[] = "0123456789abcdef";
    uint64_t magnitude = (value < 0 && base == 10) ? static_cast<uint64_t>(-value)
                                                   : static_cast<uint64_t>(value);
    std::string reversed;
    do {
        reversed += digits[magnitude % base];
        magnitude /= base;
    } while (magnitude != 0);
    if (value < 0 && base == 10) {
        reversed += '-';
    }
    while (length > 0 && static_cast<int>(reversed.size()) < length) {
        reversed += pad;
    }
    return std::string(reversed.rbegin(), reversed.rend());
}

std::string GoalFloatText(float value, int length, char pad, int precision) {
    char buffer[96];
    snprintf(buffer, sizeof(buffer), "%.*f", precision < 0 ? 4 : precision, value);
    std::string text(buffer);
    if (length > 0 && static_cast<int>(text.size()) < length) {
        text.insert(0, static_cast<size_t>(length) - text.size(), pad);
    }
    return text;
}

// Applies ~N / ~N,'cA width to the text produced by an object directive.
void PadOrTruncate(std::string *text, int desiredLength, int padCharacter) {
    if (desiredLength < 0) {
        return;
    }
    const int length = static_cast<int>(text->size());
    if (desiredLength < length) {
        text->resize(static_cast<size_t>(desiredLength));
        if (desiredLength > 1) {
            (*text)[static_cast<size_t>(desiredLength) - 1] = '~';
        }
    } else if (length < desiredLength) {
        text->insert(0, static_cast<size_t>(desiredLength - length),
                     padCharacter >= 0 ? static_cast<char>(padCharacter) : ' ');
    }
}

// The load / save file lists (progress-draw.gc draw-memcard-file-select) show each saved slot's
// completion as "~D%", or its date in place of it ("...   ~2X:~2X") while the selected slot blinks.
// Neither string is formatted anywhere else, and slots are drawn in order, so the n-th of these
// in a frame belongs to the n-th saved slot. A mirror mode save gets an "M" left of its percentage.
// fileSelectSlotsDrawn is reset before each kernel frame.
void MarkMirrorModeSaveSlot(const char *format, std::string *output) {
    const bool percentage = std::strcmp(format, "~D%") == 0;
    if (!percentage && std::strstr(format, "   ~2X:~2X") == nullptr) return;
    const uint32_t line = gNativeHelperContext.fileSelectSlotsDrawn++;
    uint32_t seen = 0;
    for (int32_t file = 0; file < 4; file++) {
        if (!jak1::memcard::FilePresent(file)) continue;
        if (seen++ != line) continue;
        // The game font's kerned space is narrow; three keep the M clear of the digits.
        if (percentage && jak1::memcard::FileHasMirrorMode(file)) output->insert(0, "M   ");
        return;
    }
}

// Port of jak1 format_impl_jak1 (game/kernel/jak1/kprint.cpp). arguments[0] is the destination
// (#t / 0 = console, #f = new string, or a string to append to), arguments[1] the format string,
// arguments[2...7] the values.
uint64_t FormatGoal(const uint64_t *arguments) {
    const char *format = GoalString(static_cast<uint32_t>(arguments[1]));
    if (format == nullptr) {
        return 0;
    }
    std::string output;
    uint32_t nextArgument = 2;
    const auto takeArgument = [&]() -> uint64_t {
        return nextArgument < 8 ? arguments[nextArgument++] : 0;
    };
    const auto takeFloat = [&]() -> float {
        const uint32_t bits = static_cast<uint32_t>(takeArgument());
        float value = 0;
        memcpy(&value, &bits, sizeof(value));
        return value;
    };

    for (const char *cursor = format; *cursor != 0; cursor++) {
        if (*cursor != '~') {
            output += *cursor;
            continue;
        }
        const char *directiveStart = cursor;
        // Up to three prefix parameters: numbers, 'c characters, or `strings`.
        int parameters[3] = {-1, -1, -1};
        std::string stringParameter;
        int parameterIndex = 0;
        while (cursor[1] != 0) {
            const char next = cursor[1];
            if (next == ',') {
                parameterIndex = std::min(parameterIndex + 1, 2);
                cursor++;
            } else if (next == '\'') {
                parameters[parameterIndex] = static_cast<unsigned char>(cursor[2]);
                cursor += 2;
            } else if (next == '`') {
                cursor += 2;
                while (*cursor != 0 && *cursor != '`') {
                    stringParameter += *cursor++;
                }
                if (*cursor == 0) {
                    cursor--;
                }
            } else if (next == '-' || next == '+') {
                cursor++;
            } else if (next >= '0' && next <= '9') {
                parameters[parameterIndex] = std::max(parameters[parameterIndex], 0) * 10 + (next - '0');
                cursor++;
            } else {
                break;
            }
        }
        const char command = cursor[1];
        if (command == 0) {
            break;
        }
        cursor++;
        std::string piece;
        switch (command) {
            case '%':
                output += '\n';
                break;
            case '~':
                output += '~';
                break;
            case 'T': case 't':
                output += '\t';
                break;
            case 'G': case 'g': {
                const char *text = reinterpret_cast<const char *>(
                    gNativeHelperContext.addressSpace->pointerForGoal(
                        static_cast<uint32_t>(takeArgument()), 1));
                output += text != nullptr ? text : "";
                break;
            }
            case 'A': case 'a': case 'S': case 's': case 'P': case 'p': case 'I': case 'i':
                AppendGoalObject(&piece, takeArgument(), command == 'A' || command == 'a');
                if (command != 'P' && command != 'p' && command != 'I' && command != 'i') {
                    PadOrTruncate(&piece, parameters[0], parameters[1]);
                }
                output += piece;
                break;
            case 'C': case 'c':
                output += static_cast<char>(takeArgument());
                break;
            case 'X': case 'x':
                output += GoalIntegerText(static_cast<int64_t>(takeArgument()), 16, parameters[0],
                                          parameters[1] >= 0 ? static_cast<char>(parameters[1]) : '0');
                break;
            case 'D': case 'd':
                output += GoalIntegerText(static_cast<int64_t>(takeArgument()), 10, parameters[0],
                                          parameters[1] >= 0 ? static_cast<char>(parameters[1]) : ' ');
                break;
            case 'B': case 'b':
                output += GoalIntegerText(static_cast<int64_t>(takeArgument()), 2, parameters[0],
                                          parameters[1] >= 0 ? static_cast<char>(parameters[1]) : '0');
                break;
            case 'F':
                output += GoalFloatText(takeFloat(), 12, ' ', 4);
                break;
            case 'f': case 'R': case 'r': case 'M': case 'm': {
                float value = takeFloat();
                if (command == 'R' || command == 'r') {
                    value = value * 360.0f / 65536.0f;
                } else if (command == 'M' || command == 'm') {
                    value /= 4096.0f;
                }
                output += GoalFloatText(value, parameters[0],
                                        parameters[1] >= 0 ? static_cast<char>(parameters[1]) : ' ',
                                        parameters[2] >= 0 ? parameters[2] : 4);
                break;
            }
            case 'E': case 'e':
                output += GoalFloatText(static_cast<float>(static_cast<int64_t>(takeArgument())) / 300.0f,
                                        parameters[0], ' ', 4);
                break;
            default:
                // H, J, K, L, N, V, W, Y, Z and lower case: passed through for the text renderer.
                output.append(directiveStart, static_cast<size_t>(cursor - directiveStart + 1));
                break;
        }
    }

    MarkMirrorModeSaveSlot(format, &output);

    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const uint32_t destination = static_cast<uint32_t>(arguments[0]);
    if (destination == s7 + 8 || destination == 0) {
        // The stock game retries absent subtitle text every frame. Logging that expected failure
        // synchronously can dominate frame time on a device attached to Xcode; the STR loader
        // already reports each missing filename once.
        if (output == "Error loading subtitle\n") {
            return 0;
        }
        fputs(output.c_str(), stderr);
        return 0;
    }
    if (destination == s7) {
        return gNativeHelperContext.kernel != nullptr ?
            gNativeHelperContext.kernel->makeString(output.c_str()) : 0;
    }
    uint32_t type = 0;
    uint32_t stringType = 0;
    if ((destination & 7) == 4 && ReadGoalValue(destination - 4, &type, 4) &&
        ReadGoalValue(s7 + 0x20, &stringType, 4) && type == stringType) {
        uint32_t capacity = 0;
        ReadGoalValue(destination, &capacity, 4);
        char *text = reinterpret_cast<char *>(
            gNativeHelperContext.addressSpace->pointerForGoal(destination + 4, capacity + 1));
        if (text != nullptr) {
            // kstrncat: append, keeping the result within the string's capacity.
            const size_t used = strnlen(text, capacity);
            const size_t room = capacity > used ? capacity - used : 0;
            const size_t count = std::min(room, output.size());
            memcpy(text + used, output.data(), count);
            text[used + count] = 0;
        }
        return 0;
    }
    // GOAL's settings serializer passes an open file-stream as format's destination.
    // Write the formatted text to that stream so commit-to-file survives relaunches.
    NativeFileStream *stream = GoalFileStream(destination);
    if (stream != nullptr && (stream->flags & 1) == 0 && stream->file >= 0) {
        size_t offset = 0;
        while (offset < output.size()) {
            const ssize_t written = write(stream->file, output.data() + offset,
                                          output.size() - offset);
            if (written > 0) {
                offset += static_cast<size_t>(written);
            } else if (written < 0 && errno == EINTR) {
                continue;
            } else {
                stream->flags |= 1;
                break;
            }
        }
        return 0;
    }

    fputs(output.c_str(), stderr);
    return 0;
}

std::string SandboxedPath(const char *goalPath) {
    if (goalPath == nullptr || gNativeHelperContext.contentPath.empty()) {
        return {};
    }
    std::string relative(goalPath);
    const size_t colon = relative.find(':');
    if (colon != std::string::npos) {
        relative.erase(0, colon + 1);
    }
    while (!relative.empty() && relative.front() == '/') {
        relative.erase(relative.begin());
    }
    if (relative.empty() || relative.find("..") != std::string::npos) {
        return {};
    }
    // PC settings are mutable user data, not imported game content. Keeping them in Application
    // Support makes changes survive relaunches and also works when the imported content is read-only.
    if (relative.size() >= 14 &&
        relative.compare(relative.size() - 14, 14, "pc-settings.gc") == 0 &&
        !gNativeHelperContext.settingsPath.empty()) {
        return gNativeHelperContext.settingsPath + "/pc-settings.gc";
    }
    return gNativeHelperContext.contentPath + "/" + relative;
}

// Port of file_util::ISONameFromAnimationName: "ndi-intro" -> "NDINTRO", the 8.3 base name of
// the chunked STR file holding a spooled animation. Returns the name with padding trimmed.
std::string ISONameFromAnimationName(const char *source) {
    char destination[9] = {source[0], source[0] ? source[1] : '\0'};
    int count = 2;
    const char *word = source;
    while (*word != 0 && *word != '-') {
        word++;
    }
    const char *next = word;
    if (*word != 0) {
        while (word = next + 1, count < 8) {
            next = word;
            while (*next != 0 && *next != '-') {
                next++;
            }
            if (*next == 0) {
                break;
            }
            const size_t length = static_cast<size_t>(next - word);
            char character = *word;
            if (next[-1] >= '0' && next[-1] <= '9') {
                character = next[-1];
            } else if (length == 10 && memcmp(word, "resolution", 10) == 0) {
                character = 'z';
            } else if (length == 6 && memcmp(word, "accept", 6) == 0) {
                character = 'y';
            } else if (length == 6 && memcmp(word, "reject", 6) == 0) {
                character = 'n';
            } else if (length == 5 && memcmp(word, "keira", 5) == 0) {
                character = 'i';
            }
            destination[count++] = character;
        }
        while (*word != 0 && count < 8) {
            destination[count++] = *word++;
        }
    }
    std::string name(destination, static_cast<size_t>(count));
    for (char &character : name) {
        if (character >= 'a' && character <= 'z') {
            character -= 0x20;
        }
    }
    return name;
}

// Finds an imported ISO file by its 8.3 name, checking the content root and its first-level
// directories (the overlord's isofs->find searches the whole disc).
std::string FindImportedISOFileUncached(const std::string &root, const std::string &name) {
    struct stat info {};
    if (stat((root + "/" + name).c_str(), &info) == 0) {
        return root + "/" + name;
    }
    NSArray<NSString *> *entries =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(root.c_str()) error:nil];
    for (NSString *entry in entries) {
        const std::string candidate = root + "/" + entry.UTF8String + "/" + name;
        if (stat(candidate.c_str(), &info) == 0 && S_ISREG(info.st_mode)) {
            return candidate;
        }
    }
    return {};
}

// Imported content is read-only while the game runs, so lookups (including misses) are cached.
// The game polls for some PS2-only files (0SUBTIT.TXT) every frame; uncached, each poll listed
// the content directory and stat'ed every entry, the single largest CPU cost in the app.
std::string FindImportedISOFile(const std::string &name) {
    static std::mutex cacheMutex;
    static std::unordered_map<std::string, std::string> cache;
    const std::string key = gNativeHelperContext.contentPath + "\n" + name;
    {
        std::lock_guard<std::mutex> lock(cacheMutex);
        const auto found = cache.find(key);
        if (found != cache.end()) return found->second;
    }
    std::string path = FindImportedISOFileUncached(gNativeHelperContext.contentPath, name);
    std::lock_guard<std::mutex> lock(cacheMutex);
    cache[key] = path;
    return path;
}

void DisableViewerFallback();
bool gDisableViewerFallbackAfterCurrentFrame = false;

void ScheduleViewerFallbackDisable(uint32_t nameAddress, uint32_t entry) {
    // The link name is a raw C string (Kernel::linkBegin reads it with cString), not a GOAL string.
    const char *name = GoalCString(nameAddress);
    if (entry != 0 && name != nullptr && strcmp(name, "logo-intro") == 0) {
        gDisableViewerFallbackAfterCurrentFrame = true;
    }
}

// In-process replacement for the overlord's RPC_STR handler (game/overlord/jak1/stream.cpp).
// The command (RPC_Str_Cmd_Jak1) doubles as the receive buffer for str-load.
void HandleLoadStrRpc(uint32_t commandAddress) {
    constexpr uint16_t kStrResultDone = 0;
    constexpr uint16_t kStrResultError = 1;
    constexpr uint32_t kSectorSize = 0x800;
    constexpr uint32_t kSectorTableSize = 64;
    struct StrCommand {
        uint16_t reserved;
        uint16_t result;
        uint32_t address;
        int32_t chunk;
        uint32_t length;
        char name[64];
    } command {};
    if (!ReadGoalValue(commandAddress, &command, sizeof(command))) {
        return;
    }
    command.name[sizeof(command.name) - 1] = 0;
    command.result = kStrResultError;

    // 0x08000000 is the one-past-end failure sentinel for the 128 MB GOAL arena. The debug
    // birth-viewer fallback historically ignores a failed STR result and dereferences address+12.
    // Keep the fallback available while level actors are born, then retire it only when it reaches
    // this unsafe art-load path (not globally during startup, which prevents the level handoff).
    if (command.address >= gNativeHelperContext.goalMemorySize) {
        NSLog(@"jakIOS: rejecting out-of-range STR destination 0x%08x for %s",
              command.address, command.name);
        DisableViewerFallback();
        // The active birth-viewer invocation ignores result and immediately reads address+12.
        // Clear the sentinel in the response so that invocation cannot access one-past the arena.
        command.address = 0;
        command.length = 0;
        WriteGoalValue(commandAddress, &command, 16);
        return;
    }

    const auto loadRange = [&](const std::string &path, uint64_t offset, uint32_t size) -> bool {
        uint8_t *destination = gNativeHelperContext.addressSpace == nullptr ? nullptr :
            gNativeHelperContext.addressSpace->pointerForGoal(command.address, size);
        FILE *file = path.empty() ? nullptr : fopen(path.c_str(), "rb");
        if (file == nullptr || destination == nullptr) {
            if (file != nullptr) {
                fclose(file);
            }
            return false;
        }
        const bool ok = fseeko(file, static_cast<off_t>(offset), SEEK_SET) == 0 &&
            fread(destination, 1, size, file) == size;
        fclose(file);
        return ok;
    };

    if (command.chunk < 0) {
        // ISO names are upper case (MakeISOName); GOAL asks for e.g. "0common.TXT".
        std::string isoName(command.name);
        for (char &character : isoName) {
            if (character >= 'a' && character <= 'z') {
                character -= 0x20;
            }
        }
        // Text files come from the import-time PC build (Jak1PCTextBuilder) when it exists, so the
        // game sees OpenGOAL's added strings; otherwise from the disc.
        // Resolved path and size per name (misses included), as content doesn't change at runtime.
        struct ResolvedTextFile {
            std::string path;
            off_t size = -1;
        };
        static std::unordered_map<std::string, ResolvedTextFile> resolvedTextFiles;
        const std::string cacheKey = gNativeHelperContext.contentPath + "\n" + isoName;
        auto resolved = resolvedTextFiles.find(cacheKey);
        if (resolved == resolvedTextFiles.end()) {
            struct stat info {};
            ResolvedTextFile entry;
            entry.path = gNativeHelperContext.contentPath + "/pc-text/" + isoName;
            if (stat(entry.path.c_str(), &info) != 0) {
                entry.path = FindImportedISOFile(isoName);
            }
            // PC-only files absent from the disc (the OpenGOAL-compiled NSUBTIT.TXT subtitles)
            // ship in the app bundle.
            if (entry.path.empty()) {
                NSString *bundled = [NSBundle.mainBundle.resourcePath
                    stringByAppendingPathComponent:@(isoName.c_str())];
                if (bundled != nil) entry.path = bundled.UTF8String;
            }
            if (!entry.path.empty() && stat(entry.path.c_str(), &info) == 0) {
                entry.size = info.st_size;
            }
            resolved = resolvedTextFiles.emplace(cacheKey, std::move(entry)).first;
        }
        const std::string &path = resolved->second.path;
        if (resolved->second.size >= 0) {
            uint32_t size = static_cast<uint32_t>(resolved->second.size);
            if (command.length != 0 && command.length < size) {
                size = command.length;
            }
            if (loadRange(path, 0, size)) {
                command.length = size;
                command.result = kStrResultDone;
            }
        }
        // A missing file is polled every frame; report each name once.
        static std::unordered_set<std::string> reportedMissingFiles;
        if (command.result != kStrResultDone && reportedMissingFiles.insert(isoName).second) {
            NSLog(@"jakIOS: STR load failed for file %s", isoName.c_str());
        }
    } else if (static_cast<uint32_t>(command.chunk) < kSectorTableSize) {
        const std::string path = gNativeHelperContext.contentPath + "/STR/" +
            ISONameFromAnimationName(command.name) + ".STR";
        uint32_t header[kSectorTableSize * 2] = {};
        FILE *file = fopen(path.c_str(), "rb");
        const bool haveHeader = file != nullptr && fread(header, 1, sizeof(header), file) == sizeof(header);
        if (file != nullptr) {
            fclose(file);
        }
        if (haveHeader) {
            const uint32_t sector = header[command.chunk];
            const uint32_t size = header[kSectorTableSize + command.chunk];
            if (loadRange(path, static_cast<uint64_t>(sector) * kSectorSize, size)) {
                command.length = size;
                command.result = kStrResultDone;
            }
        }
        if (command.result != kStrResultDone) {
            NSLog(@"jakIOS: STR load failed for %s chunk %d (%s)", command.name, command.chunk,
                  path.c_str());
        }
    }
    WriteGoalValue(commandAddress, &command, 16);
}

// In-process replacement for the overlord's RPC_Ramdisk (game/overlord/jak1/ramdisk.cpp). Level
// VIS files live here; the game pulls each leaf's compressed visibility string from it.
struct RamdiskFile {
    uint32_t fileId = 0;
    std::vector<uint8_t> data;
};
std::vector<RamdiskFile> gRamdiskFiles;

void HandleRamdiskRpc(uint32_t function, uint32_t sendBuffer, uint32_t receiveBuffer, uint32_t receiveSize) {
    constexpr uint32_t kGetData = 0;       // RAMDISK_GET_DATA_FNO
    constexpr uint32_t kResetAndLoad = 1;  // RAMDISK_RESET_AND_LOAD_FNO
    struct LoadCommand {                   // RPC_Ramdisk_LoadCmd
        uint32_t pad;
        uint32_t fileIdOrEeAddr;
        uint32_t offsetIntoFile;
        uint32_t size;
        char name[16];
    } command {};
    if (!ReadGoalValue(sendBuffer, &command, sizeof(command))) return;

    if (function == kResetAndLoad) {
        gRamdiskFiles.clear();
        char name[17] = {};
        memcpy(name, command.name, 16);
        if (name[0] == 0) {
            // string->sound-name's uint128 return is lost by the AOT translation (see the DGO
            // workaround); make-file-name leaves the name ("vi1.VIS") in *file-temp-string*.
            const auto symbol = gNativeHelperContext.symbols.find("*file-temp-string*");
            uint32_t tempString = 0;
            if (symbol != gNativeHelperContext.symbols.end() &&
                ReadGoalValue(symbol->second, &tempString, sizeof(tempString))) {
                const char *source = GoalString(tempString);
                if (source != nullptr) strncpy(name, source, 16);
            }
        }
        for (char *c = name; *c != 0; c++) {
            if (*c >= 'a' && *c <= 'z') *c -= 0x20;
        }
        const std::string path = FindImportedISOFile(name);
        FILE *file = path.empty() ? nullptr : fopen(path.c_str(), "rb");
        if (file == nullptr) {
            NSLog(@"jakIOS: ramdisk could not find %s", name);
            return;
        }
        RamdiskFile ramdisk;
        ramdisk.fileId = command.fileIdOrEeAddr;
        fseeko(file, 0, SEEK_END);
        ramdisk.data.resize(static_cast<size_t>(ftello(file)));
        fseeko(file, 0, SEEK_SET);
        const size_t read = fread(ramdisk.data.data(), 1, ramdisk.data.size(), file);
        fclose(file);
        ramdisk.data.resize(read);
        NSLog(@"jakIOS: ramdisk loaded %s (%zu bytes) as id %u", name, read, ramdisk.fileId);
        gRamdiskFiles.push_back(std::move(ramdisk));
    } else if (function == kGetData) {
        for (const RamdiskFile &file : gRamdiskFiles) {
            if (file.fileId != command.fileIdOrEeAddr) continue;
            const uint64_t end = static_cast<uint64_t>(command.offsetIntoFile) + command.size;
            if (command.size > receiveSize || end > file.data.size()) {
                // Like the overlord, a short read still copies what exists.
                if (command.offsetIntoFile >= file.data.size()) return;
            }
            const uint32_t count = static_cast<uint32_t>(
                std::min<uint64_t>({command.size, receiveSize, file.data.size() - command.offsetIntoFile}));
            WriteGoalValue(receiveBuffer, file.data.data() + command.offsetIntoFile, count);
            return;
        }
    }
}

// Streamed-audio clock from the overlord (game/overlord/jak1/iso.cpp). Spooled animations
// (ja-play-spooled-anim) take their frame from *sound-iop-info* strpos and abort after 4 s if it
// stays <= 0. Until VAG audio streaming exists we run the overlord's "fake VAG clock".
struct VagStreamClock {
    bool running = false;
    // Like the overlord, streams without a VAG (e.g. the fisherman's boat rides, which are
    // animation-only) still run the clock; such a clock ignores the audio player's state.
    bool audioBacked = false;
    // While set, the clock is the audio's real playback position (the overlord's gRealVAGClock)
    // rather than a per-frame step, so audio and animation can't drift apart.
    bool followAudio = false;
    // Streams started by the sound player (ambient dialog) end with their audio. Spooled
    // animations are always stopped by GOAL (ja-abort-spooled-anim), so their clock outlives
    // the audio: otherwise strpos drops to -1 and the animation freezes for 4 s before
    // aborting (the title flyover hitched at the end of every loop).
    bool stopAtAudioEnd = false;
    bool paused = false;
    int32_t clock = 0;
    uint32_t audioStallFrames = 0;
    uint32_t soundId = 1;
    uint32_t frame = 0;
} gVagStreamClock;

void StartVagStreamClock(uint32_t soundId, bool audioBacked, bool stopAtAudioEnd) {
    gVagStreamClock.running = true;
    gVagStreamClock.audioBacked = audioBacked;
    gVagStreamClock.followAudio = audioBacked;
    gVagStreamClock.stopAtAudioEnd = audioBacked && stopAtAudioEnd;
    gVagStreamClock.paused = false;
    gVagStreamClock.clock = 0;
    gVagStreamClock.audioStallFrames = 0;
    gVagStreamClock.soundId = soundId;
}

void StopVagStreamClock() {
    gVagStreamClock.running = false;
    gVagStreamClock.audioBacked = false;
    gVagStreamClock.followAudio = false;
    gVagStreamClock.stopAtAudioEnd = false;
    gVagStreamClock.paused = false;
    gVagStreamClock.soundId = 1;
}

// Jak's animation names are converted to the eight-character keys stored in VAGDIR.AYB.
// Keep this in sync with file_util::ISONameFromAnimationName in the original runtime.
static NSString *VAGNameFromPlayCommand(const char *commandName) {
    if (commandName == nullptr || commandName[0] == 0) return nil;
    if (commandName[0] == '$') {
        return [NSString stringWithUTF8String:commandName + 1];
    }

    char name[9] {};
    name[0] = commandName[0];
    name[1] = commandName[1];
    int outputIndex = 2;

    const char *word = commandName;
    while (*word != 0 && *word != '-') word++;
    const char *next = word;
    if (*word != 0) {
        while (outputIndex < 8) {
            word = next + 1;
            next = word;
            while (*next != 0 && *next != '-') next++;
            if (*next == 0) break;

            const size_t length = static_cast<size_t>(next - word);
            char character = word[0];
            if (length > 0 && next[-1] >= '0' && next[-1] <= '9') {
                character = next[-1];
            } else if (length == 10 && memcmp(word, "resolution", 10) == 0) {
                character = 'z';
            } else if (length == 6 && memcmp(word, "accept", 6) == 0) {
                character = 'y';
            } else if (length == 6 && memcmp(word, "reject", 6) == 0) {
                character = 'n';
            } else if (length == 5 && memcmp(word, "keira", 5) == 0) {
                character = 'i';
            }
            name[outputIndex++] = character;
        }
        while (*word != 0 && outputIndex < 8) name[outputIndex++] = *word++;
    }
    while (outputIndex < 8) name[outputIndex++] = ' ';
    for (int index = 0; index < 8; index++) {
        if (name[index] >= 'a' && name[index] <= 'z') name[index] -= 'a' - 'A';
    }
    return [[NSString alloc] initWithBytes:name length:8 encoding:NSASCIIStringEncoding];
}

// In-process replacement for the overlord's RPC_PLAY handler (game/overlord/jak1/stream.cpp).
void HandlePlayStrRpc(uint32_t sendBuffer, uint32_t sendSize) {
    struct PlayCommand {  // load-chunk-msg
        uint16_t reserved;
        uint16_t result;
        uint32_t address;
        uint32_t section;
        uint32_t maxlen;
        char name[48];
    };
    static_assert(sizeof(PlayCommand) == 64, "load-chunk-msg is 64 bytes");
    for (uint32_t offset = 0; offset + sizeof(PlayCommand) <= sendSize; offset += sizeof(PlayCommand)) {
        PlayCommand command {};
        if (!ReadGoalValue(sendBuffer + offset, &command, sizeof(command))) {
            return;
        }
        command.name[sizeof(command.name) - 1] = 0;
        NSString *streamName = VAGNameFromPlayCommand(command.name);
        if (command.result == 0) {  // play
            const BOOL started = streamName.length > 0 &&
                [[Jak1AudioManager sharedManager] playVAGStreamNamed:streamName];
            NSLog(@"jakIOS audio RPC: stream play animation=%s key='%@' started=%@",
                  command.name, streamName, started ? @"yes" : @"no");
            // Overlord iso.cpp PLAY_VAG_STREAM: a missing VAG starts the fake clock instead, so
            // spooled animations without audio still advance.
            StartVagStreamClock(command.address, started, false);
        } else if (command.result == 1) {  // stop
            StopVagStreamClock();
            [[Jak1AudioManager sharedManager] stopVAGStream];
        } else {  // queue; decoding is quick enough to defer until the matching play command
            NSLog(@"jakIOS audio RPC: stream queued animation=%s key='%@'", command.name, streamName);
        }
    }
}

// In-process RPC_Player (overlord srpc.cpp). Bank sounds and music go to the 989snd overlord
// port; the host keeps the VAG-stream parts: "spool-" PLAYs, and PAUSE/STOP/CONTINUE/SET_PARAM
// on the stream's id when no bank sound has that id.
void HandleSoundPlayerRpc(uint32_t sendBuffer, uint32_t sendSize) {
    constexpr uint32_t kCommandSize = jak1sound::kCommandSize;
    // This runs on the GOAL kernel thread, so its cost lands in the frame time.
    static uint32_t playCount = 0;
    static CFTimeInterval rpcSeconds = 0;
    static CFTimeInterval windowStart = 0;
    const CFTimeInterval rpcStart = CACurrentMediaTime();
    jak1sound::BeginPlayerRpc();
    Jak1AudioManager *audio = Jak1AudioManager.sharedManager;
    for (uint32_t offset = 0; offset + kCommandSize <= sendSize; offset += kCommandSize) {
        uint8_t command[kCommandSize] {};
        if (!ReadGoalValue(sendBuffer + offset, command, sizeof(command))) return;
        uint16_t opcode = 0;
        memcpy(&opcode, command + 2, sizeof(opcode));
        uint32_t soundId = 0;
        memcpy(&soundId, command + 4, sizeof(soundId));
        const bool bankSound = jak1sound::HandlePlayerCommand(command);
        const bool streamSound = !bankSound && soundId != 0 && soundId == gVagStreamClock.soundId;
        switch (opcode) {
            case 3: { // PLAY
                if (soundId == 0 || memcmp(command + 16, "spool-", 6) != 0) {
                    playCount++;
                    break;
                }
                char rawName[17] {};
                memcpy(rawName, command + 16, 16);
                NSString *name = [[NSString stringWithUTF8String:rawName]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                // stringWithUTF8String: returns nil for non-UTF-8 bytes; a garbage name can't
                // match any stream, so drop the command rather than passing nil downstream.
                if (name.length <= 6) break;
                int32_t volume = 0x400;
                memcpy(&volume, command + 44, sizeof(volume));
                NSString *vagName = [name substringFromIndex:6];
                const BOOL started = [audio playVAGStreamNamed:vagName];
                StartVagStreamClock(soundId, started, true);
                if (started) {
                    [audio setVAGStreamVolume:(float)volume / 1024.0f];
                    // RPC_Player positions the stream at parms.trans when parms.pitch-mod is set.
                    int16_t pitchMod = 0;
                    memcpy(&pitchMod, command + 34, sizeof(pitchMod));
                    if (pitchMod != 0) {
                        int32_t trans[3] {};
                        memcpy(trans, command + 48, sizeof(trans));
                        [audio setVAGStreamPosition:trans];
                    }
                }
                break;
            }
            case 4: // PAUSE_SOUND
                if (streamSound) {
                    [audio pauseVAGStream];
                    gVagStreamClock.paused = true;
                }
                break;
            case 5: // STOP_SOUND
                if (streamSound) {
                    [audio stopVAGStream];
                    StopVagStreamClock();
                }
                break;
            case 6: // CONTINUE_SOUND
                if (streamSound) {
                    [audio resumeVAGStream];
                    gVagStreamClock.paused = false;
                }
                break;
            case 7: { // SET_PARAM: sound-rpc-set-param parms at +8 (volume at +20)
                uint16_t mask = 0;
                memcpy(&mask, command + 8, sizeof(mask));
                int32_t volume = 0;
                memcpy(&volume, command + 20, sizeof(volume));
                if (streamSound && (mask & 1)) [audio setVAGStreamVolume:(float)volume / 1024.0f];
                break;
            }
            case 8: { // SET_MASTER_VOLUME: group 2 (bit 4) is the dialog volume
                const uint8_t group = command[4];
                int32_t volume = 0x400;
                memcpy(&volume, command + 8, sizeof(volume));
                if (group & 4) [audio setDialogVolume:(float)volume / 1024.0f];
                break;
            }
            case 9: // PAUSE_GROUP: menus/progress pause groups sfx|music|dialog|... (0xff)
                if (command[4] & 4) {
                    [audio pauseVAGStream];
                    gVagStreamClock.paused = true;
                }
                break;
            case 10: // STOP_GROUP
                if (command[4] & 4) {
                    [audio stopVAGStream];
                    StopVagStreamClock();
                }
                break;
            case 11: // CONTINUE_GROUP
                if (command[4] & 4) {
                    [audio resumeVAGStream];
                    gVagStreamClock.paused = false;
                }
                break;
            case 19: // SET_EAR_TRANS: SetEarTrans ends with SetVAGVol
                [audio refreshVAGStreamVolume];
                break;
            default:
                break;
        }
    }
    const CFTimeInterval rpcEnd = CACurrentMediaTime();
    rpcSeconds += rpcEnd - rpcStart;
    if (windowStart == 0) windowStart = rpcEnd;
    if (rpcEnd - windowStart >= 1.0) {
        NSLog(@"jakIOS perf sound: %u plays, %.2f ms/s in sound RPCs", playCount, 1000.0 * rpcSeconds);
        playCount = 0;
        rpcSeconds = 0;
        windowStart = rpcEnd;
    }
}

void HandleSoundLoaderRpc(uint32_t sendBuffer, uint32_t sendSize) {
    constexpr uint32_t kCommandSize = jak1sound::kCommandSize;
    for (uint32_t offset = 0; offset + kCommandSize <= sendSize; offset += kCommandSize) {
        uint8_t command[kCommandSize] {};
        if (!ReadGoalValue(sendBuffer + offset, command, sizeof(command))) return;
        jak1sound::HandleLoaderCommand(command);
    }
}

// Port of TexturePool::handle_upload_now (game/graphics/texture/TexturePool.cpp): the PC port
// doesn't upload texels; it tells the renderer which PC texture now lives at each VRAM block.
void HandleTextureUploadNow(uint32_t page, int32_t mode) {
    struct GoalTexturePage {  // texture-page, from its first field (file-info)
        uint32_t fileInfo;
        uint32_t name;
        uint32_t id;
        int32_t length;
        uint32_t mip0Size;
        uint32_t size;
        uint32_t segment[3][3];
        uint32_t pad[16];
    } texturePage {};
    struct GoalTexture {
        int16_t w, h;
        uint8_t numMips, tex1Control, psm, mipShift;
        uint16_t clutpsm;
        uint16_t dest[7];
        uint16_t clutDest;
        uint8_t width[7];
        uint32_t name, size;
        float uvDist;
        uint32_t masks[3];
    };
    static_assert(sizeof(GoalTexture) == 60, "GoalTexture size");
    static int loggedUploads = 0;
    const bool logThis = loggedUploads < 24;
    if (!ReadGoalValue(page, &texturePage, sizeof(texturePage)) || texturePage.length < 0) {
        if (logThis) {
            NSLog(@"jakIOS: texture upload-now page=0x%x mode=%d unreadable", page, mode);
            loggedUploads++;
        }
        return;
    }
    if (logThis) {
        const char *pageName = GoalString(texturePage.name);
        NSLog(@"jakIOS: texture upload-now page=0x%x mode=%d id=0x%x name=%s length=%d seg-dest=%u/%u/%u",
              page, mode, texturePage.id, pageName != nullptr ? pageName : "?", texturePage.length,
              texturePage.segment[0][2], texturePage.segment[1][2], texturePage.segment[2][2]);
        loggedUploads++;
    }
    bool hasSegment[3] = {true, true, true};
    if (mode == 2) {
        hasSegment[0] = hasSegment[1] = false;
    } else if (mode == -2) {
        hasSegment[2] = false;
    } else if (mode == 0) {
        hasSegment[1] = hasSegment[2] = false;
    } else if (mode != -1) {
        return;
    }
    const uint32_t falseObject = static_cast<uint32_t>(GoalBoolean(false));
    for (int32_t index = 0; index < texturePage.length; index++) {
        uint32_t texturePointer = 0;
        GoalTexture texture {};
        if (!ReadGoalValue(page + sizeof(GoalTexturePage) + 4 * index, &texturePointer, 4) ||
            texturePointer == falseObject || texturePointer == 0 ||
            !ReadGoalValue(texturePointer, &texture, sizeof(texture))) {
            continue;
        }
        for (int mip = 0; mip < texture.numMips && mip < 7; mip++) {
            const int segment = texture.numMips <= 2 ? texture.numMips - mip - 1 : std::max(0, 2 - mip);
            if (segment >= 0 && segment < 3 && hasSegment[segment]) {
                Jak1TexturePoolSetVramSlot(texture.dest[mip], (texturePage.id << 16) | index);
            }
        }
    }
}

// The AOT snapshot is taken after the desktop boot already uploaded the common texture pages
// (GAME.CGO art such as Jak's eyes) to VRAM, so those uploads never reach our pool. Replay them
// once from *texture-page-dir*: every resident page, all segments.
void SeedTexturePoolFromResidentPages() {
    const auto symbol = gNativeHelperContext.symbols.find("*texture-page-dir*");
    uint32_t directory = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &directory, sizeof(directory)) || directory == 0) {
        NSLog(@"jakIOS: *texture-page-dir* unavailable; common textures not seeded");
        return;
    }
    // texture-page-dir is a basic: length at +0, then 12-byte entries {s16 length, u16 status,
    // texture-page page, texture-link link} from +4.
    int32_t length = 0;
    ReadGoalValue(directory, &length, sizeof(length));
    const uint32_t falseObject = static_cast<uint32_t>(GoalBoolean(false));
    int seeded = 0;
    for (int32_t index = 0; index < length && index < 4096; index++) {
        uint32_t page = 0;
        if (!ReadGoalValue(directory + 4 + 12 * index + 4, &page, sizeof(page)) || page == 0 ||
            page == falseObject) {
            continue;
        }
        HandleTextureUploadNow(page, -1);
        seeded++;
    }
    NSLog(@"jakIOS: seeded texture pool from %d resident texture pages (of %d)", seeded, length);
}

// entity-actor birth! falls back to birth-viewer (a debug process that loads art by name and
// loops an animation) when an actor's type has no code. On iOS level actor code isn't in the AOT
// image, so many actors hit that path, and the viewer reads freed art once the title script kills
// its entity (fishermans-boat-2), crashing. Point birth-viewer at native helper 142 (the
// debug-only test-function thunk), which repairs the orphaned process and declines the spawn.
// Viewers already born before the disable (e.g. fishermans-boat-2 during the village1 title load)
// keep running and later call methods on their freed janim, so park them with the `execute` mask
// bit, which stops a process (code and post) from running in every case.
void ParkLiveViewerProcesses() {
    constexpr uint32_t kProcessMaskExecute = 1u << 0;
    constexpr uint32_t kProcessTreeMaskOffset = 4;
    constexpr uint32_t kProcessTreeBrotherOffset = 12;
    constexpr uint32_t kProcessTreeChildOffset = 16;
    const auto activePool = gNativeHelperContext.symbols.find("*active-pool*");
    const auto viewerSymbol = gNativeHelperContext.symbols.find("viewer");
    uint32_t root = 0;
    uint32_t viewerType = 0;
    if (activePool == gNativeHelperContext.symbols.end() || viewerSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(activePool->second, &root, sizeof(root)) ||
        !ReadGoalValue(viewerSymbol->second, &viewerType, sizeof(viewerType)) || viewerType == 0) {
        return;
    }
    // brother/child are (pointer process-tree) slots; #f (s7) or 0 ends a chain.
    const auto deref = [](uint32_t slot) -> uint32_t {
        uint32_t node = 0;
        if (slot == 0 || slot == kCapturedS7GoalOffset || !ReadGoalValue(slot, &node, sizeof(node)) ||
            node == kCapturedS7GoalOffset) {
            return 0;
        }
        return node;
    };
    std::vector<uint32_t> pending {root};
    int parked = 0;
    for (int visited = 0; !pending.empty() && visited < 4096; visited++) {
        const uint32_t node = pending.back();
        pending.pop_back();
        uint32_t type = 0;
        uint32_t brother = 0;
        uint32_t child = 0;
        if (node < 4 || !ReadGoalValue(node - 4, &type, sizeof(type)) ||
            !ReadGoalValue(node + kProcessTreeBrotherOffset, &brother, sizeof(brother)) ||
            !ReadGoalValue(node + kProcessTreeChildOffset, &child, sizeof(child))) {
            continue;
        }
        if (type == viewerType) {
            uint32_t mask = 0;
            if (ReadGoalValue(node + kProcessTreeMaskOffset, &mask, sizeof(mask))) {
                mask |= kProcessMaskExecute;
                WriteGoalValue(node + kProcessTreeMaskOffset, &mask, sizeof(mask));
                parked++;
            }
        }
        if (const uint32_t next = deref(brother)) {
            pending.push_back(next);
        }
        if (const uint32_t next = deref(child)) {
            pending.push_back(next);
        }
    }
    if (parked > 0) {
        NSLog(@"jakIOS: parked %d live birth-viewer process(es)", parked);
    }
}

// Heat diagnostic: every 2 s, log total process CPU, the busiest threads by name, and the
// thermal state. Mach's cpu_usage is a decaying per-thread average (TH_USAGE_SCALE = 100%).
void LogThreadCPUUsageIfDue() {
    static CFTimeInterval lastLog = 0;
    const CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog < 2.0) return;
    lastLog = now;

    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) return;
    struct ThreadUsage {
        double percent;
        std::string name;
    };
    std::vector<ThreadUsage> usages;
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        thread_extended_info_data_t info {};
        mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(threads[i], THREAD_EXTENDED_INFO, reinterpret_cast<thread_info_t>(&info), &count) ==
            KERN_SUCCESS) {
            const double percent = 100.0 * info.pth_cpu_usage / TH_USAGE_SCALE;
            total += percent;
            if (percent >= 2.0) {
                // Called from drawInView, i.e. on the main thread.
                static const mach_port_t mainThread = pthread_mach_thread_np(pthread_self());
                usages.push_back({percent, threads[i] == mainThread ? "main" :
                                           info.pth_name[0] != 0 ? info.pth_name : "(unnamed)"});
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads), threadCount * sizeof(thread_act_t));
    std::sort(usages.begin(), usages.end(),
              [](const ThreadUsage &a, const ThreadUsage &b) { return a.percent > b.percent; });
    std::string busiest;
    char entry[96];
    for (size_t i = 0; i < usages.size() && i < 8; i++) {
        snprintf(entry, sizeof(entry), "%s%s %.0f%%", i == 0 ? "" : ", ", usages[i].name.c_str(),
                 usages[i].percent);
        busiest += entry;
    }
    static NSArray<NSString *> *const thermalNames = @[@"nominal", @"fair", @"serious", @"critical"];
    const NSInteger thermal = NSProcessInfo.processInfo.thermalState;
    NSLog(@"jakIOS perf threads: total %.0f%% CPU across %u threads, thermal %@; busiest: %s", total, threadCount,
          thermal >= 0 && thermal < 4 ? thermalNames[thermal] : @"?", busiest.c_str());
}

void DisableViewerFallback() {
    const auto birthViewer = gNativeHelperContext.symbols.find("birth-viewer");
    const auto falseFunc = gNativeHelperContext.symbols.find("test-function");
    uint32_t falseFuncValue = 0;
    if (birthViewer == gNativeHelperContext.symbols.end() || falseFunc == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(falseFunc->second, &falseFuncValue, sizeof(falseFuncValue)) || falseFuncValue == 0) {
        NSLog(@"jakIOS: could not disable birth-viewer fallback");
        return;
    }
    WriteGoalValue(birthViewer->second, &falseFuncValue, sizeof(falseFuncValue));
    NSLog(@"jakIOS: birth-viewer fallback disabled");
    ParkLiveViewerProcesses();
}

// main.gc draws black bars via (letterbox) during (movie?). In native-aspect mode the PC port's
// letterbox forces a 16:9 picture, so cutscenes ignore the chosen display aspect (e.g. fit to
// screen). The viewport is already shaped by pc-set-letterbox, so point letterbox at false-func
// and let cutscenes fill the same game area as gameplay. Checked per frame (cheap) in case a
// relink restores the original function.
void DisableCutsceneLetterbox() {
    static uint32_t letterboxSymbol = 0;
    static uint32_t falseFuncSymbol = 0;
    if (letterboxSymbol == 0 || falseFuncSymbol == 0) {
        const auto letterbox = gNativeHelperContext.symbols.find("letterbox");
        const auto falseFunc = gNativeHelperContext.symbols.find("false-func");
        if (letterbox == gNativeHelperContext.symbols.end() || falseFunc == gNativeHelperContext.symbols.end()) {
            return;
        }
        letterboxSymbol = letterbox->second;
        falseFuncSymbol = falseFunc->second;
    }
    uint32_t letterboxValue = 0;
    uint32_t falseFuncValue = 0;
    if (!ReadGoalValue(letterboxSymbol, &letterboxValue, sizeof(letterboxValue)) ||
        !ReadGoalValue(falseFuncSymbol, &falseFuncValue, sizeof(falseFuncValue)) || falseFuncValue == 0 ||
        letterboxValue == falseFuncValue) {
        return;
    }
    WriteGoalValue(letterboxSymbol, &falseFuncValue, sizeof(falseFuncValue));
    NSLog(@"jakIOS: cutscene letterbox disabled (cutscenes use the game display aspect)");
}

// A new aspect picked in the pause menu otherwise only reaches the menu once it is reopened:
// - The menu's side panels and icon offsets (left/right-x-offset, sides scale, *PC-*-ADJUST*) are
//   set by progress::adjust-ratios, which only runs when the progress process is created.
// - 2D sprites are projected through *math-camera*'s perspective / sprite-2d matrices, which only
//   update-math-camera recomputes. cam-update calls it, but cameras don't run while paused.
// Rerun both whenever the aspect changes. Picking 4x3 / 16x9 sets *setting-control* default, and
// current follows a frame later, so the current aspect symbol is watched as well as the float.
// Must run on the kernel queue.
void RefreshDisplayOnAspectChange() {
    constexpr uint32_t kPCSettingsAspectRatioOffset = 96;           // aspect-ratio float
    constexpr uint32_t kSettingCurrentVideoModeOffset = 12 + 68;    // current (inline) video-mode
    constexpr uint32_t kSettingCurrentAspectRatioOffset = 12 + 72;  // current aspect-ratio symbol
    constexpr uint32_t kProgressAdjustRatiosMethodId = 23;          // progress-h.gc :methods order
    static float lastAspect = 0;
    static uint32_t lastAspectMode = 0;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const auto symbolValue = [s7](const char *name, uint32_t *value) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        return symbol != gNativeHelperContext.symbols.end() &&
            ReadGoalValue(symbol->second, value, sizeof(*value)) && *value != 0 && *value != s7;
    };
    uint32_t settings = 0, settingControl = 0, videoMode = 0, aspectMode = 0;
    float aspect = 0;
    if (!symbolValue("*pc-settings*", &settings) ||
        !ReadGoalValue(settings + kPCSettingsAspectRatioOffset, &aspect, sizeof(aspect)) || !(aspect > 0) ||
        !symbolValue("*setting-control*", &settingControl) ||
        !ReadGoalValue(settingControl + kSettingCurrentVideoModeOffset, &videoMode, sizeof(videoMode)) ||
        !ReadGoalValue(settingControl + kSettingCurrentAspectRatioOffset, &aspectMode, sizeof(aspectMode)) ||
        (aspect == lastAspect && aspectMode == lastAspectMode)) {
        return;
    }
    const bool firstCheck = lastAspect == 0;
    lastAspect = aspect;
    lastAspectMode = aspectMode;

    uint32_t mathCamera = 0, updateMathCamera = 0;
    if (symbolValue("*math-camera*", &mathCamera) && symbolValue("update-math-camera", &updateMathCamera)) {
        CallGoalOnArenaStack(updateMathCamera, mathCamera, videoMode, aspectMode);
    }

    // *progress-process* is a (pointer progress); call its (possibly PC-overridden) adjust-ratios.
    uint32_t progressPointer = 0, progress = 0, progressType = 0, adjustRatios = 0;
    const bool menuOpen = symbolValue("*progress-process*", &progressPointer) &&
        ReadGoalValue(progressPointer, &progress, sizeof(progress)) && progress != 0 && progress != s7 &&
        ReadGoalValue(progress - sizeof(uint32_t), &progressType, sizeof(progressType)) &&
        ReadGoalValue(progressType + 16 + kProgressAdjustRatiosMethodId * 4, &adjustRatios, sizeof(adjustRatios)) &&
        adjustRatios != 0 && adjustRatios != s7;
    if (menuOpen) CallGoalOnArenaStack(adjustRatios, progress, aspectMode, videoMode);

    if (!firstCheck) {
        NSLog(@"jakIOS: aspect -> %.3f (%s), refreshed math camera%s", aspect,
              GoalSymbolName(aspectMode) ?: "?", menuOpen ? " and menu layout" : "");
    }
}

// The pause menu's completion percentage (progress-pc.gc draw-progress) sits in the green disc at
// the bottom right, offset by *PC-PERCENT-X-ADJUST*. OpenGOAL's fit leaves it ~10.5 font units
// right of the disc's center on phone-wide aspects (measured at 2.17). PC's 16:9 calibration is
// kept and the correction ramps in linearly past it. adjust-ratios rewrites the global each time
// the menu opens or the aspect changes, so re-apply whenever its value isn't the one written here.
// Must run on the kernel queue.
void CenterProgressCompletionPercent() {
    constexpr uint32_t kPCSettingsAspectRatioOffset = 96;  // aspect-ratio float
    constexpr float kCalibratedAspect = 1.78f;             // OpenGOAL's 16:9 placement is centered
    constexpr float kMeasuredAspect = 2.174f;              // iPhone (2622x1206)
    constexpr float kMeasuredCorrection = -10.5f;          // font units at kMeasuredAspect
    static uint32_t adjustSymbol = 0, settingsSymbol = 0;
    static float lastWritten = 0.0f;
    static bool hasWritten = false;
    if (adjustSymbol == 0 || settingsSymbol == 0) {
        const auto adjust = gNativeHelperContext.symbols.find("*PC-PERCENT-X-ADJUST*");
        const auto settings = gNativeHelperContext.symbols.find("*pc-settings*");
        if (adjust == gNativeHelperContext.symbols.end() || settings == gNativeHelperContext.symbols.end()) return;
        adjustSymbol = adjust->second;
        settingsSymbol = settings->second;
    }
    // Float globals keep their raw bits in the symbol's value slot.
    float current = 0.0f, aspect = 0.0f;
    uint32_t settings = 0;
    if (!ReadGoalValue(adjustSymbol, &current, sizeof(current)) || (hasWritten && current == lastWritten) ||
        !ReadGoalValue(settingsSymbol, &settings, sizeof(settings)) || settings == 0 ||
        settings == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(settings + kPCSettingsAspectRatioOffset, &aspect, sizeof(aspect)) || !(aspect > 0)) {
        return;
    }
    const float ramp = std::max(0.0f, (aspect - kCalibratedAspect) / (kMeasuredAspect - kCalibratedAspect));
    const float corrected = current + kMeasuredCorrection * ramp;
    if (corrected != current) WriteGoalValue(adjustSymbol, &corrected, sizeof(corrected));
    lastWritten = corrected;
    hasWritten = true;
}

// The new-game intro (sequence-a-village1.gc, group-sequenceAV-2d-intro-mist) draws its mist and
// title credits over particle 2860, and the end credits (sage-finalboss-part.gc,
// group-2d-credits-mist) over particle 2827: each a screen-space black quad sized 15m x 12m, i.e.
// exactly the PS2's 4:3 screen. On wider displays its edges show. Widen them so the backdrop
// covers any aspect. The parts live in VI1 / FIN level code, so re-check each frame (cheap) to
// catch every reload of those levels.
void WidenIntroMistBackdrop() {
    struct Backdrop {
        uint32_t partId;
        const char *name;
    };
    static constexpr Backdrop kBackdrops[] = {
        {2860, "intro mist"},
        {2827, "end credits"},
    };
    constexpr uint16_t kSptScaleX = 13;           // sp-field-id spt-scale-x
    constexpr float kOriginalScaleX = 15.0f * 4096.0f;  // (meters 15)
    constexpr float kWideScaleX = 60.0f * 4096.0f;      // covers aspects up to 16:3
    static uint32_t partTableSymbol = 0;
    if (partTableSymbol == 0) {
        const auto partTable = gNativeHelperContext.symbols.find("*part-id-table*");
        if (partTable == gNativeHelperContext.symbols.end()) return;
        partTableSymbol = partTable->second;
    }
    // boxed-array: length @ +0, data @ +12. sparticle-launcher (basic): init-specs @ +8.
    uint32_t partTable = 0, length = 0;
    if (!ReadGoalValue(partTableSymbol, &partTable, sizeof(partTable)) || partTable == 0 ||
        !ReadGoalValue(partTable, &length, sizeof(length))) {
        return;
    }
    for (const Backdrop &backdrop : kBackdrops) {
        uint32_t launcher = 0, initSpecs = 0;
        if (length <= backdrop.partId ||
            !ReadGoalValue(partTable + 12 + backdrop.partId * 4, &launcher, sizeof(launcher)) || launcher == 0 ||
            !ReadGoalValue(launcher + 8, &initSpecs, sizeof(initSpecs)) || initSpecs == 0) {
            continue;
        }
        // sp-field-init-spec (16 bytes): field u16 @ +0, initial-valuef @ +4.
        for (uint32_t i = 0; i < 16; i++) {
            const uint32_t spec = initSpecs + i * 16;
            uint16_t field = 0;
            float value = 0.0f;
            if (!ReadGoalValue(spec, &field, sizeof(field))) break;
            if (field != kSptScaleX) continue;
            if (ReadGoalValue(spec + 4, &value, sizeof(value)) && value == kOriginalScaleX) {
                WriteGoalValue(spec + 4, &kWideScaleX, sizeof(kWideScaleX));
                NSLog(@"jakIOS: %s backdrop widened past 4:3", backdrop.name);
            }
            break;
        }
    }
}

// TextureUploadHandler::render: the texture buckets carry PC-port upload packets
// (vif0 = PC_PORT, vif1 = 3, payload {u64 page, s64 mode}); each is a handle_upload_now.
// Applied in chain order, so the pool ends in the frame's final VRAM layout. The layout at each
// sky-blend bucket (32 / 39, right after that level's alpha tpage upload) is saved as snapshot
// 0 / 1, since the sky blend samples VRAM there and later uploads overwrite those blocks.
// Likewise snapshot 2 at the eye bucket (54, MERC_EYES_AFTER_PRIS, right after the pris tpages):
// EyeRenderer samples iris/pupil/lid there, and water/sprite/HUD uploads can reuse those blocks.
void ApplyTextureUploadsInTrace(const std::vector<uint8_t> &trace, const std::vector<uint32_t> &bucketOffsets) {
    constexpr int kSnapshotCount = 3;
    constexpr size_t kSnapshotBuckets[kSnapshotCount] = {32, 39, 54};
    size_t snapshotOffsets[kSnapshotCount];
    bool snapshotPending[kSnapshotCount];
    for (int level = 0; level < kSnapshotCount; level++) {
        const size_t bucket = kSnapshotBuckets[level];
        snapshotPending[level] = bucket < bucketOffsets.size() && bucketOffsets[bucket] != UINT32_MAX;
        snapshotOffsets[level] = snapshotPending[level] ? bucketOffsets[bucket] : 0;
        if (!snapshotPending[level]) Jak1TexturePoolClearSnapshot(level);
    }
    const auto takeSnapshotsBefore = [&](size_t offset) {
        for (int level = 0; level < kSnapshotCount; level++) {
            if (snapshotPending[level] && offset >= snapshotOffsets[level]) {
                Jak1TexturePoolSaveSnapshot(level);
                snapshotPending[level] = false;
            }
        }
    };
    // Every write is also journaled with its trace offset, for passes that look textures up at
    // their own bucket (Generic2: pris/water/alpha tpages share the common segment, so the final
    // layout holds whichever tpage was uploaded last).
    Jak1TexturePoolBeginTraceJournal();
    size_t offset = 0;
    while (offset + 16 <= trace.size()) {
        takeSnapshotsBefore(offset);
        Jak1TexturePoolSetTraceJournalOffset(static_cast<uint32_t>(offset));
        uint64_t tag = 0;
        uint32_t vif0 = 0, vif1 = 0;
        memcpy(&tag, trace.data() + offset, 8);
        memcpy(&vif0, trace.data() + offset + 8, 4);
        memcpy(&vif1, trace.data() + offset + 12, 4);
        const size_t size = static_cast<size_t>(tag & 0xffff) * 16;
        if (size > trace.size() - offset - 16) {
            break;
        }
        if (size == 16 && ((vif0 >> 24) & 0x7f) == 0x08 && vif1 == 3) {
            uint64_t page = 0;
            int64_t mode = 0;
            memcpy(&page, trace.data() + offset + 16, 8);
            memcpy(&mode, trace.data() + offset + 24, 8);
            if (page <= UINT32_MAX) {
                HandleTextureUploadNow(static_cast<uint32_t>(page), static_cast<int32_t>(mode));
            }
        }
        offset += 16 + size;
    }
    Jak1TexturePoolEndTraceJournal();
    // Never leave a previous frame's snapshot in place.
    takeSnapshotsBefore(SIZE_MAX);
}

// Merc draws reference GOAL memory the chain doesn't carry: bone matrices (in the frame's DMA
// buffer) and, for pc-merc update-verts (ripple / texture scroll), the merc fragments the game
// rewrites in place. Once the game runs a frame ahead of the render thread it overwrites them,
// flinging vertices for a frame, so they are copied at submission too. Mirrors the packet layout
// read by DecodeMercSubmissions / UnpackModVertices.
// Snapshot format (setMercMemorySnapshot: in Jak1MetalRenderer.h): u32 range count, 12 pad bytes,
// then per range {u32 address, u32 length, u32 data offset, u32 pad} sorted by address and
// non-overlapping, then the range bytes.
void SnapshotMercMemory(const std::vector<uint8_t> &trace, std::vector<uint8_t> *snapshot) {
    constexpr uint8_t kPcMercBitUpdateVerts = 1u << 0;
    constexpr uint8_t kPcMercBitPcBlerc = 1u << 2;
    constexpr uint32_t kMatrixSize = 112;
    const GoalAddressSpace *memory = gNativeHelperContext.addressSpace;
    snapshot->clear();
    if (memory == nullptr) return;
    std::vector<std::pair<uint32_t, uint32_t>> ranges;  // (address, length)
    auto addRange = [&](uint64_t address, uint64_t length) {
        if (address == 0 || length == 0 || address + length > UINT32_MAX) return false;
        if (memory->pointerForGoal(static_cast<uint32_t>(address), static_cast<uint32_t>(length)) == nullptr) {
            return false;
        }
        ranges.emplace_back(static_cast<uint32_t>(address), static_cast<uint32_t>(length));
        return true;
    };
    // merc-effect: frag-geo at +0, frag-ctrl at +4, frag-count at +18. Fragments and their
    // controls are each laid out contiguously, so an effect is three ranges.
    auto addEffect = [&](uint32_t effectAddress) {
        const uint8_t *effect = memory->pointerForGoal(effectAddress, 20);
        if (effect == nullptr || !addRange(effectAddress, 20)) return;
        uint32_t fragAddress = 0, ctrlAddress = 0;
        uint16_t fragCount = 0;
        memcpy(&fragAddress, effect, 4);
        memcpy(&ctrlAddress, effect + 4, 4);
        memcpy(&fragCount, effect + 18, 2);
        uint64_t frag = fragAddress, ctrl = ctrlAddress;
        for (uint16_t fi = 0; fi < fragCount; fi++) {
            const uint8_t *ctrlBytes = ctrl <= UINT32_MAX ? memory->pointerForGoal(static_cast<uint32_t>(ctrl), 4) : nullptr;
            const uint8_t *fragBytes = frag <= UINT32_MAX ? memory->pointerForGoal(static_cast<uint32_t>(frag), 12) : nullptr;
            if (ctrlBytes == nullptr || fragBytes == nullptr) break;
            ctrl += 4 + 2 * static_cast<uint64_t>(ctrlBytes[3]);   // mat-xfer-count
            frag += static_cast<uint64_t>(fragBytes[11]) * 16;     // mm-qwc-count
        }
        // At least the first control / fragment header, which the renderer always reads.
        addRange(ctrlAddress, std::max<uint64_t>(ctrl - ctrlAddress, 4));
        addRange(fragAddress, std::max<uint64_t>(frag - fragAddress, 12));
    };
    size_t offset = 0;
    while (offset + 16 <= trace.size()) {
        uint64_t tag = 0;
        uint32_t vif1 = 0;
        memcpy(&tag, trace.data() + offset, 8);
        memcpy(&vif1, trace.data() + offset + 12, 4);
        const size_t payloadLength = static_cast<size_t>(tag & 0xffff) * 16;
        if (payloadLength > trace.size() - offset - 16) break;
        const uint8_t *payload = trace.data() + offset + 16;
        constexpr size_t kSlotsOffset = 128 + 112 + 16;
        constexpr size_t kPointersOffset = kSlotsOffset + 128;
        if (((vif1 >> 24) & 0x7f) == 0x08 && payloadLength >= kPointersOffset &&
            memchr(payload, 0, 128) != nullptr) {
            size_t slotCount = 0;
            while (slotCount < 128 && payload[kSlotsOffset + slotCount] != 0xff) slotCount++;
            const size_t flagsOffset = kPointersOffset + slotCount * 16;
            if (flagsOffset + 18 <= payloadLength) {
                for (size_t slot = 0; slot < slotCount; slot++) {
                    uint32_t address = 0;
                    memcpy(&address, payload + kPointersOffset + slot * 16, 4);
                    addRange(address, kMatrixSize);
                }
                const uint8_t bitFlags = payload[flagsOffset + 17];
                if ((bitFlags & kPcMercBitPcBlerc) == 0 && (bitFlags & kPcMercBitUpdateVerts) != 0) {
                    const size_t effectCount = payload[flagsOffset + 16];
                    const size_t pointersOffset = flagsOffset + 32 + ((effectCount * 4 + 15) / 16) * 16;
                    if (pointersOffset + effectCount * 4 <= payloadLength) {
                        for (size_t effect = 0; effect < effectCount; effect++) {
                            uint32_t address = 0;
                            memcpy(&address, payload + pointersOffset + effect * 4, 4);
                            addEffect(address);
                        }
                    }
                }
            }
        }
        offset += 16 + payloadLength;
    }
    // Merge overlapping ranges so a lookup only has to check the one range starting at or before it.
    std::sort(ranges.begin(), ranges.end());
    std::vector<std::pair<uint32_t, uint32_t>> merged;
    for (const auto &range : ranges) {
        if (!merged.empty() && range.first <= merged.back().first + merged.back().second) {
            const uint64_t end = std::max<uint64_t>(merged.back().first + merged.back().second,
                                                    static_cast<uint64_t>(range.first) + range.second);
            merged.back().second = static_cast<uint32_t>(end - merged.back().first);
        } else {
            merged.push_back(range);
        }
    }
    const uint32_t count = static_cast<uint32_t>(merged.size());
    size_t dataOffset = 16 + merged.size() * 16;
    size_t totalSize = dataOffset;
    for (const auto &range : merged) totalSize += (range.second + 15) & ~15u;
    snapshot->assign(totalSize, 0);
    memcpy(snapshot->data(), &count, 4);
    for (size_t i = 0; i < merged.size(); i++) {
        const uint32_t entry[4] = {merged[i].first, merged[i].second, static_cast<uint32_t>(dataOffset), 0};
        memcpy(snapshot->data() + 16 + i * 16, entry, sizeof(entry));
        memcpy(snapshot->data() + dataOffset, memory->pointerForGoal(merged[i].first, merged[i].second),
               merged[i].second);
        dataOffset += (merged[i].second + 15) & ~15u;
    }
}

// The newest complete DMA trace, published by the game thread for the render thread.
struct PublishedDMATrace {
    std::vector<uint8_t> bytes;
    std::vector<uint32_t> bucketOffsets;
    std::vector<uint8_t> mercMemory;  // SnapshotMercMemory of `bytes`
    uint64_t serial = 0;  // incremented per published trace
};
std::mutex gPublishedDMAMutex;
PublishedDMATrace gPublishedDMA;
std::vector<uint8_t> gDMACaptureSpare;  // reused capture allocation (game thread only)
std::vector<uint8_t> gMercMemorySpare;  // reused merc memory snapshot allocation (game thread only)
bool gLoggedDMAIngestion = false;

// Called from __send-gfx-dma-chain on the game thread, like OpenGOAL's DmaCopier: the chain (and
// every REF'd payload) is copied out of GOAL memory at submission, before the game builds the next
// frame over it. Copying later from the render thread raced with that: when the game ran ahead
// (cheap paused frames), the copy caught half-rewritten buffers and menu frames flickered.
void CaptureAndPublishDMAChain(uint32_t bank, uint64_t chainAddress, uint64_t serial) {
    const CFTimeInterval captureStart = CACurrentMediaTime();
    if (chainAddress > UINT32_MAX) {
        NSLog(@"jakIOS: rejected GOAL DMA chain serial=%llu with non-GOAL address 0x%llx",
              static_cast<unsigned long long>(serial), static_cast<unsigned long long>(chainAddress));
        return;
    }
    const uint32_t chain = static_cast<uint32_t>(chainAddress);
    DmaChainCapture capture;
    capture.bytes = std::move(gDMACaptureSpare);
    capture.bytes.clear();
    const bool captured = CaptureDMAChain(gNativeHelperContext.addressSpace, chain, &capture,
                                          !gLoggedDMAIngestion) && capture.ended;
    if (!captured) {
        NSLog(@"jakIOS: rejected GOAL DMA chain serial=%llu root=0x%08x: %s",
              static_cast<unsigned long long>(serial), chain, capture.error.c_str());
        gDMACaptureSpare = std::move(capture.bytes);
        return;
    }
    static bool seededTexturePool = false;
    if (!seededTexturePool) {
        SeedTexturePoolFromResidentPages();
        seededTexturePool = true;
    }
    // The trace's texture uploads are NOT applied here: the pool is the current VRAM layout, and
    // applying frame N+1's uploads while frame N is still being drawn makes slots shared across
    // frames (sky, ...) sample the wrong texture. The render thread applies them per frame.
    // Describing a large chain is expensive enough to visibly hitch the title flyover. Log the
    // first successful ingestion only (the only capture that computes fingerprint and VIF list).
    if (!gLoggedDMAIngestion) {
        const std::string vifDescription = DescribeVifCommands(capture);
        NSLog(@"jakIOS: walked GOAL DMA chain serial=%llu bank=%u root=0x%08x tags=%u "
              @"payload=%u bytes direct=%u unpack=%u gif=%u ad=%u xyz=%u image=%u "
              @"fingerprint=%016llx tag-vif={%s}",
              static_cast<unsigned long long>(serial), bank, chain,
              capture.tagCount, capture.payloadBytes, capture.directCommandCount,
              capture.unpackCommandCount, capture.gifTagCount, capture.gifADWrites,
              capture.gifVertexWrites, capture.gifImageBytes,
              static_cast<unsigned long long>(capture.fingerprint), vifDescription.c_str());
        gLoggedDMAIngestion = true;
    }
    SnapshotMercMemory(capture.bytes, &gMercMemorySpare);
    size_t traceBytes = 0;
    {
        std::lock_guard<std::mutex> lock(gPublishedDMAMutex);
        // The previously published trace (if the render thread never took it) becomes the spare.
        gPublishedDMA.bytes.swap(capture.bytes);
        gPublishedDMA.bucketOffsets.swap(capture.bucketTraceOffsets);
        gPublishedDMA.mercMemory.swap(gMercMemorySpare);
        gPublishedDMA.serial++;
        traceBytes = gPublishedDMA.bytes.size();
    }
    gDMACaptureSpare = std::move(capture.bytes);

    // Game-thread cost of copying the chain.
    static CFTimeInterval captureSeconds = 0, captureWindowStart = 0;
    static uint32_t captureCount = 0;
    const CFTimeInterval captureEnd = CACurrentMediaTime();
    captureSeconds += captureEnd - captureStart;
    captureCount++;
    if (captureWindowStart == 0) captureWindowStart = captureEnd;
    if (captureEnd - captureWindowStart >= 1.0) {
        NSLog(@"jakIOS perf host: %u captures, %.2f ms/capture, %zu KB trace", captureCount,
              1000.0 * captureSeconds / captureCount, traceBytes / 1024);
        captureSeconds = 0;
        captureCount = 0;
        captureWindowStart = captureEnd;
    }
}

// Render thread: swaps the newest published trace (if any) into `trace`. The render thread's
// previous trace goes back to the publisher as its next swap target.
bool TakePublishedDMATrace(uint64_t *consumedSerial, std::vector<uint8_t> *trace,
                           std::vector<uint32_t> *bucketOffsets, std::vector<uint8_t> *mercMemory) {
    std::lock_guard<std::mutex> lock(gPublishedDMAMutex);
    if (gPublishedDMA.serial == *consumedSerial) return false;
    trace->swap(gPublishedDMA.bytes);
    *bucketOffsets = gPublishedDMA.bucketOffsets;
    mercMemory->swap(gPublishedDMA.mercMemory);
    *consumedSerial = gPublishedDMA.serial;
    return true;
}

// Port of the overlord VBlank_Handler info update: advance the clock one game frame and DMA
// frame/strpos/str-id into *sound-iop-info*.
// Diagnostic for the title "press start" -> progress menu path (title-obs.gc target-title-wait).
struct PadDiagnostics {
    uint32_t reads = 0;       // cpad-get-data calls since the last log
    uint32_t startEdges = 0;  // Start rising edges handed to GOAL since the last log
    uint64_t frames = 0;
};
PadDiagnostics gPadDiagnostics;

void LogPadAndProgressStateIfDue() {
    if (gPadDiagnostics.frames++ % 120 != 0) return;
    auto symbolValue = [](const char *name) -> uint32_t {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        uint32_t value = 0;
        if (symbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(symbol->second, &value, sizeof(value))) {
            return 0;
        }
        return value;
    };
    // *cpad-list* basic: num-cpads at +0, cpad-info pointers from +4. cpad-info: button0-abs[0]
    // at +40, button0-rel[0] at +56 (type-db offsets minus the 4-byte type tag).
    const uint32_t cpadList = symbolValue("*cpad-list*");
    uint32_t pad0 = 0, abs0 = 0, rel0 = 0;
    ReadGoalValue(cpadList + 4, &pad0, sizeof(pad0));
    ReadGoalValue(pad0 + 40, &abs0, sizeof(abs0));
    ReadGoalValue(pad0 + 56, &rel0, sizeof(rel0));
    // process state at +52; a state's name symbol is its first field.
    const uint32_t target = symbolValue("*target*");
    uint32_t state = 0, stateName = 0;
    if (target != gNativeHelperContext.s7GoalOffset) {
        ReadGoalValue(target + 52, &state, sizeof(state));
        ReadGoalValue(state, &stateName, sizeof(stateName));
    }
    const char *stateText = stateName != 0 ? GoalSymbolName(stateName) : nullptr;
    const uint32_t progress = symbolValue("*progress-process*");
    NSLog(@"jakIOS: pad diag reads=%u startEdges=%u abs0=0x%x rel0=0x%x target-state=%s progress=%s",
          gPadDiagnostics.reads, gPadDiagnostics.startEdges, abs0, rel0,
          stateText != nullptr ? stateText : "?",
          progress == gNativeHelperContext.s7GoalOffset ? "#f" : "active");
    gPadDiagnostics.reads = 0;
    gPadDiagnostics.startEdges = 0;
}

void UpdateSoundIopInfo() {
    // Overlord StopVAG at end of stream: gVAG_Id = 1 and strpos -1. Without this GOAL believes
    // dialog is still playing and leaves music/SFX ducked indefinitely.
    // A fake (audio-less) clock runs until GOAL stops the stream, as in the overlord.
    // Frames the audio position may stand still (engine start-up, interruption, route change)
    // before the clock stops waiting for it; a stalled strpos > 0 freezes a spooled anim forever.
    constexpr uint32_t kMaxAudioStallFrames = 30;
    Jak1AudioManager *audio = Jak1AudioManager.sharedManager;
    if (gVagStreamClock.running && gVagStreamClock.audioBacked && !audio.isVAGStreamActive) {
        if (gVagStreamClock.stopAtAudioEnd) {
            StopVagStreamClock();
        } else {
            gVagStreamClock.audioBacked = false;
            gVagStreamClock.followAudio = false;
        }
    }
    if (gVagStreamClock.running && !gVagStreamClock.paused) {
        bool advanced = false;
        if (gVagStreamClock.followAudio) {
            const double seconds = audio.VAGStreamPlaybackSeconds;
            const int32_t audioClock = seconds >= 0 ? static_cast<int32_t>(seconds * 1024.0) : -1;
            if (audioClock > gVagStreamClock.clock) {
                gVagStreamClock.clock = audioClock;
                gVagStreamClock.audioStallFrames = 0;
                advanced = true;
            } else if (++gVagStreamClock.audioStallFrames > kMaxAudioStallFrames) {
                NSLog(@"jakIOS audio: VAG stream position stalled at %d, using frame clock",
                      gVagStreamClock.clock);
                gVagStreamClock.followAudio = false;
            }
        }
        if (!gVagStreamClock.followAudio && !advanced) {
            gVagStreamClock.clock += 1024 / 60;
        }
    }
    gVagStreamClock.frame++;
    jak1sound::VBlank();
    [audio serviceAudioEngine];
    const auto symbol = gNativeHelperContext.symbols.find("*sound-iop-info*");
    uint32_t info = 0;
    if (symbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(symbol->second, &info, sizeof(info)) || info == 0) {
        return;
    }
    // sound-iop-info is a basic: type-db offset 16 (frame) is object pointer + 12.
    struct {
        uint32_t frame;
        int32_t strpos;
        uint32_t strId;
    } fields {gVagStreamClock.frame, gVagStreamClock.running ? gVagStreamClock.clock : -1,
              gVagStreamClock.soundId};
    WriteGoalValue(info + 12, &fields, sizeof(fields));
}

bool HasValidBootstrapManifest() {
    NSURL *manifestURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTBootstrapManifest"
                                                 withExtension:@"json"];
    if (manifestURL == nil) {
        return false;
    }

    NSData *data = [NSData dataWithContentsOfURL:manifestURL];
    if (data == nil) {
        return false;
    }

    NSError *error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![root isKindOfClass:[NSDictionary class]]) {
        return false;
    }

    NSDictionary *manifest = root;
    return [manifest[@"format"] isEqual:@"OpenGOAL Jak 1 iOS AOT bootstrap manifest v1"] &&
           [manifest[@"execution"] isEqual:@"signed-native-kernel-dispatch-ready"] &&
           [manifest[@"capturedObjectCount"] unsignedIntegerValue] == 369 &&
           [manifest[@"signedMainSegmentCount"] unsignedIntegerValue] ==
               kCapturedCodeRangeCount &&
           [manifest[@"s7GoalOffset"] unsignedIntValue] == kCapturedS7GoalOffset;
}

bool HasExecutableBootstrapPlan() {
    NSURL *manifestURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTBootstrapManifest"
                                                 withExtension:@"json"];
    NSData *data = manifestURL == nil ? nil : [NSData dataWithContentsOfURL:manifestURL];
    NSError *error = nil;
    id root = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![root isKindOfClass:[NSDictionary class]]) {
        return false;
    }
    return [((NSDictionary *)root)[@"execution"] isEqual:@"signed-native-kernel-dispatch-ready"];
}

struct FundamentalTypeOffsets {
    uint32_t type;
    uint32_t symbol;
    uint32_t string;
    uint32_t function;
};

bool InstallFundamentalTypes(GoalAddressSpace *addressSpace,
                             GoalBumpHeap *heap,
                             FundamentalTypeOffsets *offsets) {
    constexpr uint32_t s7GoalOffset = 0x0014FD24;
    constexpr uint32_t functionSymbolOffset = 0x10;
    constexpr uint32_t stringSymbolOffset = 0x20;
    constexpr uint32_t symbolSymbolOffset = 0x28;
    constexpr uint32_t typeSymbolOffset = 0x30;
    if (addressSpace == nullptr || heap == nullptr || offsets == nullptr) {
        return false;
    }
    offsets->type = heap->allocate(64, 16);
    offsets->symbol = heap->allocate(64, 16);
    offsets->string = heap->allocate(64, 16);
    offsets->function = heap->allocate(64, 16);
    if (offsets->type == 0 || offsets->symbol == 0 || offsets->string == 0 || offsets->function == 0) {
        return false;
    }
    const uint32_t typeSymbols[] = {
        s7GoalOffset + typeSymbolOffset,
        s7GoalOffset + symbolSymbolOffset,
        s7GoalOffset + stringSymbolOffset,
        s7GoalOffset + functionSymbolOffset,
    };
    const uint32_t typeValues[] = {offsets->type, offsets->symbol, offsets->string, offsets->function};
    for (size_t index = 0; index < 4; index++) {
        uint8_t *symbolValue = addressSpace->pointerForGoal(typeSymbols[index], sizeof(uint32_t));
        uint8_t *symbolTag = addressSpace->pointerForGoal(typeSymbols[index] - 4, sizeof(uint32_t));
        uint8_t *typeTag = addressSpace->pointerForGoal(typeValues[index] - 4, sizeof(uint32_t));
        uint8_t *typeSymbol = addressSpace->pointerForGoal(typeValues[index], sizeof(uint32_t));
        uint8_t *methodCount = addressSpace->pointerForGoal(typeValues[index] + 14, sizeof(uint16_t));
        if (symbolValue == nullptr || symbolTag == nullptr || typeTag == nullptr ||
            typeSymbol == nullptr || methodCount == nullptr) {
            return false;
        }
        const uint16_t methods = 9;
        memcpy(symbolValue, &typeValues[index], sizeof(uint32_t));
        memcpy(symbolTag, &offsets->symbol, sizeof(uint32_t));
        memcpy(typeTag, &offsets->type, sizeof(uint32_t));
        memcpy(typeSymbol, &typeSymbols[index], sizeof(uint32_t));
        memcpy(methodCount, &methods, sizeof(methods));
    }
    return true;
}

struct __attribute__((packed)) AOTImageHeader {
    char magic[8];
    uint32_t version;
    uint32_t goalBaseOffset;
    uint32_t imageSize;
    uint32_t segmentCount;
    uint32_t staticPatchCount;
    uint8_t imageDigest[CC_SHA256_DIGEST_LENGTH];
};

// Jak1AOTRuntimeState.xd3 (tools/runtime_state_patch/runtime_state_patch.py): the captured arena as an
// xdelta3 patch against the player's own disc files, so the app ships none of the disc data it holds.
struct __attribute__((packed)) RuntimeStatePatchHeader {
    char magic[8];
    uint32_t version;
    uint32_t decodedSize;
    uint32_t decodedCRC32;
    uint32_t patchSize;
    uint32_t encodedSize;
    uint32_t sourceCount;
};

struct __attribute__((packed)) RuntimeStatePatchSource {
    char name[32];  // path relative to the imported game directory, e.g. "CGO/GAME.CGO"
    uint32_t size;
    uint32_t crc32;
};

// Standard CRC-32 (zlib / Python zlib.crc32).
uint32_t RuntimeStateCRC32(const uint8_t *bytes, size_t length) {
    static const auto table = [] {
        std::array<uint32_t, 256> entries {};
        for (uint32_t index = 0; index < 256; index++) {
            uint32_t crc = index;
            for (int bit = 0; bit < 8; bit++) {
                crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
            }
            entries[index] = crc;
        }
        return entries;
    }();
    uint32_t crc = UINT32_MAX;
    for (size_t index = 0; index < length; index++) {
        crc = table[(crc ^ bytes[index]) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

// GOAL code sometimes uses the float 1.0 (0x3F800000) as a pointer, i.e. x22 + 0x3F800000, about
// 1 GB past the 128 MiB arena. A zeroed page is mapped there so those reads see 0 instead of faulting.
// The page must be mapped at that exact address, which other mappings (Metal buffers, the allocator's
// cached regions after the level build, a previous host's page) can already occupy, so it is claimed
// when the arena is placed and the arena is placed elsewhere if it can't be.
vm_address_t gFloatPointerPage = 0;

NSMutableData *AllocateGoalArena() {
    if (gFloatPointerPage != 0) {
        // Left by an earlier host in this process, whose arena is gone.
        vm_deallocate(mach_task_self(), gFloatPointerPage, vm_page_size);
        gFloatPointerPage = 0;
    }
    // Rejected arenas stay allocated until we return, so each attempt lands at a new address.
    // They are never touched, so they cost address space only.
    NSMutableArray<NSMutableData *> *rejected = [NSMutableArray array];
    for (int attempt = 0; attempt < 16; attempt++) {
        NSMutableData *arena = [NSMutableData dataWithLength:kGoalMemorySize];
        if (arena == nil) return nil;
        vm_address_t page = reinterpret_cast<vm_address_t>(arena.mutableBytes) + kFloatOnePointerOffset;
        const kern_return_t result = vm_allocate(mach_task_self(), &page, vm_page_size, VM_FLAGS_FIXED);
        if (result == KERN_SUCCESS) {
            memset(reinterpret_cast<void *>(page), 0, vm_page_size);
            gFloatPointerPage = page;
            NSLog(@"jakIOS: GOAL arena at %p, float-pointer compatibility page at %p (attempt %d)",
                  arena.mutableBytes, reinterpret_cast<void *>(page), attempt + 1);
            return arena;
        }
        NSLog(@"jakIOS: float-pointer page for arena %p is unavailable (%d); placing the arena again",
              arena.mutableBytes, result);
        [rejected addObject:arena];
    }
    return nil;
}

// Rebuilds the captured 128 MiB GOAL arena from the bundled patch and the imported disc.
// On failure returns nil and sets *error to a message for the bootstrap readiness text.
NSMutableData *LoadValidRuntimeState(const std::string &contentPath, NSString **error) {
    *error = @"The bundled runtime state patch is missing or invalid.";
    NSURL *patchURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTRuntimeState"
                                                withExtension:@"xd3"];
    NSData *data = patchURL == nil ? nil : [NSData dataWithContentsOfURL:patchURL];
    if (data == nil || data.length < sizeof(RuntimeStatePatchHeader)) {
        return nil;
    }
    RuntimeStatePatchHeader header;
    memcpy(&header, data.bytes, sizeof(header));
    constexpr char expectedMagic[] = "JAK1SXD";
    const size_t sourcesSize = static_cast<size_t>(header.sourceCount) * sizeof(RuntimeStatePatchSource);
    if (memcmp(header.magic, expectedMagic, sizeof(header.magic)) != 0 ||
        header.version != 1 || header.decodedSize != kGoalMemorySize || header.sourceCount == 0 ||
        data.length != sizeof(header) + sourcesSize + header.encodedSize) {
        return nil;
    }

    // The patch source is the listed disc files, concatenated. Any other disc revision or region
    // has different bytes, so check each file before decoding.
    std::vector<uint8_t> source;
    const auto *records = reinterpret_cast<const RuntimeStatePatchSource *>(
        static_cast<const uint8_t *>(data.bytes) + sizeof(header));
    for (uint32_t index = 0; index < header.sourceCount; index++) {
        RuntimeStatePatchSource record;
        memcpy(&record, &records[index], sizeof(record));
        const std::string name(record.name, strnlen(record.name, sizeof(record.name)));
        std::ifstream stream(contentPath + "/" + name, std::ios::binary);
        std::vector<uint8_t> file;
        if (stream) {
            file.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
        }
        if (file.size() != record.size || RuntimeStateCRC32(file.data(), file.size()) != record.crc32) {
            NSLog(@"jakIOS: runtime state source %s missing or different (%zu bytes)",
                  name.c_str(), file.size());
            *error = [NSString stringWithFormat:
                @"%s on the imported disc does not match the supported Jak and Daxter NTSC (v1) "
                @"disc. Import an NTSC v1 disc image.", name.c_str()];
            return nil;
        }
        source.insert(source.end(), file.begin(), file.end());
    }

    std::vector<uint8_t> patch(header.patchSize);
    const uint8_t *encoded = static_cast<const uint8_t *>(data.bytes) + sizeof(header) + sourcesSize;
    if (compression_decode_buffer(patch.data(), patch.size(), encoded, header.encodedSize, nullptr,
                                  COMPRESSION_ZLIB) != patch.size()) {
        return nil;
    }
    NSMutableData *state = AllocateGoalArena();
    if (state == nil) {
        *error = @"The GOAL memory arena could not be reserved. Restart the app and try again.";
        return nil;
    }
    size_t decoded = 0;
    if (xd3_decode_memory(patch.data(), patch.size(), source.data(), source.size(),
                          static_cast<uint8_t *>(state.mutableBytes), &decoded,
                          header.decodedSize, 0) != 0 ||
        decoded != header.decodedSize ||
        RuntimeStateCRC32(static_cast<const uint8_t *>(state.bytes), header.decodedSize) !=
            header.decodedCRC32) {
        *error = @"The runtime state could not be rebuilt from the imported disc.";
        return nil;
    }
    *error = nil;
    return state;
}

bool LoadCapturedRuntimeSymbols(GoalAddressSpace *addressSpace,
                                FundamentalTypeOffsets *fundamentalTypes) {
    if (addressSpace == nullptr || fundamentalTypes == nullptr) {
        return false;
    }
    NSURL *symbolsURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTRuntimeSymbols"
                                                  withExtension:@"json"];
    NSData *data = symbolsURL == nil ? nil : [NSData dataWithContentsOfURL:symbolsURL];
    NSError *error = nil;
    NSDictionary *root = data == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    NSArray *symbols = root[@"symbols"];
    if (error != nil || ![root isKindOfClass:[NSDictionary class]] ||
        ![root[@"format"] isEqual:@"OpenGOAL Jak 1 iOS captured runtime symbols v1"] ||
        [root[@"s7GoalOffset"] unsignedIntValue] != kCapturedS7GoalOffset ||
        ![symbols isKindOfClass:[NSArray class]] ||
        [root[@"symbolCount"] unsignedIntegerValue] != symbols.count) {
        return false;
    }

    gNativeHelperContext.symbols.clear();
    gNativeHelperContext.s7GoalOffset = kCapturedS7GoalOffset;
    for (NSDictionary *entry in symbols) {
        NSString *name = entry[@"name"];
        const uint32_t goalOffset = [entry[@"goalOffset"] unsignedIntValue];
        if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
            addressSpace->pointerForGoal(goalOffset, sizeof(uint32_t)) == nullptr) {
            return false;
        }
        const char *utf8Name = name.UTF8String;
        if (utf8Name == nullptr) {
            return false;
        }
        gNativeHelperContext.symbols[utf8Name] = goalOffset;
    }

    // These are fixed Jak 1 symbols created before dynamic interning begins, so
    // they are intentionally absent from OPENGOAL_DYNAMIC_SYMBOL capture lines.
    gNativeHelperContext.symbols["function"] = kCapturedS7GoalOffset + 0x10;
    gNativeHelperContext.symbols["string"] = kCapturedS7GoalOffset + 0x20;
    gNativeHelperContext.symbols["symbol"] = kCapturedS7GoalOffset + 0x28;
    gNativeHelperContext.symbols["type"] = kCapturedS7GoalOffset + 0x30;

    const auto readType = [&](const char *name, uint32_t *output) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        if (symbol == gNativeHelperContext.symbols.end()) {
            return false;
        }
        const uint8_t *value = addressSpace->pointerForGoal(symbol->second, sizeof(uint32_t));
        if (value == nullptr) {
            return false;
        }
        memcpy(output, value, sizeof(uint32_t));
        return *output != 0;
    };
    return readType("type", &fundamentalTypes->type) &&
        readType("symbol", &fundamentalTypes->symbol) &&
        readType("string", &fundamentalTypes->string) &&
        readType("function", &fundamentalTypes->function);
}

NSMutableData *LoadValidBootstrapImage(uint32_t *goalBaseOffset) {
    NSURL *imageURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTBootstrap"
                                                withExtension:@"bin"];
    NSData *data = imageURL == nil ? nil : [NSData dataWithContentsOfURL:imageURL];
    if (data == nil || data.length < sizeof(AOTImageHeader)) {
        return nil;
    }

    const auto *header = static_cast<const AOTImageHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1AOT";
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 ||
        header->goalBaseOffset != kCapturedCodeBaseOffset ||
        header->imageSize != kCapturedCodeImageSize ||
        header->segmentCount != kCapturedCodeRangeCount ||
        header->staticPatchCount != 0 ||
        data.length != sizeof(AOTImageHeader) + header->imageSize) {
        return nil;
    }

    const auto *imageBytes = static_cast<const uint8_t *>(data.bytes) + sizeof(AOTImageHeader);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(imageBytes, static_cast<CC_LONG>(header->imageSize), digest);
    if (memcmp(digest, header->imageDigest, sizeof(digest)) != 0) {
        return nil;
    }

    *goalBaseOffset = header->goalBaseOffset;
    // This buffer deliberately contains data only. It remains non-executable on iOS.
    return [NSMutableData dataWithBytes:imageBytes length:header->imageSize];
}

bool HasMatchingSignedAOTImage(NSData *bootstrapImage) {
    if (bootstrapImage == nil) {
        return false;
    }
    const size_t signedImageSize = static_cast<size_t>(
        reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_end) -
        reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin)
    );
    return signedImageSize == bootstrapImage.length &&
        memcmp(og_jak1_aot_signed_image_begin, bootstrapImage.bytes, signedImageSize) == 0;
}

bool HasValidGoalExecutionViews(NSData *writableGoalMemory, uint32_t goalCodeBaseOffset) {
    const size_t signedImageSize = static_cast<size_t>(
        reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_end) -
        reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin)
    );
    return writableGoalMemory.length == kGoalMemorySize &&
        goalCodeBaseOffset == kCapturedCodeBaseOffset &&
        signedImageSize == kCapturedCodeImageSize &&
        goalCodeBaseOffset <= kGoalMemorySize - signedImageSize;
}

// The page itself is mapped by AllocateGoalArena together with the arena; this only checks that it
// belongs to this arena.
bool InstallFloatPointerCompatibilityPage(NSMutableData *writableGoalMemory) {
    return writableGoalMemory != nil && writableGoalMemory.length == kGoalMemorySize &&
        gFloatPointerPage != 0 &&
        gFloatPointerPage ==
            reinterpret_cast<vm_address_t>(writableGoalMemory.mutableBytes) + kFloatOnePointerOffset;
}

bool InstallFixedFunctionThunks(GoalAddressSpace *addressSpace,
                                uint32_t goalCodeBaseOffset,
                                uint32_t functionTypeGoalOffset) {
    constexpr uint32_t capturedNothingGoalOffset = 0x001BFF24;
    constexpr uint32_t capturedZeroGoalOffset = 0x001BFF54;
    constexpr uint32_t nothingSymbolOffset = 0x128;
    constexpr uint32_t zeroFunctionSymbolOffset = 0x180;
    constexpr uint32_t profilerSymbolOffset = 0xE218;
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    const uintptr_t signedEnd = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_end);
    const uintptr_t nothing = reinterpret_cast<uintptr_t>(og_jak1_goal_nothing);
    const uintptr_t zero = reinterpret_cast<uintptr_t>(og_jak1_goal_zero);
    if (addressSpace == nullptr || nothing < signedEnd || zero < nothing ||
        zero - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t nothingGoalOffset = goalCodeBaseOffset + static_cast<uint32_t>(nothing - signedBegin);
    const uint32_t zeroGoalOffset = goalCodeBaseOffset + static_cast<uint32_t>(zero - signedBegin);
    uint8_t *nothingFunctionTag = addressSpace->pointerForGoal(
        nothingGoalOffset - 4,
        sizeof(uint32_t)
    );
    uint8_t *zeroFunctionTag = addressSpace->pointerForGoal(
        zeroGoalOffset - 4,
        sizeof(uint32_t)
    );
    uint8_t *nothingSymbol = addressSpace->pointerForGoal(
        kCapturedS7GoalOffset + nothingSymbolOffset,
        sizeof(uint32_t)
    );
    uint8_t *zeroSymbol = addressSpace->pointerForGoal(
        kCapturedS7GoalOffset + zeroFunctionSymbolOffset,
        sizeof(uint32_t)
    );
    uint8_t *profilerSymbol = addressSpace->pointerForGoal(
        kCapturedS7GoalOffset + profilerSymbolOffset,
        sizeof(uint32_t)
    );
    // Some optional HUD manipy roots remain null-typed when their source art is
    // unavailable during the captured bootstrap. y-angle is method slot 22
    // (type offset 0x68); give only that null-type slot a safe numeric result.
    uint8_t *nullTypeYAngleMethod = addressSpace->pointerForGoal(0x68, sizeof(uint32_t));
    uint8_t *nullTypeSetAngleMethod = addressSpace->pointerForGoal(0x48, sizeof(uint32_t));
    if (nothingFunctionTag == nullptr || zeroFunctionTag == nullptr ||
        nothingSymbol == nullptr || zeroSymbol == nullptr || profilerSymbol == nullptr ||
        nullTypeYAngleMethod == nullptr || nullTypeSetAngleMethod == nullptr) {
        return false;
    }
    memcpy(nothingFunctionTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    memcpy(zeroFunctionTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    memcpy(nothingSymbol, &nothingGoalOffset, sizeof(nothingGoalOffset));
    memcpy(zeroSymbol, &zeroGoalOffset, sizeof(zeroGoalOffset));
    // kernel-dispatcher calls pc-prof before any game code. Until a profiler is
    // installed, bind it to the signed no-op function instead of virtual offset zero.
    memcpy(profilerSymbol, &nothingGoalOffset, sizeof(nothingGoalOffset));
    memcpy(nullTypeYAngleMethod, &zeroGoalOffset, sizeof(zeroGoalOffset));
    memcpy(nullTypeSetAngleMethod, &nothingGoalOffset, sizeof(nothingGoalOffset));

    // InitHeapAndSymbol creates these two tiny functions immediately before the
    // first linked object. They are valid desktop code but lie outside the signed
    // AOT image. Relocate every captured GOAL reference to signed equivalents.
    for (uint32_t offset = 0; offset <= kGoalMemorySize - sizeof(uint32_t); offset += 4) {
        uint8_t *word = addressSpace->pointerForGoal(offset, sizeof(uint32_t));
        uint32_t value = 0;
        memcpy(&value, word, sizeof(value));
        if (value == capturedNothingGoalOffset) {
            memcpy(word, &nothingGoalOffset, sizeof(nothingGoalOffset));
        } else if (value == capturedZeroGoalOffset) {
            memcpy(word, &zeroGoalOffset, sizeof(zeroGoalOffset));
        }
    }
    return true;
}

bool RunSignedThunkSmokeTest(NSMutableData *writableGoalMemory, uint32_t goalCodeBaseOffset) {
    if (writableGoalMemory == nil) {
        return false;
    }
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    if (signedBegin < goalCodeBaseOffset) {
        return false;
    }
    void *signedCodeBase = reinterpret_cast<void *>(signedBegin - goalCodeBaseOffset);
    void *writableGoalBase = writableGoalMemory.mutableBytes;
    const uint64_t nothingResult = og_jak1_call_goal_arm64(
        0, 0, 0, const_cast<uint8_t *>(og_jak1_goal_nothing),
        reinterpret_cast<void *>(static_cast<uintptr_t>(kCapturedS7GoalOffset)), writableGoalBase,
        signedCodeBase
    );
    const uint64_t zeroResult = og_jak1_call_goal_arm64(
        123, 0, 0, const_cast<uint8_t *>(og_jak1_goal_zero),
        reinterpret_cast<void *>(static_cast<uintptr_t>(kCapturedS7GoalOffset)), writableGoalBase,
        signedCodeBase
    );
    return nothingResult == 0 && zeroResult == 0;
}

struct __attribute__((packed)) SignedCodeRangeHeader {
    char magic[8];
    uint32_t version;
    uint32_t goalBaseOffset;
    uint32_t rangeCount;
};

struct __attribute__((packed)) SignedCodeRange {
    uint32_t goalOffset;
    uint32_t size;
};

bool HasValidSignedCodeIndex(uint32_t goalBaseOffset, uint32_t imageSize) {
    NSURL *indexURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTCodeRanges"
                                              withExtension:@"bin"];
    NSData *data = indexURL == nil ? nil : [NSData dataWithContentsOfURL:indexURL];
    if (data == nil || data.length < sizeof(SignedCodeRangeHeader)) {
        return false;
    }
    const auto *header = static_cast<const SignedCodeRangeHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1COD";
    const NSUInteger expectedLength = sizeof(SignedCodeRangeHeader) +
        static_cast<NSUInteger>(header->rangeCount) * sizeof(SignedCodeRange);
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 || header->goalBaseOffset != goalBaseOffset ||
        header->rangeCount != kCapturedCodeRangeCount || data.length != expectedLength) {
        return false;
    }
    const auto *ranges = reinterpret_cast<const SignedCodeRange *>(
        static_cast<const uint8_t *>(data.bytes) + sizeof(SignedCodeRangeHeader)
    );
    uint64_t previousEnd = goalBaseOffset;
    const uint64_t imageEnd = static_cast<uint64_t>(goalBaseOffset) + imageSize;
    for (uint32_t index = 0; index < header->rangeCount; index++) {
        const uint64_t start = ranges[index].goalOffset;
        const uint64_t end = start + ranges[index].size;
        if (ranges[index].size == 0 || start < previousEnd || end > imageEnd) {
            return false;
        }
        previousEnd = end;
    }
    return true;
}

bool HasValidKernelDispatcherEntry() {
    NSURL *entryURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTKernelEntry"
                                              withExtension:@"json"];
    NSData *data = entryURL == nil ? nil : [NSData dataWithContentsOfURL:entryURL];
    NSError *error = nil;
    id root = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![root isKindOfClass:[NSDictionary class]]) {
        return false;
    }
    NSDictionary *entry = root;
    return [entry[@"format"] isEqual:@"OpenGOAL Jak 1 iOS kernel entry v1"] &&
        [entry[@"symbol"] isEqual:@"kernel-dispatcher"] &&
        [entry[@"goalOffset"] unsignedIntValue] == kCapturedKernelDispatcherGoalOffset &&
        [entry[@"sourceObject"] isEqual:@"gkernel"] &&
        [entry[@"sourceMainRelativeOffset"] unsignedIntValue] == 0x4154 &&
        [entry[@"execution"] isEqual:@"signed-native-kernel-dispatch-ready"];
}

bool CanInitializeNativeKernel(NSData *writableGoalMemory,
                               uint32_t goalCodeBaseOffset,
                               bool hasInstalledNativeHelpers) {
    if (writableGoalMemory == nil || writableGoalMemory.length != kGoalMemorySize ||
        !hasInstalledNativeHelpers || kCapturedKernelDispatcherGoalOffset < goalCodeBaseOffset) {
        return false;
    }
    uint32_t dispatcherValue = 0;
    auto symbol = gNativeHelperContext.symbols.find("kernel-dispatcher");
    if (symbol == gNativeHelperContext.symbols.end()) {
        return false;
    }
    const uint8_t *value = gNativeHelperContext.addressSpace->pointerForGoal(
        symbol->second, sizeof(dispatcherValue)
    );
    if (value == nullptr) {
        return false;
    }
    memcpy(&dispatcherValue, value, sizeof(dispatcherValue));
    return dispatcherValue == kCapturedKernelDispatcherGoalOffset &&
        kCapturedS7GoalOffset < writableGoalMemory.length;
}

bool InstallNativeKernelEntry(GoalAddressSpace *addressSpace,
                              uint32_t functionTypeGoalOffset) {
    auto symbol = gNativeHelperContext.symbols.find("kernel-dispatcher");
    if (addressSpace == nullptr || symbol == gNativeHelperContext.symbols.end()) {
        return false;
    }
    uint8_t *functionTag = addressSpace->pointerForGoal(
        kCapturedKernelDispatcherGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    uint8_t *symbolValue = addressSpace->pointerForGoal(symbol->second, sizeof(uint32_t));
    if (functionTag == nullptr || symbolValue == nullptr) {
        return false;
    }
    memcpy(functionTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    memcpy(symbolValue, &kCapturedKernelDispatcherGoalOffset,
           sizeof(kCapturedKernelDispatcherGoalOffset));
    return true;
}

uint64_t DispatchNativeKernelFrame(NSMutableData *writableGoalMemory,
                                   uint32_t goalCodeBaseOffset) {
    // Translated GOAL functions grow the stack downward, but may address outgoing argument and
    // vector spill slots above their current SP. Some deep kernel paths (including progress-menu
    // state during a level transition) reach more than one page above SP, so reserve enough mapped
    // headroom to keep those accesses inside the 128 MB writable arena.
    constexpr NSUInteger goalStackTopOffset = 64 * 1024;
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    const uintptr_t dispatcher = signedBegin + kCapturedKernelDispatcherGoalOffset - goalCodeBaseOffset;
    void *signedCodeBase = reinterpret_cast<void *>(signedBegin - goalCodeBaseOffset);
    void *writableGoalBase = writableGoalMemory.mutableBytes;
    const uintptr_t stackTop = reinterpret_cast<uintptr_t>(writableGoalBase) +
        kGoalMemorySize - goalStackTopOffset;
    return og_jak1_call_goal_on_stack_arm64(
        stackTop, 0, 0, reinterpret_cast<void *>(dispatcher),
        reinterpret_cast<void *>(static_cast<uintptr_t>(kCapturedS7GoalOffset)),
        writableGoalBase, signedCodeBase
    );
}

// pc-settings method ids (pckernel-h.gc :methods order; `initialize` is method 9).
constexpr uint32_t kPCSettingsCommitToFileMethodId = 46;
constexpr uint32_t kPCSettingsLoadSettingsMethodId = 47;

// Calls a one-argument pc-settings method on *pc-settings*, on the GOAL stack, since
// read-from-file / write-to-file allocate their file-stream with `new 'stack`. Must run on the
// kernel queue between GOAL frames.
void CallPCSettingsMethod(NSMutableData *writableGoalMemory, uint32_t goalCodeBaseOffset,
                          uint32_t methodId) {
    constexpr NSUInteger goalStackTopOffset = 4096;
    const auto settingsSymbol = gNativeHelperContext.symbols.find("*pc-settings*");
    const auto functionSymbol = gNativeHelperContext.symbols.find("function");
    uint32_t settings = 0, settingsType = 0, method = 0, functionType = 0, methodType = 0;
    if (settingsSymbol == gNativeHelperContext.symbols.end() ||
        functionSymbol == gNativeHelperContext.symbols.end() ||
        !ReadGoalValue(settingsSymbol->second, &settings, sizeof(settings)) ||
        settings <= sizeof(uint32_t) || settings == kCapturedS7GoalOffset ||
        !ReadGoalValue(settings - sizeof(uint32_t), &settingsType, sizeof(settingsType)) ||
        !ReadGoalValue(settingsType + 16 + methodId * 4, &method, sizeof(method)) ||
        !ReadGoalValue(functionSymbol->second, &functionType, sizeof(functionType)) ||
        method <= sizeof(uint32_t) ||
        !ReadGoalValue(method - sizeof(uint32_t), &methodType, sizeof(methodType)) ||
        methodType != functionType) {
        NSLog(@"jakIOS: could not resolve pc-settings method %u", methodId);
        return;
    }
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    void *signedCodeBase = reinterpret_cast<void *>(signedBegin - goalCodeBaseOffset);
    void *writableGoalBase = writableGoalMemory.mutableBytes;
    const uintptr_t stackTop = reinterpret_cast<uintptr_t>(writableGoalBase) +
        kGoalMemorySize - goalStackTopOffset;
    og_jak1_call_goal_on_stack_with_arg_arm64(
        stackTop, settings, 0,
        reinterpret_cast<void *>(signedBegin + method - goalCodeBaseOffset),
        reinterpret_cast<void *>(static_cast<uintptr_t>(kCapturedS7GoalOffset)),
        writableGoalBase, signedCodeBase
    );
}

// The captured runtime image already contains an initialized *pc-settings*, so its `initialize`
// method (which calls load-settings) never runs on iOS. Without this, the game keeps its defaults
// and the next commit-to-file overwrites the user's saved pc-settings.gc.
void LoadPCSettingsFromFile(NSMutableData *writableGoalMemory, uint32_t goalCodeBaseOffset) {
    CallPCSettingsMethod(writableGoalMemory, goalCodeBaseOffset, kPCSettingsLoadSettingsMethodId);
}

void CommitPCSettingsToFile(NSMutableData *writableGoalMemory, uint32_t goalCodeBaseOffset) {
    CallPCSettingsMethod(writableGoalMemory, goalCodeBaseOffset, kPCSettingsCommitToFileMethodId);
}

bool HasValidNativeStubInventory() {
    NSURL *inventoryURL = [[NSBundle mainBundle] URLForResource:@"Jak1NativeStubInventory"
                                                  withExtension:@"json"];
    NSData *data = inventoryURL == nil ? nil : [NSData dataWithContentsOfURL:inventoryURL];
    NSError *error = nil;
    id root = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![root isKindOfClass:[NSDictionary class]]) {
        return false;
    }
    NSDictionary *inventory = root;
    NSArray *stubs = inventory[@"stubs"];
    if (![inventory[@"format"] isEqual:@"OpenGOAL Jak 1 iOS native stub inventory v1"] ||
        [inventory[@"stubCount"] unsignedIntegerValue] != 143 ||
        ![stubs isKindOfClass:[NSArray class]] || stubs.count != 143 ||
        ![inventory[@"execution"] isEqual:@"signed-native-thunks-installed"]) {
        return false;
    }
    NSMutableSet<NSString *> *names = [NSMutableSet setWithCapacity:stubs.count];
    for (id item in stubs) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            return false;
        }
        NSDictionary *stub = item;
        NSString *name = stub[@"name"];
        NSString *convention = stub[@"convention"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0 ||
            !([convention isEqual:@"arguments"] || [convention isEqual:@"stack_arguments"]) ||
            [names containsObject:name]) {
            return false;
        }
        [names addObject:name];
    }
    return [names containsObject:@"link"] && [names containsObject:@"dgo-load"] &&
        [names containsObject:@"method-set!"];
}

struct __attribute__((packed)) StartupPatchHeader {
    char magic[8];
    uint32_t version;
    uint32_t s7GoalOffset;
    uint32_t operationCount;
    uint32_t deferredOperationCount;
};

struct __attribute__((packed)) StartupPatchOperation {
    uint8_t kind;
    uint8_t padding[3];
    uint32_t imageOffset;
    uint32_t primaryValue;
    int32_t alternateValue;
};

bool ValidatePrelinkedStartupPatches(uint32_t *resolvedOperationCount,
                                     uint32_t *deferredOperationCount) {
    NSURL *patchURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTStartupPatches"
                                               withExtension:@"bin"];
    NSData *data = patchURL == nil ? nil : [NSData dataWithContentsOfURL:patchURL];
    if (data == nil || data.length < sizeof(StartupPatchHeader)) {
        return false;
    }

    const auto *header = static_cast<const StartupPatchHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1STP";
    const NSUInteger expectedLength = sizeof(StartupPatchHeader) +
        static_cast<NSUInteger>(header->operationCount) * sizeof(StartupPatchOperation);
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 ||
        header->s7GoalOffset != 0x0014FD24 ||
        data.length != expectedLength) {
        return false;
    }

    // All operations were applied offline before this image was compiled into signed text.
    // The table stays bundled as an audit record; iOS must never rewrite executable pages.
    if (header->operationCount != 170346 || header->deferredOperationCount != 0) {
        return false;
    }
    *resolvedOperationCount = header->operationCount;
    *deferredOperationCount = header->deferredOperationCount;
    return true;
}

struct __attribute__((packed)) SymbolHashHeader {
    char magic[8];
    uint32_t version;
    uint32_t s7GoalOffset;
    uint32_t entryCount;
};

struct __attribute__((packed)) SymbolHashEntry {
    int32_t s7RelativeOffset;
    uint32_t hash;
};

bool MaterializeSymbolHashes(GoalAddressSpace *addressSpace,
                             uint32_t symbolTypeGoalOffset,
                             uint32_t *entryCount) {
    NSURL *hashURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTSymbolHashes"
                                              withExtension:@"bin"];
    NSData *data = hashURL == nil ? nil : [NSData dataWithContentsOfURL:hashURL];
    if (data == nil || data.length < sizeof(SymbolHashHeader)) {
        return false;
    }

    const auto *header = static_cast<const SymbolHashHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1SYM";
    const NSUInteger expectedLength = sizeof(SymbolHashHeader) +
        static_cast<NSUInteger>(header->entryCount) * sizeof(SymbolHashEntry);
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 ||
        header->s7GoalOffset != 0x0014FD24 ||
        data.length != expectedLength) {
        return false;
    }

    const auto *entries = reinterpret_cast<const SymbolHashEntry *>(
        static_cast<const uint8_t *>(data.bytes) + sizeof(SymbolHashHeader)
    );
    constexpr uint32_t symInfoOffset = 0x1FFFC;
    for (uint32_t index = 0; index < header->entryCount; index++) {
        const uint32_t symbolGoalOffset = header->s7GoalOffset + entries[index].s7RelativeOffset;
        uint8_t *symbolTag = addressSpace->pointerForGoal(symbolGoalOffset - 4, sizeof(uint32_t));
        uint8_t *symbolValue = addressSpace->pointerForGoal(symbolGoalOffset, sizeof(uint32_t));
        uint8_t *symbolInfo = addressSpace->pointerForGoal(
            symbolGoalOffset + symInfoOffset,
            sizeof(uint32_t)
        );
        if (symbolTag == nullptr || symbolValue == nullptr || symbolInfo == nullptr) {
            return false;
        }
        memcpy(symbolTag, &symbolTypeGoalOffset, sizeof(symbolTypeGoalOffset));
        // Some bootstrap symbols (fundamental types and fixed signed functions)
        // are installed before this metadata pass. Preserve their values.
        memcpy(symbolInfo, &entries[index].hash, sizeof(entries[index].hash));
    }

    *entryCount = header->entryCount;
    return true;
}

struct __attribute__((packed)) SymbolStringHeader {
    char magic[8];
    uint32_t version;
    uint32_t s7GoalOffset;
    uint32_t arenaGoalOffset;
    uint32_t arenaSize;
    uint32_t entryCount;
};

struct __attribute__((packed)) SymbolStringEntry {
    int32_t s7RelativeOffset;
    uint32_t stringGoalOffset;
    uint16_t nameLength;
};

NSMutableData *MaterializeSymbolStrings(GoalAddressSpace *addressSpace,
                                        uint32_t stringTypeGoalOffset,
                                        uint32_t *entryCount) {
    NSURL *stringURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTSymbolStrings"
                                                withExtension:@"bin"];
    NSData *data = stringURL == nil ? nil : [NSData dataWithContentsOfURL:stringURL];
    if (data == nil || data.length < sizeof(SymbolStringHeader)) {
        return nil;
    }

    const auto *header = static_cast<const SymbolStringHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1STR";
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 ||
        header->s7GoalOffset != 0x0014FD24 ||
        header->arenaGoalOffset != 0x0017FD20 ||
        header->arenaSize != 270160) {
        return nil;
    }

    // The caller owns one contiguous writable GOAL arena; strings live in that arena.
    if (addressSpace->pointerForGoal(header->arenaGoalOffset, header->arenaSize) == nullptr) {
        return nil;
    }
    // Keep the existing nullable return contract without retaining a duplicate string buffer.
    NSMutableData *arena = [NSMutableData data];

    const uint8_t *cursor = static_cast<const uint8_t *>(data.bytes) + sizeof(SymbolStringHeader);
    const uint8_t *end = static_cast<const uint8_t *>(data.bytes) + data.length;
    constexpr uint32_t symInfoOffset = 0x1FFFC;
    for (uint32_t index = 0; index < header->entryCount; index++) {
        if (static_cast<size_t>(end - cursor) < sizeof(SymbolStringEntry)) {
            return nil;
        }
        SymbolStringEntry entry;
        memcpy(&entry, cursor, sizeof(entry));
        cursor += sizeof(entry);
        if (static_cast<size_t>(end - cursor) < entry.nameLength) {
            return nil;
        }

        uint8_t *stringHeader = addressSpace->pointerForGoal(entry.stringGoalOffset - 4, 8 + entry.nameLength);
        const uint32_t symbolGoalOffset = header->s7GoalOffset + entry.s7RelativeOffset;
        uint8_t *symbolInfoString = addressSpace->pointerForGoal(
            symbolGoalOffset + symInfoOffset + sizeof(uint32_t),
            sizeof(uint32_t)
        );
        if (stringHeader == nullptr || symbolInfoString == nullptr) {
            return nil;
        }
        const uint32_t nameLength = entry.nameLength;
        memcpy(stringHeader, &stringTypeGoalOffset, sizeof(stringTypeGoalOffset));
        memcpy(stringHeader + sizeof(uint32_t), &nameLength, sizeof(nameLength));
        memcpy(stringHeader + 8, cursor, entry.nameLength);
        stringHeader[8 + entry.nameLength] = 0;
        memcpy(symbolInfoString, &entry.stringGoalOffset, sizeof(entry.stringGoalOffset));
        cursor += entry.nameLength;
    }
    if (cursor != end) {
        return nil;
    }

    *entryCount = header->entryCount;
    return arena;
}

struct __attribute__((packed)) TypeRecordHeader {
    char magic[8];
    uint32_t version;
    uint32_t entryCount;
};

struct __attribute__((packed)) TypeRecordEntry {
    uint32_t typeGoalOffset;
    uint32_t symbolGoalOffset;
    uint16_t methodCount;
    uint16_t allocationSize;
};

bool MaterializeTypeRecords(GoalAddressSpace *addressSpace,
                            uint32_t typeTypeGoalOffset,
                            uint32_t *entryCount) {
    NSURL *typeURL = [[NSBundle mainBundle] URLForResource:@"Jak1AOTTypeRecords"
                                              withExtension:@"bin"];
    NSData *data = typeURL == nil ? nil : [NSData dataWithContentsOfURL:typeURL];
    if (data == nil || data.length < sizeof(TypeRecordHeader)) {
        return false;
    }

    const auto *header = static_cast<const TypeRecordHeader *>(data.bytes);
    constexpr char expectedMagic[] = "JAK1TYP";
    const NSUInteger expectedLength = sizeof(TypeRecordHeader) +
        static_cast<NSUInteger>(header->entryCount) * sizeof(TypeRecordEntry);
    if (memcmp(header->magic, expectedMagic, sizeof(header->magic)) != 0 ||
        header->version != 1 || header->entryCount != 117 || data.length != expectedLength) {
        return false;
    }

    const auto *entries = reinterpret_cast<const TypeRecordEntry *>(
        static_cast<const uint8_t *>(data.bytes) + sizeof(TypeRecordHeader)
    );
    for (uint32_t index = 0; index < header->entryCount; index++) {
        const TypeRecordEntry &entry = entries[index];
        if (entry.allocationSize < 16) {
            return false;
        }
        uint8_t *typeTag = addressSpace->pointerForGoal(entry.typeGoalOffset - 4, sizeof(uint32_t));
        uint8_t *type = addressSpace->pointerForGoal(entry.typeGoalOffset, entry.allocationSize - 4);
        uint8_t *symbolValue = addressSpace->pointerForGoal(entry.symbolGoalOffset, sizeof(uint32_t));
        if (typeTag == nullptr || type == nullptr || symbolValue == nullptr) {
            return false;
        }
        memcpy(typeTag, &typeTypeGoalOffset, sizeof(typeTypeGoalOffset));
        memcpy(type, &entry.symbolGoalOffset, sizeof(entry.symbolGoalOffset));
        memcpy(type + 14, &entry.methodCount, sizeof(entry.methodCount));
        memcpy(symbolValue, &entry.typeGoalOffset, sizeof(entry.typeGoalOffset));
    }

    *entryCount = header->entryCount;
    return true;
}

uint32_t ResolveMips2CSymbol(const char *name) {
    if (strcmp(name, "debug") == 0) {
        return kCapturedS7GoalOffset + 0x148; // FIX_SYM_DEBUG_HEAP, a fixed symbol
    }
    const auto symbol = gNativeHelperContext.symbols.find(name);
    if (symbol == gNativeHelperContext.symbols.end()) {
        NSLog(@"jakIOS: Mips2C symbol %s is not in the captured image", name);
        return 0;
    }
    return symbol->second;
}

// Reads the captured value of a Mips2C function: a symbol's value, or for "(method N type)"
// the method slot of that type. On desktop this is the def-mips2c heap trampoline, which is
// zero in the signed payload.
uint32_t CapturedMips2CEntry(const std::string &name) {
    uint32_t location = 0;
    unsigned methodIndex = 0;
    char typeName[64] = {};
    if (sscanf(name.c_str(), "(method %u %63[^)])", &methodIndex, typeName) == 2) {
        const auto typeSymbol = gNativeHelperContext.symbols.find(typeName);
        uint32_t type = 0;
        if (typeSymbol == gNativeHelperContext.symbols.end() ||
            !ReadGoalValue(typeSymbol->second, &type, sizeof(type)) || type == 0) {
            return 0;
        }
        location = type + 16 + methodIndex * 4;
    } else {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        if (symbol == gNativeHelperContext.symbols.end()) {
            return 0;
        }
        location = symbol->second;
    }
    uint32_t entry = 0;
    return ReadGoalValue(location, &entry, sizeof(entry)) ? entry : 0;
}

// Binds every Mips2C function registered by og_jak1_mips2c_link_all to a signed indexed thunk,
// skipping captured entries that already have a dedicated thunk.
bool BindIndexedMips2CThunks(GoalAddressSpace *addressSpace,
                             uintptr_t signedBegin,
                             uint32_t goalCodeBaseOffset,
                             uint32_t functionTypeGoalOffset,
                             std::unordered_map<uint32_t, uint32_t> *relocations) {
    constexpr uint32_t kThunkSize = 8;
    const uintptr_t thunksBegin = reinterpret_cast<uintptr_t>(og_jak1_mips2c_indexed_thunks_begin);
    const uintptr_t thunksEnd = reinterpret_cast<uintptr_t>(og_jak1_mips2c_indexed_thunks_end);
    if (thunksBegin < signedBegin || thunksBegin - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t slotCount = static_cast<uint32_t>((thunksEnd - thunksBegin) / kThunkSize);
    const uint32_t registeredCount = og_jak1_mips2c_link_all(ResolveMips2CSymbol);
    uint32_t bound = 0;
    for (uint32_t index = 0; index < registeredCount; index++) {
        const char *name = nullptr;
        uint64_t (*execute)(void *) = nullptr;
        uint32_t stackSize = 0;
        if (!og_jak1_mips2c_registered(index, &name, &execute, &stackSize)) {
            return false;
        }
        const uint32_t captured = CapturedMips2CEntry(name);
        if (captured == 0 || relocations->count(captured) != 0) {
            continue;
        }
        if (index >= slotCount) {
            NSLog(@"jakIOS: no indexed Mips2C thunk left for %s", name);
            continue;
        }
        const uint32_t thunkGoalOffset = goalCodeBaseOffset +
            static_cast<uint32_t>(thunksBegin - signedBegin) + index * kThunkSize;
        if (!WriteGoalValue(thunkGoalOffset - sizeof(uint32_t), &functionTypeGoalOffset,
                            sizeof(functionTypeGoalOffset))) {
            return false;
        }
        og_jak1_mips2c_slot_table[index * 2] = reinterpret_cast<uint64_t>(execute);
        og_jak1_mips2c_slot_table[index * 2 + 1] = stackSize;
        relocations->emplace(captured, thunkGoalOffset);
        bound++;
    }
    NSLog(@"jakIOS: bound %u of %u Mips2C functions to indexed thunks", bound, registeredCount);
    return true;
}

bool InstallNativeHelperThunks(GoalAddressSpace *addressSpace,
                               uint32_t goalCodeBaseOffset,
                               uint32_t functionTypeGoalOffset,
                               uint32_t *installedCount) {
    if (addressSpace == nullptr || installedCount == nullptr) {
        return false;
    }
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    const uintptr_t thunkBegin = reinterpret_cast<uintptr_t>(og_jak1_native_thunks_begin);
    const uintptr_t thunkEnd = reinterpret_cast<uintptr_t>(og_jak1_native_thunks_end);
    constexpr uint32_t namedThunkCount = 143;
    constexpr uint32_t thunkCount = 150;
    constexpr uint32_t thunkSize = 8;
    if (thunkBegin < signedBegin || thunkEnd - thunkBegin != thunkCount * thunkSize ||
        thunkEnd - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }

    NSURL *inventoryURL = [[NSBundle mainBundle] URLForResource:@"Jak1NativeStubInventory"
                                                  withExtension:@"json"];
    NSData *inventoryData = inventoryURL == nil ? nil : [NSData dataWithContentsOfURL:inventoryURL];
    NSError *error = nil;
    NSDictionary *inventory = inventoryData == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:inventoryData options:0 error:&error];
    NSArray *stubs = inventory[@"stubs"];
    if (error != nil || ![stubs isKindOfClass:[NSArray class]] ||
        stubs.count != namedThunkCount) {
        return false;
    }

    std::unordered_map<uint32_t, uint32_t> capturedThunkRelocations;
    capturedThunkRelocations.reserve(thunkCount);
    for (uint32_t index = 0; index < namedThunkCount; index++) {
        NSString *name = stubs[index][@"name"];
        NSNumber *desktopGoalOffset = stubs[index][@"desktop_goal_offset"];
        if (![name isKindOfClass:[NSString class]] ||
            ![desktopGoalOffset isKindOfClass:[NSNumber class]] ||
            desktopGoalOffset.unsignedIntValue == 0) {
            return false;
        }
        const char *utf8Name = name.UTF8String;
        const auto symbol = utf8Name == nullptr ? gNativeHelperContext.symbols.end() :
            gNativeHelperContext.symbols.find(utf8Name);
        if (symbol == gNativeHelperContext.symbols.end()) {
            return false;
        }
        const uint32_t thunkGoalOffset = goalCodeBaseOffset +
            static_cast<uint32_t>(thunkBegin - signedBegin) + index * thunkSize;
        uint8_t *functionTag = addressSpace->pointerForGoal(thunkGoalOffset - 4, sizeof(uint32_t));
        uint8_t *symbolValue = addressSpace->pointerForGoal(symbol->second, sizeof(uint32_t));
        if (functionTag == nullptr || symbolValue == nullptr) {
            return false;
        }
        memcpy(functionTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
        memcpy(symbolValue, &thunkGoalOffset, sizeof(thunkGoalOffset));
        capturedThunkRelocations.emplace(desktopGoalOffset.unsignedIntValue, thunkGoalOffset);
    }
    constexpr uint32_t capturedAllocHeapObjectGoalOffset = 0x001C1574;
    const uint32_t allocatorThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + namedThunkCount * thunkSize;
    uint8_t *allocatorTag = addressSpace->pointerForGoal(
        allocatorThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (allocatorTag == nullptr) {
        return false;
    }
    memcpy(allocatorTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedAllocHeapObjectGoalOffset, allocatorThunkGoalOffset);
    // Value of the captured asize-of-basic-func fixed symbol (s7 + 0x188), which every basic type's
    // asize-of slot inherits. It sits below the code base, so an unrelocated call faults.
    constexpr uint32_t capturedAsizeOfBasicGoalOffset = 0x001BFF94;
    const uint32_t asizeOfBasicThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 144 * thunkSize;
    uint8_t *asizeOfBasicTag = addressSpace->pointerForGoal(
        asizeOfBasicThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (asizeOfBasicTag == nullptr) {
        return false;
    }
    memcpy(asizeOfBasicTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedAsizeOfBasicGoalOffset, asizeOfBasicThunkGoalOffset);
    constexpr uint32_t capturedNewBasicGoalOffset = 0x001C05F4;
    const uint32_t newBasicThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 145 * thunkSize;
    uint8_t *newBasicTag = addressSpace->pointerForGoal(
        newBasicThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (newBasicTag == nullptr) {
        return false;
    }
    memcpy(newBasicTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedNewBasicGoalOffset, newBasicThunkGoalOffset);
    constexpr uint32_t capturedNewStructureGoalOffset = 0x001C04A4;
    const uint32_t newStructureThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 146 * thunkSize;
    uint8_t *newStructureTag = addressSpace->pointerForGoal(
        newStructureThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (newStructureTag == nullptr) {
        return false;
    }
    memcpy(newStructureTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedNewStructureGoalOffset, newStructureThunkGoalOffset
    );
    // copy-basic is another InitHeapAndSymbol function below the signed code base. It allocates
    // an object of the source's runtime type on the requested heap and copies the full basic object.
    constexpr uint32_t capturedCopyBasicGoalOffset = 0x001BFFF4;
    const uint32_t copyBasicThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 147 * thunkSize;
    uint8_t *copyBasicTag = addressSpace->pointerForGoal(
        copyBasicThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (copyBasicTag == nullptr) {
        return false;
    }
    memcpy(copyBasicTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedCopyBasicGoalOffset, copyBasicThunkGoalOffset);
    // new_type, the `new` method of `type` (method 0 at type + 16). Every runtime deftype in
    // level code top-levels calls it.
    constexpr uint32_t capturedNewTypeGoalOffset = 0x001C0754;
    const uint32_t newTypeThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 148 * thunkSize;
    uint8_t *newTypeTag = addressSpace->pointerForGoal(
        newTypeThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (newTypeTag == nullptr) {
        return false;
    }
    memcpy(newTypeTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedNewTypeGoalOffset, newTypeThunkGoalOffset);
    // new_pair, the `new` method of `pair` (method 0 at pair + 16). Level startup code
    // uses it to cons newly loaded packages onto *kernel-packages*.
    constexpr uint32_t capturedNewPairGoalOffset = 0x001C0BB4;
    const uint32_t newPairThunkGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(thunkBegin - signedBegin) + 149 * thunkSize;
    uint8_t *newPairTag = addressSpace->pointerForGoal(
        newPairThunkGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (newPairTag == nullptr) {
        return false;
    }
    memcpy(newPairTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedNewPairGoalOffset, newPairThunkGoalOffset);
    constexpr uint32_t capturedSetupBlercGoalOffset = 0x0191B604;
    const uintptr_t setupBlerc = reinterpret_cast<uintptr_t>(og_jak1_mips2c_setup_blerc);
    if (setupBlerc < signedBegin || setupBlerc - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t setupBlercGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(setupBlerc - signedBegin);
    uint8_t *setupBlercTag = addressSpace->pointerForGoal(
        setupBlercGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    const auto blercGlobals = gNativeHelperContext.symbols.find("*blerc-globals*");
    const auto fakeScratchpad = gNativeHelperContext.symbols.find("*fake-scratchpad-data*");
    const auto cosPolyVec = gNativeHelperContext.symbols.find("*cos-poly-vec*");
    const auto oceanWaveFrames = gNativeHelperContext.symbols.find("*ocean-wave-frames*");
    const auto oceanWork = gNativeHelperContext.symbols.find("*ocean-work*");
    const auto oceanVu0Work = gNativeHelperContext.symbols.find("*ocean-vu0-work*");
    const auto timeOfDayContext = gNativeHelperContext.symbols.find("*time-of-day-context*");
    const auto oceanVu0Block = gNativeHelperContext.symbols.find("ocean-vu0-block");
    const auto uploadVu0Program = gNativeHelperContext.symbols.find("upload-vu0-program");
    const auto vectorFunction = gNativeHelperContext.symbols.find("vector*!");
    const auto vuLightsLightGroup = gNativeHelperContext.symbols.find("vu-lights<-light-group!");
    const auto oceanGenerateVertsVector =
        gNativeHelperContext.symbols.find("*ocean-generate-verts-vector*");
    uint8_t *goalMemory = addressSpace->pointerForGoal(0, kGoalMemorySize);
    if (setupBlercTag == nullptr || goalMemory == nullptr ||
        blercGlobals == gNativeHelperContext.symbols.end() ||
        fakeScratchpad == gNativeHelperContext.symbols.end() ||
        cosPolyVec == gNativeHelperContext.symbols.end() ||
        oceanWaveFrames == gNativeHelperContext.symbols.end() ||
        oceanWork == gNativeHelperContext.symbols.end() ||
        oceanVu0Work == gNativeHelperContext.symbols.end() ||
        timeOfDayContext == gNativeHelperContext.symbols.end() ||
        oceanVu0Block == gNativeHelperContext.symbols.end() ||
        uploadVu0Program == gNativeHelperContext.symbols.end() ||
        vectorFunction == gNativeHelperContext.symbols.end() ||
        vuLightsLightGroup == gNativeHelperContext.symbols.end() ||
        oceanGenerateVertsVector == gNativeHelperContext.symbols.end()) {
        return false;
    }
    memcpy(setupBlercTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    og_jak1_configure_mips2c(
        goalMemory, reinterpret_cast<void *>(signedBegin - goalCodeBaseOffset),
        blercGlobals->second, fakeScratchpad->second, cosPolyVec->second,
        oceanWaveFrames->second, oceanWork->second
    );
    og_jak1_configure_ocean_generate_verts(
        oceanVu0Work->second, timeOfDayContext->second, oceanVu0Block->second,
        uploadVu0Program->second, vectorFunction->second, vuLightsLightGroup->second,
        oceanGenerateVertsVector->second
    );
    capturedThunkRelocations.emplace(capturedSetupBlercGoalOffset, setupBlercGoalOffset);
    constexpr uint32_t capturedRippleExecuteInitGoalOffset = 0x0191E544;
    const uintptr_t rippleExecuteInit =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_ripple_execute_init);
    if (rippleExecuteInit < signedBegin ||
        rippleExecuteInit - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t rippleExecuteInitGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(rippleExecuteInit - signedBegin);
    uint8_t *rippleExecuteInitTag = addressSpace->pointerForGoal(
        rippleExecuteInitGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (rippleExecuteInitTag == nullptr) {
        return false;
    }
    memcpy(rippleExecuteInitTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedRippleExecuteInitGoalOffset, rippleExecuteInitGoalOffset
    );
    constexpr uint32_t capturedOceanInterpWaveGoalOffset = 0x01FD2FD4;
    const uintptr_t oceanInterpWave =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_ocean_interp_wave);
    if (oceanInterpWave < signedBegin ||
        oceanInterpWave - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t oceanInterpWaveGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(oceanInterpWave - signedBegin);
    uint8_t *oceanInterpWaveTag = addressSpace->pointerForGoal(
        oceanInterpWaveGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (oceanInterpWaveTag == nullptr) {
        return false;
    }
    memcpy(oceanInterpWaveTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedOceanInterpWaveGoalOffset, oceanInterpWaveGoalOffset
    );
    constexpr uint32_t capturedOceanGenerateVertsGoalOffset = 0x01FD3014;
    const uintptr_t oceanGenerateVerts =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_ocean_generate_verts);
    if (oceanGenerateVerts < signedBegin ||
        oceanGenerateVerts - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t oceanGenerateVertsGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(oceanGenerateVerts - signedBegin);
    uint8_t *oceanGenerateVertsTag = addressSpace->pointerForGoal(
        oceanGenerateVertsGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (oceanGenerateVertsTag == nullptr) {
        return false;
    }
    memcpy(oceanGenerateVertsTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedOceanGenerateVertsGoalOffset, oceanGenerateVertsGoalOffset
    );
    constexpr uint32_t capturedSpLaunchParticlesVarGoalOffset = 0x01950EF4;
    const uintptr_t spLaunchParticlesVar =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_sp_launch_particles_var);
    if (spLaunchParticlesVar < signedBegin ||
        spLaunchParticlesVar - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t spLaunchParticlesVarGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(spLaunchParticlesVar - signedBegin);
    uint8_t *spLaunchParticlesVarTag = addressSpace->pointerForGoal(
        spLaunchParticlesVarGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    constexpr const char *spLaunchSymbolNames[] = {
        "*level*", "*sp-launcher-enable*", "*sp-launcher-lock*",
        "*time-of-day-context*", "add-to-sprite-aux-list", "cos",
        "new-sound-id", "particle-adgif", "quaternion-axis-angle!", "sin",
        "sound-play-by-spec", "sp-adjust-launch", "sp-euler-convert",
        "sp-get-particle", "sp-init-fields!", "sp-queue-launch", "sp-rotate-system",
        "*particle-adgif-cache*", "particle-setup-adgif", "*sp-frame-time*",
        "quaternion*!", "sp-free-particle", "sp-relaunch-particle-3d",
        "sp-orbiter", "sp-relaunch-particle-2d"
    };
    uint32_t spLaunchSymbols[std::size(spLaunchSymbolNames)] = {};
    if (spLaunchParticlesVarTag == nullptr) {
        return false;
    }
    for (size_t index = 0; index < std::size(spLaunchSymbolNames); index++) {
        const auto symbol = gNativeHelperContext.symbols.find(spLaunchSymbolNames[index]);
        if (symbol == gNativeHelperContext.symbols.end()) {
            return false;
        }
        spLaunchSymbols[index] = symbol->second;
    }
    memcpy(spLaunchParticlesVarTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    og_jak1_configure_sp_launch_particles_var(spLaunchSymbols);
    capturedThunkRelocations.emplace(
        capturedSpLaunchParticlesVarGoalOffset, spLaunchParticlesVarGoalOffset
    );
    constexpr uint32_t capturedParticleAdgifGoalOffset = 0x01950EB4;
    const uintptr_t particleAdgif = reinterpret_cast<uintptr_t>(og_jak1_mips2c_particle_adgif);
    if (particleAdgif < signedBegin ||
        particleAdgif - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t particleAdgifGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(particleAdgif - signedBegin);
    uint8_t *particleAdgifTag = addressSpace->pointerForGoal(
        particleAdgifGoalOffset - sizeof(uint32_t), sizeof(uint32_t)
    );
    if (particleAdgifTag == nullptr) {
        return false;
    }
    memcpy(particleAdgifTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(capturedParticleAdgifGoalOffset, particleAdgifGoalOffset);
    constexpr uint32_t capturedSpProcessBlock3DGoalOffset = 0x01959FC4;
    constexpr uint32_t capturedSpProcessBlock2DGoalOffset = 0x0195A004;
    const uintptr_t spProcessBlock3D =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_sp_process_block_3d);
    const uintptr_t spProcessBlock2D =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_sp_process_block_2d);
    if (spProcessBlock3D < signedBegin || spProcessBlock2D < signedBegin ||
        spProcessBlock3D - signedBegin > UINT32_MAX - goalCodeBaseOffset ||
        spProcessBlock2D - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t spProcessBlock3DGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(spProcessBlock3D - signedBegin);
    const uint32_t spProcessBlock2DGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(spProcessBlock2D - signedBegin);
    uint8_t *spProcessBlock3DTag = addressSpace->pointerForGoal(
        spProcessBlock3DGoalOffset - sizeof(uint32_t), sizeof(uint32_t));
    uint8_t *spProcessBlock2DTag = addressSpace->pointerForGoal(
        spProcessBlock2DGoalOffset - sizeof(uint32_t), sizeof(uint32_t));
    if (spProcessBlock3DTag == nullptr || spProcessBlock2DTag == nullptr) {
        return false;
    }
    memcpy(spProcessBlock3DTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    memcpy(spProcessBlock2DTag, &functionTypeGoalOffset, sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedSpProcessBlock3DGoalOffset, spProcessBlock3DGoalOffset);
    capturedThunkRelocations.emplace(
        capturedSpProcessBlock2DGoalOffset, spProcessBlock2DGoalOffset);
    // texture.o's def-mips2c trampoline; title tpage logins call it right after linking.
    constexpr uint32_t capturedAdgifShaderTextureWithUpdateGoalOffset = 0x014FA864;
    const uintptr_t adgifShaderTextureWithUpdate =
        reinterpret_cast<uintptr_t>(og_jak1_mips2c_adgif_shader_texture_with_update);
    if (adgifShaderTextureWithUpdate < signedBegin ||
        adgifShaderTextureWithUpdate - signedBegin > UINT32_MAX - goalCodeBaseOffset) {
        return false;
    }
    const uint32_t adgifShaderTextureWithUpdateGoalOffset = goalCodeBaseOffset +
        static_cast<uint32_t>(adgifShaderTextureWithUpdate - signedBegin);
    uint8_t *adgifShaderTextureWithUpdateTag = addressSpace->pointerForGoal(
        adgifShaderTextureWithUpdateGoalOffset - sizeof(uint32_t), sizeof(uint32_t));
    if (adgifShaderTextureWithUpdateTag == nullptr) {
        return false;
    }
    memcpy(adgifShaderTextureWithUpdateTag, &functionTypeGoalOffset,
           sizeof(functionTypeGoalOffset));
    capturedThunkRelocations.emplace(
        capturedAdgifShaderTextureWithUpdateGoalOffset, adgifShaderTextureWithUpdateGoalOffset);
    if (!BindIndexedMips2CThunks(addressSpace, signedBegin, goalCodeBaseOffset,
                                 functionTypeGoalOffset, &capturedThunkRelocations)) {
        return false;
    }
    uint32_t relocatedPointerCount = 0;
    for (uint32_t offset = 0; offset <= kGoalMemorySize - sizeof(uint32_t); offset += 4) {
        uint8_t *word = addressSpace->pointerForGoal(offset, sizeof(uint32_t));
        uint32_t value = 0;
        memcpy(&value, word, sizeof(value));
        const auto relocation = capturedThunkRelocations.find(value);
        if (relocation != capturedThunkRelocations.end()) {
            memcpy(word, &relocation->second, sizeof(relocation->second));
            relocatedPointerCount++;
        }
    }
    NSLog(@"jakIOS bootstrap: relocated %u captured native helper pointers", relocatedPointerCount);
    *installedCount = thunkCount;
    return true;
}

}  // namespace

// Heap symbols whose value is a kheap (alloc_from_heap in game/kernel/jak1/kscheme.cpp).
constexpr uint32_t kFixSymDebugHeap = 0x148;
constexpr uint32_t kFixSymLoadingLevel = 0x150;
constexpr uint32_t kFixSymProcessLevelHeap = 0x160;
constexpr uint32_t kKmallocMemset = 0x1000;

// Level and debug heaps are real GOAL kheaps that the game manages itself (for example, the
// level loader resets them when a level unloads), so allocations naming them must come from
// that kheap. 'global allocations keep using the host bump heap; 'process allocations use the
// calling process's heap (AllocateOnProcessHeap).
bool ResolveKheapForSymbol(uint32_t heapSymbol, uint32_t *kheap) {
    const uint32_t offset = heapSymbol - gNativeHelperContext.s7GoalOffset;
    if (gNativeHelperContext.kernel == nullptr ||
        (offset != kFixSymDebugHeap && offset != kFixSymLoadingLevel &&
         offset != kFixSymProcessLevelHeap)) {
        return false;
    }
    uint32_t value = 0;
    if (!ReadGoalValue(heapSymbol, &value, sizeof(value)) || value == 0) {
        return false;
    }
    *kheap = value;
    return true;
}

// 'process allocations come from the current process's own heap (alloc_from_heap in
// game/kernel/jak1/kscheme.cpp). They must: when the actor heap compacts, each process's relocate
// method shifts its object pointers (root, draw, skel, ...) by the move offset, which corrupts
// any object that lives outside the process heap.
constexpr uint32_t kFixSymProcessType = 0xC8;
constexpr uint32_t kProcessHeapTopOffset = 0x50;
constexpr uint32_t kProcessHeapCurOffset = 0x54;

uint32_t AllocateOnProcessHeap(uint32_t pp, uint32_t size) {
    const uint32_t alignedSize = (size + 0xf) & ~0xfu;
    uint32_t start = 0;
    uint32_t heapEnd = 0;
    if (pp == 0 || pp == gNativeHelperContext.s7GoalOffset ||
        !ReadGoalValue(pp + kProcessHeapCurOffset, &start, sizeof(start)) ||
        !ReadGoalValue(pp + kProcessHeapTopOffset, &heapEnd, sizeof(heapEnd)) ||
        static_cast<uint64_t>(start) + alignedSize >= heapEnd) {
        return 0;
    }
    uint8_t *bytes = gNativeHelperContext.addressSpace == nullptr ? nullptr :
        gNativeHelperContext.addressSpace->pointerForGoal(start, alignedSize);
    if (bytes == nullptr) {
        return 0;
    }
    const uint32_t allocEnd = start + alignedSize;
    WriteGoalValue(pp + kProcessHeapCurOffset, &allocEnd, sizeof(allocEnd));
    memset(bytes, 0, alignedSize);
    return start;
}

// Allocates `size` bytes for an object on the heap named by `heapSymbol`. `pp` is the calling
// GOAL process (x20), used for 'process allocations.
uint32_t AllocateOnHeap(uint32_t heapSymbol, uint32_t size, uint32_t pp) {
    // (new 'stack ...) passes the address of a GOAL stack slot instead of a heap symbol. Like
    // upstream alloc_from_heap, clear it and return it in place. Taking these from the bump heap
    // leaked memory on every call (font-contexts each frame) until the heap ran out, after which
    // new_basic returned 0 and draw_string hit its lqc2 alignment assert. The stack is not only
    // the kernel stack at 0x07F00000: process code runs on *dram-stack*, an array in the global
    // heap. So, like upstream, treat any address outside the symbol table as a stack address.
    // Jak 1 has 0x4000 8-byte symbols centered on s7.
    constexpr uint32_t kSymbolTableHalfSize = 0x4000 * 8 / 2;
    const uint32_t s7 = gNativeHelperContext.s7GoalOffset;
    const bool isSymbol = heapSymbol >= s7 - kSymbolTableHalfSize &&
        heapSymbol < s7 + kSymbolTableHalfSize;
    if (!isSymbol && heapSymbol != 0 && heapSymbol < kGoalMemorySize) {
        const uint32_t alignedSize = (size + 0xf) & ~0xfu;
        uint8_t *bytes = gNativeHelperContext.addressSpace == nullptr ? nullptr :
            gNativeHelperContext.addressSpace->pointerForGoal(heapSymbol, alignedSize);
        if (bytes == nullptr) {
            return 0;
        }
        memset(bytes, 0, alignedSize);
        return heapSymbol;
    }
    uint32_t kheap = 0;
    if (ResolveKheapForSymbol(heapSymbol, &kheap)) {
        return gNativeHelperContext.kernel->kmalloc(kheap, size, kKmallocMemset);
    }
    if (heapSymbol - gNativeHelperContext.s7GoalOffset == kFixSymProcessType) {
        if (const uint32_t object = AllocateOnProcessHeap(pp, size)) {
            return object;
        }
        // Upstream returns 0 here; keep the old bump-heap behavior so callers don't crash, but
        // report it since such objects are corrupted if their process is later relocated.
        static int reportedFailures = 0;
        if (reportedFailures++ < 16) {
            NSLog(@"jakIOS: 'process allocation of %u bytes failed for pp 0x%08x; using global heap",
                  size, pp);
        }
    }
    return gNativeHelperContext.heap == nullptr ? 0 : gNativeHelperContext.heap->allocate(size, 16);
}

// Loads LevelCode/Jak1LevelCodeManifest.json and hands the prelinked level code to the kernel.
bool InstallLevelCode(jak1::Kernel *kernel) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"Jak1LevelCodeManifest" withExtension:@"json"];
    NSData *data = url == nil ? nil : [NSData dataWithContentsOfURL:url];
    NSDictionary *root = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    const uintptr_t levelBegin = reinterpret_cast<uintptr_t>(og_jak1_level_code_begin);
    const uintptr_t levelEnd = reinterpret_cast<uintptr_t>(og_jak1_level_code_end);
    if (kernel == nullptr || ![root isKindOfClass:[NSDictionary class]] ||
        ![root[@"format"] isEqual:@"OpenGOAL Jak 1 iOS level code v1"] ||
        [root[@"s7GoalOffset"] unsignedIntValue] != kCapturedS7GoalOffset) {
        NSLog(@"jakIOS: level code manifest is missing or invalid; level code disabled");
        return false;
    }
    jak1::LevelCode levelCode;
    levelCode.regionBase = [root[@"regionBase"] unsignedIntValue];
    levelCode.regionSize = [root[@"regionSize"] unsignedIntValue];
    levelCode.signedRegion = og_jak1_level_code_begin;
    // The signed blob must sit where GOAL code expects it: x27 + regionBase.
    if (levelCode.regionBase != kLevelCodeRegionBase ||
        levelCode.regionBase + levelCode.regionSize > kLevelCodeRegionLimit ||
        levelBegin - signedBegin != levelCode.regionBase - kCapturedCodeBaseOffset ||
        levelEnd - levelBegin != levelCode.regionSize) {
        NSLog(@"jakIOS: signed level code does not match the manifest; level code disabled");
        return false;
    }
    for (NSArray *entry in root[@"symbols"]) {
        levelCode.symbols.emplace_back([entry[0] UTF8String], [entry[1] unsignedIntValue]);
    }
    NSDictionary *objects = root[@"objects"];
    for (NSString *name in objects) {
        NSDictionary *info = objects[name];
        jak1::LevelCodeObject object;
        object.main = [info[@"main"][0] unsignedIntValue];
        object.mainSize = [info[@"main"][1] unsignedIntValue];
        object.top = [info[@"top"][0] unsignedIntValue];
        object.topSize = [info[@"top"][1] unsignedIntValue];
        object.entry = [info[@"entry"] unsignedIntValue];
        for (NSArray *typeLink in info[@"types"]) {
            jak1::LevelCodeObject::TypeLink link;
            link.name = [typeLink[0] UTF8String];
            link.methodCount = [typeLink[1] unsignedIntValue];
            for (NSNumber *location in typeLink[2]) {
                link.locations.push_back(location.unsignedIntValue);
            }
            object.types.push_back(std::move(link));
        }
        levelCode.objects.emplace(name.UTF8String, std::move(object));
    }
    gStartupLevelCodeOverrides.clear();
    for (NSString *name in root[@"startupOverrides"]) {
        if ([name isKindOfClass:[NSString class]]) {
            gStartupLevelCodeOverrides.emplace_back(name.UTF8String);
        }
    }
    const bool installed = kernel->installLevelCode(std::move(levelCode));
    NSLog(@"jakIOS: prelinked level code installed=%d", installed);
    return installed;
}

void NormalizePendingStateHandlers() {
    // state extends protect-frame. `code` at +16 is required; the other function fields are
    // optional and GOAL tests them against #f, so raw zero must be canonicalized.
    constexpr uint32_t optionalHandlerOffsets[] = {12, 20, 24, 28, 32};
    for (const uint32_t state : gNativeHelperContext.pendingStateObjects) {
        for (const uint32_t offset : optionalHandlerOffsets) {
            uint32_t handler = 0;
            if (ReadGoalValue(state + offset, &handler, sizeof(handler)) && handler == 0) {
                WriteGoalValue(state + offset, &gNativeHelperContext.s7GoalOffset,
                               sizeof(gNativeHelperContext.s7GoalOffset));
            }
        }
    }
    gNativeHelperContext.pendingStateObjects.clear();
}

bool IsTypeOrSubtypeOf(uint32_t type, uint32_t expectedParent) {
    // Type objects point at their immediate parent at +4. Bound the walk so corrupt GOAL data
    // cannot turn a constructor into an unbounded native loop.
    for (uint32_t depth = 0; type != 0 && depth < 128; depth++) {
        if (type == expectedParent) {
            return true;
        }
        uint32_t parent = 0;
        if (!ReadGoalValue(type + 4, &parent, sizeof(parent)) || parent == type) {
            return false;
        }
        type = parent;
    }
    return false;
}

uint64_t CallGoalFromNative(uint32_t function, uint64_t a0, uint64_t a1, uint64_t a2) {
    if (gNativeHelperContext.goalMemory == nullptr || gNativeHelperContext.signedCodeBase == 0) {
        return 0;
    }
    const uint64_t result = og_jak1_call_goal_arm64(
        a0, a1, a2, reinterpret_cast<void *>(gNativeHelperContext.signedCodeBase + function),
        reinterpret_cast<void *>(static_cast<uintptr_t>(gNativeHelperContext.s7GoalOffset)),
        gNativeHelperContext.goalMemory, reinterpret_cast<void *>(gNativeHelperContext.signedCodeBase)
    );
    NormalizePendingStateHandlers();
    return result;
}

void ReturnPendingProcesses() {
    constexpr uint32_t kProcessTreeParentOffset = 8;
    constexpr uint32_t kProcessTreePPointerOffset = 0x14;
    constexpr uint32_t kProcessPoolOffset = 0x1c;
    constexpr uint32_t kProcessStatusOffset = 0x20;
    auto pending = std::move(gNativeHelperContext.pendingProcessReturns);
    gNativeHelperContext.pendingProcessReturns.clear();
    const uint32_t deadSymbol = gNativeHelperContext.kernel != nullptr ?
        gNativeHelperContext.kernel->findSymbol("dead") : 0;
    for (const NativeHelperContext::PendingProcessReturn &item : pending) {
        // dead-pool-heap get-process leaves a process with status 'dead, parent = the pool's
        // ppointer and ppointer = its dead-pool-heap-rec (whose first word is the process).
        // activate sets status 'ready and reparents it, so a match means it is still orphaned.
        // (brother/child are #f, i.e. s7, never 0, so they can't be used as the test.)
        uint32_t parent = 0;
        uint32_t pool = 0;
        uint32_t status = 0;
        uint32_t poolPPointer = 0;
        uint32_t rec = 0;
        uint32_t recProcess = 0;
        if (deadSymbol == 0 ||
            !ReadGoalValue(item.process + kProcessTreeParentOffset, &parent, sizeof(parent)) ||
            !ReadGoalValue(item.process + kProcessPoolOffset, &pool, sizeof(pool)) ||
            !ReadGoalValue(item.process + kProcessStatusOffset, &status, sizeof(status)) ||
            !ReadGoalValue(item.pool + kProcessTreePPointerOffset, &poolPPointer, sizeof(poolPPointer)) ||
            !ReadGoalValue(item.process + kProcessTreePPointerOffset, &rec, sizeof(rec)) ||
            !ReadGoalValue(rec, &recProcess, sizeof(recProcess)) ||
            pool != item.pool || status != deadSymbol || parent != poolPPointer || recProcess != item.process) {
            // The GOAL caller adopted and activated this process after the native helper returned.
            // It is now owned by the process tree and must follow the normal shutdown path.
            continue;
        }
        // return-process -> change-parent unlinks the process from its parent's child/brother chain,
        // but a dead-pool-heap keeps no real tree: pool.child is only the newest allocation and
        // brothers are #f. When another process was allocated after this one, the search walks off
        // the chain and spins on #f. With parent #f, change-parent skips the unlink.
        const uint32_t noParent = kCapturedS7GoalOffset;
        WriteGoalValue(item.process + kProcessTreeParentOffset, &noParent, sizeof(noParent));
        CallGoalFromNative(item.function, item.pool, item.process, 0);
    }
}

// Captured objects normally never link again on iOS. Run the manifest's prelinked overrides once
// before the first kernel frame so modded engine tables/functions and title behavior replace the
// captured definitions. Like pc-settings, these run outside a GOAL frame and need an arena stack.
void InstallIOSCapturedOverrides(NSMutableData *writableGoalMemory, uint32_t goalCodeBaseOffset) {
    constexpr NSUInteger goalStackTopOffset = 4096;
    const uintptr_t signedBegin = reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin);
    void *writableGoalBase = writableGoalMemory.mutableBytes;
    const uintptr_t stackTop = reinterpret_cast<uintptr_t>(writableGoalBase) +
        kGoalMemorySize - goalStackTopOffset;
    for (const std::string &name : gStartupLevelCodeOverrides) {
        const uint32_t entry = gNativeHelperContext.kernel ?
            gNativeHelperContext.kernel->prepareLevelCodeObject(name) : 0;
        if (entry <= 1) {
            NSLog(@"jakIOS: startup override %s is missing or has no top-level", name.c_str());
            continue;
        }
        og_jak1_call_goal_on_stack_with_arg_arm64(
            stackTop, 0, 0,
            reinterpret_cast<void *>(signedBegin + entry - goalCodeBaseOffset),
            reinterpret_cast<void *>(static_cast<uintptr_t>(kCapturedS7GoalOffset)),
            writableGoalBase, reinterpret_cast<void *>(signedBegin - goalCodeBaseOffset)
        );
        NormalizePendingStateHandlers();
        NSLog(@"jakIOS: installed startup override %s", name.c_str());
    }

    // The retail capture retains the development shader-login path. On PC that path is
    // deliberately rebound to the fast implementation: its missing-texture fallback expects the
    // debug-network loader, and its dynamically allocated link arrays can survive a level unload.
    // Apply the same compatibility binding on iOS. Packaged texture pages are still linked and
    // updated normally; only the unsupported debug-network fallback is removed.
    const auto bindFastShaderLogin = [](const char *name, const char *fastName) {
        const auto symbol = gNativeHelperContext.symbols.find(name);
        const auto fastSymbol = gNativeHelperContext.symbols.find(fastName);
        if (symbol == gNativeHelperContext.symbols.end() ||
            fastSymbol == gNativeHelperContext.symbols.end()) {
            NSLog(@"jakIOS: shader-login binding missing %s or %s", name, fastName);
            return;
        }
        uint32_t fastFunction = 0;
        if (!ReadGoalValue(fastSymbol->second, &fastFunction, sizeof(fastFunction)) ||
            fastFunction == 0 ||
            !WriteGoalValue(symbol->second, &fastFunction, sizeof(fastFunction))) {
            NSLog(@"jakIOS: failed to bind %s to %s", name, fastName);
            return;
        }
        NSLog(@"jakIOS: bound %s to %s at 0x%x", name, fastName, fastFunction);
    };
    bindFastShaderLogin("adgif-shader-login", "adgif-shader-login-fast");
    bindFastShaderLogin("adgif-shader-login-no-remap", "adgif-shader-login-no-remap-fast");

    // Resolve the captured function range where the Red Sage transition livelocks. The AOT image
    // has no native symbols, but GOAL symbol cells still contain their function entry offsets.
    constexpr uint32_t stuckRangeStart = 0x01ee58b0;
    constexpr uint32_t stuckRangeEnd = 0x01ee7180;
    for (const auto &[name, symbolOffset] : gNativeHelperContext.symbols) {
        uint32_t functionOffset = 0;
        if (ReadGoalValue(symbolOffset, &functionOffset, sizeof(functionOffset)) &&
            functionOffset >= stuckRangeStart && functionOffset < stuckRangeEnd) {
            NSLog(@"jakIOS: Red Sage stuck range symbol %s = 0x%x", name.c_str(), functionOffset);
        }
    }
}

// Graphics > Resolution choices as multiples of the capped-Retina drawable, listed top to bottom.
static constexpr double kResolutionScales[] = {1.5, 1.0, 0.75, 0.5, 0.25};

static int64_t ScaledDrawableDimension(uint32_t dimension, double scale) {
    return MAX(1, static_cast<int64_t>(llround(dimension * scale)));
}

// set-window-size! clamps to PC_MIN_WIDTH x PC_MIN_HEIGHT before calling pc-set-window-size!,
// so e.g. the 437x201 entry arrives as 437x240.
static constexpr int64_t kGoalMinWindowWidth = 320;
static constexpr int64_t kGoalMinWindowHeight = 240;

// The scale whose resolution-menu entry is width x height, or 1 (native) when none matches,
// e.g. reset-gfx's 640x480 desktop default or a size saved for a different screen.
static double SelectedResolutionScale() {
    for (const double scale : kResolutionScales) {
        if (gNativeHelperContext.selectedWindowWidth ==
                MAX(kGoalMinWindowWidth,
                    ScaledDrawableDimension(gNativeHelperContext.drawableWidth, scale)) &&
            gNativeHelperContext.selectedWindowHeight ==
                MAX(kGoalMinWindowHeight,
                    ScaledDrawableDimension(gNativeHelperContext.drawableHeight, scale))) {
            return scale;
        }
    }
    return 1.0;
}

extern "C" uint64_t og_jak1_dispatch_native_helper(uint64_t index, const uint64_t *arguments) {
    if (arguments == nullptr || index >= 150) {
        return 0;
    }
    static uint64_t g_thunkDispatchCount = 0;
    if (g_thunkDispatchCount < 100) {
        NSLog(@"jakIOS: native helper thunk #%llu (arg0=0x%llx, arg1=0x%llx)", index, arguments[0], arguments[1]);
        g_thunkDispatchCount++;
    }
    // _og_jak1_native_thunk_dispatch stores x0-x7 in [0..7], x30 in [8] and the caller's pp in [9].
    const uint32_t pp = static_cast<uint32_t>(arguments[9]);
    // set-frame-rate! runs (pc-set-frame-rate rate), then clears vsync? when
    // (pc-get-display-mode) isn't fullscreen and (pc-get-active-display-refresh-rate) != rate.
    // iOS is always "windowed" at the panel's 120 Hz, and the menu's rates are 60 and 100, so that
    // would turn V-Sync off on every frame-rate change. Answer that one refresh query with the
    // rate just set, recognized by the exact 111 -> 67 -> 71 sequence.
    static int32_t frameRateVSyncQueryRate = 0;
    static int frameRateVSyncQueryStep = 0;
    if (index == 111) {
        frameRateVSyncQueryRate = static_cast<int32_t>(arguments[0]);
        frameRateVSyncQueryStep = 1;
    } else if (index == 67 && frameRateVSyncQueryStep == 1) {
        frameRateVSyncQueryStep = 2;
    } else if (index == 71 && frameRateVSyncQueryStep == 2) {
        frameRateVSyncQueryStep = 0;
        return frameRateVSyncQueryRate;
    } else {
        frameRateVSyncQueryStep = 0;
    }
    switch (index) {
        case 149: { // new_pair (heap, type, car, cdr), an anonymous fundamental type method
            const uint32_t type = static_cast<uint32_t>(arguments[1]);
            uint16_t allocatedSize = 0;
            if (!ReadGoalValue(type + 8, &allocatedSize, sizeof(allocatedSize)) || allocatedSize < 8) {
                return 0;
            }
            const uint32_t pair = AllocateOnHeap(static_cast<uint32_t>(arguments[0]),
                                                 allocatedSize, pp);
            const uint32_t car = static_cast<uint32_t>(arguments[2]);
            const uint32_t cdr = static_cast<uint32_t>(arguments[3]);
            // Pairs are an untyped body tagged by adding 2 to the raw address. Pair accessors
            // subtract that tag before reading car/cdr (for example, `car` reads at pair - 2).
            return pair != 0 && WriteGoalValue(pair, &car, sizeof(car)) &&
                WriteGoalValue(pair + sizeof(uint32_t), &cdr, sizeof(cdr)) ? pair + 2 : 0;
        }
        case 148: // new_type (symbol, parent, flags), an anonymous fundamental type method
            return gNativeHelperContext.kernel == nullptr ? 0 :
                gNativeHelperContext.kernel->newType(static_cast<uint32_t>(arguments[0]),
                                                     static_cast<uint32_t>(arguments[1]),
                                                     arguments[2]);
        case 147: { // copy_basic, an anonymous fundamental type method
            const uint32_t object = static_cast<uint32_t>(arguments[0]);
            uint32_t type = 0;
            uint16_t allocatedSize = 0;
            if (object < sizeof(uint32_t) ||
                !ReadGoalValue(object - sizeof(uint32_t), &type, sizeof(type)) ||
                !ReadGoalValue(type + 8, &allocatedSize, sizeof(allocatedSize)) ||
                allocatedSize < sizeof(uint32_t)) {
                return 0;
            }
            const uint32_t raw = AllocateOnHeap(static_cast<uint32_t>(arguments[1]),
                                                allocatedSize, pp);
            uint8_t *source = gNativeHelperContext.addressSpace->pointerForGoal(
                object - sizeof(uint32_t), allocatedSize
            );
            uint8_t *destination = gNativeHelperContext.addressSpace->pointerForGoal(
                raw, allocatedSize
            );
            if (raw == 0 || source == nullptr || destination == nullptr) {
                return 0;
            }
            memcpy(destination, source, allocatedSize);
            return raw + sizeof(uint32_t);
        }
        case 146: { // new_structure, an anonymous fundamental type method
            if (gNativeHelperContext.heap == nullptr) {
                return 0;
            }
            const uint32_t type = static_cast<uint32_t>(arguments[1]);
            uint16_t allocatedSize = 0;
            if (!ReadGoalValue(type + 8, &allocatedSize, sizeof(allocatedSize))) {
                return 0;
            }
            return AllocateOnHeap(static_cast<uint32_t>(arguments[0]), allocatedSize, pp);
        }
        case 145: { // new_basic, an anonymous fundamental type method
            if (gNativeHelperContext.heap == nullptr) {
                return 0;
            }
            const uint32_t type = static_cast<uint32_t>(arguments[1]);
            uint16_t allocatedSize = 0;
            if (!ReadGoalValue(type + 8, &allocatedSize, sizeof(allocatedSize))) {
                return 0;
            }
            const uint32_t raw = AllocateOnHeap(static_cast<uint32_t>(arguments[0]), allocatedSize, pp);
            if (raw == 0 || !WriteGoalValue(raw, &type, sizeof(type))) {
                return 0;
            }
            const uint32_t object = raw + sizeof(uint32_t);
            const auto stateSymbol = gNativeHelperContext.symbols.find("state");
            uint32_t stateType = 0;
            if (stateSymbol != gNativeHelperContext.symbols.end() &&
                ReadGoalValue(stateSymbol->second, &stateType, sizeof(stateType)) &&
                IsTypeOrSubtypeOf(type, stateType)) {
                // A state can be entered later in this same GOAL frame, before control returns to
                // CallGoalFromNative. Give absent optional handlers their canonical #f value now;
                // the generated constructor will overwrite every handler it actually supplies.
                constexpr uint32_t optionalHandlerOffsets[] = {12, 20, 24, 28, 32};
                for (const uint32_t offset : optionalHandlerOffsets) {
                    WriteGoalValue(object + offset, &gNativeHelperContext.s7GoalOffset,
                                   sizeof(gNativeHelperContext.s7GoalOffset));
                }
                gNativeHelperContext.pendingStateObjects.push_back(object);
            }
            return object;
        }
        case 144: { // asize_of_basic, an anonymous fundamental type method
            const uint32_t object = static_cast<uint32_t>(arguments[0]);
            uint32_t type = 0;
            uint16_t allocatedSize = 0;
            if (object < sizeof(uint32_t) ||
                !ReadGoalValue(object - sizeof(uint32_t), &type, sizeof(type)) ||
                !ReadGoalValue(type + 8, &allocatedSize, sizeof(allocatedSize))) {
                return 0;
            }
            return allocatedSize;
        }
        case 143: { // alloc_heap_object, an anonymous fundamental type method
            if (gNativeHelperContext.heap == nullptr) {
                return 0;
            }
            const uint32_t raw = AllocateOnHeap(static_cast<uint32_t>(arguments[0]),
                                                static_cast<uint32_t>(arguments[2]), pp);
            const uint32_t type = static_cast<uint32_t>(arguments[1]);
            return raw != 0 && WriteGoalValue(raw, &type, sizeof(type)) ? raw + 4 : 0;
        }
        case 0: { // string->symbol
            const char *name = GoalString(static_cast<uint32_t>(arguments[0]));
            if (name == nullptr) {
                return gNativeHelperContext.s7GoalOffset;
            }
            if (gNativeHelperContext.kernel != nullptr) {
                const uint32_t interned = gNativeHelperContext.kernel->internSymbol(name);
                return interned != 0 ? interned : gNativeHelperContext.s7GoalOffset;
            }
            const auto symbol = gNativeHelperContext.symbols.find(name);
            return symbol == gNativeHelperContext.symbols.end() ?
                gNativeHelperContext.s7GoalOffset : symbol->second;
        }
        case 1: // print
        case 2: // inspect
            return arguments[0];
        case 3: // load -- all captured objects are already present in the signed AOT image
        case 5: // unload -- immutable signed code cannot be physically unloaded
            return 0;
        case 4: // loado -- no debug-network files on iOS. Fails like upstream (kscheme.cpp loado): #f, not 0,
                // which GOAL treats as true. texture-page-login calls it for a texture page that isn't loaded
                // (resident art logged in while its level is not) and would relocate object 0.
            return gNativeHelperContext.s7GoalOffset;
        case 6: // _format
            return FormatGoal(arguments);
        case 7: // malloc
            return AllocateOnHeap(static_cast<uint32_t>(arguments[0]),
                                  static_cast<uint32_t>(arguments[1]), pp);
        case 8: // kmalloc (heap is a kheapinfo pointer)
            if (gNativeHelperContext.kernel != nullptr) {
                return gNativeHelperContext.kernel->kmalloc(static_cast<uint32_t>(arguments[0]),
                                                           static_cast<uint32_t>(arguments[1]),
                                                           static_cast<uint32_t>(arguments[2]));
            }
            return gNativeHelperContext.heap == nullptr ? 0 :
                gNativeHelperContext.heap->allocate(static_cast<uint32_t>(arguments[1]), 16);
        case 9: // new-dynamic-structure
            return AllocateOnHeap(static_cast<uint32_t>(arguments[0]),
                                  static_cast<uint32_t>(arguments[2]), pp);
        case 10: { // method-set!
            const uint32_t typeOffset = static_cast<uint32_t>(arguments[0]);
            const uint32_t methodID = static_cast<uint32_t>(arguments[1]);
            uint32_t method = static_cast<uint32_t>(arguments[2]);
            uint8_t *type = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(typeOffset, 16);
            if (type == nullptr || methodID > 127 || method == 0) {
                return method;
            }
            if (method == 1) {
                method = 0;
            } else if (method == 2) {
                uint32_t parent = 0;
                memcpy(&parent, type + 4, sizeof(parent));
                uint8_t *parentMethod = gNativeHelperContext.addressSpace->pointerForGoal(
                    parent + 16 + methodID * sizeof(uint32_t), sizeof(uint32_t)
                );
                if (parentMethod == nullptr) {
                    return 0;
                }
                memcpy(&method, parentMethod, sizeof(method));
            }
            uint8_t *slot = gNativeHelperContext.addressSpace->pointerForGoal(
                typeOffset + 16 + methodID * sizeof(uint32_t), sizeof(uint32_t)
            );
            if (slot == nullptr) {
                return 0;
            }
            memcpy(slot, &method, sizeof(method));
            return method;
        }
        case 11: { // link: object data, name, size, heap, flags (klink.cpp link_and_exec)
            // Synchronous link used for spooled art (STR chunks). Code objects come from the
            // signed image, so only data objects produce an entry here.
            if (gNativeHelperContext.kernel == nullptr) {
                return GoalBoolean(false);
            }
            gNativeHelperContext.kernel->linkBegin(
                static_cast<uint32_t>(arguments[0]), static_cast<uint32_t>(arguments[1]),
                static_cast<uint32_t>(arguments[2]), static_cast<uint32_t>(arguments[3]),
                static_cast<uint32_t>(arguments[4]));
            const uint32_t entry = gNativeHelperContext.kernel->lastLinkEntry();
            ScheduleViewerFallbackDisable(static_cast<uint32_t>(arguments[1]), entry);
            return entry != 0 ? entry : GoalBoolean(false);
        }
        case 12: // dgo-load: DGOs are represented by the prelinked AOT image
            return 0;
        case 13: { // link-begin: object data, name, size, heap, flags
            if (gNativeHelperContext.kernel != nullptr) {
                const uint64_t result = gNativeHelperContext.kernel->linkBegin(
                    static_cast<uint32_t>(arguments[0]), static_cast<uint32_t>(arguments[1]),
                    static_cast<uint32_t>(arguments[2]), static_cast<uint32_t>(arguments[3]),
                    static_cast<uint32_t>(arguments[4]));
                ScheduleViewerFallbackDisable(
                    static_cast<uint32_t>(arguments[1]),
                    gNativeHelperContext.kernel->lastLinkEntry()
                );
                return result;
            }
            return 1;
        }
        case 14: // link-resume
            return gNativeHelperContext.kernel != nullptr ?
                gNativeHelperContext.kernel->linkResume() : 1;
        // Memory card: port of kmemcard.cpp's raw-save emulation (Jak1MemoryCardManager.mm).
        case 15: // mc-run
            jak1::memcard::Run();
            return 0;
        case 16: // mc-format
            return jak1::memcard::Format(static_cast<int32_t>(arguments[0]));
        case 17: // mc-unformat
            return jak1::memcard::Unformat(static_cast<int32_t>(arguments[0]));
        case 18: // mc-create-file
            return jak1::memcard::CreateFile(static_cast<int32_t>(arguments[0]),
                                             static_cast<uint32_t>(arguments[1]));
        case 19: // mc-save: card, file, save data, summary data
            return jak1::memcard::Save(static_cast<int32_t>(arguments[0]), static_cast<int32_t>(arguments[1]),
                                       static_cast<uint32_t>(arguments[2]), static_cast<uint32_t>(arguments[3]));
        case 20: // mc-load: card, file, buffer
            return jak1::memcard::Load(static_cast<int32_t>(arguments[0]), static_cast<int32_t>(arguments[1]),
                                       static_cast<uint32_t>(arguments[2]));
        case 21: // mc-check-result
            return jak1::memcard::CheckResult();
        case 22: // mc-get-slot-info: slot, mc-slot-info
            jak1::memcard::GetSlotInfo(static_cast<int32_t>(arguments[0]), static_cast<uint32_t>(arguments[1]));
            return 0;
        case 23: // mc-makefile: debug-only garbage writer that nothing calls
            return 0;
        case 24: // kset-language
            gNativeHelperContext.language = static_cast<uint32_t>(arguments[0]);
            jak1::memcard::SetLanguage(static_cast<int32_t>(arguments[0]));
            return arguments[0];
        case 25: { // put-display-env
            uint8_t *environment = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(
                    static_cast<uint32_t>(arguments[0]), 2
                );
            if (environment != nullptr) {
                gNativeHelperContext.displayAlpha = environment[1];
            }
            return 0;
        }
        case 26: // syncv
        case 27: // sync-path
        case 28: // reset-path
        case 29: // reset-graph
        case 30: // dma-sync
            return 0;
        case 31: // gs-put-imr
            gNativeHelperContext.gsIMR = static_cast<uint32_t>(arguments[0]);
            return 0;
        case 32: // gs-get-imr
            return gNativeHelperContext.gsIMR;
        case 33: // gs-store-image
        case 34: // flush-cache -- coherent on Apple silicon
            return 0;
        case 35: // cpad-open
            return arguments[0];
        case 36: { // cpad-get-data
            uint8_t *pad = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(
                    static_cast<uint32_t>(arguments[0]), 132
                );
            if (pad == nullptr) {
                return 0;
            }
            // Mirror OpenGOAL's scePadRead: valid = 0 (success), status = DualShock 2 (0x7) with a
            // 20-byte payload. pad.gc only honors the analog sticks when status >> 4 == 7.
            pad[0] = 0;
            pad[1] = 0x70 | (20 / 2);
            // cpad-info number (controller port) at +32. Only port 0 is driven; the other ports
            // see what is held but don't consume the latched taps and presses meant for port 0.
            int32_t padNumber = 0;
            memcpy(&padNumber, pad + 32, sizeof(padNumber));
            uint16_t padButtons = gNativeHelperContext.buttons.load(std::memory_order_relaxed);
            if (padNumber == 0) {
                // Kernel thread only: what the previous read reported, and presses held back
                // to report on this read.
                static uint16_t lastDelivered = 0;
                static uint16_t deferredPresses = 0;
                const uint16_t edges = gNativeHelperContext.pressEdges.exchange(0, std::memory_order_relaxed);
                padButtons |= gNativeHelperContext.latchedButtons.exchange(0, std::memory_order_relaxed) |
                    deferredPresses;
                // A new press of a button the last read already showed down means it was released
                // and pressed again between reads (a quick re-tap, or any tap during a slow frame).
                // Show it up on this read and down on the next, so the game sees a fresh press
                // (button0-rel) instead of one long hold.
                const uint16_t repressed = edges & lastDelivered;
                padButtons &= ~repressed;
                deferredPresses = repressed;
                lastDelivered = padButtons;
            }
            const uint16_t buttons = padButtons | gMenuInjectedButtons.load(std::memory_order_relaxed);
            gPadReadCount.fetch_add(1, std::memory_order_relaxed);
            memcpy(pad + 2, &buttons, sizeof(buttons));
            static uint16_t lastReportedButtons = 0;
            if ((buttons & ~lastReportedButtons) & (1u << 3)) {
                NSLog(@"jakIOS: cpad-get-data delivered Start press (button0=0x%04x)", buttons);
                gPadDiagnostics.startEdges++;
            }
            lastReportedButtons = buttons;
            gPadDiagnostics.reads++;
            // Pressure bytes (abutton-idx order): touch and MFi controllers are digital, so report
            // full pressure for anything held.
            static constexpr uint8_t kPressureBits[12] = {5, 7, 4, 6, 12, 13, 14, 15, 10, 11, 8, 9};
            for (size_t i = 0; i < 12; i++) {
                pad[8 + i] = (buttons & (1u << kPressureBits[i])) ? 255 : 0;
            }
            auto axis = [](float value) -> uint8_t {
                return static_cast<uint8_t>(127.5f + MAX(-1.0f, MIN(1.0f, value)) * 127.5f);
            };
            pad[4] = axis(gNativeHelperContext.rightX);
            pad[5] = axis(-gNativeHelperContext.rightY);
            pad[6] = axis(gNativeHelperContext.leftX);
            pad[7] = axis(-gNativeHelperContext.leftY);
            return arguments[0];
        }
        case 37: // install-handler
        case 38: // install-debug-handler
            return 0;
        case 39: { // file-stream-open
            NativeFileStream *stream = GoalFileStream(static_cast<uint32_t>(arguments[0]));
            const std::string path = SandboxedPath(GoalString(static_cast<uint32_t>(arguments[1])));
            const char *mode = GoalSymbolName(static_cast<uint32_t>(arguments[2]));
            if (stream == nullptr || path.empty()) {
                return 0;
            }
            const bool readOnly = mode != nullptr && strcmp(mode, "read") == 0;
            stream->mode = static_cast<uint32_t>(arguments[2]);
            stream->name = static_cast<uint32_t>(arguments[1]);
            stream->flags = 0;
            stream->file = open(path.c_str(), readOnly ? O_RDONLY : O_WRONLY | O_CREAT | O_TRUNC,
                                S_IRUSR | S_IWUSR);
            if (stream->file < 0) {
                stream->flags |= 1;
            }
            return arguments[0];
        }
        case 40: { // file-stream-close
            NativeFileStream *stream = GoalFileStream(static_cast<uint32_t>(arguments[0]));
            if (stream == nullptr) {
                return 0;
            }
            if ((stream->flags & 1) == 0 && stream->file >= 0) {
                close(stream->file);
            }
            stream->file = -1;
            stream->flags = 0;
            return arguments[0];
        }
        case 41: { // file-stream-length
            NativeFileStream *stream = GoalFileStream(static_cast<uint32_t>(arguments[0]));
            if (stream == nullptr || (stream->flags & 1) != 0) {
                return 0;
            }
            const off_t current = lseek(stream->file, 0, SEEK_CUR);
            const off_t end = lseek(stream->file, 0, SEEK_END);
            if (current < 0 || end < 0 || lseek(stream->file, current, SEEK_SET) < 0) {
                stream->flags |= 1;
                return 0;
            }
            return static_cast<uint64_t>(end);
        }
        case 42: { // file-stream-seek
            NativeFileStream *stream = GoalFileStream(static_cast<uint32_t>(arguments[0]));
            if (stream == nullptr || (stream->flags & 1) != 0) {
                return static_cast<uint64_t>(-1);
            }
            const off_t result = lseek(stream->file, static_cast<int32_t>(arguments[1]),
                                       static_cast<int32_t>(arguments[2]));
            if (result < 0) {
                stream->flags |= 1;
            }
            return static_cast<uint64_t>(result);
        }
        case 43:
        case 44: { // file-stream-read/write
            NativeFileStream *stream = GoalFileStream(static_cast<uint32_t>(arguments[0]));
            const uint32_t length = static_cast<uint32_t>(arguments[2]);
            uint8_t *buffer = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(
                    static_cast<uint32_t>(arguments[1]), length
                );
            if (stream == nullptr || buffer == nullptr || (stream->flags & 1) != 0) {
                return static_cast<uint64_t>(-1);
            }
            const ssize_t result = index == 43 ? read(stream->file, buffer, length) :
                                                 write(stream->file, buffer, length);
            if (result < 0) {
                stream->flags |= 1;
            }
            return static_cast<uint64_t>(result);
        }
        case 45: // scf-get-language
            return gNativeHelperContext.language;
        case 46: { // scf-get-time
            NSDateComponents *parts = [[NSCalendar currentCalendar]
                components:(NSCalendarUnitSecond | NSCalendarUnitMinute | NSCalendarUnitHour |
                            NSCalendarUnitWeekday | NSCalendarUnitDay | NSCalendarUnitMonth |
                            NSCalendarUnitYear)
                  fromDate:NSDate.date];
            auto bcd = [](NSInteger value) -> uint8_t {
                return static_cast<uint8_t>(((value / 10) << 4) | (value % 10));
            };
            const uint8_t clock[8] = {
                0, bcd(parts.second), bcd(parts.minute), bcd(parts.hour),
                static_cast<uint8_t>(parts.weekday - 1), bcd(parts.day), bcd(parts.month),
                bcd(parts.year % 100)
            };
            WriteGoalValue(static_cast<uint32_t>(arguments[0]), clock, sizeof(clock));
            return 0;
        }
        case 47: // scf-get-aspect
            return gNativeHelperContext.drawableWidth * 3 >
                gNativeHelperContext.drawableHeight * 4 ? 1 : 0;
        case 48: // scf-get-volume
            return 100;
        case 49: // scf-get-territory (SCEA)
        case 50: // scf-get-timeout
        case 51: // scf-get-inactive-timeout
            return 0;
        case 52: // dma-to-iop -- audio/RPC is in-process on iOS
            return 0;
        case 53: // kernel-shutdown
            gNativeHelperContext.shutdownRequested = true;
            // The game only reaches this helper after the player confirms Quit Game. Merely
            // stopping kernel dispatch leaves the app frozen on its final frame, so terminate
            // successfully just as the desktop runtime does. Hop to the main queue so UIKit is
            // not torn down from the kernel worker.
            dispatch_async(dispatch_get_main_queue(), ^{
                exit(EXIT_SUCCESS);
            });
            return 0;
        case 54: // aybabtu
            return 0;
        case 55: { // __read-ee-timer
            static mach_timebase_info_data_t timebase {};
            if (timebase.denom == 0) {
                mach_timebase_info(&timebase);
            }
            const uint64_t ticks = mach_continuous_time();
            const uint64_t nanos = (ticks * timebase.numer) / timebase.denom;
            return nanos / 1000ULL;
        }
        case 56: { // __mem-move
            const uint32_t destination = static_cast<uint32_t>(arguments[0]);
            const uint32_t source = static_cast<uint32_t>(arguments[1]);
            const uint32_t length = static_cast<uint32_t>(arguments[2]);
            uint8_t *destinationBytes = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(destination, length);
            uint8_t *sourceBytes = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(source, length);
            if (destinationBytes == nullptr || sourceBytes == nullptr) {
                return 0;
            }
            memmove(destinationBytes, sourceBytes, length);
            return destination;
        }
        case 57: { // __send-gfx-dma-chain
            std::lock_guard<std::mutex> lock(gDMASubmissionMutex);
            gNativeHelperContext.lastDMABank = static_cast<uint32_t>(arguments[0]);
            gNativeHelperContext.lastDMAChain = arguments[1];
            gNativeHelperContext.dmaSubmissionSerial++;
            CaptureAndPublishDMAChain(static_cast<uint32_t>(arguments[0]), arguments[1],
                                      gNativeHelperContext.dmaSubmissionSerial);
            if (gDisableViewerFallbackAfterCurrentFrame) {
                gDisableViewerFallbackAfterCurrentFrame = false;
                DisableViewerFallback();
            }
            DisableCutsceneLetterbox();
            WidenIntroMistBackdrop();
            UpdateSoundIopInfo();
            LogPadAndProgressStateIfDue();
            return 0;
        }
        case 58: // __pc-texture-upload-now
            gNativeHelperContext.lastTextureUpload = arguments[0];
            gNativeHelperContext.lastTextureUploadMode = static_cast<uint32_t>(arguments[1]);
            if (arguments[0] <= UINT32_MAX) {
                HandleTextureUploadNow(static_cast<uint32_t>(arguments[0]),
                                       static_cast<int32_t>(arguments[1]));
            }
            return 0;
        case 59: // __pc-texture-relocate
            gNativeHelperContext.lastTextureRelocation = arguments[0];
            gNativeHelperContext.lastTextureRelocationSource = arguments[1];
            gNativeHelperContext.lastTextureRelocationFormat = static_cast<uint32_t>(arguments[2]);
            // (__pc-texture-relocate dest-tbp source-tbp format), like TexturePool::relocate.
            Jak1TexturePoolRelocate(static_cast<uint32_t>(arguments[0]),
                                    static_cast<uint32_t>(arguments[1]),
                                    static_cast<uint32_t>(arguments[2]));
            return 0;
        case 60: // __pc-get-mips2c: all translated routines are in signed AOT text
        case 61: // __pc-force-reload-all-levels
        case 62: // __pc-force-reload-level
        case 63: // __pc-force-reload-common-level
            return 0;
        case 64: // pc-get-display-id
            return 0;
        case 65: // pc-set-display-id!
            return 0;
        case 66: // pc-get-display-name
            return WriteGoalString(static_cast<uint32_t>(arguments[1]), "IOS DISPLAY") ?
                GoalBoolean(true) : GoalBoolean(false);
        case 67: { // pc-get-display-mode
            // iOS has one app-owned Metal surface rather than desktop window/fullscreen modes.
            // Reporting it as windowed also keeps Jak's PC menu from appending the hard-coded
            // 512x448 and 512x224 PS2 compatibility resolutions.
            const auto symbol = gNativeHelperContext.symbols.find("windowed");
            return symbol == gNativeHelperContext.symbols.end() ?
                gNativeHelperContext.s7GoalOffset : symbol->second;
        }
        case 68: // pc-set-display-mode!
            return 0;
        case 69: // pc-get-display-count
            return 1;
        case 70: // pc-get-active-display-size
        case 72: { // pc-get-window-size
            const int64_t width = gNativeHelperContext.drawableWidth;
            const int64_t height = gNativeHelperContext.drawableHeight;
            WriteGoalValue(static_cast<uint32_t>(arguments[0]), &width, sizeof(width));
            WriteGoalValue(static_cast<uint32_t>(arguments[1]), &height, sizeof(height));
            return 0;
        }
        case 71: // pc-get-active-display-refresh-rate
            return gNativeHelperContext.displayRefreshRate.load(std::memory_order_relaxed);
        case 73: { // pc-get-window-scale
            const float scale = 1;
            WriteGoalValue(static_cast<uint32_t>(arguments[0]), &scale, sizeof(scale));
            WriteGoalValue(static_cast<uint32_t>(arguments[1]), &scale, sizeof(scale));
            return 0;
        }
        case 74: // pc-set-window-size!
            // iOS owns the window. Do not let a saved desktop window size replace the physical
            // drawable size used to build the resolution list; instead treat it as the
            // Graphics > Resolution choice, which pc-set-game-resolution applies as a scale.
            gNativeHelperContext.selectedWindowWidth = static_cast<int64_t>(arguments[0]);
            gNativeHelperContext.selectedWindowHeight = static_cast<int64_t>(arguments[1]);
            return 0;
        case 75: // pc-get-num-resolutions
            // A 1.5x supersampled choice, native/capped-Retina, plus three lower-cost choices.
            // The default stays 1x because reset-gfx uses pc-get-active-display-size.
            return std::size(kResolutionScales);
        case 76: { // pc-get-resolution
            const size_t index = MIN(static_cast<size_t>(arguments[0]),
                                     std::size(kResolutionScales) - 1);
            const double scale = kResolutionScales[index];
            const int64_t width = MAX(1, static_cast<int64_t>(
                llround(gNativeHelperContext.drawableWidth * scale)
            ));
            const int64_t height = MAX(1, static_cast<int64_t>(
                llround(gNativeHelperContext.drawableHeight * scale)
            ));
            WriteGoalValue(static_cast<uint32_t>(arguments[2]), &width, sizeof(width));
            WriteGoalValue(static_cast<uint32_t>(arguments[3]), &height, sizeof(height));
            return 0;
        }
        case 77: { // pc-is-supported-resolution?
            const int64_t requestedWidth = static_cast<int64_t>(arguments[0]);
            const int64_t requestedHeight = static_cast<int64_t>(arguments[1]);
            bool supported = false;
            for (const double scale : kResolutionScales) {
                const int64_t width = MAX(1, static_cast<int64_t>(
                    llround(gNativeHelperContext.drawableWidth * scale)
                ));
                const int64_t height = MAX(1, static_cast<int64_t>(
                    llround(gNativeHelperContext.drawableHeight * scale)
                ));
                supported |= requestedWidth == width && requestedHeight == height;
            }
            return GoalBoolean(supported);
        }
        case 78: // pc-get-controller-name
            return WriteGoalString(static_cast<uint32_t>(arguments[1]), "GAME CONTROLLER") ?
                GoalBoolean(gNativeHelperContext.controllerCount != 0) : GoalBoolean(false);
        case 79: // pc-get-current-bind
            return WriteGoalString(static_cast<uint32_t>(arguments[1]), "UNKNOWN") ?
                GoalBoolean(true) : GoalBoolean(false);
        case 80: // pc-get-controller-count
            return gNativeHelperContext.controllerCount;
        case 81: // pc-get-controller-index
            return 0;
        case 82: // pc-set-controller!
            return 0;
        case 83: // pc-get-keyboard-enabled?
            return GoalBoolean(gNativeHelperContext.keyboardEnabled);
        case 84: // pc-set-keyboard-enabled!
            gNativeHelperContext.keyboardEnabled = arguments[0] != gNativeHelperContext.s7GoalOffset;
            return arguments[0];
        case 85: // pc-set-mouse-options!
        case 86: // pc-set-mouse-camera-sens!
        case 87: // pc-ignore-background-controller-events!
        case 90: // pc-set-controller-led!
            return 0;
        case 88: // pc-current-controller-has-led?
            return GoalBoolean(false);
        case 89: // pc-current-controller-has-rumble?
            return GoalBoolean(true);
        case 91: // pc-waiting-for-bind?
            return GoalBoolean(gNativeHelperContext.waitingForBind);
        case 92: // pc-set-waiting-for-bind!
            gNativeHelperContext.waitingForBind = true;
            return arguments[0];
        case 93: // pc-stop-waiting-for-bind!
            gNativeHelperContext.waitingForBind = false;
            return gNativeHelperContext.s7GoalOffset;
        case 94: // pc-reset-bindings-to-defaults!
        case 95: // pc-set-auto-hide-cursor!
            return 0;
        case 96: // pc-get-pressure-sensitivity-enabled?
            return GoalBoolean(gNativeHelperContext.pressureSensitivity);
        case 97: // pc-set-pressure-sensitivity-enabled!
            gNativeHelperContext.pressureSensitivity =
                arguments[0] != gNativeHelperContext.s7GoalOffset;
            return 0;
        case 98: { // pc-set-axis-scale!
            const uint32_t bits = static_cast<uint32_t>(arguments[0]);
            memcpy(&gNativeHelperContext.axisScale, &bits, sizeof(bits));
            return 0;
        }
        case 99: { // pc-get-axis-scale
            uint32_t bits = 0;
            memcpy(&bits, &gNativeHelperContext.axisScale, sizeof(bits));
            return bits;
        }
        case 100: // pc-current-controller-has-pressure-sensitivity?
            return GoalBoolean(true);
        case 101: // pc-current-controller-has-trigger-effect-support?
            return GoalBoolean(false);
        case 102: // pc-get-trigger-effects-enabled?
            return GoalBoolean(gNativeHelperContext.triggerEffects);
        case 103: // pc-set-trigger-effects-enabled!
            gNativeHelperContext.triggerEffects =
                arguments[0] != gNativeHelperContext.s7GoalOffset;
            return 0;
        case 104: // pc-clear-trigger-effect!
        case 105: // pc-send-trigger-effect-feedback!
        case 106: // pc-send-trigger-effect-vibrate!
        case 107: // pc-send-trigger-effect-weapon!
        case 108: // pc-send-trigger-rumble!
            return 0;
        case 109: // pc-set-vsync
            gNativeHelperContext.vsync = arguments[0] != gNativeHelperContext.s7GoalOffset;
            return 0;
        case 110: // pc-set-msaa
            gNativeHelperContext.msaaSamples = static_cast<int32_t>(arguments[0]);
            return 0;
        case 111: { // pc-set-frame-rate
            const int32_t fps = static_cast<int32_t>(arguments[0]) >= 100 ? 120 : 60;
            if (gNativeHelperContext.targetFPS.exchange(fps, std::memory_order_relaxed) != fps) {
                NSLog(@"jakIOS: pc-set-frame-rate %d -> presenting at %d fps",
                      static_cast<int32_t>(arguments[0]), fps);
            }
            return 0;
        }
        case 112: { // pc-set-game-resolution
            // In windowed mode GOAL sends the aspect-adjusted window size every frame, so the
            // menu's choice would otherwise never reach the renderer. Scale it here.
            const double scale = SelectedResolutionScale();
            gNativeHelperContext.gameWidth.store(
                MAX(1, static_cast<int32_t>(llround(static_cast<int32_t>(arguments[0]) * scale))),
                std::memory_order_relaxed
            );
            gNativeHelperContext.gameHeight.store(
                MAX(1, static_cast<int32_t>(llround(static_cast<int32_t>(arguments[1]) * scale))),
                std::memory_order_relaxed
            );
            return 0;
        }
        case 114: // pc-set-letterbox (width, height of the game area in window pixels)
            Jak1RendererSetLetterbox(static_cast<int32_t>(arguments[0]),
                                     static_cast<int32_t>(arguments[1]));
            return 0;
        case 113: // pc-set-brightness-contrast
        case 115: // pc-renderer-tree-set-lod
        case 116: // pc-set-collision-mode
            return 0;
        case 117: { // pc-set-collision-mask
            if (arguments[2] != gNativeHelperContext.s7GoalOffset) {
                gNativeHelperContext.collisionMask |= arguments[1];
            } else {
                gNativeHelperContext.collisionMask &= ~arguments[1];
            }
            return 0;
        }
        case 118: // pc-get-collision-mask
            return GoalBoolean((gNativeHelperContext.collisionMask & arguments[1]) != 0);
        case 119: // pc-set-collision-wireframe
        case 120: // pc-set-collision
        case 121: // pc-set-gfx-hack
            return 0;
        case 122: { // pc-get-os
            const auto symbol = gNativeHelperContext.symbols.find("darwin");
            return symbol == gNativeHelperContext.symbols.end() ?
                gNativeHelperContext.s7GoalOffset : symbol->second;
        }
        case 123: // pc-get-unix-timestamp
            return static_cast<uint64_t>(NSDate.date.timeIntervalSince1970);
        case 124: // pc-treat-pad0-as-pad1
            return 0;
        case 125: // pc-is-imgui-visible?
            return GoalBoolean(false);
        case 126: { // pc-filepath-exists?
            const std::string path = SandboxedPath(GoalString(static_cast<uint32_t>(arguments[0])));
            struct stat status {};
            return GoalBoolean(!path.empty() && stat(path.c_str(), &status) == 0);
        }
        case 127: { // pc-mkdir-file-path
            const std::string path = SandboxedPath(GoalString(static_cast<uint32_t>(arguments[0])));
            if (path.empty()) {
                return EINVAL;
            }
            NSString *parent = [[NSString stringWithUTF8String:path.c_str()] stringByDeletingLastPathComponent];
            NSError *error = nil;
            const BOOL created = [[NSFileManager defaultManager]
                createDirectoryAtPath:parent
                withIntermediateDirectories:YES
                attributes:nil
                error:&error];
            return created ? 0 : static_cast<uint64_t>(error.code ?: EIO);
        }
        case 128: // pc-discord-rpc-set
        case 129: // pc-prof
            return 0;
        case 130: // pc-rand
            return arc4random();
        case 131: { // pc-encode-utf8-string
            const char *source = GoalString(static_cast<uint32_t>(arguments[0]));
            uint8_t *destinationObject = gNativeHelperContext.addressSpace == nullptr ? nullptr :
                gNativeHelperContext.addressSpace->pointerForGoal(
                    static_cast<uint32_t>(arguments[1]), sizeof(uint32_t)
                );
            if (source == nullptr || destinationObject == nullptr) {
                return 0;
            }
            uint32_t capacity = 0;
            memcpy(&capacity, destinationObject, sizeof(capacity));
            uint8_t *destination = gNativeHelperContext.addressSpace->pointerForGoal(
                static_cast<uint32_t>(arguments[1]) + sizeof(uint32_t), capacity + 1
            );
            if (destination == nullptr) {
                return 0;
            }
            const size_t count = MIN(static_cast<size_t>(capacity), strlen(source));
            memcpy(destination, source, count);
            destination[count] = 0;
            return arguments[1];
        }
        case 132: // pc-filter-debug-string?
            return GoalBoolean(false);
        case 133: // pc-screen-shot
            gNativeHelperContext.screenshotRequested = true;
            return 0;
        case 134: // pc-register-screen-shot-settings
            gNativeHelperContext.screenshotSettings = static_cast<uint32_t>(arguments[0]);
            return 0;
        case 135: { // __pc-set-levels (l0, l1 GOAL strings; "none"/"#f" for empty)
            std::vector<std::string> levels;
            for (int index = 0; index < 2; index++) {
                const char *name = arguments[index] <= UINT32_MAX ?
                    GoalString(static_cast<uint32_t>(arguments[index])) : nullptr;
                if (name != nullptr && name[0] != 0 && strcmp(name, "none") != 0 && strcmp(name, "#f") != 0) {
                    levels.emplace_back(name);
                }
            }
            jak1::RequestBackgroundLevels(levels);
            return 0;
        }
        case 136: // pc-discord-rpc-update
            return 0;
        case 137: { // rpc-call: channel, fno, async, send, send size, receive, receive size
            constexpr uint64_t kDgoRpcChannel = 3;
            constexpr uint64_t kDgoLoadFunction = 0;
            constexpr uint32_t kDgoCommandNameOffset = 16;
            constexpr uint32_t kDgoCommandNameSize = 16;
            const uint32_t sendBuffer = static_cast<uint32_t>(arguments[3]);
            if (arguments[0] == kDgoRpcChannel && arguments[1] == kDgoLoadFunction) {
                char commandName[kDgoCommandNameSize] {};
                if (ReadGoalValue(sendBuffer + kDgoCommandNameOffset, commandName,
                                  sizeof(commandName)) && commandName[0] == 0) {
                    // The captured ARM64 translation loses string->sound-name's uint128 return,
                    // leaving the RPC filename empty. Recover the source string used by
                    // dgo-load-begin from *temp-string* before dispatching the command.
                    const auto tempStringSymbol = gNativeHelperContext.symbols.find("*temp-string*");
                    uint32_t tempString = 0;
                    if (tempStringSymbol != gNativeHelperContext.symbols.end() &&
                        ReadGoalValue(tempStringSymbol->second, &tempString, sizeof(tempString))) {
                        const char *source = GoalString(tempString);
                        if (source != nullptr && source[0] != 0) {
                            strncpy(commandName, source, sizeof(commandName) - 1);
                        }
                    }
                    if (commandName[0] == 0) {
                        // The first retail level load is the title DGO. Keep this narrow fallback
                        // until uint128 returns are represented by the AOT translator.
                        strncpy(commandName, "TIT.DGO", sizeof(commandName) - 1);
                    }
                    WriteGoalValue(sendBuffer + kDgoCommandNameOffset, commandName,
                                   sizeof(commandName));
                    NSLog(@"jakIOS: recovered DGO command name %s", commandName);
                }
            }
            if (arguments[0] == kDgoRpcChannel && gNativeHelperContext.kernel != nullptr) {
                gNativeHelperContext.kernel->dgoRpc(static_cast<uint32_t>(arguments[1]),
                                                    static_cast<uint32_t>(arguments[3]),
                                                    static_cast<uint32_t>(arguments[5]));
            }
            constexpr uint64_t kLoadStrRpcChannel = 4;
            if (arguments[0] == kLoadStrRpcChannel && sendBuffer != 0) {
                HandleLoadStrRpc(sendBuffer);
            }
            constexpr uint64_t kRamdiskRpcChannel = 2;
            if (arguments[0] == kRamdiskRpcChannel && sendBuffer != 0) {
                HandleRamdiskRpc(static_cast<uint32_t>(arguments[1]), sendBuffer,
                                 static_cast<uint32_t>(arguments[5]), static_cast<uint32_t>(arguments[6]));
            }
            constexpr uint64_t kPlayStrRpcChannel = 5;
            if (arguments[0] == kPlayStrRpcChannel && sendBuffer != 0) {
                HandlePlayStrRpc(sendBuffer, static_cast<uint32_t>(arguments[4]));
            }
            // These port numbers are defined by RPC-SOUND-PLAYER/LOADER in rpc-h.gc.
            constexpr uint64_t kSoundPlayerRpcChannel = 0;
            if (arguments[0] == kSoundPlayerRpcChannel && sendBuffer != 0) {
                HandleSoundPlayerRpc(sendBuffer, static_cast<uint32_t>(arguments[4]));
            }
            constexpr uint64_t kSoundLoaderRpcChannel = 1;
            if (arguments[0] == kSoundLoaderRpcChannel && sendBuffer != 0) {
                HandleSoundLoaderRpc(sendBuffer, static_cast<uint32_t>(arguments[4]));
            }
            // Remaining audio channels complete in-process.
            return 0;
        }
        case 138: // rpc-busy?
            // This kernel function returns an integer status, not a GOAL boolean object.
            // Returning the nonzero address of #f makes `(nonzero? (rpc-busy? ...))`
            // spin forever even though the in-process RPC has already completed.
            return 0;
        case 139: // test-load-dgo-c
            return GoalBoolean(true);
        case 140: // pc-sound-set-flava-hack
            gNativeHelperContext.soundFlava = arguments[0];
            jak1sound::SetFlavaHack(arguments[0]);
            return 0;
        case 141: // pc-sound-set-fade-hack
            gNativeHelperContext.soundFade = arguments[0];
            jak1sound::SetFadeHack(static_cast<uint32_t>(arguments[0]));
            return 0;
        case 142: { // test-function (debug-only), repurposed as the iOS birth-viewer (process, entity)
            // entity-actor birth! stamps the actor's (code-less, possibly bogus) type onto the process
            // it took from the dead pool, then abandons it when birth-viewer fails. Give it the real
            // `process` type so later heap compaction can relocate it, and report failure so the
            // entity is marked dead instead of spawning a debug viewer.
            const uint32_t process = static_cast<uint32_t>(arguments[0]);
            const uint32_t processSymbol = gNativeHelperContext.kernel != nullptr ?
                gNativeHelperContext.kernel->findSymbol("process") : 0;
            uint32_t processType = 0;
            if (process > 4 && processSymbol != 0 && ReadGoalValue(processSymbol, &processType, 4) && processType != 0) {
                WriteGoalValue(process - 4, &processType, 4);
            }
            // The process was never activated, so its connection-list is still zeroed (activate is
            // what sets next1/prev1 to #f). Left in the dead-pool-heap's live list, the next heap
            // compaction runs process relocate on it, which walks next1 until #f and spins forever
            // on 0. Return it after the kernel frame finishes. Recycling it here poisons the object
            // with 0xe1 while entity-actor birth! still has the process in its live register set.
            constexpr uint32_t kProcessPoolOffset = 0x1c;
            constexpr uint32_t kReturnProcessMethodOffset = 16 + 15 * 4;
            uint32_t pool = 0;
            uint32_t poolType = 0;
            uint32_t returnProcess = 0;
            if (process > 4 && ReadGoalValue(process + kProcessPoolOffset, &pool, 4) &&
                pool > 4 && pool != kCapturedS7GoalOffset && ReadGoalValue(pool - 4, &poolType, 4) &&
                ReadGoalValue(poolType + kReturnProcessMethodOffset, &returnProcess, 4) && returnProcess != 0) {
                gNativeHelperContext.pendingProcessReturns.push_back({returnProcess, pool, process});
            }
            return GoalBoolean(false);
        }
        default:
            return 0;
    }
}

@interface OGJak1RuntimeHost () {
    id<MTLCommandQueue> _commandQueue;
    Jak1MetalRenderer *_renderer;
    // The renderer only reads the trace on the CPU, so it gets a no-copy NSData view of
    // _lastDMABytes (render thread only) instead of a freshly allocated MTLBuffer per frame.
    NSData *_lastDMABuffer;
    std::vector<uint8_t> _lastDMABytes;
    NSData *_lastDMABucketOffsets;
    std::vector<uint8_t> _lastMercMemory;  // SnapshotMercMemory taken with _lastDMABytes
    NSData *_lastMercMemorySnapshot;
    id<MTLBuffer> _lastTextureBuffer;
    uint64_t _consumedDMASubmissionSerial;
    uint64_t _consumedTextureUpload;
    BOOL _loggedKernelDispatch;
    // Set once saved pc-settings have been loaded; committing before that would overwrite the
    // user's file with the captured image's defaults.
    std::atomic<bool> _hasLoadedPCSettings;
    BOOL _loggedTextureIngestion;
    BOOL _hasValidBootstrapManifest;
    BOOL _hasExecutableBootstrapPlan;
    BOOL _hasValidBootstrapImage;
    BOOL _hasMatchingSignedAOTImage;
    BOOL _hasValidSignedCodeIndex;
    BOOL _hasValidKernelDispatcherEntry;
    BOOL _hasValidNativeStubInventory;
    BOOL _hasInstalledFixedFunctionThunks;
    BOOL _hasPassedSignedThunkSmokeTest;
    BOOL _hasInitializedGoalGlobalHeap;
    BOOL _hasValidGoalExecutionViews;
    BOOL _hasInstalledFloatPointerGuard;
    NSMutableData *_bootstrapImage;
    NSMutableData *_goalWritableMemory;
    NSString *_runtimeStateError;  // why the arena could not be rebuilt from the imported disc
    NSMutableData *_symbolTableImage;
    NSMutableData *_symbolStringImage;
    NSMutableData *_typeArenaImage;
    std::unique_ptr<GoalAddressSpace> _goalAddressSpace;
    std::unique_ptr<GoalBumpHeap> _goalGlobalHeap;
    uint32_t _goalBaseOffset;
    BOOL _hasValidGoalAddressSpace;
    BOOL _hasMaterializedSymbolHashes;
    uint32_t _materializedSymbolHashCount;
    BOOL _hasMaterializedSymbolStrings;
    uint32_t _materializedSymbolStringCount;
    BOOL _hasMaterializedTypeRecords;
    uint32_t _materializedTypeRecordCount;
    BOOL _hasAppliedResolvedStartupPatches;
    uint32_t _resolvedStartupOperationCount;
    uint32_t _deferredStartupOperationCount;
    BOOL _hasInstalledNativeHelperThunks;
    uint32_t _installedNativeHelperThunkCount;
    BOOL _hasInitializedNativeKernel;
    BOOL _hasInstalledNativeKernelEntry;
    BOOL _kernelDispatchEnabled;
    uint64_t _kernelDispatchCount;
    dispatch_queue_t _kernelQueue;
    std::atomic<bool> _isDispatchingKernel;
    // DMA capture, decoding and Metal encoding run here, off the main thread, one frame at a time.
    dispatch_queue_t _renderQueue;
    std::atomic<int> _renderFramesInFlight;
    // Render queue only: depth target matching the current drawable (MTKView's isn't used).
    id<MTLTexture> _renderDepthTexture;
    FundamentalTypeOffsets _fundamentalTypes;
    BOOL _hasInstalledFundamentalTypes;
    std::string _contentPath;
    CGSize _drawableSize;
    struct {
        float left_x;
        float left_y;
        float right_x;
        float right_y;
        bool button_a;
        bool button_b;
        bool button_x;
        bool button_y;
        bool left_shoulder;
        bool right_shoulder;
        float left_trigger;
        float right_trigger;
        bool menu;
        bool select;
        bool left_thumb;
        bool right_thumb;
        bool dpad_up;
        bool dpad_down;
        bool dpad_left;
        bool dpad_right;
    } _input;
}
@end

@implementation OGJak1RuntimeHost

- (instancetype)initWithDevice:(id<MTLDevice>)device contentURL:(NSURL *)contentURL {
    self = [super init];
    if (self) {
        NSLog(@"jakIOS bootstrap: begin");
        _commandQueue = [device newCommandQueue];
        // The GOAL frame gates every rendered game frame; without an explicit QoS the scheduler
        // may run it on efficiency cores, and kernel frames then miss the display's 60 Hz tick.
        _kernelQueue = dispatch_queue_create(
            "com.opengoal.jak1.kernel",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        _renderQueue = dispatch_queue_create(
            "com.opengoal.jak1.render",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        _renderFramesInFlight.store(0);
        _isDispatchingKernel = false;
        _renderer = [[Jak1MetalRenderer alloc] initWithDevice:device];
        [[Jak1AudioManager sharedManager] startAudioEngine];
        NSLog(@"jakIOS bootstrap: Metal and audio ready");
        _hasValidBootstrapManifest = HasValidBootstrapManifest();
        _hasExecutableBootstrapPlan = HasExecutableBootstrapPlan();
        _bootstrapImage = LoadValidBootstrapImage(&_goalBaseOffset);
        NSLog(@"jakIOS bootstrap: bundled image loaded");
        _hasValidBootstrapImage = _bootstrapImage != nil;
        _hasMatchingSignedAOTImage = HasMatchingSignedAOTImage(_bootstrapImage);
        _hasValidSignedCodeIndex = HasValidSignedCodeIndex(_goalBaseOffset, _bootstrapImage.length);
        _hasValidKernelDispatcherEntry = HasValidKernelDispatcherEntry();
        _hasValidNativeStubInventory = HasValidNativeStubInventory();
        NSLog(@"jakIOS bootstrap: manifests validated");
        if (_hasValidBootstrapImage) {
            if (_goalBaseOffset <= kGoalMemorySize &&
                _bootstrapImage.length <= kGoalMemorySize - _goalBaseOffset) {
                NSString *runtimeStateError = nil;
                _goalWritableMemory = LoadValidRuntimeState(
                    contentURL == nil ? std::string() : std::string(contentURL.path.UTF8String),
                    &runtimeStateError);
                _runtimeStateError = runtimeStateError;
                _hasValidGoalExecutionViews = HasValidGoalExecutionViews(
                    _goalWritableMemory,
                    _goalBaseOffset
                );
                NSLog(@"jakIOS bootstrap: captured writable GOAL arena restored");
                _goalAddressSpace = std::make_unique<GoalAddressSpace>();
                _hasValidGoalAddressSpace =
                    _goalWritableMemory != nil && _goalAddressSpace->addRegion(0, _goalWritableMemory);
            }
            if (_hasValidGoalAddressSpace) {
                _goalGlobalHeap = std::make_unique<GoalBumpHeap>();
                // The captured game heap ends below 64 MiB. Reserve a separate native-helper
                // arena so helper allocations cannot overwrite captured GOAL objects. It uses the
                // unused arena space up to 1 MiB below the GOAL stack, after the region reserved
                // for prelinked level code.
                _hasInitializedGoalGlobalHeap =
                    _goalGlobalHeap->initialize(kLevelCodeRegionLimit, 0x07F00000);
                // A previous host (e.g. a failed import followed by a retry) may have left a
                // kernel bound to its now-freed arena; drop it so configureContentURL: rebuilds
                // the kernel against this host's memory.
                gNativeHelperContext.kernel.reset();
                gNativeHelperContext.goalMemory =
                    static_cast<uint8_t *>(_goalWritableMemory.mutableBytes);
                gNativeHelperContext.goalMemorySize = kGoalMemorySize;
                _hasInstalledFloatPointerGuard =
                    InstallFloatPointerCompatibilityPage(_goalWritableMemory);
                gNativeHelperContext.signedCodeBase =
                    reinterpret_cast<uintptr_t>(og_jak1_aot_signed_image_begin) - _goalBaseOffset;
                gNativeHelperContext.addressSpace = _goalAddressSpace.get();
                gNativeHelperContext.heap = _goalGlobalHeap.get();
                jak1::memcard::Initialize([](uint32_t goalOffset, uint32_t length) -> uint8_t * {
                    return gNativeHelperContext.addressSpace == nullptr ? nullptr :
                        gNativeHelperContext.addressSpace->pointerForGoal(goalOffset, length);
                });
                _hasInstalledFundamentalTypes = _hasInitializedGoalGlobalHeap &&
                    LoadCapturedRuntimeSymbols(
                        _goalAddressSpace.get(), &_fundamentalTypes
                    );
                _hasInstalledFixedFunctionThunks = _hasInstalledFundamentalTypes &&
                    InstallFixedFunctionThunks(
                        _goalAddressSpace.get(), _goalBaseOffset, _fundamentalTypes.function
                    );
                _hasPassedSignedThunkSmokeTest = _hasInstalledFixedFunctionThunks &&
                    RunSignedThunkSmokeTest(_goalWritableMemory, _goalBaseOffset);
                _hasMaterializedSymbolHashes = _hasInstalledFundamentalTypes;
                _hasMaterializedSymbolStrings = _hasInstalledFundamentalTypes;
                _hasMaterializedTypeRecords = _hasInstalledFundamentalTypes;
                _hasAppliedResolvedStartupPatches = _hasInstalledFundamentalTypes;
                NSLog(@"jakIOS bootstrap: captured symbols and types restored=%d "
                       "(type=0x%08x symbol=0x%08x string=0x%08x function=0x%08x)",
                      _hasInstalledFundamentalTypes, _fundamentalTypes.type,
                      _fundamentalTypes.symbol, _fundamentalTypes.string,
                      _fundamentalTypes.function);
                _hasInstalledNativeHelperThunks = _hasInstalledFundamentalTypes &&
                    InstallNativeHelperThunks(
                        _goalAddressSpace.get(), _goalBaseOffset, _fundamentalTypes.function,
                        &_installedNativeHelperThunkCount
                    );
                NSLog(@"jakIOS bootstrap: native helper thunks installed=%d count=%u",
                      _hasInstalledNativeHelperThunks, _installedNativeHelperThunkCount);
                _hasInstalledNativeKernelEntry = _hasInstalledNativeHelperThunks &&
                    InstallNativeKernelEntry(
                        _goalAddressSpace.get(), _fundamentalTypes.function
                    );
                _hasInitializedNativeKernel = _hasValidBootstrapManifest &&
                    _hasExecutableBootstrapPlan &&
                    _hasMatchingSignedAOTImage &&
                    _hasValidSignedCodeIndex &&
                    _hasValidKernelDispatcherEntry &&
                    _hasValidNativeStubInventory &&
                    _hasValidGoalExecutionViews &&
                    _hasInstalledFloatPointerGuard &&
                    _hasInitializedGoalGlobalHeap &&
                    _hasInstalledFundamentalTypes &&
                    _hasInstalledNativeHelperThunks &&
                    _hasInstalledNativeKernelEntry &&
                    CanInitializeNativeKernel(
                        _goalWritableMemory, _goalBaseOffset, _hasInstalledNativeHelperThunks
                    );
            }
        }
        // The game commits settings when an option is confirmed or the menu closes. Also save when
        // the app leaves the foreground, so a change can't be lost if iOS terminates the app.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(savePCSettings)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(savePCSettings)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
        NSLog(@"jakIOS bootstrap: initialization complete");
    }
    return self;
}

- (void)savePCSettings {
    if (!_hasLoadedPCSettings.load() || _kernelQueue == nil) {
        return;
    }
    // Run on the serial kernel queue so the commit happens between GOAL frames, never during one.
    dispatch_sync(_kernelQueue, ^{
        if (!gNativeHelperContext.shutdownRequested) {
            CommitPCSettingsToFile(self->_goalWritableMemory, self->_goalBaseOffset);
        }
    });
}

- (void)configureContentURL:(NSURL *)contentURL {
    _contentPath = contentURL == nil ? "" : contentURL.path.UTF8String;
    gNativeHelperContext.contentPath = _contentPath;
    NSURL *applicationSupport = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *settingsDirectory = [applicationSupport URLByAppendingPathComponent:@"jakIOS" isDirectory:YES];
    NSError *settingsDirectoryError = nil;
    const BOOL hasSettingsDirectory = [[NSFileManager defaultManager]
        createDirectoryAtURL:settingsDirectory
        withIntermediateDirectories:YES
        attributes:nil
        error:&settingsDirectoryError];
    if (hasSettingsDirectory) {
        gNativeHelperContext.settingsPath = settingsDirectory.path.UTF8String;
    } else {
        gNativeHelperContext.settingsPath.clear();
        NSLog(@"jakIOS: could not create settings directory: %@", settingsDirectoryError);
    }
    jak1::ConfigureBackgroundContentPath(_contentPath);
    [[Jak1AudioManager sharedManager] configureContentDirectory:contentURL];
    if (gNativeHelperContext.goalMemory != nullptr && gNativeHelperContext.kernel == nullptr) {
        jak1::KernelEnvironment environment;
        environment.memory = gNativeHelperContext.goalMemory;
        environment.memorySize = gNativeHelperContext.goalMemorySize;
        environment.s7 = gNativeHelperContext.s7GoalOffset;
        environment.contentPath = _contentPath;
        environment.allocateGlobal = [](uint32_t size, uint32_t alignment) -> uint32_t {
            return gNativeHelperContext.heap == nullptr ? 0 :
                gNativeHelperContext.heap->allocate(size, alignment);
        };
        environment.callGoal = CallGoalFromNative;
        environment.findExistingSymbol = [](const std::string &name) -> uint32_t {
            const auto symbol = gNativeHelperContext.symbols.find(name);
            return symbol == gNativeHelperContext.symbols.end() ? 0 : symbol->second;
        };
        environment.onSymbolCreated = [](const std::string &name, uint32_t symbol) {
            gNativeHelperContext.symbols[name] = symbol;
        };
        // Eroded Coast is removed from this build; never load a stale ERO.DGO left by an older import.
        environment.canLoadDgo = [](const std::string &name) -> bool {
            return name != "ERO.DGO";
        };
        gNativeHelperContext.expandedFlutEnabled.store(
            [NSUserDefaults.standardUserDefaults boolForKey:kExpandedFlutDefaultsKey],
            std::memory_order_relaxed);
        // Expanded Flut Flut keeps the flut art in the global heap; Swamp/Snowy use that copy.
        environment.skipDgoObject = [](const std::string &dgo, const std::string &object) -> bool {
            return (dgo == "SWA.DGO" || dgo == "SNO.DGO") &&
                gNativeHelperContext.expandedFlutLoaded.load(std::memory_order_relaxed) &&
                IsExpandedFlutArtName(object);
        };
        gNativeHelperContext.kernel = std::make_unique<jak1::Kernel>(std::move(environment));
        // Before any GOAL code runs: the level-code symbol slots must match the build-time link.
        InstallLevelCode(gNativeHelperContext.kernel.get());
    }
    _kernelDispatchEnabled = _hasInitializedNativeKernel && !_contentPath.empty();
}

- (CGSize)gameResolution {
    const int32_t width = gNativeHelperContext.gameWidth.load(std::memory_order_relaxed);
    const int32_t height = gNativeHelperContext.gameHeight.load(std::memory_order_relaxed);
    return CGSizeMake(
        width > 0 ? width : gNativeHelperContext.drawableWidth,
        height > 0 ? height : gNativeHelperContext.drawableHeight
    );
}

- (void)configureDisplayRefreshRate:(NSInteger)framesPerSecond {
    gNativeHelperContext.displayRefreshRate.store(
        MAX(1, static_cast<int32_t>(framesPerSecond)), std::memory_order_relaxed
    );
}

- (BOOL)isTitleIntroReady {
    return gNativeHelperContext.titleIntroReady.load(std::memory_order_relaxed);
}

- (void)startTitleIntro {
    gNativeHelperContext.titleIntroReleaseRequested.store(true, std::memory_order_relaxed);
}

- (BOOL)isTitleWaitingForStart {
    return gNativeHelperContext.titleWaitingForStart.load(std::memory_order_relaxed);
}

- (BOOL)isMenuOpen {
    return gNativeHelperContext.menuOpen.load(std::memory_order_relaxed);
}

- (BOOL)isOnTitleScreen {
    return gNativeHelperContext.onTitleScreen.load(std::memory_order_relaxed);
}

- (BOOL)isDirectCameraLookAvailable {
    return gNativeHelperContext.directCameraLookAvailable.load(std::memory_order_relaxed);
}

- (BOOL)isCameraAimingMode {
    return gNativeHelperContext.cameraAimingMode.load(std::memory_order_relaxed);
}

- (BOOL)isSwipeCameraEnabled {
    return gNativeHelperContext.swipeCameraEnabled.load(std::memory_order_relaxed);
}

- (BOOL)isFloatingRightJoystickEnabled {
    return gNativeHelperContext.floatingRightJoystick.load(std::memory_order_relaxed);
}

- (BOOL)isFloatingLeftJoystickEnabled {
    return gNativeHelperContext.floatingLeftJoystick.load(std::memory_order_relaxed);
}

- (BOOL)isHapticFeedbackEnabled {
    return gNativeHelperContext.hapticFeedback.load(std::memory_order_relaxed);
}

- (BOOL)isNewGameMirrorOptionVisible {
    return gNativeHelperContext.newGameMirrorVisible.load(std::memory_order_relaxed);
}

- (BOOL)isNewGameMirrorChecked {
    return gNativeHelperContext.newGameMirrorChecked.load(std::memory_order_relaxed);
}

- (void)setNewGameMirrorChecked:(BOOL)checked {
    gNativeHelperContext.newGameMirrorChecked.store(checked, std::memory_order_relaxed);
}

- (void)addCameraLookYaw:(double)yawDegrees zoom:(double)zoom touching:(BOOL)touching {
    std::lock_guard<std::mutex> lock(gCameraLookMutex);
    gPendingCameraLookYaw += yawDegrees;
    gPendingCameraLookZoom += zoom;
    gCameraLookTouching = touching;
}

- (void)menuTapAtX:(double)x y:(double)y viewAspect:(double)viewAspect {
    MenuTouchEvent event {MenuTouchEvent::Kind::Tap};
    if (!ViewPointToGameViewport(x, y, viewAspect, &event.x, &event.y)) return;
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(event);
}

- (void)menuPressAtX:(double)x y:(double)y viewAspect:(double)viewAspect {
    MenuTouchEvent event {MenuTouchEvent::Kind::Press};
    if (!ViewPointToGameViewport(x, y, viewAspect, &event.x, &event.y)) return;
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(event);
}

- (void)menuPressCancel {
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(MenuTouchEvent {MenuTouchEvent::Kind::PressCancel});
}

- (void)menuScrollByRows:(NSInteger)rows startsSwipe:(BOOL)startsSwipe {
    if (rows == 0) return;
    MenuTouchEvent event {MenuTouchEvent::Kind::Scroll};
    event.steps = static_cast<int>(rows);
    event.startsSwipe = startsSwipe;
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(event);
}

- (void)menuStepHorizontal:(NSInteger)steps startsSwipe:(BOOL)startsSwipe {
    if (steps == 0) return;
    MenuTouchEvent event {MenuTouchEvent::Kind::Horizontal};
    event.steps = static_cast<int>(steps);
    event.startsSwipe = startsSwipe;
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(event);
}

- (BOOL)isWarpGateActive {
    return gNativeHelperContext.warpGateActive.load(std::memory_order_relaxed);
}

- (BOOL)isCutsceneActive {
    return gNativeHelperContext.cutsceneActive.load(std::memory_order_relaxed);
}

- (BOOL)isOnZoomer {
    return gNativeHelperContext.onZoomer.load(std::memory_order_relaxed);
}

- (BOOL)isGameVisible {
    return gNativeHelperContext.gameVisible.load(std::memory_order_relaxed);
}

- (BOOL)isMenuOnCollectionPage {
    return gMenuOnCollectionPage.load(std::memory_order_relaxed);
}

- (void)setTouchMenuStyle:(BOOL)touchMenus {
    gTouchMenuStyle.store(touchMenus, std::memory_order_relaxed);
}

- (void)menuBack {
    std::lock_guard<std::mutex> lock(gMenuTouchMutex);
    gPendingMenuTouchEvents.push_back(MenuTouchEvent {MenuTouchEvent::Kind::Back});
}

- (void)setTitleAttractMode:(BOOL)attract {
    const bool wasAttract = gNativeHelperContext.titleAttract.exchange(attract, std::memory_order_relaxed);
    if (wasAttract && !attract) {
        // PLAY stands in for "press start": deliver one Start press so the title menu opens.
        gNativeHelperContext.latchedButtons.fetch_or(1 << 3, std::memory_order_relaxed);
    }
}

- (NSInteger)preferredFrameRate {
    const int32_t selected = gNativeHelperContext.targetFPS.load(std::memory_order_relaxed);
    const int32_t maximum = gNativeHelperContext.displayRefreshRate.load(std::memory_order_relaxed);
    return MIN(MAX(selected, 1), MAX(maximum, 1));
}

- (void)resizeToWidth:(CGFloat)width height:(CGFloat)height {
    _drawableSize = CGSizeMake(width, height);
    gNativeHelperContext.drawableWidth = static_cast<uint32_t>(MAX(width, 0));
    gNativeHelperContext.drawableHeight = static_cast<uint32_t>(MAX(height, 0));
    NSLog(@"jakIOS: runtime drawable resized to %.0f x %.0f (%@)", width, height,
          width >= height ? @"landscape" : @"portrait");
}

- (NSString *)bootstrapReadiness {
    if (!_hasValidBootstrapManifest) {
        return @"AOT bootstrap manifest is missing or invalid.";
    }
    if (!_hasExecutableBootstrapPlan) {
        return @"The bundled AOT payload is validated, but its GOAL executor is incomplete. Kernel dispatch is disabled to prevent an invalid code branch.";
    }
    if (!_hasValidBootstrapImage) {
        return @"AOT bootstrap image is missing, truncated, or invalid.";
    }
    if (!_hasMatchingSignedAOTImage) {
        return @"The signed AOT image does not match the validated bootstrap payload.";
    }
    if (!_hasValidSignedCodeIndex) {
        return @"The signed AOT executable-range index is missing or invalid.";
    }
    if (!_hasValidKernelDispatcherEntry) {
        return @"The signed kernel dispatcher entry manifest is missing or invalid.";
    }
    if (!_hasValidNativeStubInventory) {
        return @"The native GOAL stub inventory is missing or invalid.";
    }
    if (_runtimeStateError != nil) {
        return _runtimeStateError;
    }
    if (!_hasValidGoalExecutionViews) {
        return @"The x22 writable arena and x27 signed-code view are unavailable.";
    }
    if (!_hasInstalledFixedFunctionThunks) {
        return @"The signed fixed GOAL function thunks could not be installed.";
    }
    if (!_hasPassedSignedThunkSmokeTest) {
        return @"The signed GOAL call bridge smoke test failed.";
    }
    if (!_hasInitializedGoalGlobalHeap) {
        return @"The GOAL global heap could not be initialized.";
    }
    if (!_hasInstalledFundamentalTypes) {
        return @"The fundamental GOAL types could not be initialized.";
    }
    if (!_hasValidGoalAddressSpace) {
        return @"GOAL memory regions overlap or could not be allocated.";
    }
    if (!_hasMaterializedSymbolHashes) {
        return @"AOT symbol hash table is missing or invalid.";
    }
    if (!_hasMaterializedSymbolStrings) {
        return @"AOT symbol string table is missing or invalid.";
    }
    if (!_hasMaterializedTypeRecords) {
        return @"AOT type record table is missing or invalid.";
    }
    if (!_hasAppliedResolvedStartupPatches) {
        return @"AOT startup patch table is missing or invalid.";
    }
    if (!_hasInstalledNativeHelperThunks) {
        return @"The 143 signed native helper thunks could not be installed.";
    }
    if (!_hasInitializedNativeKernel) {
        return @"The signed GOAL kernel dispatcher could not be initialized.";
    }
    return [NSString stringWithFormat:
        @"The signed GOAL kernel is ready with a %zu-region 128 MB x22 arena, 960 signed AOT ranges, %u symbol hashes, %u symbol strings, %u type records, %u audited patches, and %u native helper thunks.",
        _goalAddressSpace->regionCount(),
        _materializedSymbolHashCount,
        _materializedSymbolStringCount,
        _materializedTypeRecordCount,
        _resolvedStartupOperationCount,
        _installedNativeHelperThunkCount
    ];
}

// DualShock 2 button0 bits (active-high) for the app's digital controls.
static uint16_t PackDualShock2Buttons(
    bool buttonA, bool buttonB, bool buttonX, bool buttonY, bool leftShoulder, bool rightShoulder,
    bool leftTrigger, bool rightTrigger, bool menu, bool select, bool leftThumb, bool rightThumb,
    bool dpadUp, bool dpadDown, bool dpadLeft, bool dpadRight
) {
    uint16_t buttons = 0;
    auto setPressed = [&buttons](uint16_t mask, bool pressed) {
        if (pressed) {
            buttons |= mask;
        }
    };
    setPressed(1 << 14, buttonA);
    setPressed(1 << 13, buttonB);
    setPressed(1 << 15, buttonX);
    setPressed(1 << 12, buttonY);
    setPressed(1 << 10, leftShoulder);
    setPressed(1 << 11, rightShoulder);
    setPressed(1 << 8, leftTrigger);
    setPressed(1 << 9, rightTrigger);
    setPressed(1 << 3, menu);
    // Remaining DualShock 2 bits: Select, L3, R3, and the D-pad.
    setPressed(1 << 0, select);
    setPressed(1 << 1, leftThumb);
    setPressed(1 << 2, rightThumb);
    setPressed(1 << 4, dpadUp);
    setPressed(1 << 5, dpadRight);
    setPressed(1 << 6, dpadDown);
    setPressed(1 << 7, dpadLeft);
    return buttons;
}

- (void)notePressesWithButtonA:(BOOL)buttonA
                       buttonB:(BOOL)buttonB
                       buttonX:(BOOL)buttonX
                       buttonY:(BOOL)buttonY
                  leftShoulder:(BOOL)leftShoulder
                 rightShoulder:(BOOL)rightShoulder
                   leftTrigger:(BOOL)leftTrigger
                  rightTrigger:(BOOL)rightTrigger
                          menu:(BOOL)menu
                        select:(BOOL)select
                     leftThumb:(BOOL)leftThumb
                    rightThumb:(BOOL)rightThumb
                        dpadUp:(BOOL)dpadUp
                      dpadDown:(BOOL)dpadDown
                      dpadLeft:(BOOL)dpadLeft
                     dpadRight:(BOOL)dpadRight {
    const uint16_t presses = PackDualShock2Buttons(
        buttonA, buttonB, buttonX, buttonY, leftShoulder, rightShoulder, leftTrigger, rightTrigger,
        menu, select, leftThumb, rightThumb, dpadUp, dpadDown, dpadLeft, dpadRight
    );
    if (presses != 0) {
        gNativeHelperContext.pressEdges.fetch_or(presses, std::memory_order_relaxed);
    }
}

- (void)updateWithLeftX:(float)leftX
                  leftY:(float)leftY
                 rightX:(float)rightX
                 rightY:(float)rightY
                buttonA:(BOOL)buttonA
                buttonB:(BOOL)buttonB
                buttonX:(BOOL)buttonX
                buttonY:(BOOL)buttonY
           leftShoulder:(BOOL)leftShoulder
          rightShoulder:(BOOL)rightShoulder
            leftTrigger:(float)leftTrigger
           rightTrigger:(float)rightTrigger
                   menu:(BOOL)menu
                 select:(BOOL)select
              leftThumb:(BOOL)leftThumb
             rightThumb:(BOOL)rightThumb
                 dpadUp:(BOOL)dpadUp
               dpadDown:(BOOL)dpadDown
               dpadLeft:(BOOL)dpadLeft
              dpadRight:(BOOL)dpadRight {
    _input = {
        leftX,
        leftY,
        rightX,
        rightY,
        static_cast<bool>(buttonA),
        static_cast<bool>(buttonB),
        static_cast<bool>(buttonX),
        static_cast<bool>(buttonY),
        static_cast<bool>(leftShoulder),
        static_cast<bool>(rightShoulder),
        leftTrigger,
        rightTrigger,
        static_cast<bool>(menu),
        static_cast<bool>(select),
        static_cast<bool>(leftThumb),
        static_cast<bool>(rightThumb),
        static_cast<bool>(dpadUp),
        static_cast<bool>(dpadDown),
        static_cast<bool>(dpadLeft),
        static_cast<bool>(dpadRight)
    };
    gNativeHelperContext.leftX = leftX;
    gNativeHelperContext.leftY = leftY;
    gNativeHelperContext.rightX = rightX;
    gNativeHelperContext.rightY = rightY;
    const uint16_t buttons = PackDualShock2Buttons(
        buttonA, buttonB, buttonX, buttonY, leftShoulder, rightShoulder,
        leftTrigger > 0.5f, rightTrigger > 0.5f, menu, select, leftThumb, rightThumb,
        dpadUp, dpadDown, dpadLeft, dpadRight
    );
    static bool lastMenu = false;
    if (static_cast<bool>(menu) != lastMenu) {
        NSLog(@"jakIOS: input layer Start %@", menu ? @"down" : @"up");
        lastMenu = menu;
    }
    gNativeHelperContext.buttons.store(buttons, std::memory_order_relaxed);
    gNativeHelperContext.latchedButtons.fetch_or(buttons, std::memory_order_relaxed);
    gNativeHelperContext.controllerCount = 1;
}

- (void)drawInView:(MTKView *)view {
    LogThreadCPUUsageIfDue();
    // The GOAL kernel is only dispatched from this tick, so a late tick is a dropped game frame.
    // Logged to tell main-thread/display stalls apart from slow kernel frames ("perf kernel").
    {
        static CFTimeInterval lastTick = 0;
        const CFTimeInterval now = CACurrentMediaTime();
        if (lastTick > 0 && now - lastTick > 0.05) {
            NSLog(@"jakIOS perf hitch: display tick late by %.0f ms", (now - lastTick) * 1000.0);
        }
        lastTick = now;
    }
    if (_kernelDispatchEnabled && !gNativeHelperContext.shutdownRequested) {
        if (!_isDispatchingKernel.exchange(true)) {
            dispatch_async(_kernelQueue, ^{
                if (!gNativeHelperContext.shutdownRequested) {
                    pthread_setname_np("jak1-kernel");  // GCD worker; named for the thread CPU log
                    if (!self->_loggedKernelDispatch) {
                        NSLog(@"jakIOS: entering first signed GOAL kernel frame on background thread");
                    }
                    if (!self->_hasLoadedPCSettings.load()) {
                        InstallIOSCapturedOverrides(self->_goalWritableMemory, self->_goalBaseOffset);
                        LoadPCSettingsFromFile(self->_goalWritableMemory, self->_goalBaseOffset);
                        self->_hasLoadedPCSettings.store(true);
                    }
                    const uint64_t kernelStart = mach_continuous_time();
                    SyncTitleState();
                    SyncCameraLook();
                    SyncMenuTouch();
                    SyncMenuHighlightStyle();
                    SyncDriveableBoatOption();
                    SyncExpandedFlutOption();
                    SyncDynamicSavePointsOption();
                    SyncOceanFishOption();
                    SyncExpandedGreenEcoOption();
                    DispatchNativeKernelFrame(self->_goalWritableMemory, self->_goalBaseOffset);
                    ReturnPendingProcesses();
                    RefreshDisplayOnAspectChange();
                    CenterProgressCompletionPercent();
                    PromoteIOSInputOptions();
                    SyncIOSTitleOptionsRemap();
                    RepairIOSGameOptionTargets();
                    RemoveIOSDesktopGraphicsOptions();
                    RepairIOSGraphicsOptionTargets();
                    RemoveUnsupportedIOSAspectRatios();
                    RemoveIOSDesktopInputOptions();
                    RemoveIOSDiscordOption();
                    RepairIOSMiscOptionTargets();
                    RemoveUnsupportedIOSControllerOptions();
                    InstallIOSExperimentalOptions();
                    SyncIOSExperimentalOptions();
                    SyncErodedCoastProgressTotals();
                    InstallIOSDevMenu();
                    SyncIOSDevMenu();
                    RemoveIOSMirrorCheatOption();
                    SyncMirrorMode();
                    SyncIOSTouchOptions();
                    ConfigureIOSFrameRateOptions();
                    SyncTitlePressStartText();
                    SyncIOSHighFrameRateTiming();
                    ForceIOSPS2Particles();
                    ApplyIOSHudLayout();
                    const uint64_t kernelEnd = mach_continuous_time();
                    static mach_timebase_info_data_t timebase {};
                    static uint64_t sampleStart = 0;
                    static uint64_t accumulated = 0;
                    static uint64_t longest = 0;
                    static uint32_t frames = 0;
                    if (timebase.denom == 0) mach_timebase_info(&timebase);
                    if (sampleStart == 0) sampleStart = kernelStart;
                    accumulated += kernelEnd - kernelStart;
                    longest = std::max<uint64_t>(longest, kernelEnd - kernelStart);
                    frames++;
                    const double windowSeconds = (kernelEnd - sampleStart) *
                        static_cast<double>(timebase.numer) / timebase.denom / 1.0e9;
                    if (windowSeconds >= 1.0) {
                        const double toMilliseconds =
                            static_cast<double>(timebase.numer) / timebase.denom / 1.0e6;
                        NSLog(@"jakIOS perf kernel: %.1f frames/s, %.2f ms/frame, max %.2f ms",
                              frames / windowSeconds, accumulated * toMilliseconds / frames,
                              longest * toMilliseconds);
                        sampleStart = kernelEnd;
                        accumulated = 0;
                        longest = 0;
                        frames = 0;
                    }
                    self->_kernelDispatchCount++;
                    if (!self->_loggedKernelDispatch) {
                        NSLog(@"jakIOS: signed GOAL kernel frame returned successfully");
                        self->_loggedKernelDispatch = YES;
                    }
                    pthread_setname_np("");  // the worker returns to the GCD pool; don't mislabel later work
                }
                self->_isDispatchingKernel.store(false);
            });
        }
    }
    // Only input stays on the main thread. Up to two frames may be in flight on the render queue
    // (one encoding, one waiting), so an encode slightly over a vsync interval doesn't halve the
    // frame rate. Skip this tick when both are taken.
    if (_commandQueue == nil || _renderFramesInFlight.load() >= 2) {
        return;
    }
    // The drawable is acquired on the render queue, not here: -nextDrawable blocks (up to a
    // second) while every drawable is in use, which happens when the system compositor takes
    // GPU time for a screenshot or notification banner. Blocking the main thread there would
    // also stop input and the GOAL kernel, which is only dispatched from this display tick.
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    const BOOL contentReady = !_contentPath.empty();
    _renderFramesInFlight.fetch_add(1);
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {  // release each frame's drawable and transient objects promptly
            pthread_setname_np("jak1-render");
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            MTLRenderPassDescriptor *renderPassDescriptor =
                drawable == nil ? nil : [self renderPassDescriptorForDrawable:drawable];
            if (renderPassDescriptor != nil) {
                [self captureAndRenderFrameWithPassDescriptor:renderPassDescriptor
                                                     drawable:drawable
                                                 contentReady:contentReady];
            }
            pthread_setname_np("");
        }
        self->_renderFramesInFlight.fetch_sub(1);
    });
}

// Render queue only: a pass targeting the drawable plus a depth texture of the same size.
// Load/store actions and clear values are set by the renderer.
- (MTLRenderPassDescriptor *)renderPassDescriptorForDrawable:(id<CAMetalDrawable>)drawable {
    id<MTLTexture> color = drawable.texture;
    if (_renderDepthTexture == nil || _renderDepthTexture.width != color.width ||
        _renderDepthTexture.height != color.height) {
        MTLTextureDescriptor *depthDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:jak1::kMainPassDepthStencilFormat
                                                               width:color.width
                                                              height:color.height
                                                           mipmapped:NO];
        depthDescriptor.usage = MTLTextureUsageRenderTarget;
        depthDescriptor.storageMode = MTLStorageModePrivate;
        _renderDepthTexture = [_commandQueue.device newTextureWithDescriptor:depthDescriptor];
        if (_renderDepthTexture == nil) {
            return nil;
        }
    }
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = color;
    descriptor.depthAttachment.texture = _renderDepthTexture;
    descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    descriptor.stencilAttachment.texture = _renderDepthTexture;
    descriptor.stencilAttachment.storeAction = MTLStoreActionDontCare;
    return descriptor;
}

// Render queue only: ingests the newest GOAL DMA chain, then encodes and presents the frame.
- (void)captureAndRenderFrameWithPassDescriptor:(MTLRenderPassDescriptor *)renderPassDescriptor
                                       drawable:(id<CAMetalDrawable>)drawable
                                   contentReady:(BOOL)contentReady {
    // The game thread copied the chain at submission (CaptureAndPublishDMAChain); take the newest.
    std::vector<uint32_t> bucketOffsets;
    if (TakePublishedDMATrace(&_consumedDMASubmissionSerial, &_lastDMABytes, &bucketOffsets,
                              &_lastMercMemory)) {
        // VRAM layout for exactly the frame about to be drawn (TextureUploadHandler order).
        ApplyTextureUploadsInTrace(_lastDMABytes, bucketOffsets);
        _lastDMABuffer = [NSData dataWithBytesNoCopy:_lastDMABytes.data()
                                              length:_lastDMABytes.size()
                                        freeWhenDone:NO];
        _lastDMABucketOffsets = [NSData dataWithBytes:bucketOffsets.data()
                                               length:bucketOffsets.size() * sizeof(uint32_t)];
        _lastMercMemorySnapshot = [NSData dataWithBytesNoCopy:_lastMercMemory.data()
                                                       length:_lastMercMemory.size()
                                                 freeWhenDone:NO];
    }
    if (_consumedTextureUpload != gNativeHelperContext.lastTextureUpload &&
        gNativeHelperContext.lastTextureUpload <= UINT32_MAX) {
        const uint32_t page = static_cast<uint32_t>(gNativeHelperContext.lastTextureUpload);
        constexpr uint32_t textureHeaderProbeSize = 4096;
        uint8_t *texturePage = _goalAddressSpace == nullptr ? nullptr :
            _goalAddressSpace->pointerForGoal(page, textureHeaderProbeSize);
        if (texturePage != nullptr) {
            _lastTextureBuffer = [_commandQueue.device newBufferWithBytes:texturePage
                                                                   length:textureHeaderProbeSize
                                                                  options:MTLResourceStorageModeShared];
            if (!_loggedTextureIngestion && _lastTextureBuffer != nil) {
                NSLog(@"jakIOS: consumed GOAL texture page into a Metal buffer");
                _loggedTextureIngestion = YES;
            }
        }
        _consumedTextureUpload = gNativeHelperContext.lastTextureUpload;
    }

    // PCRTC alpha from put-display-env: the game blacks out loads, respawns and menu
    // transitions this way, so the renderer must honor it.
    const double displayLevel = gNativeHelperContext.displayAlpha / 255.0;
    [_renderer setDMABucketTraceOffsets:_lastDMABucketOffsets];
    [_renderer setMercMemorySnapshot:_lastMercMemorySnapshot];
    [_renderer renderFrameWithPassDescriptor:renderPassDescriptor
                                    drawable:drawable
                                commandQueue:_commandQueue
                                   dmaBuffer:_lastDMABuffer
                               textureBuffer:_lastTextureBuffer
                                  goalMemory:gNativeHelperContext.goalMemory
                              goalMemorySize:gNativeHelperContext.goalMemorySize
                                displayAlpha:displayLevel
                                contentReady:contentReady];
}

@end
