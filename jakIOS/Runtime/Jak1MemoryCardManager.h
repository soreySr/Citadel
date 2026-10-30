#pragma once

// Port of OpenGOAL's game/kernel/common/kmemcard.cpp (PC raw-save variant) for Jak 1.
// There is no memory card: the four save files are stored as eight bank files
// (Documents/saves/BASCUS-97124AYBABTU!/bank0..7.bin), byte-compatible with desktop OpenGOAL.
// The GOAL kernel functions mc-run ... mc-makefile map 1:1 onto the functions below.

#include <cstdint>

namespace jak1::memcard {

// Resolves a GOAL address range to host memory, or nullptr if it is out of bounds.
using GoalPointerResolver = uint8_t *(*)(uint32_t goalOffset, uint32_t length);

void Initialize(GoalPointerResolver resolver);

void SetLanguage(int32_t language);                      // kset-language
void Run();                                              // mc-run, called once per GOAL frame
uint64_t Format(int32_t cardIndex);                      // mc-format
uint64_t Unformat(int32_t cardIndex);                    // mc-unformat
uint64_t CreateFile(int32_t param, uint32_t data);       // mc-create-file
uint64_t Save(int32_t cardIndex, int32_t fileIndex, uint32_t saveData, uint32_t summaryData); // mc-save
uint64_t Load(int32_t cardIndex, int32_t fileIndex, uint32_t data);                          // mc-load
uint32_t CheckResult();                                  // mc-check-result
void GetSlotInfo(int32_t slot, uint32_t info);           // mc-get-slot-info (fills a GOAL mc-slot-info)

// iOS mirror mode is a per-save setting, kept in the unused part of each bank's header (desktop
// OpenGOAL neither writes nor reads it, so files stay compatible).
void SetMirrorModeForSaves(bool mirror);                 // stored with every following save
bool FilePresent(int32_t fileIndex);
bool FileHasMirrorMode(int32_t fileIndex);
// After a successful load: true once, with that save's mirror setting.
bool TakeLoadedMirrorMode(bool *mirror);

// Fishing log (catch count per fish species, IOSFishRoster.h ids), also kept in the bank header.
// The memcard owns the log of the game being played: loading a save replaces it, every save
// writes it, ResetFishLog clears it for a new game. It is saved whether or not Fishing is on.
constexpr int kFishLogCapacity = 64;
void ResetFishLog();
uint16_t FishCaughtCount(int species);
void AddFishCatch(int species);  // saturates at 0xFFFF

// Open Ocean progress (pc/ios/ios-open-ocean.gc, open-ocean-plan.md), also kept in the bank header and owned like the
// fishing log: loading a save replaces it, every save writes it, ResetOceanProgress clears it for a new game. Ocean
// items are a separate bonus, outside the stock task table (which can't hold them).
constexpr int kOceanOrbTotal = 500;
struct OceanProgress {
    uint16_t orbs = 0;      // 0..kOceanOrbTotal
    uint8_t flies = 0;      // scout fly bits 0-6
    uint8_t cells = 0;      // power cell bits 0-7
    bool visited = false;   // Jak has been in the Open Ocean (opens its pause menu page)
};
void ResetOceanProgress();
OceanProgress GetOceanProgress();
void SetOceanProgress(const OceanProgress &progress);

// Driveable boat upgrade level (boat-upgrades-plan.md), 1..kBoatMaxLevel, also kept in the bank header and owned
// like the fishing log: loading a save replaces it, every save writes it, ResetBoatLevel sets 1 for a new game.
// Saves from before upgrades read as level 1.
constexpr int kBoatMaxLevel = 6;
void ResetBoatLevel();
int GetBoatLevel();
void SetBoatLevel(int level);  // clamped to 1..kBoatMaxLevel

}  // namespace jak1::memcard
