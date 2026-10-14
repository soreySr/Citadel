#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Owns the AVAudioEngine. Bank SFX and music come from OpenGOAL's 989snd synth (driven by the
// overlord port in Sound989/Jak1OverlordSound), rendered through one source node; VAG dialog
// streams render through their own source node, as the overlord's dedicated stream voice did.
@interface Jak1AudioManager : NSObject

+ (instancetype)sharedManager;

- (void)startAudioEngine;
- (void)stopAudioEngine;
// Called once per game frame. Restarts audio output that has stopped (phone call, Siri, a lost
// route) while the app is in the foreground; cheap when output is healthy.
- (void)serviceAudioEngine;
- (void)setMasterVolume:(float)volume;
// Points the sound system at the imported disc files and starts the 989snd synth.
- (void)configureContentDirectory:(nullable NSURL *)contentDirectory;
- (BOOL)playVAGStreamNamed:(NSString *)name;
- (void)stopVAGStream;
// NO once the current VAG stream has played to the end or been stopped. The host uses this to
// report the stream as finished to GOAL, which otherwise keeps dialog ducking applied.
@property (atomic, readonly, getter=isVAGStreamActive) BOOL VAGStreamActive;
// Audio actually played from the current VAG stream (the overlord's real VAG clock), or -1 when
// nothing has rendered yet. Clamped to the stream's length.
@property (readonly) double VAGStreamPlaybackSeconds;
- (void)pauseVAGStream;
- (void)resumeVAGStream;
- (void)setVAGStreamVolume:(float)volume;
- (void)setDialogVolume:(float)volume;
// Positions the current stream in the world (GOAL trans, meters * 4096 >> 4), or makes it a
// plain centred stream when nil. PLAY_VAG_STREAM decides this once per stream.
- (void)setVAGStreamPosition:(nullable const int32_t *)trans;
// Re-applies falloff and pan of a positioned stream after the ear/camera moved (SetVAGVol).
- (void)refreshVAGStreamVolume;

@end

NS_ASSUME_NONNULL_END
