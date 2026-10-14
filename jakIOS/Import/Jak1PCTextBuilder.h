#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the PC-port XCOMMON.TXT files from the imported disc, as OpenGOAL's text build does
/// (game/assets/jak1/game_text.gp): the disc text, patched to the v2 text revision, plus the
/// bundled OpenGOAL custom strings (options, SECRETS, ...). Output goes to `pc-text/`.
@interface Jak1PCTextBuilder : NSObject

/// Name of the output folder inside the imported game directory.
@property (class, nonatomic, readonly) NSString *outputDirectoryName;

+ (BOOL)buildPCTextInGameDirectory:(NSURL *)gameDirectory error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
