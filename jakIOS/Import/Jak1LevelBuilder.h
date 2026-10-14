#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the PC renderer's level files (fr3/Jak1Level-<name>.fr3z) from the imported disc with OpenGOAL's
/// level extractor, so the app bundle ships no level data.
@interface Jak1LevelBuilder : NSObject

/// True once the imported game directory holds levels built by this version of the builder.
+ (BOOL)hasBuiltLevelsInGameDirectory:(NSURL *)gameDirectory;

/// Extracts every level (several seconds to a few minutes; call off the main thread).
/// progress receives (completed, total, level name) before each level and once when finished.
+ (BOOL)buildLevelsInGameDirectory:(NSURL *)gameDirectory
                          progress:(nullable void (^)(NSInteger completed, NSInteger total,
                                                      NSString *name))progress
                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
