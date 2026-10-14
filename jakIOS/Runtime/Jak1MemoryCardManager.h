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

}  // namespace jak1::memcard
