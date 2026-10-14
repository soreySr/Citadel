#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Jak1DGOEntry : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, assign, readonly) uint32_t length;
@property (nonatomic, strong, readonly) NSData *data;
@end

@interface Jak1DGOFile : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<Jak1DGOEntry *> *entries;
@end

@interface Jak1DGOExtractor : NSObject

+ (nullable Jak1DGOFile *)parseDGOAtURL:(NSURL *)dgoURL error:(NSError **)error;
+ (BOOL)extractAllDGOsInDirectory:(NSURL *)gameDirURL
                toOutputDirectory:(NSURL *)outputDirURL
                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
