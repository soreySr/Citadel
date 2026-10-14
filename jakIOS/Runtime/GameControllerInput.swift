import Combine
import Foundation
import GameController

@MainActor
public final class TouchInputState: ObservableObject {
    public static let shared = TouchInputState()

    // Control values are read once per frame by the input reader and drawn by no view, so they
    // aren't @Published: publishing them re-rendered the whole overlay (and the shell around the
    // game view) on the main thread for every stick move and button press, delaying touches.
    public var leftX: Float = 0
    public var leftY: Float = 0
    public var rightX: Float = 0
    public var rightY: Float = 0
    public var buttonA: Bool = false
    public var buttonB: Bool = false
    public var buttonX: Bool = false
    public var buttonY: Bool = false
    public var leftShoulder: Bool = false
    public var rightShoulder: Bool = false
    public var leftTrigger: Float = 0
    public var rightTrigger: Float = 0
    public var menu: Bool = false
    public var select: Bool = false
    public var leftThumb: Bool = false
    public var rightThumb: Bool = false
    public var dpadUp: Bool = false
    public var dpadDown: Bool = false
    public var dpadLeft: Bool = false
    public var dpadRight: Bool = false
    /// Mirrors the game's pause/progress menu so the overlay can show a D-pad instead of the stick.
    @Published public var isMenuOpen: Bool = false
    /// The pause menu shows a collectible page: the corner button resumes the game instead of Back.
    @Published public var isOnCollectionPage: Bool = false
    /// The game shows its title ("press start") with no menu open: no pad controls are shown.
    @Published public var isOnTitleScreen: Bool = false
    /// The game is on screen (not the black loading screen): gameplay controls are shown.
    @Published public var isGameVisible: Bool = false
    /// A warp gate is choosing a destination: swipes pick it (D-pad Left/Right) instead of moving.
    @Published public var isWarpGateActive: Bool = false
    /// A cutscene is playing: only Pause is shown.
    @Published public var isCutsceneActive: Bool = false
    /// Jak is riding the zoomer: R1 moves to the left side, under Pause.
    @Published public var isOnZoomer: Bool = false
    /// Touch control choices configured by the native in-game Touch Options menu.
    @Published public var isSwipeCameraEnabled: Bool = true
    @Published public var isFloatingRightJoystickEnabled: Bool = true
    @Published public var isFloatingLeftJoystickEnabled: Bool = true
    /// Plays a light tap when an on-screen button (not a joystick) is pressed.
    public var isHapticFeedbackEnabled: Bool = true
    /// The on-screen controls are in use (no physical controller), so menus are tapped directly.
    public var isTouchControlsActive = true
    /// The New Game slot screen offers mirror mode for the new save (unlocked by beating the game).
    @Published public var isNewGameMirrorOptionVisible: Bool = false
    @Published public var isNewGameMirrorChecked: Bool = false
    /// A tap on the Mirror Mode checkbox, handed to the runtime on the next frame.
    var pendingNewGameMirrorToggle = false

    /// Controls pressed since the last `consumeTaps()`. Input is sampled once per frame, so a tap
    /// whose touch-down and touch-up land between two samples would otherwise never be seen.
    private var taps: Set<PartialKeyPath<TouchInputState>> = []

    public func setButton(_ button: ReferenceWritableKeyPath<TouchInputState, Bool>, pressed: Bool) {
        self[keyPath: button] = pressed
        if pressed { taps.insert(button) }
    }

    public func setTrigger(_ trigger: ReferenceWritableKeyPath<TouchInputState, Float>, pressed: Bool) {
        self[keyPath: trigger] = pressed ? 1 : 0
        if pressed { taps.insert(trigger) }
    }

    func consumeTaps() -> Set<PartialKeyPath<TouchInputState>> {
        defer { taps.removeAll() }
        return taps
    }

    // MARK: - Touch menus

    /// What the menu touch layer asks of the game's menu; the runtime turns these into presses.
    enum MenuTouchEvent {
        /// A finger went down (same coordinates as `tap`): what's under it is highlighted.
        case press(CGPoint, viewAspect: Double)
        /// The pressed finger became a swipe: the highlight is dropped.
        case pressCancel
        /// A tap, normalized to the game view (0...1, origin top-left), with the view's aspect.
        case tap(CGPoint, viewAspect: Double)
        /// Scroll by whole rows (positive reveals later rows). `startsSwipe` marks a swipe's first
        /// scroll, so pages that move one entry per swipe can ignore the rest of it.
        case scroll(rows: Int, startsSwipe: Bool)
        /// Left (negative) or right (positive) presses. `startsSwipe` marks a swipe's first step,
        /// so options that change once per swipe (carousels) can ignore the rest of it.
        case horizontal(steps: Int, startsSwipe: Bool)
        case back
    }

    private var menuEvents: [MenuTouchEvent] = []

    func sendMenuEvent(_ event: MenuTouchEvent) {
        menuEvents.append(event)
    }

    func takeMenuEvents() -> [MenuTouchEvent] {
        defer { menuEvents.removeAll() }
        return menuEvents
    }

    // MARK: - Swipe camera

    /// Camera rotation (degrees) and zoom (view-off-param units) the thumb has asked for but the
    /// emulated right stick hasn't delivered yet. Not @Published: it changes on every touch move.
    private var pendingCameraYaw: Double = 0
    private var pendingCameraZoom: Double = 0
    private var lastCameraTouchLocation: CGPoint?
    private var lastCameraSampleTime: TimeInterval?

    /// Feeds the camera swipe finger's location (`nil` when it lifts). Movement since the previous
    /// location becomes camera rotation/zoom, handed to the runtime directly (`takeCameraSwipe`) in
    /// the main third-person camera, or played back on the right stick (`consumeCameraStick`).
    public func trackCameraTouch(at location: CGPoint?) {
        if let location, let last = lastCameraTouchLocation {
            let limits = SwipeCamera.self
            pendingCameraYaw = (pendingCameraYaw + Double(location.x - last.x) * limits.degreesPerPoint)
                .clamped(to: -limits.maxPendingYaw...limits.maxPendingYaw)
            // Thumb up (negative screen y) acts like pushing the stick up.
            pendingCameraZoom = (pendingCameraZoom - Double(location.y - last.y) * limits.zoomPerPoint)
                .clamped(to: -limits.maxPendingZoom...limits.maxPendingZoom)
        }
        lastCameraTouchLocation = location
    }

    /// A finger is on the swipe camera area.
    var isCameraTouchActive: Bool { lastCameraTouchLocation != nil }

    /// Hands over all pending swipe movement: turn in degrees (positive = stick right) and zoom
    /// (positive = stick up). Used when the runtime can apply it directly, without the stick's
    /// dead zone and top speed.
    func takeCameraSwipe() -> (yaw: Double, zoom: Double) {
        defer {
            pendingCameraYaw = 0
            pendingCameraZoom = 0
        }
        return (pendingCameraYaw, pendingCameraZoom)
    }

    /// Fallback for camera states the runtime can't drive directly (first person, circular, ...):
    /// right stick values that make the game's camera cover the pending swipe this frame. The stick sets a turn *rate*, so the pending amount is divided by
    /// the frame time and run back through the game's analog curves (dead zone and top speed),
    /// then the amount actually delivered is removed. Whatever is left (rounding, or a swipe
    /// faster than the stick's top speed) carries into the next frame, so the camera ends up
    /// where the thumb went.
    func consumeCameraStick(now: TimeInterval) -> (x: Float, y: Float) {
        let dt = lastCameraSampleTime.map { (now - $0).clamped(to: (1.0 / 240)...(1.0 / 20)) } ?? (1.0 / 60)
        lastCameraSampleTime = now
        // The camera stops when the thumb lifts: drop any catch-up the stick hasn't delivered.
        guard isCameraTouchActive else {
            pendingCameraYaw = 0
            pendingCameraZoom = 0
            return (0, 0)
        }
        typealias Curve = SwipeCamera

        // Horizontal: analog-input(rightx, 128, 32, 110, 120°/s). Bytes 32...110 away from
        // center map linearly onto 0...120°/s.
        var x: Float = 0
        let yawCounts = min((abs(pendingCameraYaw) / dt / Curve.maxYawRate * Curve.yawSpan).rounded(), Curve.yawSpan)
        if yawCounts > 0 {
            let direction: Double = pendingCameraYaw < 0 ? -1 : 1
            pendingCameraYaw -= direction * yawCounts / Curve.yawSpan * Curve.maxYawRate * dt
            x = Curve.stickValue(forByte: 128 + direction * (Curve.yawDeadZone + yawCounts))
        }

        // Vertical: cam-dist-analog-input(righty, 0.05) changes view-off-param by up to 0.05 per
        // 60 Hz frame. Its dead zone is lopsided: stick up uses bytes 28 down to 16, stick down
        // uses bytes 160 up to 240.
        var y: Float = 0
        let zoomPerFrame = abs(pendingCameraZoom) / (dt * 60)
        if pendingCameraZoom > 0 {
            let counts = min((zoomPerFrame / Curve.maxZoomStep * 12).rounded(), 12)
            if counts > 0 {
                pendingCameraZoom -= Curve.maxZoomStep * counts / 12 * dt * 60
                y = -Curve.stickValue(forByte: 28 - counts)
            }
        } else if pendingCameraZoom < 0 {
            let counts = min((zoomPerFrame / Curve.maxZoomStep * 80).rounded(), 80)
            if counts > 0 {
                pendingCameraZoom += Curve.maxZoomStep * counts / 80 * dt * 60
                y = -Curve.stickValue(forByte: 160 + counts)
            }
        }
        return (x, y)
    }

    private func resetCameraSwipe() {
        pendingCameraYaw = 0
        pendingCameraZoom = 0
        lastCameraTouchLocation = nil
    }

    /// Releases every touch control. Used when the overlay is removed mid-press, since its
    /// buttons and sticks will never deliver the matching release.
    public func reset() {
        leftX = 0
        leftY = 0
        rightX = 0
        rightY = 0
        resetCameraSwipe()
        buttonA = false
        buttonB = false
        buttonX = false
        buttonY = false
        leftShoulder = false
        rightShoulder = false
        leftTrigger = 0
        rightTrigger = 0
        menu = false
        select = false
        leftThumb = false
        rightThumb = false
        dpadUp = false
        dpadDown = false
        dpadLeft = false
        dpadRight = false
        taps.removeAll()
        menuEvents.removeAll()
    }

    /// Called every frame. While a controller is attached the overlay is hidden, but a finger that
    /// was on a control when it connected keeps reporting to the fading (then removed) view and
    /// never delivers its lift, which left that control held. Drop anything it reports meanwhile.
    func releaseIfTouchControlsInactive() {
        if !isTouchControlsActive { reset() }
    }
}

/// Tuning for the swipe camera, plus the constants of Jak 1's right-stick curves it emulates.
private enum SwipeCamera {
    /// Camera turn per point of horizontal thumb travel.
    static let degreesPerPoint = 0.4
    /// Zoom (view-off-param, 0 = closest, 1 = farthest) per point of vertical thumb travel.
    static let zoomPerPoint = 1.0 / 250
    /// Caps on undelivered movement, so a hard flick can't keep the camera turning long after.
    static let maxPendingYaw = 40.0
    static let maxPendingZoom = 0.3

    /// cam-string-joystick: 21845.334 rotation units (65536 = 360°) per second at full stick.
    static let maxYawRate = 120.0
    static let yawDeadZone = 32.0
    static let yawSpan = 110.0 - 32.0
    static let maxZoomStep = 0.05

    /// Float the host's axis encoding (`127.5 + v * 127.5`, truncated) turns into `byte`.
    static func stickValue(forByte byte: Double) -> Float {
        Float((byte - 127) / 127.5)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct GameControllerInput {
    let leftX: Float
    let leftY: Float
    let rightX: Float
    let rightY: Float
    let buttonA: Bool
    let buttonB: Bool
    let buttonX: Bool
    let buttonY: Bool
    let leftShoulder: Bool
    let rightShoulder: Bool
    let leftTrigger: Float
    let rightTrigger: Float
    let menu: Bool
    let select: Bool
    let leftThumb: Bool
    let rightThumb: Bool
    let dpadUp: Bool
    let dpadDown: Bool
    let dpadLeft: Bool
    let dpadRight: Bool

    static let neutral = GameControllerInput(
        leftX: 0,
        leftY: 0,
        rightX: 0,
        rightY: 0,
        buttonA: false,
        buttonB: false,
        buttonX: false,
        buttonY: false,
        leftShoulder: false,
        rightShoulder: false,
        leftTrigger: 0,
        rightTrigger: 0,
        menu: false,
        select: false,
        leftThumb: false,
        rightThumb: false,
        dpadUp: false,
        dpadDown: false,
        dpadLeft: false,
        dpadRight: false
    )
}

enum GameControllerInputReader {
    /// True when a physical controller the input reader can use is attached, not counting
    /// `ignored` (one that has just disconnected but can still be listed for a moment).
    @MainActor
    static func isPhysicalControllerConnected(ignoring ignored: GCController? = nil) -> Bool {
        GCController.controllers().contains { $0 !== ignored && $0.extendedGamepad != nil }
    }

    /// The pad for this frame, plus the touch controls pressed since the previous frame (only
    /// the digital controls are meaningful in `presses`). The runtime needs the presses
    /// separately: a control released and pressed again since the last frame reads as held.
    @MainActor
    static func currentInput() -> (input: GameControllerInput, presses: GameControllerInput) {
        let touch = TouchInputState.shared
        // A control counts as held if it is down now or was tapped since the previous frame.
        // This runs every frame: read properties directly, and only build key paths to look up
        // taps when a tap actually happened (key path creation/lookup was a large per-frame cost).
        let taps = touch.consumeTaps()
        func tapped(_ control: @autoclosure () -> PartialKeyPath<TouchInputState>) -> Bool {
            !taps.isEmpty && taps.contains(control())
        }
        let presses = taps.isEmpty ? GameControllerInput.neutral : GameControllerInput(
            leftX: 0,
            leftY: 0,
            rightX: 0,
            rightY: 0,
            buttonA: tapped(\.buttonA),
            buttonB: tapped(\.buttonB),
            buttonX: tapped(\.buttonX),
            buttonY: tapped(\.buttonY),
            leftShoulder: tapped(\.leftShoulder),
            rightShoulder: tapped(\.rightShoulder),
            leftTrigger: tapped(\.leftTrigger) ? 1 : 0,
            rightTrigger: tapped(\.rightTrigger) ? 1 : 0,
            menu: tapped(\.menu),
            select: tapped(\.select),
            leftThumb: tapped(\.leftThumb),
            rightThumb: tapped(\.rightThumb),
            dpadUp: tapped(\.dpadUp),
            dpadDown: tapped(\.dpadDown),
            dpadLeft: tapped(\.dpadLeft),
            dpadRight: tapped(\.dpadRight)
        )
        let cameraStick = touch.isSwipeCameraEnabled ?
            touch.consumeCameraStick(now: ProcessInfo.processInfo.systemUptime) :
            (x: touch.rightX, y: touch.rightY)
        let touchInput = GameControllerInput(
            leftX: touch.leftX,
            leftY: touch.leftY,
            rightX: cameraStick.x,
            rightY: cameraStick.y,
            buttonA: touch.buttonA || tapped(\.buttonA),
            buttonB: touch.buttonB || tapped(\.buttonB),
            buttonX: touch.buttonX || tapped(\.buttonX),
            buttonY: touch.buttonY || tapped(\.buttonY),
            leftShoulder: touch.leftShoulder || tapped(\.leftShoulder),
            rightShoulder: touch.rightShoulder || tapped(\.rightShoulder),
            leftTrigger: tapped(\.leftTrigger) ? 1 : touch.leftTrigger,
            rightTrigger: tapped(\.rightTrigger) ? 1 : touch.rightTrigger,
            menu: touch.menu || tapped(\.menu),
            select: touch.select || tapped(\.select),
            leftThumb: touch.leftThumb || tapped(\.leftThumb),
            rightThumb: touch.rightThumb || tapped(\.rightThumb),
            dpadUp: touch.dpadUp || tapped(\.dpadUp),
            dpadDown: touch.dpadDown || tapped(\.dpadDown),
            dpadLeft: touch.dpadLeft || tapped(\.dpadLeft),
            dpadRight: touch.dpadRight || tapped(\.dpadRight)
        )
        guard let gamepad = GCController.controllers().lazy.compactMap(\.extendedGamepad).first else {
            return (touchInput, presses)
        }

        let input = GameControllerInput(
            leftX: abs(touchInput.leftX) > abs(gamepad.leftThumbstick.xAxis.value) ? touchInput.leftX : gamepad.leftThumbstick.xAxis.value,
            leftY: abs(touchInput.leftY) > abs(gamepad.leftThumbstick.yAxis.value) ? touchInput.leftY : gamepad.leftThumbstick.yAxis.value,
            rightX: abs(touchInput.rightX) > abs(gamepad.rightThumbstick.xAxis.value) ? touchInput.rightX : gamepad.rightThumbstick.xAxis.value,
            rightY: abs(touchInput.rightY) > abs(gamepad.rightThumbstick.yAxis.value) ? touchInput.rightY : gamepad.rightThumbstick.yAxis.value,
            buttonA: touchInput.buttonA || gamepad.buttonA.isPressed,
            buttonB: touchInput.buttonB || gamepad.buttonB.isPressed,
            buttonX: touchInput.buttonX || gamepad.buttonX.isPressed,
            buttonY: touchInput.buttonY || gamepad.buttonY.isPressed,
            leftShoulder: touchInput.leftShoulder || gamepad.leftShoulder.isPressed,
            rightShoulder: touchInput.rightShoulder || gamepad.rightShoulder.isPressed,
            leftTrigger: max(touchInput.leftTrigger, gamepad.leftTrigger.value),
            rightTrigger: max(touchInput.rightTrigger, gamepad.rightTrigger.value),
            menu: touchInput.menu || gamepad.buttonMenu.isPressed,
            select: touchInput.select || (gamepad.buttonOptions?.isPressed ?? false),
            leftThumb: touchInput.leftThumb || (gamepad.leftThumbstickButton?.isPressed ?? false),
            rightThumb: touchInput.rightThumb || (gamepad.rightThumbstickButton?.isPressed ?? false),
            dpadUp: touchInput.dpadUp || gamepad.dpad.up.isPressed,
            dpadDown: touchInput.dpadDown || gamepad.dpad.down.isPressed,
            dpadLeft: touchInput.dpadLeft || gamepad.dpad.left.isPressed,
            dpadRight: touchInput.dpadRight || gamepad.dpad.right.isPressed
        )
        return (input, presses)
    }
}
