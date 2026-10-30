#import "Jak1MemoryCardManager.h"
#import "IOSFishRoster.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace jak1::memcard {
namespace {

// Jak 1 constants from kmemcard.h (SAVE_SIZE / BANK_SIZE for GameVersion::Jak1).
constexpr int32_t kSaveSize = 692;
constexpr uint32_t kBankSize = 0x10000;
constexpr uint32_t kPCMemCardHandle = 0x6C616F67;  // arbitrary "card handle" used by the PC port
constexpr uint32_t kMemCardMagic = 0x12345678;
constexpr const char *kSaveDirectoryName = "BASCUS-97124AYBABTU!";

enum class OperationKind : uint32_t { NoOp = 0, Format = 1, Unformat = 2, CreateFile = 3, Save = 4, Load = 5 };

// Matches GOAL's mc-status-code (kernel-defs.gc).
enum class StatusCode : uint32_t {
    Busy = 0, OK = 1, BadHandle = 2, FormatFailed = 3, InternalError = 4, WriteError = 5,
    ReadError = 6, NewGame = 7, NoMemory = 8, NoCard = 9, NoLast = 10, NoFormat = 11,
    NoFile = 12, NoSave = 13, NoSpace = 14, BadVersion = 15, NoProcess = 16, NoAutoSave = 17
};

struct Operation {
    OperationKind operation = OperationKind::NoOp;
    uint32_t param = 0;
    uint32_t param2 = 0;
    StatusCode result = StatusCode::Busy;
    uint32_t retryCount = 0;
    uint32_t dataPtr = 0;   // GOAL address
    uint32_t dataPtr2 = 0;  // GOAL address
};

struct MemoryCardFile {
    uint32_t present = 0;
    uint32_t mostRecentSaveCount = 0;
    uint32_t lastSavedBank = 0;
    uint8_t data[64] {};
    bool mirror = false;
};

struct McHeader {
    uint32_t saveCount;
    uint32_t checksum;
    uint32_t magic;
    uint8_t previewData[64];
    uint8_t data[944];
    uint32_t saveCount2;
};
static_assert(sizeof(McHeader) == 0x400, "McHeader size");

// GOAL mc-file-info / mc-slot-info layout (kmemcard.h mc_slot_info).
struct GoalFileInfo {
    uint32_t present;
    uint8_t data[64];
};
struct GoalSlotInfo {
    uint32_t handle;
    uint32_t known;
    uint32_t formatted;
    uint32_t initted;
    int32_t lastFile;
    uint32_t memRequired;
    uint32_t memActual;
    GoalFileInfo files[4];
};
static_assert(sizeof(GoalSlotInfo) == 300, "mc-slot-info size");

constexpr uint32_t kTotalBankSize = kBankSize + sizeof(McHeader) * 2;

// iOS settings in McHeader::data: a tag, then flags. Headers without the tag (desktop saves,
// older iOS saves) have no mirror mode.
constexpr uint32_t kIOSHeaderTag = 0x4D534F69;  // "iOSM"
constexpr uint8_t kIOSHeaderMirrorFlag = 1 << 0;

bool HeaderMirrorMode(const McHeader *header) {
    uint32_t tag = 0;
    memcpy(&tag, header->data, sizeof(tag));
    return tag == kIOSHeaderTag && (header->data[sizeof(tag)] & kIOSHeaderMirrorFlag) != 0;
}

void SetHeaderMirrorMode(McHeader *header, bool mirror) {
    memcpy(header->data, &kIOSHeaderTag, sizeof(kIOSHeaderTag));
    header->data[sizeof(kIOSHeaderTag)] = mirror ? kIOSHeaderMirrorFlag : 0;
}

// Fishing log, after the mirror tag + flags: its own tag, the number of counts stored, then the
// counts. Species added later read as 0 from older saves; counts past kFishLogCapacity are dropped.
constexpr uint32_t kFishLogHeaderTag = 0x46534F69;  // "iOSF"
struct HeaderFishLog {
    uint32_t tag;
    uint16_t count;
    uint16_t reserved;
    uint16_t counts[kFishLogCapacity];
};
constexpr size_t kFishLogHeaderOffset = 8;
static_assert(kFishLogHeaderOffset + sizeof(HeaderFishLog) <= sizeof(McHeader::data), "fish log fits the header");

static_assert(jak1::fishing::kFishSpeciesCount <= kFishLogCapacity, "every species has a log slot");

uint16_t gFishLog[kFishLogCapacity] {};

void ReadHeaderFishLog(const McHeader *header, uint16_t *counts) {
    HeaderFishLog log;
    memcpy(&log, header->data + kFishLogHeaderOffset, sizeof(log));
    memset(counts, 0, sizeof(uint16_t) * kFishLogCapacity);
    if (log.tag != kFishLogHeaderTag) return;  // no log: desktop or pre-Fishing save
    memcpy(counts, log.counts, sizeof(uint16_t) * std::min<int>(log.count, kFishLogCapacity));
}

void WriteHeaderFishLog(McHeader *header, const uint16_t *counts) {
    HeaderFishLog log {};
    log.tag = kFishLogHeaderTag;
    log.count = kFishLogCapacity;
    memcpy(log.counts, counts, sizeof(log.counts));
    memcpy(header->data + kFishLogHeaderOffset, &log, sizeof(log));
}

// Open Ocean progress, after the fishing log: its own tag, then the values. Older saves have no tag and read as
// nothing collected.
constexpr uint32_t kOceanHeaderTag = 0x4F534F69;  // "iOSO"
struct HeaderOceanProgress {
    uint32_t tag;
    uint16_t orbs;
    uint8_t flies;
    uint8_t cells;
    uint8_t flags;
    uint8_t reserved[3];
};
constexpr uint8_t kOceanFlagVisited = 1 << 0;
// Set on every save written since the scout fly counter fix (user 2026-10-23: the HUD / pause screen showed the
// level's fly count at sea). Saves without it had their ocean flies counted under the old code: their flies and the
// all-flies cell (bit 5, or bit 7 from the 8-cell layout) are reset once, so the count starts again from 0.
constexpr uint8_t kOceanFlagFliesReset = 1 << 1;
constexpr uint8_t kOceanFlyCellBits = (1 << 5) | (1 << 7);
constexpr size_t kOceanHeaderOffset = kFishLogHeaderOffset + sizeof(HeaderFishLog);
static_assert(kOceanHeaderOffset + sizeof(HeaderOceanProgress) <= sizeof(McHeader::data), "ocean progress fits the header");

OceanProgress gOceanProgress;

void ReadHeaderOceanProgress(const McHeader *header, OceanProgress *progress) {
    HeaderOceanProgress stored;
    memcpy(&stored, header->data + kOceanHeaderOffset, sizeof(stored));
    *progress = {};
    if (stored.tag != kOceanHeaderTag) return;  // desktop or pre-Open Ocean save
    progress->orbs = std::min<uint16_t>(stored.orbs, kOceanOrbTotal);
    progress->flies = stored.flies & 0x7f;
    progress->cells = stored.cells;
    progress->visited = (stored.flags & kOceanFlagVisited) != 0;
    if ((stored.flags & kOceanFlagFliesReset) == 0) {
        NSLog(@"jakIOS: Open Ocean: resetting scout flies 0x%02x and fly cell (save from before the counter fix)",
              progress->flies);
        progress->flies = 0;
        progress->cells &= static_cast<uint8_t>(~kOceanFlyCellBits);
    }
}

void WriteHeaderOceanProgress(McHeader *header, const OceanProgress &progress) {
    HeaderOceanProgress stored {};
    stored.tag = kOceanHeaderTag;
    stored.orbs = progress.orbs;
    stored.flies = progress.flies;
    stored.cells = progress.cells;
    stored.flags = (progress.visited ? kOceanFlagVisited : 0) | kOceanFlagFliesReset;
    memcpy(header->data + kOceanHeaderOffset, &stored, sizeof(stored));
}

// Boat upgrade level, after the Open Ocean progress: its own tag, then the level. Older saves have no tag and
// read as level 1.
constexpr uint32_t kBoatHeaderTag = 0x42534F69;  // "iOSB"
struct HeaderBoatLevel {
    uint32_t tag;
    uint8_t level;
    uint8_t reserved[3];
};
constexpr size_t kBoatHeaderOffset = kOceanHeaderOffset + sizeof(HeaderOceanProgress);
static_assert(kBoatHeaderOffset + sizeof(HeaderBoatLevel) <= sizeof(McHeader::data), "boat level fits the header");

int gBoatLevel = 1;

int ReadHeaderBoatLevel(const McHeader *header) {
    HeaderBoatLevel stored;
    memcpy(&stored, header->data + kBoatHeaderOffset, sizeof(stored));
    if (stored.tag != kBoatHeaderTag) return 1;  // desktop or pre-upgrade save
    return std::clamp<int>(stored.level, 1, kBoatMaxLevel);
}

void WriteHeaderBoatLevel(McHeader *header, int level) {
    HeaderBoatLevel stored {};
    stored.tag = kBoatHeaderTag;
    stored.level = static_cast<uint8_t>(level);
    memcpy(header->data + kBoatHeaderOffset, &stored, sizeof(stored));
}

GoalPointerResolver gResolver = nullptr;
int32_t gLanguage = 0;
Operation gOp;
MemoryCardFile gFiles[4];
int gLastFile = -1;
// Scratch values named after the sceMcGetInfo results the original callbacks reuse.
int32_t gP2 = 0;
int32_t gP4 = 0;
bool gMirrorForSaves = false;
bool gHasLoadedMirror = false;
bool gLoadedMirror = false;

uint8_t *Resolve(uint32_t goalOffset, uint32_t length) {
    return gResolver != nullptr && goalOffset != 0 ? gResolver(goalOffset, length) : nullptr;
}

std::string SaveDirectory() {
    static std::string directory;
    if (directory.empty()) {
        NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                  inDomains:NSUserDomainMask].firstObject;
        NSURL *saves = [[documents URLByAppendingPathComponent:@"saves" isDirectory:YES]
            URLByAppendingPathComponent:@(kSaveDirectoryName) isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:saves withIntermediateDirectories:YES
                                                  attributes:nil error:nil];
        directory = saves.fileSystemRepresentation;
    }
    return directory;
}

// Bank file for (file, bank): the original names are bank0.bin..bank7.bin, two banks per file.
std::string BankPath(int file, int bank) {
    return SaveDirectory() + "/bank" + std::to_string(file * 2 + bank) + ".bin";
}

bool PathExists(const std::string &path, off_t *size = nullptr) {
    struct stat info {};
    if (stat(path.c_str(), &info) != 0) return false;
    if (size != nullptr) *size = info.st_size;
    return true;
}

std::vector<uint8_t> ReadFile(const std::string &path) {
    std::vector<uint8_t> bytes;
    FILE *file = fopen(path.c_str(), "rb");
    if (file == nullptr) return bytes;
    fseek(file, 0, SEEK_END);
    const long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (length > 0) {
        bytes.resize(static_cast<size_t>(length));
        if (fread(bytes.data(), bytes.size(), 1, file) != 1) bytes.clear();
    }
    fclose(file);
    return bytes;
}

// "A questionable checksum used on memory card data."
uint32_t Checksum(const uint8_t *data, int32_t size) {
    if (size < 0) size += 3;
    uint32_t result = 0;
    for (int32_t i = 0; i < size / 4; i++) {
        uint32_t word;
        memcpy(&word, data + i * 4, sizeof(word));
        result = (result << 1) ^ static_cast<uint32_t>(static_cast<int32_t>(result) >> 0x1f) ^ word ^ kMemCardMagic;
    }
    return result ^ 0xedd1e666;
}

bool FileIsPresent(int file, int bank = 0) {
    off_t size = 0;
    // Missing or truncated banks would fail the read, so treat them as absent.
    return PathExists(BankPath(file, bank), &size) && size >= static_cast<off_t>(kTotalBankSize);
}

// pc_update_card. The game polls slot info every frame, and a full scan reads every bank file
// (about 0.5 MB), so the disk is scanned once: saves made here update gFiles directly and nothing
// else writes the save directory while the game runs. last_file still resets on every call.
bool gCardScanned = false;

void UpdateCard() {
    gLastFile = -1;
    if (gCardScanned) return;
    gCardScanned = true;
    for (int file = 0; file < 4; file++) {
        gFiles[file].present = FileIsPresent(file);
        if (!gFiles[file].present) continue;
        std::vector<uint8_t> bank0 = ReadFile(BankPath(file, 0));
        if (bank0.size() < sizeof(McHeader)) {
            gFiles[file].present = 0;
            continue;
        }
        const McHeader *header = reinterpret_cast<const McHeader *>(bank0.data());
        std::vector<uint8_t> bank1;
        uint32_t lastBank = 0;
        if (FileIsPresent(file, 1)) {
            bank1 = ReadFile(BankPath(file, 1));
            if (bank1.size() >= sizeof(McHeader)) {
                const McHeader *header2 = reinterpret_cast<const McHeader *>(bank1.data());
                if (header2->saveCount > header->saveCount) {
                    header = header2;  // use the most recent bank
                    lastBank = 1;
                }
            }
        }
        gFiles[file].lastSavedBank = lastBank;
        gFiles[file].mostRecentSaveCount = header->saveCount;
        memcpy(gFiles[file].data, header->previewData, 64);
        gFiles[file].mirror = HeaderMirrorMode(header);
    }
}

void Finish(StatusCode result) {
    gOp.operation = OperationKind::NoOp;
    gOp.result = result;
}

// Whole save done synchronously (pc_game_save_synch).
void SaveSynchronously() {
    UpdateCard();
    const uint32_t file = gOp.param2;
    if (file >= 4) {
        Finish(StatusCode::InternalError);
        return;
    }
    if (!FileIsPresent(static_cast<int>(file))) {
        gP2 = 0;  // first save: save count 0, first bank
        gP4 = 0;
    } else {
        gP2 = static_cast<int32_t>(gFiles[file].mostRecentSaveCount + 1);
        gP4 = static_cast<int32_t>(gFiles[file].lastSavedBank ^ 1);  // alternate banks
    }
    if (gP2 == 0) gP2 = 1;  // 0 means "never saved"

    const uint8_t *saveData = Resolve(gOp.dataPtr, kBankSize);
    const uint8_t *summary = Resolve(gOp.dataPtr2, 64);
    if (saveData == nullptr || summary == nullptr) {
        Finish(StatusCode::InternalError);
        return;
    }

    McHeader header {};
    header.saveCount = static_cast<uint32_t>(gP2);
    header.checksum = Checksum(saveData, kBankSize);
    header.magic = kMemCardMagic;
    header.saveCount2 = static_cast<uint32_t>(gP2);
    memcpy(header.previewData, summary, 64);
    SetHeaderMirrorMode(&header, gMirrorForSaves);
    WriteHeaderFishLog(&header, gFishLog);
    WriteHeaderOceanProgress(&header, gOceanProgress);
    WriteHeaderBoatLevel(&header, gBoatLevel);

    const std::string path = BankPath(static_cast<int>(file), gP4);
    FILE *fd = fopen(path.c_str(), "wb");
    if (fd == nullptr) {
        NSLog(@"jakIOS: memcard could not open %s for writing (errno %d)", path.c_str(), errno);
        Finish(StatusCode::InternalError);
        return;
    }
    const bool written = fwrite(&header, sizeof(header), 1, fd) == 1 &&
                         fwrite(saveData, kBankSize, 1, fd) == 1 &&
                         fwrite(&header, sizeof(header), 1, fd) == 1;
    const bool closed = fclose(fd) == 0;
    if (!written || !closed) {
        gCardScanned = false;  // the bank on disk may now be partial; rescan on next poll
        Finish(StatusCode::InternalError);
        return;
    }
    gFiles[file].present = 1;
    gFiles[file].mostRecentSaveCount = static_cast<uint32_t>(gP2);
    gFiles[file].lastSavedBank = static_cast<uint32_t>(gP4);
    memcpy(gFiles[file].data, summary, 64);
    gFiles[file].mirror = gMirrorForSaves;
    gLastFile = static_cast<int>(file);
    NSLog(@"jakIOS: memcard saved file %u bank %d (save count %d%s)", file, gP4, gP2,
          gMirrorForSaves ? ", mirror mode" : "");
    Finish(StatusCode::OK);
}

bool HeaderValid(const McHeader *header, const McHeader *footer) {
    const uint32_t count = header->saveCount;
    if (header->saveCount2 != count || footer->saveCount != count || footer->saveCount2 != count) return false;
    if (header->magic != kMemCardMagic || footer->magic != kMemCardMagic) return false;
    if (header->checksum != footer->checksum) return false;
    return Checksum(reinterpret_cast<const uint8_t *>(header + 1), kBankSize) == header->checksum;
}

bool HeaderEmpty(const McHeader *header) {
    return header->saveCount == 0 && header->checksum == 0 && header->magic == 0 && header->saveCount2 == 0;
}

// Whole load done synchronously (pc_game_load_synch / pc_game_load_open_file). The GOAL buffer
// holds both raw banks back to back; the chosen bank's payload is moved to its start.
void LoadSynchronously() {
    UpdateCard();
    const uint32_t file = gOp.param2;
    uint8_t *buffer = file < 4 ? Resolve(gOp.dataPtr, kTotalBankSize * 2) : nullptr;
    if (buffer == nullptr) {
        Finish(StatusCode::InternalError);
        return;
    }

    int banksRead = 0;
    for (int bank = 0; bank < 2; bank++) {
        const std::string path = BankPath(static_cast<int>(file), bank);
        if (bank > 0 && !PathExists(path)) break;
        FILE *fd = fopen(path.c_str(), "rb");
        if (fd == nullptr) {
            Finish(StatusCode::InternalError);
            return;
        }
        const bool read = fread(buffer + bank * kTotalBankSize, kTotalBankSize, 1, fd) == 1;
        fclose(fd);
        if (!read) {
            Finish(StatusCode::InternalError);
            return;
        }
        banksRead++;
    }

    const McHeader *headers[2];
    const McHeader *footers[2];
    bool ok[2];
    for (int bank = 0; bank < 2; bank++) {
        headers[bank] = reinterpret_cast<const McHeader *>(buffer + bank * kTotalBankSize);
        footers[bank] = reinterpret_cast<const McHeader *>(buffer + bank * kTotalBankSize + sizeof(McHeader) + kBankSize);
        ok[bank] = bank < banksRead && HeaderValid(headers[bank], footers[bank]);
    }

    if (!ok[0] && !ok[1]) {
        if (HeaderEmpty(headers[0]) && HeaderEmpty(headers[1])) {
            // A fresh file that was never saved to.
            gLastFile = static_cast<int>(file);
            Finish(StatusCode::NewGame);
        } else {
            NSLog(@"jakIOS: memcard file %u is corrupted", file);
            Finish(StatusCode::ReadError);
        }
        return;
    }

    int bank = 0;
    if (!ok[0] || !ok[1]) {
        bank = ok[1] ? 1 : 0;
    } else {
        bank = headers[0]->saveCount <= headers[1]->saveCount ? 1 : 0;
    }
    const uint32_t saveCount = headers[bank]->saveCount;
    const bool mirror = HeaderMirrorMode(headers[bank]);  // read before the payload overwrites it
    ReadHeaderFishLog(headers[bank], gFishLog);
    ReadHeaderOceanProgress(headers[bank], &gOceanProgress);
    gBoatLevel = ReadHeaderBoatLevel(headers[bank]);
    memmove(buffer, buffer + bank * kTotalBankSize + sizeof(McHeader), kBankSize);
    gLastFile = static_cast<int>(file);
    gFiles[file].mostRecentSaveCount = saveCount;
    gFiles[file].lastSavedBank = static_cast<uint32_t>(bank);
    gFiles[file].mirror = mirror;
    gLoadedMirror = mirror;
    gHasLoadedMirror = true;
    NSLog(@"jakIOS: memcard loaded file %u bank %d (save count %u%s)", file, bank, saveCount,
          mirror ? ", mirror mode" : "");
    Finish(StatusCode::OK);
}

bool StartOperation(OperationKind kind, int32_t cardIndex, int32_t fileIndex, uint32_t data, uint32_t data2) {
    if (gOp.operation != OperationKind::NoOp) return false;
    gOp.operation = kind;
    gOp.result = StatusCode::Busy;
    gOp.retryCount = 100;
    gOp.param = static_cast<uint32_t>(cardIndex);
    gOp.param2 = static_cast<uint32_t>(fileIndex);
    gOp.dataPtr = data;
    gOp.dataPtr2 = data2;
    return true;
}

}  // namespace

void Initialize(GoalPointerResolver resolver) {
    gResolver = resolver;
    gLanguage = 0;
    gOp = {};
    for (MemoryCardFile &file : gFiles) file = {};
    gCardScanned = false;
    gLastFile = -1;
    gP2 = 0;
    gP4 = 0;
    gMirrorForSaves = false;
    gHasLoadedMirror = false;
    gLoadedMirror = false;
    ResetFishLog();
    ResetOceanProgress();
    ResetBoatLevel();
}

void SetLanguage(int32_t language) {
    gLanguage = language;
}

void Run() {
    // There are no asynchronous Sony calls: requested operations complete within one mc-run.
    // Format/unformat/create-file are never requested because the "card" is always formatted.
    if (gOp.operation == OperationKind::Save) {
        SaveSynchronously();
    } else if (gOp.operation == OperationKind::Load) {
        if (!FileIsPresent(static_cast<int>(gOp.param2))) {
            Finish(StatusCode::NoMemory);  // nothing saved in that file
        } else {
            LoadSynchronously();
        }
    }
}

uint64_t Format(int32_t) {
    return static_cast<uint64_t>(StatusCode::OK);
}

uint64_t Unformat(int32_t) {
    return static_cast<uint64_t>(StatusCode::OK);
}

uint64_t CreateFile(int32_t, uint32_t) {
    return static_cast<uint64_t>(StatusCode::OK);
}

uint64_t Save(int32_t cardIndex, int32_t fileIndex, uint32_t saveData, uint32_t summaryData) {
    return StartOperation(OperationKind::Save, cardIndex, fileIndex, saveData, summaryData) ? 1 : 0;
}

uint64_t Load(int32_t cardIndex, int32_t fileIndex, uint32_t data) {
    return StartOperation(OperationKind::Load, cardIndex, fileIndex, data, 0) ? 1 : 0;
}

uint32_t CheckResult() {
    return static_cast<uint32_t>(gOp.result);
}

void GetSlotInfo(int32_t, uint32_t info) {
    // The slot is ignored: there is a single always-present, formatted "card".
    uint8_t *bytes = Resolve(info, sizeof(GoalSlotInfo));
    if (bytes == nullptr) return;
    UpdateCard();
    GoalSlotInfo slot {};
    slot.handle = kPCMemCardHandle;
    slot.known = 1;
    slot.formatted = 1;
    slot.initted = 1;
    slot.lastFile = gLastFile;
    slot.memRequired = kSaveSize;
    slot.memActual = kSaveSize;
    for (int file = 0; file < 4; file++) {
        slot.files[file].present = gFiles[file].present;
        memcpy(slot.files[file].data, gFiles[file].data, 64);
    }
    memcpy(bytes, &slot, sizeof(slot));
}

void SetMirrorModeForSaves(bool mirror) {
    gMirrorForSaves = mirror;
}

bool FilePresent(int32_t fileIndex) {
    UpdateCard();
    return fileIndex >= 0 && fileIndex < 4 && gFiles[fileIndex].present != 0;
}

bool FileHasMirrorMode(int32_t fileIndex) {
    return FilePresent(fileIndex) && gFiles[fileIndex].mirror;
}

bool TakeLoadedMirrorMode(bool *mirror) {
    if (!gHasLoadedMirror) return false;
    gHasLoadedMirror = false;
    *mirror = gLoadedMirror;
    return true;
}

void ResetFishLog() {
    memset(gFishLog, 0, sizeof(gFishLog));
}

uint16_t FishCaughtCount(int species) {
    return species >= 0 && species < kFishLogCapacity ? gFishLog[species] : 0;
}

void AddFishCatch(int species) {
    if (species >= 0 && species < kFishLogCapacity && gFishLog[species] != 0xFFFF) gFishLog[species]++;
}

void ResetOceanProgress() {
    gOceanProgress = {};
}

OceanProgress GetOceanProgress() {
    return gOceanProgress;
}

void SetOceanProgress(const OceanProgress &progress) {
    gOceanProgress = progress;
    gOceanProgress.orbs = std::min<uint16_t>(gOceanProgress.orbs, kOceanOrbTotal);
    gOceanProgress.flies &= 0x7f;
}

void ResetBoatLevel() {
    gBoatLevel = 1;
}

int GetBoatLevel() {
    return gBoatLevel;
}

void SetBoatLevel(int level) {
    gBoatLevel = std::clamp(level, 1, kBoatMaxLevel);
}

}  // namespace jak1::memcard
