#import "Jak1AudioManager.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
#import <UIKit/UIKit.h>
#endif
#include <algorithm>
#include <atomic>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <memory>
#include <mutex>
#include <os/workgroup.h>
#include <pthread.h>
#include <vector>

#include "Sound989/Jak1OverlordSound.h"

static uint32_t JakReadBigEndian32(const uint8_t *bytes) {
    return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
           (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}

// connect:to:format:error: only exists on iOS 27+. Older systems have connect:to:format:, which
// raises an Objective-C exception on failure instead of returning an error, so convert that here.
static BOOL JakConnectNode(AVAudioEngine *engine, AVAudioNode *node, AVAudioNode *destination,
                           AVAudioFormat *format, NSError **error) {
    if (@available(iOS 27.0, *)) {
        return [engine connect:node to:destination format:format error:error];
    }
    @try {
        [engine connect:node to:destination format:format];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"Jak1AudioManager" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        }
        return NO;
    }
}

// 989snd's Synth applies its master volume register (0x3fff of 0x8000) to everything it mixes,
// the overlord's VAG stream voice included. The stream plays on its own node here, so it takes
// the same factor to keep dialog level with SFX and music.
static constexpr float kSynthMasterGain = (float)0x3fff / (float)0x8000;

// 989snd renders 48 kHz stereo; this many frames are produced per synth lock.
static constexpr int kSynthChunkFrames = 64;

// Bumped by every synth render callback. Output that has stopped (an interruption, a lost route)
// is detected from this rather than from -[AVAudioEngine isRunning], which can stay YES after
// an interruption has stopped the hardware.
static std::atomic<uint64_t> gSynthRenderCount {0};

// How long the synth may go without a render callback, while the app is active, before the
// engine is restarted.
static constexpr CFTimeInterval kRenderStallSeconds = 0.5;

// The synth is rendered ahead into this ring by its own real-time thread, and the engine's
// render callback only copies out of it. Rendering inside the callback made the callback wait
// on the 989snd tick lock whenever the GOAL kernel thread held it for a sound RPC; when the system
// got busy (screenshot, notification banner, Bluetooth pairing) the kernel thread could be
// preempted while holding it, the callback missed its deadline, and the output crackled.
static constexpr uint32_t kSynthRingFrames = 8192;  // power of two
// Frames kept ready beyond one hardware buffer: how long the producer may be held up (by the tick
// lock or a CPU burst) before the output underruns. Also the latency this adds (~16 ms).
static constexpr uint32_t kSynthLeadSlackFrames = 768;

struct JakSynthRing {
    uint32_t frames[kSynthRingFrames];               // interleaved L/R int16 pairs
    std::atomic<uint64_t> writePosition {0};         // producer only
    std::atomic<uint64_t> readPosition {0};          // render callback only
    std::atomic<uint32_t> leadFrames {1024 + kSynthLeadSlackFrames};
    std::atomic<uint64_t> underrunFrames {0};
    dispatch_semaphore_t wake = nullptr;             // signalled after every render callback
};
static JakSynthRing gSynthRing;

// Real-time scheduling for the producer, sized for one wake per hardware buffer (~21 ms).
static void JakMakeThreadRealTime() {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const double ticksPerMillisecond = 1.0e6 * timebase.denom / timebase.numer;
    thread_time_constraint_policy_data_t policy;
    policy.period = (uint32_t)(ticksPerMillisecond * 1024.0 / 48.0);
    policy.computation = (uint32_t)(ticksPerMillisecond * 3.0);
    policy.constraint = (uint32_t)(ticksPerMillisecond * 10.0);
    policy.preemptible = TRUE;
    const kern_return_t result = thread_policy_set(
        pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
        reinterpret_cast<thread_policy_t>(&policy), THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (result != KERN_SUCCESS) {
        NSLog(@"Jak1AudioManager: synth thread real-time policy failed (%d)", result);
    }
}

static void *JakSynthProducerMain(void *) {
    pthread_setname_np("jak1-synth");
    JakMakeThreadRealTime();
    // An audio work interval tells the scheduler this thread has audio deadlines (P-core
    // placement under load). The thread must already be real-time to join.
    os_workgroup_interval_t workgroup = AudioWorkIntervalCreate("jak1-synth", OS_CLOCK_MACH_ABSOLUTE_TIME, nullptr);
    os_workgroup_join_token_s joinToken;
    const bool joined = workgroup != nullptr && os_workgroup_join(workgroup, &joinToken) == 0;
    if (!joined) NSLog(@"Jak1AudioManager: synth thread could not join an audio workgroup");

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const uint64_t intervalTicks = (uint64_t)(1.0e9 * 1024.0 / 48000.0 * timebase.denom / timebase.numer);
    JakSynthRing &ring = gSynthRing;
    int16_t stereo[kSynthChunkFrames * 2];
    for (;;) {
        const uint64_t start = mach_absolute_time();
        if (joined) os_workgroup_interval_start(workgroup, start, start + intervalTicks, nullptr);
        const uint32_t lead = std::min<uint32_t>(ring.leadFrames.load(std::memory_order_relaxed),
                                                 kSynthRingFrames - kSynthChunkFrames);
        uint64_t write = ring.writePosition.load(std::memory_order_relaxed);
        // Rendering in short chunks keeps each hold of the synth lock brief, so sound RPCs
        // from the GOAL kernel thread never wait on a whole hardware buffer.
        while (write - ring.readPosition.load(std::memory_order_acquire) < lead) {
            jak1sound::Render(stereo, kSynthChunkFrames);
            for (int frame = 0; frame < kSynthChunkFrames; frame++) {
                ring.frames[(write + frame) & (kSynthRingFrames - 1)] =
                    (uint32_t)(uint16_t)stereo[frame * 2] | ((uint32_t)(uint16_t)stereo[frame * 2 + 1] << 16);
            }
            write += kSynthChunkFrames;
            ring.writePosition.store(write, std::memory_order_release);
        }
        if (joined) os_workgroup_interval_finish(workgroup, nullptr);
        // Woken by every render callback; the timeout only matters while output is stopped.
        dispatch_semaphore_wait(ring.wake, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
    }
    return nullptr;
}

// One decoded VAG stream, shared between the manager and its render block. The overlord's stream
// voice has independent VOLL/VOLR registers (positioned dialog pans and falls off), which a
// player node can't express, so the stream renders its own samples with per-channel gains.
struct JakVAGStream {
    std::vector<float> samples;
    double sampleRate = 0;
    std::atomic<uint64_t> position {0};   // frames rendered: the overlord's real VAG clock
    std::atomic<bool> paused {false};
    std::atomic<float> gainLeft {0}, gainRight {0};
    float renderedLeft = 0, renderedRight = 0;  // render thread only
    bool gainsInitialized = false;              // render thread only
};

@interface Jak1AudioManager () {
    AVAudioEngine *_engine;
    AVAudioMixerNode *_mainMixer;
    AVAudioSourceNode *_synthNode;
    float _masterVolume;
    float _streamVolume;
    float _dialogVolume;
    NSURL *_contentDirectory;
    NSDictionary<NSString *, NSURL *> *_contentFiles;   // lowercase file name -> URL
    AVAudioSourceNode *_streamNode;
    // Written under @synchronized(self) *and* _streamMutex. The kernel thread polls it every
    // frame under _streamMutex alone, so a slow engine restart can never stall a GOAL frame.
    std::shared_ptr<JakVAGStream> _stream;
    std::mutex _streamMutex;
    // Serializes engine start/stop. Never held while taking @synchronized(self).
    std::mutex _engineMutex;
    // Session reactivation and engine restarts (each can block for hundreds of milliseconds)
    // run here rather than on the main thread, which drives every rendered and GOAL frame.
    dispatch_queue_t _engineQueue;
    BOOL _streamPositioned;
    int32_t _streamTrans[3];
    std::atomic<bool> _appActive;
    std::atomic<bool> _recoveryPending;
    uint64_t _watchdogRenderCount;           // kernel thread only
    uint64_t _watchdogUnderrunFrames;        // kernel thread only
    CFTimeInterval _watchdogCheckTime;       // kernel thread only
}
@end

@implementation Jak1AudioManager

+ (instancetype)sharedManager {
    static Jak1AudioManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[Jak1AudioManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = [[AVAudioEngine alloc] init];
        _mainMixer = _engine.mainMixerNode;
        _masterVolume = 1.0f;
        _streamVolume = 1.0f;
        _dialogVolume = 1.0f;
        _engineQueue = dispatch_queue_create(
            "com.opengoal.jak1.audio-engine",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        [self configureAudioSession];
        [self attachSynthNode];

        // A route change (headphones, Bluetooth) or an interruption stops the engine. The synth
        // only advances while it renders, so a stopped engine would freeze every sound, and the
        // overlord's 64 sound slots would never free up.
        // System sounds (screenshot shutter, notification tones) can trigger these too, so the
        // handlers run on the engine queue, never the main thread.
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        __weak Jak1AudioManager *weakSelf = self;
        dispatch_queue_t engineQueue = _engineQueue;
        [center addObserverForName:AVAudioEngineConfigurationChangeNotification object:_engine
                             queue:nil usingBlock:^(NSNotification *note) {
            NSLog(@"Jak1AudioManager: engine configuration changed; restarting");
            dispatch_async(engineQueue, ^{
                [weakSelf restartAfterEngineStop];
            });
        }];
#if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
        // After a phone call the system usually recommends *not* resuming (and the app may be in
        // the background when the interruption ends), so this alone can't be relied on; coming
        // back to the foreground and the render watchdog restart the engine too.
        // The resumption notification is iOS 27+ (before that its name is nil, which would observe
        // every notification); older systems use the interruption-ended ShouldResume option below.
        if (@available(iOS 27.0, *)) {
            [center addObserverForName:AVAudioSessionResumptionRecommendationNotification object:nil
                                 queue:nil usingBlock:^(NSNotification *note) {
                AVAudioSessionResumptionContext *context = note.userInfo[AVAudioSessionResumptionContextKey];
                NSLog(@"Jak1AudioManager: resumption recommendation %ld", (long)context.recommendation);
                if (context.recommendation == AVAudioSessionResumptionRecommendationShouldResume) {
                    dispatch_async(engineQueue, ^{
                        [weakSelf recoverAudioOutput];
                    });
                }
            }];
        }
        // Logged only, to line up with "perf audio" underruns and kernel hitches.
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil
                             queue:nil usingBlock:^(NSNotification *note) {
            AVAudioSession *session = AVAudioSession.sharedInstance;
            NSLog(@"Jak1AudioManager: route change reason %@ (%.0f Hz, %.1f ms buffer)",
                  note.userInfo[AVAudioSessionRouteChangeReasonKey], session.sampleRate,
                  session.IOBufferDuration * 1000.0);
        }];
        [center addObserverForName:AVAudioSessionInterruptionNotification object:nil
                             queue:nil usingBlock:^(NSNotification *note) {
            NSLog(@"Jak1AudioManager: interruption type %@ reason %@",
                  note.userInfo[AVAudioSessionInterruptionTypeKey],
                  note.userInfo[AVAudioSessionInterruptionReasonKey]);
            if (@available(iOS 27.0, *)) {
                return;  // handled by the resumption recommendation observer
            }
            NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
            NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
            if (type == AVAudioSessionInterruptionTypeEnded &&
                (options & AVAudioSessionInterruptionOptionShouldResume)) {
                dispatch_async(engineQueue, ^{
                    [weakSelf recoverAudioOutput];
                });
            }
        }];
        [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                             queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(engineQueue, ^{
                [weakSelf configureAudioSession];
                [weakSelf recoverAudioOutput];
            });
        }];
        _appActive = true;
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil
                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            Jak1AudioManager *strongSelf = weakSelf;
            if (strongSelf != nil) strongSelf->_appActive = false;
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            Jak1AudioManager *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf->_appActive = true;
            dispatch_async(engineQueue, ^{
                [weakSelf recoverAudioOutput];
            });
        }];
#else
        _appActive = true;
#endif
    }
    return self;
}

- (void)configureAudioSession {
#if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error];
    if (error) {
        NSLog(@"Jak1AudioManager: AudioSession category error %@", error.localizedDescription);
    }
    [session setActive:YES error:&error];
    if (error) {
        NSLog(@"Jak1AudioManager: AudioSession active error %@", error.localizedDescription);
    }
#endif
}

// The 989snd output: the cubeb callback of OpenGOAL's snd::Player, as an engine source node.
- (void)attachSynthNode {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];
    _synthNode = [[AVAudioSourceNode alloc] initWithFormat:format
                                               renderBlock:^OSStatus(BOOL *isSilence,
                                                                     const AudioTimeStamp *timestamp,
                                                                     AVAudioFrameCount frameCount,
                                                                     AudioBufferList *outputData) {
        float *left = static_cast<float *>(outputData->mBuffers[0].mData);
        float *right = outputData->mNumberBuffers > 1 ?
            static_cast<float *>(outputData->mBuffers[1].mData) : nullptr;
        gSynthRenderCount.fetch_add(1, std::memory_order_relaxed);
        // Lock-free: only copies what the synth thread has rendered ahead (see JakSynthRing).
        JakSynthRing &ring = gSynthRing;
        const uint32_t lead = frameCount + kSynthLeadSlackFrames;
        if (ring.leadFrames.load(std::memory_order_relaxed) != lead) {
            ring.leadFrames.store(lead, std::memory_order_relaxed);
        }
        const uint64_t read = ring.readPosition.load(std::memory_order_relaxed);
        const uint64_t available = ring.writePosition.load(std::memory_order_acquire) - read;
        const AVAudioFrameCount copied = (AVAudioFrameCount)std::min<uint64_t>(available, frameCount);
        for (AVAudioFrameCount frame = 0; frame < copied; frame++) {
            const uint32_t packed = ring.frames[(read + frame) & (kSynthRingFrames - 1)];
            left[frame] = (int16_t)(packed & 0xffff) / 32768.0f;
            if (right != nullptr) right[frame] = (int16_t)(packed >> 16) / 32768.0f;
        }
        if (copied < frameCount) {
            memset(left + copied, 0, (frameCount - copied) * sizeof(float));
            if (right != nullptr) memset(right + copied, 0, (frameCount - copied) * sizeof(float));
            ring.underrunFrames.fetch_add(frameCount - copied, std::memory_order_relaxed);
        }
        ring.readPosition.store(read + copied, std::memory_order_release);
        dispatch_semaphore_signal(ring.wake);
        return noErr;
    }];
    static dispatch_once_t producerOnce;
    dispatch_once(&producerOnce, ^{
        gSynthRing.wake = dispatch_semaphore_create(0);
        pthread_t thread;
        if (pthread_create(&thread, nullptr, JakSynthProducerMain, nullptr) == 0) {
            pthread_detach(thread);
        } else {
            NSLog(@"Jak1AudioManager: could not start the synth thread");
        }
    });
    [_engine attachNode:_synthNode];
    NSError *error = nil;
    if (!JakConnectNode(_engine, _synthNode, _mainMixer, format, &error)) {
        NSLog(@"Jak1AudioManager: could not connect the 989snd node: %@", error.localizedDescription);
    }
    _synthNode.volume = _masterVolume;
}

- (void)startAudioEngine {
    std::lock_guard<std::mutex> lock(_engineMutex);
    if (!_engine.isRunning) {
        NSError *error = nil;
        [_engine startAndReturnError:&error];
        if (error) {
            NSLog(@"Jak1AudioManager: Failed to start audio engine: %@", error.localizedDescription);
        } else {
            NSLog(@"Jak1AudioManager: Audio engine started successfully.");
        }
    }
}

- (void)stopAudioEngine {
    std::lock_guard<std::mutex> lock(_engineMutex);
    if (_engine.isRunning) {
        [_engine stop];
    }
}

// Engine queue only.
- (void)restartAfterEngineStop {
    // Source nodes resume with the engine; the stream continues where it stopped.
    [self startAudioEngine];
}

// Engine queue only. Brings output back after an interruption: reactivate the session, then
// restart the engine if the synth has stopped rendering. An engine that still claims to be
// running but renders nothing is stopped first, since -startAndReturnError: does nothing to a
// "running" engine.
- (void)recoverAudioOutput {
    NSError *error = nil;
#if TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
    if (![[AVAudioSession sharedInstance] setActive:YES error:&error]) {
        NSLog(@"Jak1AudioManager: could not reactivate the audio session: %@", error.localizedDescription);
    }
#endif
    const uint64_t before = gSynthRenderCount.load();
    [self startAudioEngine];
    // Give a running engine a moment to call back before deciding it is stuck.
    __weak Jak1AudioManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), _engineQueue, ^{
        Jak1AudioManager *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (gSynthRenderCount.load() == before && strongSelf->_appActive) {
            NSLog(@"Jak1AudioManager: no audio rendered after recovery; restarting the engine");
            [strongSelf stopAudioEngine];
            [strongSelf startAudioEngine];
        }
        strongSelf->_recoveryPending = false;
    });
}

- (void)serviceAudioEngine {
    const CFTimeInterval now = CACurrentMediaTime();
    if (now - _watchdogCheckTime < kRenderStallSeconds) return;
    const uint64_t underruns = gSynthRing.underrunFrames.load(std::memory_order_relaxed);
    if (underruns != _watchdogUnderrunFrames) {
        NSLog(@"jakIOS perf audio: synth underran by %llu frames (%.1f ms) in the last %.1f s",
              underruns - _watchdogUnderrunFrames, (underruns - _watchdogUnderrunFrames) / 48.0,
              now - _watchdogCheckTime);
        _watchdogUnderrunFrames = underruns;
    }
    const uint64_t count = gSynthRenderCount.load(std::memory_order_relaxed);
    const bool stalled = count == _watchdogRenderCount;
    _watchdogRenderCount = count;
    _watchdogCheckTime = now;
    if (!stalled || !_appActive || _recoveryPending.exchange(true)) return;
    NSLog(@"Jak1AudioManager: audio output stalled; recovering");
    __weak Jak1AudioManager *weakSelf = self;
    dispatch_async(_engineQueue, ^{
        Jak1AudioManager *strongSelf = weakSelf;
        if (strongSelf != nil) [strongSelf recoverAudioOutput];
    });
}

// Asynchronous start for the kernel thread, which must not wait on an engine restart.
- (void)startAudioEngineAsync {
    __weak Jak1AudioManager *weakSelf = self;
    dispatch_async(_engineQueue, ^{
        [weakSelf startAudioEngine];
    });
}

- (std::shared_ptr<JakVAGStream>)currentStream {
    std::lock_guard<std::mutex> lock(_streamMutex);
    return _stream;
}

// Callers hold @synchronized(self).
- (void)publishStream:(std::shared_ptr<JakVAGStream>)stream {
    std::lock_guard<std::mutex> lock(_streamMutex);
    _stream = std::move(stream);
}

- (void)setMasterVolume:(float)volume {
    @synchronized (self) {
        _masterVolume = fmaxf(0.0f, fminf(1.0f, volume));
        _synthNode.volume = _masterVolume;
        [self applyStreamVolume];
    }
}

- (void)configureContentDirectory:(NSURL *)contentDirectory {
    // Disc files are looked up case-insensitively anywhere under the content directory; index
    // the tree once instead of walking it for every bank, music and stream lookup.
    NSMutableDictionary<NSString *, NSURL *> *files = [NSMutableDictionary dictionary];
    if (contentDirectory != nil) {
        NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
            enumeratorAtURL:contentDirectory includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *candidate in enumerator) {
            NSString *key = candidate.lastPathComponent.lowercaseString;
            if (files[key] == nil) files[key] = candidate;
        }
    }
    @synchronized (self) {
        _contentDirectory = contentDirectory;
        _contentFiles = [files copy];
    }
    __weak Jak1AudioManager *weakSelf = self;
    jak1sound::Init([weakSelf](const char *fileName) -> std::vector<uint8_t> {
        Jak1AudioManager *strongSelf = weakSelf;
        NSString *name = [NSString stringWithUTF8String:fileName];
        NSURL *url = name == nil ? nil : [strongSelf URLForContentFileNamed:name];
        NSData *data = url == nil ? nil : [NSData dataWithContentsOfURL:url];
        if (data == nil) return {};
        const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
        return std::vector<uint8_t>(bytes, bytes + data.length);
    });
    [self startAudioEngine];
}

- (NSURL *)URLForVAGNamed:(NSString *)name {
    if (_contentDirectory == nil || name.length == 0) {
        return nil;
    }
    NSString *safeName = name.lastPathComponent;
    NSArray<NSString *> *extensions = safeName.pathExtension.length > 0 ? @[@""] : @[@"VAG", @"vag", @""];
    NSArray<NSString *> *directories = @[@"VAG", @"vag", @""];
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *directory in directories) {
        for (NSString *extension in extensions) {
            NSString *fileName = extension.length > 0 ? [safeName stringByAppendingPathExtension:extension] : safeName;
            NSURL *base = directory.length > 0 ? [_contentDirectory URLByAppendingPathComponent:directory] : _contentDirectory;
            NSURL *candidate = [base URLByAppendingPathComponent:fileName];
            if ([files fileExistsAtPath:candidate.path]) {
                return candidate;
            }
        }
    }

    NSString *target = safeName.pathExtension.length > 0 ? safeName : [safeName stringByAppendingPathExtension:@"vag"];
    return [self URLForContentFileNamed:target];
}

// Takes no lock: the overlord's bank reader calls this while holding its own lock, and the
// index is an immutable dictionary replaced only by configureContentDirectory.
- (NSURL *)URLForContentFileNamed:(NSString *)name {
    NSDictionary<NSString *, NSURL *> *files = _contentFiles;
    return files[name.lowercaseString];
}

- (NSData *)packedVAGDataNamed:(NSString *)name dataOffset:(NSUInteger *)dataOffset {
    NSURL *directoryURL = [self URLForContentFileNamed:@"VAGDIR.AYB"];
    NSData *directory = directoryURL == nil ? nil : [NSData dataWithContentsOfURL:directoryURL];
    if (directory.length < 16) return nil;

    const uint8_t *directoryBytes = static_cast<const uint8_t *>(directory.bytes);
    uint32_t count = 0;
    memcpy(&count, directoryBytes, sizeof(count));
    count = MIN(count, (uint32_t)((directory.length - 4) / 12));
    NSString *normalized = name.lastPathComponent.stringByDeletingPathExtension.uppercaseString;
    NSData *asciiName = [normalized dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t target[8];
    memset(target, ' ', sizeof(target));
    memcpy(target, asciiName.bytes, MIN(asciiName.length, sizeof(target)));

    uint32_t sectorOffset = UINT32_MAX;
    for (uint32_t index = 0; index < count; index++) {
        const uint8_t *entry = directoryBytes + 4 + index * 12;
        if (memcmp(entry, target, 8) == 0) {
            memcpy(&sectorOffset, entry + 8, sizeof(sectorOffset));
            break;
        }
    }
    if (sectorOffset == UINT32_MAX) return nil;

    NSURL *wadURL = [self URLForContentFileNamed:@"VAGWAD.ENG"];
    if (wadURL == nil) {
        NSDictionary<NSString *, NSURL *> *files = _contentFiles;
        for (NSString *key in files) {
            if ([key hasPrefix:@"vagwad."]) {
                wadURL = files[key];
                break;
            }
        }
    }
    NSData *wad = wadURL == nil ? nil : [NSData dataWithContentsOfURL:wadURL
                                                               options:NSDataReadingMappedIfSafe
                                                                 error:nil];
    uint64_t byteOffset = (uint64_t)sectorOffset * 2048;
    if (wad == nil || byteOffset + 0x30 > wad.length) return nil;
    *dataOffset = (NSUInteger)byteOffset;
    return wad;
}

- (BOOL)playVAGStreamNamed:(NSString *)name {
    @synchronized (self) {
        NSURL *url = [self URLForVAGNamed:name];
        NSData *data = url == nil ? nil : [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        NSUInteger dataOffset = 0;
        if (data == nil) {
            data = [self packedVAGDataNamed:name dataOffset:&dataOffset];
        }
        if (data.length < dataOffset + 0x40) {
            NSLog(@"Jak1AudioManager: VAG stream not found or invalid: %@", name);
            return NO;
        }

        const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes) + dataOffset;
        if (memcmp(bytes, "VAGp", 4) != 0) {
            NSLog(@"Jak1AudioManager: Unsupported VAG header for %@", name);
            return NO;
        }
        uint32_t availableSize = (uint32_t)MIN(data.length - dataOffset - 0x30, (NSUInteger)UINT32_MAX);
        uint32_t encodedSize = MIN(JakReadBigEndian32(bytes + 12), availableSize);
        uint32_t sampleRate = JakReadBigEndian32(bytes + 16);
        if (encodedSize < 16 || sampleRate < 8000 || sampleRate > 192000) {
            return NO;
        }

        auto stream = std::make_shared<JakVAGStream>();
        stream->samples.resize((encodedSize / 16) * 28);

        static const double coefficients[5][2] = {
            {0.0, 0.0}, {60.0 / 64.0, 0.0}, {115.0 / 64.0, -52.0 / 64.0},
            {98.0 / 64.0, -55.0 / 64.0}, {122.0 / 64.0, -60.0 / 64.0}
        };
        float *output = stream->samples.data();
        uint32_t frame = 0;
        double previous1 = 0.0;
        double previous2 = 0.0;
        for (uint32_t offset = 0x30; offset + 16 <= 0x30 + encodedSize; offset += 16) {
            uint8_t predictor = bytes[offset] >> 4;
            uint8_t shift = bytes[offset] & 0x0f;
            if (predictor > 4) predictor = 0;
            for (int sampleIndex = 0; sampleIndex < 28; sampleIndex++) {
                uint8_t packed = bytes[offset + 2 + sampleIndex / 2];
                int sample = (sampleIndex & 1) ? (packed >> 4) : (packed & 0x0f);
                if (sample >= 8) sample -= 16;
                double decoded = (sample * (1 << 12) >> shift) +
                    previous1 * coefficients[predictor][0] + previous2 * coefficients[predictor][1];
                decoded = fmax(-32768.0, fmin(32767.0, decoded));
                output[frame++] = (float)(decoded / 32768.0);
                previous2 = previous1;
                previous1 = decoded;
            }
            if (bytes[offset + 1] & 0x01) break;
        }
        stream->samples.resize(frame);
        stream->sampleRate = sampleRate;

        [self stopVAGStream];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
        std::shared_ptr<JakVAGStream> rendered = stream;
        _streamNode = [[AVAudioSourceNode alloc] initWithFormat:format
                                                    renderBlock:^OSStatus(BOOL *isSilence,
                                                                          const AudioTimeStamp *timestamp,
                                                                          AVAudioFrameCount frameCount,
                                                                          AudioBufferList *outputData) {
            float *left = static_cast<float *>(outputData->mBuffers[0].mData);
            float *right = outputData->mNumberBuffers > 1 ?
                static_cast<float *>(outputData->mBuffers[1].mData) : nullptr;
            JakVAGStream &state = *rendered;
            const uint64_t count = state.samples.size();
            uint64_t position = state.position.load(std::memory_order_relaxed);
            if (state.paused.load(std::memory_order_relaxed) || position >= count) {
                memset(left, 0, frameCount * sizeof(float));
                if (right != nullptr) memset(right, 0, frameCount * sizeof(float));
                *isSilence = YES;
                return noErr;
            }
            // Ramp to new gains across one buffer so per-frame falloff updates don't click.
            const float targetLeft = state.gainLeft.load(std::memory_order_relaxed);
            const float targetRight = state.gainRight.load(std::memory_order_relaxed);
            if (!state.gainsInitialized) {
                state.renderedLeft = targetLeft;
                state.renderedRight = targetRight;
                state.gainsInitialized = true;
            }
            const float stepLeft = (targetLeft - state.renderedLeft) / frameCount;
            const float stepRight = (targetRight - state.renderedRight) / frameCount;
            for (AVAudioFrameCount index = 0; index < frameCount; index++) {
                const float sample = position < count ? state.samples[position++] : 0.0f;
                state.renderedLeft += stepLeft;
                state.renderedRight += stepRight;
                left[index] = sample * state.renderedLeft;
                if (right != nullptr) right[index] = sample * state.renderedRight;
            }
            state.renderedLeft = targetLeft;
            state.renderedRight = targetRight;
            state.position.store(position, std::memory_order_relaxed);
            return noErr;
        }];
        [self publishStream:stream];
        _streamVolume = 1.0f;
        _streamPositioned = NO;
        [self applyStreamVolume];
        [_engine attachNode:_streamNode];
        NSError *connectError = nil;
        if (!JakConnectNode(_engine, _streamNode, _mainMixer, format, &connectError)) {
            NSLog(@"Jak1AudioManager: could not connect VAG stream %@: %@", name, connectError.localizedDescription);
            [_engine detachNode:_streamNode];
            _streamNode = nil;
            [self publishStream:nullptr];
            return NO;
        }
        [self startAudioEngineAsync];
        NSLog(@"Jak1AudioManager: Playing %@ (%u frames at %u Hz)", name, frame, sampleRate);
        return YES;
    }
}

// Polled by the kernel thread every frame: takes only _streamMutex.
- (BOOL)isVAGStreamActive {
    const std::shared_ptr<JakVAGStream> stream = [self currentStream];
    // Over once every sample has been rendered (StopVAG at the end of the data).
    return stream != nullptr && stream->position.load() < stream->samples.size();
}

- (void)stopVAGStream {
    @synchronized (self) {
        [self publishStream:nullptr];
        if (_streamNode != nil) {
            [_engine detachNode:_streamNode];
            _streamNode = nil;
        }
    }
}

// Polled by the kernel thread every frame: takes only _streamMutex.
- (double)VAGStreamPlaybackSeconds {
    const std::shared_ptr<JakVAGStream> stream = [self currentStream];
    if (stream == nullptr || stream->sampleRate <= 0) return -1.0;
    const uint64_t played = std::min<uint64_t>(stream->position.load(), stream->samples.size());
    if (played == 0) return -1.0;
    return (double)played / stream->sampleRate;
}

- (void)pauseVAGStream {
    const std::shared_ptr<JakVAGStream> stream = [self currentStream];
    if (stream != nullptr) stream->paused = true;
}

- (void)resumeVAGStream {
    const std::shared_ptr<JakVAGStream> stream = [self currentStream];
    if (stream != nullptr) {
        stream->paused = false;
        [self startAudioEngineAsync];
    }
}

// CalculateVAGVolumes (overlord iso.cpp) gives the stream voice's VOLL/VOLR registers; a
// register of 0x3fff is unity gain. Streams don't pass through AdjustVolToGroup.
- (void)applyStreamVolume {
    if (_stream == nullptr) return;
    int32_t left = 0, right = 0;
    jak1sound::CalculateVAGVolumes((int32_t)lroundf(_streamVolume * 1024.0f),
                                   (int32_t)lroundf(_dialogVolume * 1024.0f), _streamPositioned,
                                   _streamTrans, &left, &right);
    const float scale = kSynthMasterGain * _masterVolume / (float)0x3fff;
    _stream->gainLeft = left * scale;
    _stream->gainRight = right * scale;
}

- (void)setVAGStreamVolume:(float)volume {
    @synchronized (self) {
        _streamVolume = fmaxf(0.0f, volume);
        [self applyStreamVolume];
    }
}

- (void)setDialogVolume:(float)volume {
    @synchronized (self) {
        _dialogVolume = fmaxf(0.0f, volume);
        [self applyStreamVolume];
    }
}

- (void)setVAGStreamPosition:(const int32_t *)trans {
    @synchronized (self) {
        _streamPositioned = trans != nullptr;
        if (trans != nullptr) memcpy(_streamTrans, trans, sizeof(_streamTrans));
        [self applyStreamVolume];
    }
}

- (void)refreshVAGStreamVolume {
    @synchronized (self) {
        if (_streamPositioned) [self applyStreamVolume];
    }
}

@end
