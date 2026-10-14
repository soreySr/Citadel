#include "Jak1Kernel.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace jak1 {
namespace {

// common/goal_constants.h (OpenGOAL doubles the original 8192-entry table).
constexpr uint32_t kMaxSymbols = 16384;
constexpr uint32_t kSymbolInfoOffset = kMaxSymbols * 8 - 4;
constexpr uint32_t kSymbolTableEnd = kMaxSymbols - 32;
constexpr int kBitsForSymbol = 15; // bits_for_sym(): log2(kMaxSymbols) + 1

// common/symbols.h (jak1)
constexpr uint32_t kFixSymStringType = 0x20;
constexpr uint32_t kFixSymSymbolType = 0x28;
constexpr uint32_t kFixSymTypeType = 0x30;
constexpr int32_t kFixSymEmptyPair = -0xa;
constexpr uint32_t kFixFixedSymEndOffset = 0x1d0;
constexpr uint32_t kEmptyHash = 0x8454B6E6;
constexpr uint32_t kCrcPoly = 0x04c11db7;

constexpr uint32_t kDefaultMethodCount = 12;
constexpr uint32_t kFallbackUnknownMethodCount = 44;

// game/kernel/common/memory_layout.h
constexpr uint32_t kGlobalHeapInfo = 0x13AD00;
constexpr uint32_t kLinkControlNameAddress = 0x13AD80;

// game/kernel/common/kmalloc.h
constexpr uint32_t kKmallocTop = 0x2000;
constexpr uint32_t kKmallocMemset = 0x1000;
constexpr uint32_t kKmallocAlign256 = 0x100;
constexpr uint32_t kKmallocAlign64 = 0x40;
constexpr uint32_t kKmallocAlign16 = 0x10;

// kheapinfo field offsets.
constexpr uint32_t kHeapBase = 0;
constexpr uint32_t kHeapTop = 4;
constexpr uint32_t kHeapCurrent = 8;

constexpr uint32_t kLinkFlagExecute = 4;
constexpr uint32_t kRelocateMethod = 7;
constexpr uint32_t kObjV2CloseEnough = 0x90;

// common/dgo_rpc_types.h
constexpr uint32_t kDgoLoad = 0;
constexpr uint32_t kDgoLoadNext = 1;
constexpr uint32_t kDgoCancel = 2;
constexpr uint16_t kDgoResultDone = 0;
constexpr uint16_t kDgoResultError = 1;
constexpr uint16_t kDgoResultMore = 2;
constexpr uint16_t kDgoResultAborted = 3;

constexpr size_t kDgoHeaderSize = 64;
constexpr size_t kObjectHeaderSize = 64;

struct DgoCommand {
    uint16_t reserved;
    uint16_t result;
    uint32_t buffer1;
    uint32_t buffer2;
    uint32_t bufferHeapTop;
    char name[16];
};
static_assert(sizeof(DgoCommand) == 32, "RPC_Dgo_Cmd without padding");

// load-begin (level.gc) allocates two 2 MiB DGO buffers from the top of the level heap.
constexpr uint32_t kDgoLevelBufferSize = 2 * 1024 * 1024;

// camera-master (camera-h.gc) outro fields, verified against the captured image's layout:
// outro-curve (curve :inline) = cverts, num-cverts, knots, num-knots, length; then outro-t,
// outro-t-step, outro-exit-value.
constexpr uint32_t kCameraOutroCurveCverts = 0x92c;
constexpr uint32_t kCameraOutroCurveKnots = 0x934;
constexpr uint32_t kCameraOutroT = 0x940;
constexpr uint32_t kCameraOutroTStep = 0x944;
constexpr uint32_t kCameraOutroExitValue = 0x948;

} // namespace

Kernel::Kernel(KernelEnvironment environment) : _env(std::move(environment)) {
    // game/kernel/common/kscheme.cpp init_crc
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t n = i << 24;
        for (int j = 0; j < 8; j++) {
            n = (n & 0x80000000) ? (n << 1) ^ kCrcPoly : (n << 1);
        }
        _crcTable[i] = n;
    }
}

template <typename T> T Kernel::read(uint32_t offset) const {
    T value {};
    if (inArena(offset, sizeof(T))) {
        memcpy(&value, _env.memory + offset, sizeof(T));
    }
    return value;
}

template <typename T> void Kernel::write(uint32_t offset, T value) {
    if (inArena(offset, sizeof(T))) {
        memcpy(_env.memory + offset, &value, sizeof(T));
    }
}

bool Kernel::inArena(uint32_t offset, uint32_t length) const {
    return static_cast<uint64_t>(offset) + length <= _env.memorySize;
}

const char *Kernel::cString(uint32_t offset) const {
    return inArena(offset, 1) ? reinterpret_cast<const char *>(_env.memory + offset) : "";
}

// ---------------------------------------------------------------------------------------------
// Symbols and types (game/kernel/jak1/kscheme.cpp)

uint32_t Kernel::findSymbolInFixedArea(uint32_t hash, const char *name) {
    for (uint32_t sym = _env.s7; sym < _env.s7 + kFixFixedSymEndOffset; sym += 8) {
        if (read<uint32_t>(sym + kSymbolInfoOffset) == hash) {
            const uint32_t string = read<uint32_t>(sym + kSymbolInfoOffset + 4);
            if (strcmp(cString(string + 4), name) == 0) {
                return sym;
            }
        }
    }
    return 0;
}

uint32_t Kernel::findSymbolInArea(uint32_t hash, const char *name, uint32_t start, uint32_t end) {
    for (uint32_t sym = start; sym < end; sym += 8) {
        const uint32_t symbolHash = read<uint32_t>(sym + kSymbolInfoOffset);
        if (symbolHash == hash) {
            const uint32_t string = read<uint32_t>(sym + kSymbolInfoOffset + 4);
            if (strcmp(cString(string + 4), name) == 0) {
                return sym;
            }
        }
        if (symbolHash == 0) {
            // Open slot: the symbol is not in the table (unless it is a fixed symbol).
            _symbolSlot = sym;
            return findSymbolInFixedArea(hash, name);
        }
    }
    return 1; // reached the end; the probe must wrap
}

uint32_t Kernel::findSymbol(const char *name) {
    _symbolSlot = 0;
    uint32_t crc = 0;
    for (const char *c = name; *c; c++) {
        crc = _crcTable[crc >> 24] ^ ((crc << 8) | static_cast<uint8_t>(*c));
    }
    const uint32_t hash = ~crc;
    if (hash == kEmptyHash && strcmp(name, "_empty_") == 0) {
        return static_cast<uint32_t>(static_cast<int64_t>(_env.s7) + kFixSymEmptyPair);
    }

    const uint32_t symbolTable = _env.s7 - 4 - (kMaxSymbols / 2) * 8;
    const uint32_t symbolTable2 = symbolTable + 4;
    const uint32_t lastSymbol = symbolTable + kSymbolTableEnd * 8;
    const int bits = kBitsForSymbol - 1;
    const int32_t sh1 = static_cast<int32_t>(hash << (32 - bits));
    const int32_t sh2 = sh1 >> (32 - bits - 3);
    const uint32_t start = static_cast<uint32_t>(static_cast<int64_t>(_env.s7) + sh2);

    uint32_t probe = 0;
    if (sh2 > 0) {
        probe = findSymbolInArea(hash, name, start, lastSymbol);
        if (probe == 1) {
            probe = findSymbolInArea(hash, name, symbolTable2, _env.s7 - 0x10);
        }
    } else {
        probe = findSymbolInArea(hash, name, start, _env.s7 - 0x10);
        if (probe == 1) {
            probe = findSymbolInArea(hash, name, _env.s7 + kFixFixedSymEndOffset, lastSymbol);
        }
    }
    return probe == 1 ? findSymbolInFixedArea(hash, name) : probe;
}

uint32_t Kernel::makeString(const char *text) {
    const uint32_t length = static_cast<uint32_t>(strlen(text));
    const uint32_t memorySize = std::max<uint32_t>(length + 1, 8);
    const uint32_t raw = _env.allocateGlobal ? _env.allocateGlobal(memorySize + 8, 16) : 0;
    if (raw == 0) {
        return 0;
    }
    memset(_env.memory + raw, 0, memorySize + 8);
    write<uint32_t>(raw, read<uint32_t>(_env.s7 + kFixSymStringType));
    const uint32_t string = raw + 4;
    write<uint32_t>(string, length);
    memcpy(_env.memory + string + 4, text, length + 1);
    return string;
}

uint32_t Kernel::internSymbol(const char *name) {
    if (_env.findExistingSymbol) {
        const uint32_t captured = _env.findExistingSymbol(name);
        if (captured != 0) {
            return captured;
        }
    }
    const uint32_t existing = findSymbol(name);
    if (existing != 0) {
        return existing;
    }
    const uint32_t symbol = _symbolSlot;
    if (symbol == 0) {
        fprintf(stderr, "jak1::Kernel: symbol table full, cannot intern %s\n", name);
        return 0;
    }
    uint32_t crc = 0;
    for (const char *c = name; *c; c++) {
        crc = _crcTable[crc >> 24] ^ ((crc << 8) | static_cast<uint8_t>(*c));
    }
    write<uint32_t>(symbol - 4, read<uint32_t>(_env.s7 + kFixSymSymbolType));
    write<uint32_t>(symbol + kSymbolInfoOffset + 4, makeString(name));
    write<uint32_t>(symbol + kSymbolInfoOffset, ~crc);
    if (_env.onSymbolCreated) {
        _env.onSymbolCreated(name, symbol);
    }
    return symbol;
}

uint32_t Kernel::internType(const char *name, uint32_t methodCount) {
    const uint32_t symbol = internSymbol(name);
    if (symbol == 0) {
        return 0;
    }
    const uint32_t existing = read<uint32_t>(symbol);
    if (existing != 0) {
        return existing;
    }
    uint32_t methods = methodCount;
    if (methods == 0) {
        methods = kDefaultMethodCount;
    } else if (methods == 1) {
        // v2/v4 data objects don't know method counts and pass 1.
        methods = kFallbackUnknownMethodCount;
    }
    // GOAL's method-set! permits installation by method ID beyond num-methods. Level code uses
    // this for late virtual states, so reserve the full method ID range for host-created types.
    // num-methods remains the captured/requested logical count; this only supplies safe backing.
    const uint32_t allocatedMethods = std::max<uint32_t>(methods, 128);
    const uint32_t size = (4 * allocatedMethods + 0x23) & 0xfffffff0;
    const uint32_t raw = _env.allocateGlobal ? _env.allocateGlobal(size + 4, 16) : 0;
    if (raw == 0) {
        return 0;
    }
    memset(_env.memory + raw, 0, size + 4);
    write<uint32_t>(raw, read<uint32_t>(_env.s7 + kFixSymTypeType));
    const uint32_t type = raw + 4;
    write<uint32_t>(symbol, type);           // symbol value
    write<uint32_t>(type + 0, symbol);       // type->symbol
    write<uint16_t>(type + 0xe, static_cast<uint16_t>(methods)); // type->num_methods

    // On desktop a type referenced by data before its deftype gets defined when the level's code
    // links. Level code isn't in the iOS image, so these placeholders stay undefined forever, yet
    // entity-actor birth! stamps them onto processes it then abandons; heap compaction later calls
    // their (null) relocate method. Give placeholders `process`'s layout and base methods. Slots
    // past process's own methods (e.g. init-from-entity!) stay 0, so birth! still declines them.
    const uint32_t processSymbol = findSymbol("process");
    const uint32_t processType = processSymbol != 0 ? read<uint32_t>(processSymbol) : 0;
    if (processType != 0 && processType != type && inArena(processType, 0x10)) {
        const uint16_t processMethods = read<uint16_t>(processType + 0xe);
        write<uint32_t>(type + 0x4, processType);                          // parent
        write<uint16_t>(type + 0x8, read<uint16_t>(processType + 0x8));    // allocated-size
        write<uint16_t>(type + 0xa, read<uint16_t>(processType + 0xa));    // padded-size
        write<uint16_t>(type + 0xc, read<uint16_t>(processType + 0xc));    // heap-base
        for (uint32_t method = 0; method < std::min<uint32_t>(processMethods, methods); method++) {
            write<uint32_t>(type + 0x10 + 4 * method, read<uint32_t>(processType + 0x10 + 4 * method));
        }
    }
    return type;
}

uint32_t Kernel::newType(uint32_t symbol, uint32_t parent, uint64_t flags) {
    uint32_t methods = static_cast<uint32_t>((flags >> 32) & 0xffff);
    if (methods == 0) {
        methods = kDefaultMethodCount;
    }
    const char *name = cString(read<uint32_t>(symbol + kSymbolInfoOffset + 4) + 4);
    const uint32_t type = internType(name, methods);
    if (type == 0 || !inArena(parent, 0x10)) {
        fprintf(stderr, "jak1::Kernel: new-type %s failed (parent 0x%x)\n", name, parent);
        return type;
    }
    const uint16_t existingMethods = read<uint16_t>(type + 0xe);
    if (((4 * existingMethods + 0x23) & 0xfffffff0) < ((4 * methods + 0x23) & 0xfffffff0)) {
        // Upstream asserts: the type object is too small for the requested methods.
        fprintf(stderr, "jak1::Kernel: new-type %s wants %u methods but has %u\n", name, methods,
                existingMethods);
        methods = existingMethods;
    }
    // Copy the parent's methods. Like upstream, this uses the child's method count.
    for (uint32_t method = 0; method < methods; method++) {
        write<uint32_t>(type + 0x10 + 4 * method, read<uint32_t>(parent + 0x10 + 4 * method));
    }
    // set_type_values
    const uint16_t allocatedSize = static_cast<uint16_t>(flags & 0xffff);
    write<uint32_t>(type + 0x4, parent);
    write<uint16_t>(type + 0x8, allocatedSize);
    write<uint16_t>(type + 0xc, static_cast<uint16_t>((flags >> 16) & 0xffff));
    write<uint16_t>(type + 0xa, static_cast<uint16_t>((allocatedSize + 0xf) & 0xfff0));
    const uint16_t newMethods = static_cast<uint16_t>((flags >> 32) & 0xffff);
    if (read<uint16_t>(type + 0xe) < newMethods) {
        write<uint16_t>(type + 0xe, newMethods);
    }
    return type;
}

// ---------------------------------------------------------------------------------------------
// Prelinked level code (tools/ios/aot_level_code_link.py)

bool Kernel::installLevelCode(LevelCode levelCode) {
    _levelCodeInstalled = false;
    if (levelCode.signedRegion == nullptr || levelCode.regionSize == 0 ||
        !inArena(levelCode.regionBase, levelCode.regionSize)) {
        fprintf(stderr, "jak1::Kernel: level code region is invalid\n");
        return false;
    }
    // Statics are addressed through the writable arena (x22), code through the signed view (x27).
    memcpy(_env.memory + levelCode.regionBase, levelCode.signedRegion, levelCode.regionSize);
    for (const auto &[name, expected] : levelCode.symbols) {
        const uint32_t symbol = internSymbol(name.c_str());
        if (symbol != expected) {
            fprintf(stderr, "jak1::Kernel: level code symbol %s landed at 0x%x, expected 0x%x; "
                    "level code disabled\n", name.c_str(), symbol, expected);
            return false;
        }
    }
    _levelCode = std::move(levelCode);
    _levelCodeInstalled = true;
    fprintf(stderr, "jak1::Kernel: installed %zu prelinked level code objects (%zu symbols)\n",
            _levelCode.objects.size(), _levelCode.symbols.size());
    return true;
}

bool Kernel::linkLevelCodeObject(const std::string &name, uint32_t flags) {
    const uint32_t entry = prepareLevelCodeObject(name);
    if (entry == 0) {
        return false;
    }
    if ((flags & kLinkFlagExecute) && entry != 1 && _env.callGoal) {
        _env.callGoal(entry, 0, 0, 0);
    }
    return true;
}

bool Kernel::linkPrelinkedCodeObject(const std::string &name) {
    return linkLevelCodeObject(name, kLinkFlagExecute);
}

uint32_t Kernel::prepareLevelCodeObject(const std::string &name) {
    if (!_levelCodeInstalled) {
        return 0;
    }
    const auto found = _levelCode.objects.find(name);
    if (found == _levelCode.objects.end()) {
        return 0;
    }
    const LevelCodeObject &object = found->second;
    const auto restore = [&](uint32_t address, uint32_t size) {
        if (size != 0 && address >= _levelCode.regionBase &&
            address + size <= _levelCode.regionBase + _levelCode.regionSize) {
            memcpy(_env.memory + address,
                   _levelCode.signedRegion + (address - _levelCode.regionBase), size);
        }
    };
    // Reloading a level must see pristine statics, as if the object had been linked fresh.
    restore(object.main, object.mainSize);
    restore(object.top, object.topSize);
    for (const LevelCodeObject::TypeLink &link : object.types) {
        const uint32_t type = internType(link.name.c_str(), link.methodCount);
        for (const uint32_t location : link.locations) {
            write<uint32_t>(location, type);
        }
    }
    fprintf(stderr, "jak1::Kernel: linked prelinked code object %s (main 0x%x+0x%x)\n",
            name.c_str(), object.main, object.mainSize);
    // 1 = linked but has no top-level to run.
    return object.entry != 0 ? object.entry : 1;
}

// ---------------------------------------------------------------------------------------------
// kmalloc (game/kernel/common/kmalloc.cpp)

uint32_t Kernel::kmalloc(uint32_t heap, uint32_t size, uint32_t flags) {
    uint32_t alignment = flags & 0xfff;
    if (heap == 0 || heap == kGlobalHeapInfo) {
        // The host owns the global heap on iOS.
        const uint32_t align = alignment == kKmallocAlign256 ? 256 :
            alignment == kKmallocAlign64 ? 64 : 16;
        const uint32_t result = _env.allocateGlobal ? _env.allocateGlobal(size, align) : 0;
        if (result != 0 && (flags & kKmallocMemset)) {
            memset(_env.memory + result, 0, size);
        }
        return result;
    }

    const uint32_t current = read<uint32_t>(heap + kHeapCurrent);
    const uint32_t top = read<uint32_t>(heap + kHeapTop);
    uint32_t start = 0;
    if (!(flags & kKmallocTop)) {
        if (alignment == kKmallocAlign64) {
            start = (current + 0x3f) & 0xffffffc0;
        } else if (alignment == kKmallocAlign256) {
            start = (current + 0xff) & 0xffffff00;
        } else {
            start = (current + 0xf) & 0xfffffff0;
        }
        if (size == 0) {
            return start;
        }
        const uint64_t end = static_cast<uint64_t>(start) + size;
        if (end > top) {
            fprintf(stderr, "jak1::Kernel: kmalloc of %u bytes failed in heap 0x%x\n", size, heap);
            return 0;
        }
        write<uint32_t>(heap + kHeapCurrent, static_cast<uint32_t>(end));
    } else {
        if (alignment == 0) {
            alignment = kKmallocAlign16;
        }
        start = (top - size) & (0u - alignment);
        if (size == 0) {
            return start;
        }
        if (current >= start) {
            fprintf(stderr, "jak1::Kernel: kmalloc top of %u bytes failed in heap 0x%x\n", size, heap);
            return 0;
        }
        write<uint32_t>(heap + kHeapTop, start);
    }
    if ((flags & kKmallocMemset) && inArena(start, size)) {
        memset(_env.memory + start, 0, size);
    }
    return start;
}

// ---------------------------------------------------------------------------------------------
// Data-object linker (game/kernel/common/klink.cpp jak1_jak2_begin, jak1/klink.cpp work_v2)

uint64_t Kernel::linkBegin(uint32_t objectData, uint32_t name, uint32_t size, uint32_t heap,
                           uint32_t flags) {
    _link = LinkState();
    _link.name = cString(name);
    fprintf(stderr, "jak1::Kernel: link-begin %s size=%u heap=0x%x flags=0x%x\n",
            _link.name.c_str(), size, heap, flags);
    _link.heap = heap;
    _link.heapTop = read<uint32_t>(heap + kHeapTop);

    if (read<uint32_t>(objectData) != 0xffffffff) {
        // A code object. The PS2 code in the DGO can't run; its signed ARM64 replacement is
        // either prelinked level code or engine/title code captured in the AOT image.
        std::string objectName = _link.name;
        const size_t slash = objectName.find_last_of("/\\");
        if (slash != std::string::npos) {
            objectName = objectName.substr(slash + 1);
        }
        if (objectName.size() > 2 && objectName.compare(objectName.size() - 2, 2, ".o") == 0) {
            objectName.resize(objectName.size() - 2);
        }
        if (!linkLevelCodeObject(objectName, flags)) {
            fprintf(stderr, "jak1::Kernel: skipping code object %s (provided by the signed image)\n",
                    _link.name.c_str());
        }
        return 1;
    }

    _link.version = read<uint32_t>(objectData + 8);
    if (_link.version < 4) {
        const uint32_t headerLength = read<uint32_t>(objectData + 4);
        _link.linkBlock = objectData + 4;
        _link.objectData = objectData + headerLength;
        _link.codeSize = size - headerLength;
        const uint32_t heapBase = read<uint32_t>(heap + kHeapBase);
        const uint32_t heapTop = read<uint32_t>(heap + kHeapTop);
        const uint32_t heapCurrent = read<uint32_t>(heap + kHeapCurrent);
        if (_link.linkBlock < heapBase || _link.linkBlock >= heapTop) {
            // Link block is outside the heap; if the data is inside it, reclaim from there.
            if (heapBase <= _link.objectData && _link.objectData < heapTop &&
                _link.objectData < heapCurrent) {
                write<uint32_t>(heap + kHeapCurrent, _link.objectData);
            }
        } else {
            // Move the link block to the top of the heap so its space can be reclaimed.
            const uint32_t moved = kmalloc(heap, headerLength, kKmallocTop);
            if (moved == 0) {
                return 1;
            }
            const uint32_t oldBlock = _link.linkBlock - 4;
            memmove(_env.memory + moved, _env.memory + oldBlock, headerLength);
            _link.linkBlock = moved + 4;
            if (oldBlock < read<uint32_t>(heap + kHeapCurrent)) {
                write<uint32_t>(heap + kHeapCurrent, oldBlock);
            }
        }
    } else {
        _link.codeSize = read<uint32_t>(objectData + 12);
        _link.linkBlock = objectData + _link.codeSize + 16 + 4;
        _link.objectData = objectData + 16;
    }

    if (!linkDataObject()) {
        fprintf(stderr, "jak1::Kernel: failed to link %s\n", _link.name.c_str());
        write<uint32_t>(heap + kHeapTop, _link.heapTop);
        _link.entry = 0;
        return 1;
    }

    // jak1_finish for v2/v4: run the object's relocate method.
    if ((flags & kLinkFlagExecute) && _env.callGoal) {
        std::string base = _link.name;
        const size_t slash = base.find_last_of("/\\");
        if (slash != std::string::npos) {
            base = base.substr(slash + 1);
        }
        base.resize(std::min<size_t>(base.size(), 63));
        memcpy(_env.memory + kLinkControlNameAddress, base.c_str(), base.size() + 1);
        const uint32_t entry = _link.entry;
        const uint32_t type = read<uint32_t>(entry - 4);
        const uint32_t method = read<uint32_t>(type + 16 + kRelocateMethod * 4);
        if (method != 0) {
            fprintf(stderr,
                    "jak1::Kernel: relocate %s entry=0x%x type=0x%x method=0x%x\n",
                    _link.name.c_str(), entry, type, method);
            const uint64_t result = _env.callGoal(method, entry, heap, kLinkControlNameAddress);
            fprintf(stderr, "jak1::Kernel: relocate %s returned 0x%llx\n",
                    _link.name.c_str(), result);
        } else {
            fprintf(stderr, "jak1::Kernel: no relocate method for %s type=0x%x\n",
                    _link.name.c_str(), type);
        }
    }
    write<uint32_t>(heap + kHeapTop, _link.heapTop);
    fprintf(stderr, "jak1::Kernel: linked data object %s entry=0x%x\n",
            _link.name.c_str(), _link.entry);
    return 1;
}

uint64_t Kernel::linkResume() {
    // linkBegin always finishes in one call.
    return 1;
}

bool Kernel::linkDataObject() {
    const uint32_t heap = _link.heap;

    // State 0: move the data next to the heap's current pointer, unless it is close enough.
    const int64_t gap = static_cast<int64_t>(_link.objectData) -
        static_cast<int64_t>(read<uint32_t>(heap + kHeapCurrent));
    // An object is only already adjacent when it starts at or after the allocation cursor.
    // During teleports a reused DGO buffer can sit below heap-current; treating that negative gap
    // as "close enough" rewinds the heap into live level data and stalls the GOAL kernel.
    if (gap >= 0 && gap < kObjV2CloseEnough) {
        const uint32_t newCurrent = _link.objectData + _link.codeSize;
        write<uint32_t>(heap + kHeapCurrent, newCurrent);
        if (read<uint32_t>(heap + kHeapTop) <= newCurrent) {
            fprintf(stderr, "jak1::Kernel: heap overflow linking %s\n", _link.name.c_str());
            return false;
        }
    } else {
        const uint32_t destination = kmalloc(heap, _link.codeSize, 0);
        if (destination == 0) {
            return false;
        }
        memmove(_env.memory + destination, _env.memory + _link.objectData, _link.codeSize);
        _link.objectData = destination;
    }

    // State 1: pointer relocations. The table alternates between "seek" and "fix up" runs.
    uint32_t reloc = _link.linkBlock + 8;
    if (read<uint8_t>(reloc) == 0) {
        reloc++;
    } else {
        const uint32_t base = _link.objectData;
        uint32_t location = _link.objectData;
        int toggle = 0;
        while (true) {
            while (true) {
                const uint8_t count = read<uint8_t>(reloc++);
                if (!toggle) {
                    location += 4 * count;
                } else {
                    for (uint32_t i = 0; i < count; i++) {
                        write<uint32_t>(location, read<uint32_t>(location) + base);
                        location += 4;
                    }
                }
                if (count != 0xff) {
                    break;
                }
                if (read<uint8_t>(reloc) == 0) {
                    reloc++;
                    toggle ^= 1;
                }
            }
            toggle ^= 1;
            if (read<uint8_t>(reloc) == 0) {
                break;
            }
        }
        reloc++;
    }

    // State 2: symbol and type links.
    if (read<uint8_t>(reloc) != 0) {
        while (true) {
            const uint32_t relocation = read<uint8_t>(reloc++);
            uint32_t target = 0;
            const char *name = nullptr;
            if ((relocation & 0x80) == 0) {
                if (relocation > 9) {
                    reloc--; // the first character of the name
                }
                name = cString(reloc);
                target = internSymbol(name);
            } else {
                uint32_t methods = relocation & 0x7f;
                if (methods == 0) {
                    methods = 1;
                }
                name = cString(reloc);
                target = internType(name, methods);
            }
            reloc += static_cast<uint32_t>(strlen(name)) + 1;

            // c_symlink2: a variable-length list of offsets to patch, terminated by 0.
            uint32_t patch = _link.objectData;
            do {
                const uint8_t first = read<uint8_t>(reloc);
                uint32_t value = first;
                uint32_t next = reloc + 1;
                if (value & 3) {
                    value = (static_cast<uint32_t>(read<uint8_t>(reloc + 1)) << 8) | first;
                    next = reloc + 2;
                    if (value & 2) {
                        value |= static_cast<uint32_t>(read<uint8_t>(reloc + 2)) << 16;
                        next = reloc + 3;
                        if (value & 1) {
                            value |= static_cast<uint32_t>(read<uint8_t>(reloc + 3)) << 24;
                            next = reloc + 4;
                        }
                    }
                }
                reloc = next;
                patch += value & 0xfffffffc;
                if (read<uint32_t>(patch) != 0xffffffff) {
                    fprintf(stderr, "jak1::Kernel: bad symbol link for %s in %s\n", name,
                            _link.name.c_str());
                    return false;
                }
                write<uint32_t>(patch, target);
            } while (read<uint8_t>(reloc) != 0);
            reloc++;

            if (read<uint8_t>(reloc) == 0) {
                break;
            }
        }
    }

    _link.entry = _link.objectData + 4;
    return true;
}

// ---------------------------------------------------------------------------------------------
// RPC-DGO (game/overlord/jak1/iso.cpp), served synchronously from the imported DGO files.

bool Kernel::writeNextDgoObject(uint32_t destination) {
    if (_dgo.nextObject >= _dgo.objectOffsets.size()) {
        return false;
    }
    const size_t offset = _dgo.objectOffsets[_dgo.nextObject];
    uint32_t objectSize = 0;
    memcpy(&objectSize, _dgo.file.data() + offset, 4);
    char objectName[61] {};
    memcpy(objectName, _dgo.file.data() + offset + 4, sizeof(objectName) - 1);
    const uint32_t paddedSize = (objectSize + 15) & ~15u;
    fprintf(stderr,
            "jak1::Kernel: RPC-DGO object %zu/%zu %s size=%u destination=0x%x\n",
            _dgo.nextObject, _dgo.objectOffsets.size(), objectName, objectSize, destination);
    const size_t available = _dgo.file.size() - offset - kObjectHeaderSize;
    const uint32_t copySize = static_cast<uint32_t>(std::min<size_t>(paddedSize, available));
    if (!inArena(destination, static_cast<uint32_t>(kObjectHeaderSize) + paddedSize)) {
        return false;
    }
    memcpy(_env.memory + destination, _dgo.file.data() + offset, kObjectHeaderSize);
    memcpy(_env.memory + destination + kObjectHeaderSize,
           _dgo.file.data() + offset + kObjectHeaderSize, copySize);

    _dgo.nextObject++;
    return true;
}

// A camera outro (cam-master.gc change-state) copies the previous slave's intro curve, which
// points into that camera entity's level data. When that level is discarded and another loads
// into its heap (e.g. `want-levels misty intro` at the start of the intro's sequenceB), cam-decel
// keeps evaluating the curve for ~45 frames while the DGO buffers overwrite it, and garbage
// knots make curve-evaluate! index far outside GOAL memory. End the outro the way cam-decel
// does when it reaches the exit value, before any bytes land in the reused heap.
void Kernel::endCameraOutroInRange(uint32_t start, uint32_t end) {
    const uint32_t cameraSymbol = findSymbol("*camera*");
    if (cameraSymbol == 0 || !inArena(cameraSymbol, 4)) {
        return;
    }
    const uint32_t camera = read<uint32_t>(cameraSymbol);
    if (camera == _env.s7 || !inArena(camera, kCameraOutroExitValue + 4)) {
        return;
    }
    if (read<float>(camera + kCameraOutroTStep) == 0.0f) {
        return;
    }
    const uint32_t cverts = read<uint32_t>(camera + kCameraOutroCurveCverts);
    const uint32_t knots = read<uint32_t>(camera + kCameraOutroCurveKnots);
    const auto inRange = [&](uint32_t address) { return address >= start && address < end; };
    if (!inRange(cverts) && !inRange(knots)) {
        return;
    }
    fprintf(stderr, "jak1::Kernel: ending camera outro; curve 0x%x is in reused level heap 0x%x-0x%x\n",
            cverts, start, end);
    write<float>(camera + kCameraOutroT, read<float>(camera + kCameraOutroExitValue));
    write<float>(camera + kCameraOutroTStep, 0.0f);
}

void Kernel::dgoRpc(uint32_t function, uint32_t sendBuffer, uint32_t receiveBuffer) {
    if (!inArena(sendBuffer, sizeof(DgoCommand))) {
        return;
    }
    DgoCommand command {};
    memcpy(&command, _env.memory + sendBuffer, sizeof(command));
    fprintf(stderr, "jak1::Kernel: RPC-DGO fno=%u next=%zu active=%d send=0x%x recv=0x%x\n",
            function, _dgo.nextObject, _dgo.active, sendBuffer, receiveBuffer);
    command.result = kDgoResultError;

    if (function == kDgoLoad) {
        _dgo = DgoState();
        char name[17] {};
        memcpy(name, command.name, 16);
        // The overlord upper-cases ISO names (MakeISOName); GOAL asks for e.g. "vi1.DGO".
        for (char *c = name; *c != 0; c++) {
            if (*c >= 'a' && *c <= 'z') *c -= 0x20;
        }
        _dgo.name = name;
        if (_env.canLoadDgo && !_env.canLoadDgo(_dgo.name)) {
            fprintf(stderr, "jak1::Kernel: RPC-DGO load %s disabled by host setting\n",
                    _dgo.name.c_str());
        } else {
        std::ifstream stream(_env.contentPath + "/DGO/" + _dgo.name, std::ios::binary);
        if (!stream) {
            stream.open(_env.contentPath + "/CGO/" + _dgo.name, std::ios::binary);
        }
        if (stream) {
            _dgo.file.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
        }
        }
        uint32_t objectCount = 0;
        if (_dgo.file.size() >= kDgoHeaderSize) {
            memcpy(&objectCount, _dgo.file.data(), 4);
        }
        size_t offset = kDgoHeaderSize;
        for (uint32_t i = 0; i < objectCount && offset + kObjectHeaderSize <= _dgo.file.size(); i++) {
            uint32_t objectSize = 0;
            memcpy(&objectSize, _dgo.file.data() + offset, 4);
            _dgo.objectOffsets.push_back(offset);
            offset += kObjectHeaderSize + ((objectSize + 15) & ~15u);
        }
        const bool parsedAll = _dgo.objectOffsets.size() == objectCount;
        if (parsedAll && _env.skipDgoObject && _dgo.objectOffsets.size() > 1) {
            // The last object (the level bsp) is always kept.
            for (size_t i = _dgo.objectOffsets.size() - 1; i-- > 0;) {
                char objectName[61] {};
                memcpy(objectName, _dgo.file.data() + _dgo.objectOffsets[i] + 4, sizeof(objectName) - 1);
                if (_env.skipDgoObject(_dgo.name, objectName)) {
                    fprintf(stderr, "jak1::Kernel: RPC-DGO %s skips %s (kept resident by the host)\n",
                            _dgo.name.c_str(), objectName);
                    _dgo.objectOffsets.erase(_dgo.objectOffsets.begin() + static_cast<std::ptrdiff_t>(i));
                }
            }
        }
        fprintf(stderr, "jak1::Kernel: RPC-DGO load %s: %zu objects (%zu bytes)\n", _dgo.name.c_str(),
                _dgo.objectOffsets.size(), _dgo.file.size());
        if (!_dgo.objectOffsets.empty() && parsedAll) {
            // The new level occupies its heap from the load start up to the top DGO buffer.
            endCameraOutroInRange(command.bufferHeapTop,
                                  std::max(command.buffer1, command.buffer2) + kDgoLevelBufferSize);
            _dgo.buffer1 = command.buffer1;
            _dgo.buffer2 = command.buffer2;
            _dgo.active = true;
            if (_dgo.objectOffsets.size() == 1) {
                if (writeNextDgoObject(command.bufferHeapTop)) {
                    command.result = kDgoResultDone;
                    command.buffer1 = command.bufferHeapTop;
                }
                _dgo.active = false;
            } else if (writeNextDgoObject(command.buffer1)) {
                command.result = kDgoResultMore;
            }
        }
    } else if (function == kDgoLoadNext && _dgo.active) {
        if (_dgo.nextObject + 1 == _dgo.objectOffsets.size()) {
            // The last object is loaded directly onto the heap.
            if (writeNextDgoObject(command.bufferHeapTop)) {
                command.result = kDgoResultDone;
                command.buffer1 = command.bufferHeapTop;
            }
            _dgo.active = false;
        } else {
            // Objects alternate between the two temporary buffers: 0 -> b1, 1 -> b2, 2 -> b1...
            const uint32_t destination = (_dgo.nextObject % 2 == 1) ? _dgo.buffer2 : _dgo.buffer1;
            if (writeNextDgoObject(destination)) {
                command.result = kDgoResultMore;
                command.buffer1 = destination;
            }
        }
    } else if (function == kDgoCancel) {
        _dgo.active = false;
        command.result = kDgoResultAborted;
    }

    if (command.result == kDgoResultError) {
        fprintf(stderr, "jak1::Kernel: RPC-DGO fno %u failed for %s\n", function, _dgo.name.c_str());
        _dgo.active = false;
    }
    if (inArena(receiveBuffer, sizeof(DgoCommand))) {
        memcpy(_env.memory + receiveBuffer, &command, sizeof(command));
    }
}

} // namespace jak1
