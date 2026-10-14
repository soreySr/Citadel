#import "Jak1DGOExtractor.h"

#pragma pack(push, 1)
struct DGOHeader {
    uint32_t fileCount;
    char name[16];
};

struct DGOEntryHeader {
    uint32_t length;
    char name[16];
};
#pragma pack(pop)

@implementation Jak1DGOEntry
- (instancetype)initWithName:(NSString *)name length:(uint32_t)length data:(NSData *)data {
    self = [super init];
    if (self) {
        _name = [name copy];
        _length = length;
        _data = data;
    }
    return self;
}
@end

@implementation Jak1DGOFile
- (instancetype)initWithName:(NSString *)name entries:(NSArray<Jak1DGOEntry *> *)entries {
    self = [super init];
    if (self) {
        _name = [name copy];
        _entries = [entries copy];
    }
    return self;
}
@end

@implementation Jak1DGOExtractor

+ (Jak1DGOFile *)parseDGOAtURL:(NSURL *)dgoURL error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:dgoURL options:NSDataReadingMappedIfSafe error:error];
    if (data == nil || data.length < sizeof(DGOHeader)) {
        return nil;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    const NSUInteger totalLength = data.length;
    NSUInteger offset = 0;

    const DGOHeader *header = (const DGOHeader *)(bytes + offset);
    offset += sizeof(DGOHeader);

    char nameBuf[17] = {0};
    memcpy(nameBuf, header->name, 16);
    NSString *dgoName = [NSString stringWithUTF8String:nameBuf] ?: dgoURL.lastPathComponent;

    NSMutableArray<Jak1DGOEntry *> *entries = [NSMutableArray arrayWithCapacity:header->fileCount];

    for (uint32_t i = 0; i < header->fileCount; i++) {
        if (offset + sizeof(DGOEntryHeader) > totalLength) {
            break;
        }

        const DGOEntryHeader *entryHeader = (const DGOEntryHeader *)(bytes + offset);
        offset += sizeof(DGOEntryHeader);

        char entryNameBuf[17] = {0};
        memcpy(entryNameBuf, entryHeader->name, 16);
        NSString *entryName = [NSString stringWithUTF8String:entryNameBuf] ?: [NSString stringWithFormat:@"entry_%u.o", i];

        uint32_t entryLength = entryHeader->length;
        if (offset + entryLength > totalLength) {
            break;
        }

        NSData *entryData = [NSData dataWithBytes:(bytes + offset) length:entryLength];
        Jak1DGOEntry *entry = [[Jak1DGOEntry alloc] initWithName:entryName length:entryLength data:entryData];
        [entries addObject:entry];

        offset += entryLength;
        offset = (offset + 15) & ~15;
    }

    return [[Jak1DGOFile alloc] initWithName:dgoName entries:entries];
}

+ (BOOL)extractAllDGOsInDirectory:(NSURL *)gameDirURL
                toOutputDirectory:(NSURL *)outputDirURL
                            error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *dgoFolder = [gameDirURL URLByAppendingPathComponent:@"DGO" isDirectory:YES];
    if (![fm fileExistsAtPath:dgoFolder.path]) {
        dgoFolder = gameDirURL;
    }

    NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:dgoFolder
                                     includingPropertiesForKeys:nil
                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                          error:error];
    if (contents == nil) {
        return NO;
    }

    if (![fm createDirectoryAtURL:outputDirURL withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    for (NSURL *fileURL in contents) {
        if ([fileURL.pathExtension.lowercaseString isEqualToString:@"dgo"]) {
            Jak1DGOFile *parsed = [self parseDGOAtURL:fileURL error:error];
            if (parsed == nil) continue;

            NSURL *subDir = [outputDirURL URLByAppendingPathComponent:parsed.name isDirectory:YES];
            [fm createDirectoryAtURL:subDir withIntermediateDirectories:YES attributes:nil error:nil];

            for (Jak1DGOEntry *entry in parsed.entries) {
                NSURL *entryURL = [subDir URLByAppendingPathComponent:entry.name];
                [entry.data writeToURL:entryURL atomically:YES];
            }
        }
    }
    return YES;
}

@end
