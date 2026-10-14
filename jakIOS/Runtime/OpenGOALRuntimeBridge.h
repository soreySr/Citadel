#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>
#import "Jak1DGOExtractor.h"
#import "Jak1PCTextBuilder.h"
#import "Jak1LevelBuilder.h"

NS_ASSUME_NONNULL_BEGIN

/// The primary Objective-C surface exposed to SwiftUI by the native Jak 1 runtime host.
@interface OGJak1RuntimeHost : NSObject

/// contentURL is the imported game directory: the captured GOAL arena is rebuilt from its disc files.
- (instancetype)initWithDevice:(id<MTLDevice>)device
                    contentURL:(nullable NSURL *)contentURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Sets the app-private location of imported game content for the AOT runtime to access.
- (void)configureContentURL:(nullable NSURL *)contentURL;

/// Receives drawable-size changes from the Metal view.
- (void)resizeToWidth:(CGFloat)width height:(CGFloat)height;

/// The internal render resolution selected by the in-game graphics menu.
- (CGSize)gameResolution;

/// Supplies the active iOS display's maximum refresh rate to the in-game options.
- (void)configureDisplayRefreshRate:(NSInteger)framesPerSecond;

/// The currently selected frame rate, clamped to the active display's capability.
- (NSInteger)preferredFrameRate;

/// True while the game's title plays under the app's start screen without input.
/// Leaving attract mode presses Start once, opening the game's title menu.
- (void)setTitleAttractMode:(BOOL)attract;

/// True while the game's title is loaded and held on black, waiting for startTitleIntro.
- (BOOL)isTitleIntroReady;

/// Starts the held title logo sequence.
- (void)startTitleIntro;

/// True while the game's title shows "press start" (target-title-wait).
- (BOOL)isTitleWaitingForStart;

/// True while the game's pause/progress menu is open (*progress-process* is live).
- (BOOL)isMenuOpen;

/// True while a warp gate (teleporter) is choosing a destination with D-pad Left/Right.
- (BOOL)isWarpGateActive;

/// True while a cutscene plays (the game's movie?), when only Pause is shown.
- (BOOL)isCutsceneActive;

/// True while Jak rides the zoomer, when R1 moves to the left side of the screen.
- (BOOL)isOnZoomer;

/// True once Jak exists and the screen isn't faded to black (e.g. the black screen while a game
/// loads), so the touch controls only appear with the game.
- (BOOL)isGameVisible;

/// True while the pause menu shows a collectible page (power cells, orbs, scout flies), where
/// Start resumes the game.
- (BOOL)isMenuOnCollectionPage;

/// True while *target* is in a title state (logo intro or "press start"), menu open or not.
- (BOOL)isOnTitleScreen;

/// True while the main third-person camera (cam-string) is active, so swipe movement can turn it
/// directly through addCameraLookYaw:zoom: instead of the right stick's speed-capped curve.
- (BOOL)isDirectCameraLookAvailable;

/// True while the camera is in an aiming mode the left stick drives (first-person look, Billy's
/// shooting game). Swipe camera input is ignored there.
- (BOOL)isCameraAimingMode;

/// Live values from Game Options > Input Options > Touch Options.
- (BOOL)isSwipeCameraEnabled;
- (BOOL)isFloatingRightJoystickEnabled;
- (BOOL)isFloatingLeftJoystickEnabled;
- (BOOL)isHapticFeedbackEnabled;

/// True while the title's New Game slot screen is up and mirror mode is unlocked (game beaten):
/// the app shows the Mirror Mode checkbox. The checked value applies to the new game's save.
- (BOOL)isNewGameMirrorOptionVisible;
- (BOOL)isNewGameMirrorChecked;
- (void)setNewGameMirrorChecked:(BOOL)checked;

/// Queues swipe camera movement for the next game frame: turn in degrees (positive = stick right)
/// and zoom in view-off-param units (positive = stick up). Follows the third-person invert settings.
/// `touching` is whether a finger is on the swipe area: the camera tracks it rigidly while down
/// and stops where it is once it lifts.
- (void)addCameraLookYaw:(double)yawDegrees zoom:(double)zoom touching:(BOOL)touching;

/// Touch menu input (touch controls, progress menu open). Applied on the next game frames as the
/// pad presses the menu expects, so the game's own menu logic still runs.
/// A tap at a point normalized to the game view (0...1, origin top-left; `viewAspect` = width /
/// height): selects and engages the option under it, or the pause screen's button it covers.
- (void)menuTapAtX:(double)x y:(double)y viewAspect:(double)viewAspect
    NS_SWIFT_NAME(menuTap(atX:y:viewAspect:));
/// A finger went down at this point (same coordinates as a tap): the option or save slot under it
/// is selected and drawn highlighted until the finger lifts (the tap) or `menuPressCancel`.
- (void)menuPressAtX:(double)x y:(double)y viewAspect:(double)viewAspect
    NS_SWIFT_NAME(menuPress(atX:y:viewAspect:));
/// The pressed finger turned into a swipe: the highlight goes away.
- (void)menuPressCancel;
/// Scrolls the current list by whole rows (positive reveals later rows). On the pause screen's
/// collectible pages a swipe moves one level: only its first scroll (`startsSwipe`) counts.
- (void)menuScrollByRows:(NSInteger)rows startsSwipe:(BOOL)startsSwipe
    NS_SWIFT_NAME(menuScroll(byRows:startsSwipe:));
/// Left (negative) or right (positive) presses. While a carousel option is being changed a swipe
/// moves one value: only its first step (`startsSwipe`) counts.
- (void)menuStepHorizontal:(NSInteger)steps startsSwipe:(BOOL)startsSwipe
    NS_SWIFT_NAME(menuStepHorizontal(_:startsSwipe:));
/// Goes back one menu (Triangle), or resumes the game (Start) when the pause menu has no
/// earlier menu to go back to.
- (void)menuBack;
/// True while the touch controls are in use: menus draw the highlighted (yellow) option in the
/// same color as the others, since there's no cursor. False restores the highlight.
- (void)setTouchMenuStyle:(BOOL)touchMenus;

/// Receives raw extended-gamepad input. Jak-specific bindings remain in the AOT runtime.
- (void)updateWithLeftX:(float)leftX
                  leftY:(float)leftY
                 rightX:(float)rightX
                 rightY:(float)rightY
                buttonA:(BOOL)buttonA
                buttonB:(BOOL)buttonB
                buttonX:(BOOL)buttonX
                buttonY:(BOOL)buttonY
           leftShoulder:(BOOL)leftShoulder
          rightShoulder:(BOOL)rightShoulder
            leftTrigger:(float)leftTrigger
           rightTrigger:(float)rightTrigger
                   menu:(BOOL)menu
                 select:(BOOL)select
              leftThumb:(BOOL)leftThumb
             rightThumb:(BOOL)rightThumb
                 dpadUp:(BOOL)dpadUp
               dpadDown:(BOOL)dpadDown
               dpadLeft:(BOOL)dpadLeft
              dpadRight:(BOOL)dpadRight;

/// Digital controls that went down (a new touch) since the previous update. Call before
/// `updateWithLeftX:...`. A control released and pressed again between two pad reads would
/// otherwise look held the whole time and the game would miss the second press (a jump).
- (void)notePressesWithButtonA:(BOOL)buttonA
                       buttonB:(BOOL)buttonB
                       buttonX:(BOOL)buttonX
                       buttonY:(BOOL)buttonY
                  leftShoulder:(BOOL)leftShoulder
                 rightShoulder:(BOOL)rightShoulder
                   leftTrigger:(BOOL)leftTrigger
                  rightTrigger:(BOOL)rightTrigger
                          menu:(BOOL)menu
                        select:(BOOL)select
                     leftThumb:(BOOL)leftThumb
                    rightThumb:(BOOL)rightThumb
                        dpadUp:(BOOL)dpadUp
                      dpadDown:(BOOL)dpadDown
                      dpadLeft:(BOOL)dpadLeft
                     dpadRight:(BOOL)dpadRight;

/// Describes whether the signed AOT executor and native GOAL kernel are ready for execution.
- (NSString *)bootstrapReadiness;

/// Encodes one frame and dispatches the native GOAL kernel frame execution loop.
- (void)drawInView:(MTKView *)view;

@end

NS_ASSUME_NONNULL_END
