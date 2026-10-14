#pragma once

// Native ports of the Jak 1 C-kernel services needed to load levels on stock iOS:
// symbol/type interning (kscheme.cpp), kmalloc on GOAL kheaps (kmalloc.cpp), the v2/v4
// data-object linker (klink.cpp), and the overlord's RPC-DGO loader (overlord/jak1/iso.cpp).
//
// Code (v3) objects cannot be linked at runtime on iOS because executable code must be signed.
// Engine code (and the title level's code) was linked when the AOT image was captured; level
// code was prelinked at fixed addresses by tools/ios/aot_level_code_link.py and is embedded in
// the signed image (see LevelCodeObject). Code objects in a DGO are therefore never linked from
// the DGO bytes; only data objects (art, textures, bsp) are.

#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace jak1 {

// A prelinked level code object. All links except type pointers were resolved at build time;
// segment addresses are GOAL offsets inside the level-code region.
struct LevelCodeObject {
    struct TypeLink {
        std::string name;
        uint32_t methodCount = 0;
        std::vector<uint32_t> locations;  // GOAL addresses that receive the type pointer
    };
    uint32_t main = 0;
    uint32_t mainSize = 0;
    uint32_t top = 0;
    uint32_t topSize = 0;
    uint32_t entry = 0;  // top-level function, or 0
    std::vector<TypeLink> types;
};

struct LevelCode {
    uint32_t regionBase = 0;
    uint32_t regionSize = 0;
    const uint8_t *signedRegion = nullptr;  // pristine bytes (signed text at x27 + regionBase)
    // Symbols created by the build-time linker, in creation order, with their expected slots.
    std::vector<std::pair<std::string, uint32_t>> symbols;
    std::unordered_map<std::string, LevelCodeObject> objects;
};

struct KernelEnvironment {
    uint8_t *memory = nullptr;     // base of the 128 MiB GOAL arena (x22)
    uint32_t memorySize = 0;
    uint32_t s7 = 0;               // symbol table midpoint
    std::string contentPath;       // imported game data (contains DGO/)
    // Allocates from the global heap. Returns a GOAL offset, or 0 on failure.
    std::function<uint32_t(uint32_t size, uint32_t alignment)> allocateGlobal;
    // Calls a GOAL function with three arguments and returns its result.
    std::function<uint64_t(uint32_t function, uint64_t a0, uint64_t a1, uint64_t a2)> callGoal;
    // Resolves symbols captured in the AOT image before probing the mutable GOAL hash table.
    std::function<uint32_t(const std::string &name)> findExistingSymbol;
    // Notified whenever a symbol is created, so the host can keep its name cache current.
    std::function<void(const std::string &name, uint32_t symbol)> onSymbolCreated;
    // Lets the host disable an optional bundled DGO without changing normal disc content.
    std::function<bool(const std::string &name)> canLoadDgo;
    // Lets the host drop single objects from a DGO (e.g. art it keeps resident elsewhere).
    // Never called for the last object (the level bsp).
    std::function<bool(const std::string &dgo, const std::string &object)> skipDgoObject;
};

class Kernel {
public:
    explicit Kernel(KernelEnvironment environment);

    // kscheme.cpp
    uint32_t findSymbol(const char *name);
    uint32_t internSymbol(const char *name);
    uint32_t internType(const char *name, uint32_t methodCount);
    // kscheme.cpp new_type: the `new` method of `type`, called by every runtime deftype.
    uint32_t newType(uint32_t symbol, uint32_t parent, uint64_t flags);

    // Installs the prelinked level code: copies the region into the arena and interns the
    // linker's new symbols in order. Must run before any GOAL code so the symbol-table slots
    // match the build-time simulation. Returns false (and disables level code) on a mismatch.
    bool installLevelCode(LevelCode levelCode);

    // Restores a prelinked object's pristine segments and applies its type links without running
    // it. Returns its top-level entry, 1 if it has none, or 0 if absent. Lets the host run iOS overrides of captured
    // objects whose DGO never loads on iOS (title-obs: the title level is in the snapshot).
    uint32_t prepareLevelCodeObject(const std::string &name);
    // Links a prelinked level code object outside a DGO load and runs its top-level.
    bool linkPrelinkedCodeObject(const std::string &name);
    bool hasLevelCode() const { return _levelCodeInstalled; }
    // Swaps the GOAL call bridge (e.g. to an arena-stack bridge for links run between GOAL frames).
    std::function<uint64_t(uint32_t, uint64_t, uint64_t, uint64_t)> exchangeCallGoal(
        std::function<uint64_t(uint32_t, uint64_t, uint64_t, uint64_t)> callGoal) {
        std::swap(_env.callGoal, callGoal);
        return callGoal;
    }

    // kmalloc.cpp: allocate from the kheapinfo at `heap` (a GOAL offset).
    uint32_t kmalloc(uint32_t heap, uint32_t size, uint32_t flags);

    // klink.cpp: `link-begin` / `link-resume`. Returns nonzero when linking has finished.
    uint64_t linkBegin(uint32_t objectData, uint32_t name, uint32_t size, uint32_t heap,
                       uint32_t flags);
    uint64_t linkResume();
    // Entry of the most recent data object linked by linkBegin, or 0 if it failed or was code.
    uint32_t lastLinkEntry() const { return _link.entry; }

    // kscheme.cpp make_string_from_c: allocates a GOAL string on the global heap.
    uint32_t makeString(const char *text);

    // overlord RPC-DGO: handles `rpc-call` on the DGO channel.
    void dgoRpc(uint32_t function, uint32_t sendBuffer, uint32_t receiveBuffer);
    bool isDgoLoading() const { return _dgo.active; }

private:
    template <typename T> T read(uint32_t offset) const;
    template <typename T> void write(uint32_t offset, T value);
    bool inArena(uint32_t offset, uint32_t length) const;
    const char *cString(uint32_t offset) const;

    uint32_t findSymbolInArea(uint32_t hash, const char *name, uint32_t start, uint32_t end);
    uint32_t findSymbolInFixedArea(uint32_t hash, const char *name);

    bool linkDataObject();
    bool linkLevelCodeObject(const std::string &name, uint32_t flags);
    bool writeNextDgoObject(uint32_t destination);
    void endCameraOutroInRange(uint32_t start, uint32_t end);

    KernelEnvironment _env;
    uint32_t _crcTable[256] {};
    uint32_t _symbolSlot = 0;
    LevelCode _levelCode;
    bool _levelCodeInstalled = false;

    // Linker state for the current object.
    struct LinkState {
        uint32_t objectData = 0;
        uint32_t linkBlock = 0;
        uint32_t codeSize = 0;
        uint32_t heap = 0;
        uint32_t heapTop = 0;
        uint32_t entry = 0;
        uint32_t version = 0;
        std::string name;
        bool skip = false;
    } _link;

    // RPC-DGO state for the DGO being loaded.
    struct DgoState {
        std::vector<uint8_t> file;
        std::vector<size_t> objectOffsets;
        size_t nextObject = 0;
        uint32_t buffer1 = 0;
        uint32_t buffer2 = 0;
        bool active = false;
        std::string name;
    } _dgo;
};

} // namespace jak1
