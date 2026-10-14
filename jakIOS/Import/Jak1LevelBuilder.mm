#import "Jak1LevelBuilder.h"

#include <compression.h>
#include <mach/mach.h>

#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "common/util/compress.h"

#include "Jak1CustomLevelBuilder.h"
#include "Jak1LevelExtractor.h"

namespace {

// Bump when extraction or the output format changes, so previous imports are rebuilt once.
NSString *const kLevelsVersionMarker = @".jakios-levels-v1";
NSString *const kCustomLevelsVersionMarker = @".jakios-custom-levels-v2";
NSString *const kErrorDomain = @"Jak1LevelBuilder";

NSError *BuildError(NSString *message) {
    return [NSError errorWithDomain:kErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Physical footprint (what jetsam limits) now and at its peak, in MB; logged per level so a device run
// shows how close extraction gets to the memory limit.
void Footprint(double *current, double *peak) {
    task_vm_info_data_t info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    *current = *peak = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) ==
        KERN_SUCCESS) {
        *current = info.phys_footprint / (1024.0 * 1024.0);
        *peak = info.ledger_phys_footprint_peak / (1024.0 * 1024.0);
    }
}

// Jak1ExtractorConfig.pack (tools/ios_extractor/pack_config.py) -> files under projectDirectory.
bool UnpackExtractorConfig(NSString *projectDirectory) {
    NSURL *packURL = [NSBundle.mainBundle URLForResource:@"Jak1ExtractorConfig" withExtension:@"pack"];
    NSData *pack = packURL == nil ? nil : [NSData dataWithContentsOfURL:packURL];
    const auto *bytes = static_cast<const uint8_t *>(pack.bytes);
    if (pack.length < 12 || memcmp(bytes, "JAK1CFG\0", 8) != 0) return false;
    uint32_t count = 0;
    memcpy(&count, bytes + 8, 4);
    size_t offset = 12;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (uint32_t index = 0; index < count; index++) {
        uint16_t nameLength = 0;
        uint32_t size = 0;
        if (offset + 2 > pack.length) return false;
        memcpy(&nameLength, bytes + offset, 2);
        offset += 2;
        if (offset + nameLength + 4 > pack.length) return false;
        NSString *name = [[NSString alloc] initWithBytes:bytes + offset length:nameLength
                                                encoding:NSUTF8StringEncoding];
        offset += nameLength;
        memcpy(&size, bytes + offset, 4);
        offset += 4;
        if (name == nil || [name containsString:@".."] || offset + size > pack.length) return false;
        NSString *path = [projectDirectory stringByAppendingPathComponent:name];
        [fileManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
               withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSData dataWithBytesNoCopy:(void *)(bytes + offset) length:size freeWhenDone:NO]
                writeToFile:path atomically:NO]) {
            return false;
        }
        offset += size;
    }
    return true;
}

// <level>.fr3 (zstd, from the extractor) -> Jak1Level-<level>.fr3z (FR3Z header + LZFSE), the format
// Jak1Background.mm loads (same conversion as tools/fr3_to_lzfse.cpp).
bool ConvertToFr3z(NSString *fr3Path, NSString *outputPath) {
    std::ifstream input(fr3Path.fileSystemRepresentation, std::ios::binary);
    std::vector<uint8_t> compressed((std::istreambuf_iterator<char>(input)), {});
    if (compressed.empty()) return false;
    const std::vector<uint8_t> raw = compression::decompress_zstd(compressed.data(), compressed.size());
    compressed = {};
    if (raw.empty()) return false;
    std::vector<uint8_t> encoded(raw.size() + 4096);
    const size_t encodedSize = compression_encode_buffer(encoded.data(), encoded.size(), raw.data(),
                                                         raw.size(), nullptr, COMPRESSION_LZFSE);
    if (encodedSize == 0) return false;
    const uint32_t magic = 0x5a335246;  // "FR3Z"
    const uint64_t rawSize = raw.size();
    NSMutableData *file = [NSMutableData dataWithCapacity:12 + encodedSize];
    [file appendBytes:&magic length:4];
    [file appendBytes:&rawSize length:8];
    [file appendBytes:encoded.data() length:encodedSize];
    return [file writeToFile:outputPath atomically:YES];
}

// The disc's levels: OpenGOAL's extractor -> <output>/Jak1Level-<level>.fr3z.
BOOL ExtractDiscLevels(NSURL *gameDirectory, NSString *output,
                       void (^progress)(NSInteger, NSInteger, NSString *), NSString **failure) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:@"jak1-level-build"];
    [fileManager removeItemAtPath:scratch error:nil];
    NSString *project = [scratch stringByAppendingPathComponent:@"project"];
    NSString *extracted = [scratch stringByAppendingPathComponent:@"fr3"];
    NSString *work = [scratch stringByAppendingPathComponent:@"work"];
    const auto fail = [&](NSString *message) {
        [fileManager removeItemAtPath:scratch error:nil];
        *failure = message;
        return NO;
    };
    if (!UnpackExtractorConfig(project)) return fail(@"The level extractor configuration is missing.");

    const CFTimeInterval start = CFAbsoluteTimeGetCurrent();
    std::string extractError;
    const bool extractedAll = jak1::ExtractLevels(
        {project.UTF8String, gameDirectory.path.UTF8String, extracted.UTF8String, work.UTF8String},
        [&](int completed, int total, const std::string &name) {
            double footprint = 0, peak = 0;
            Footprint(&footprint, &peak);
            NSLog(@"jakIOS: level build %d/%d %s (%.1f s, footprint %.0f MB, peak %.0f MB)", completed,
                  total, name.c_str(), CFAbsoluteTimeGetCurrent() - start, footprint, peak);
            if (progress) progress(completed, total, @(name.c_str()));
        },
        &extractError);
    if (!extractedAll) {
        return fail([NSString stringWithFormat:@"Level extraction failed: %s", extractError.c_str()]);
    }

    NSArray<NSString *> *files = [fileManager contentsOfDirectoryAtPath:extracted error:nil];
    NSInteger converted = 0;
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"fr3"]) continue;
        // GAME.fr3 -> Jak1Level-game.fr3z: the renderer asks for lower-case level names.
        NSString *level = file.stringByDeletingPathExtension.lowercaseString;
        NSString *target = [output stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Jak1Level-%@.fr3z", level]];
        @autoreleasepool {
            if (!ConvertToFr3z([extracted stringByAppendingPathComponent:file], target)) {
                return fail([NSString stringWithFormat:@"Could not convert %@.", file]);
            }
        }
        [fileManager removeItemAtPath:[extracted stringByAppendingPathComponent:file] error:nil];
        converted++;
    }
    [fileManager removeItemAtPath:scratch error:nil];
    if (converted == 0) return fail(@"The level extractor produced no levels.");
    double footprint = 0, peak = 0;
    Footprint(&footprint, &peak);
    NSLog(@"jakIOS: built %ld level files in %.1f s (peak footprint %.0f MB)", (long)converted,
          CFAbsoluteTimeGetCurrent() - start, peak);
    return YES;
}

NSString *MarkerPath(NSURL *gameDirectory, NSString *marker) {
    return [[gameDirectory.path stringByAppendingPathComponent:@"fr3"] stringByAppendingPathComponent:marker];
}

}  // namespace

@implementation Jak1LevelBuilder

+ (BOOL)hasBuiltLevelsInGameDirectory:(NSURL *)gameDirectory {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    return [fileManager fileExistsAtPath:MarkerPath(gameDirectory, kLevelsVersionMarker)] &&
        [fileManager fileExistsAtPath:MarkerPath(gameDirectory, kCustomLevelsVersionMarker)];
}

+ (BOOL)buildLevelsInGameDirectory:(NSURL *)gameDirectory
                          progress:(void (^)(NSInteger, NSInteger, NSString *))progress
                             error:(NSError **)error {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *output = [gameDirectory.path stringByAppendingPathComponent:@"fr3"];
    const auto fail = [&](NSString *message) {
        NSLog(@"jakIOS: level build failed: %@", message);
        if (error) *error = BuildError(message);
        return NO;
    };
    if (![fileManager fileExistsAtPath:MarkerPath(gameDirectory, kLevelsVersionMarker)]) {
        [fileManager removeItemAtPath:output error:nil];
        [fileManager createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *failure = nil;
        if (!ExtractDiscLevels(gameDirectory, output, progress, &failure)) return fail(failure);
        [[NSData data] writeToFile:MarkerPath(gameDirectory, kLevelsVersionMarker) atomically:YES];
    }

    // The experimental options' models, cut from the levels just built (separate marker, so imports
    // made before these were built on the device only need this step).
    if (![fileManager fileExistsAtPath:MarkerPath(gameDirectory, kCustomLevelsVersionMarker)]) {
        NSString *coastTemplate = [NSBundle.mainBundle pathForResource:@"Jak1CoastTerrain" ofType:@"fr3z"];
        if (coastTemplate == nil) return fail(@"The coastline terrain is missing from the app.");
        std::string customError;
        const CFTimeInterval start = CFAbsoluteTimeGetCurrent();
        if (!jak1::BuildCustomLevels(output.UTF8String, coastTemplate.UTF8String, &customError)) {
            return fail([NSString stringWithFormat:@"Building the experimental models failed: %s",
                         customError.c_str()]);
        }
        NSLog(@"jakIOS: built ios-boat/fish/flut/coast/vents in %.1f s", CFAbsoluteTimeGetCurrent() - start);
        [[NSData data] writeToFile:MarkerPath(gameDirectory, kCustomLevelsVersionMarker) atomically:YES];
    }
    return YES;
}

@end
