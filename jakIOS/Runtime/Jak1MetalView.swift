import GameController
import MetalKit
import SwiftUI

/// Renders the 3D drawable below native Retina scale while UI overlays stay native. UIKit
/// resets `contentScaleFactor` to the screen scale when a view joins a window, so the cap is
/// re-applied there (setting it once at creation left 3x phones rendering at full resolution).
final class ScaledMTKView: MTKView {
    /// 2x on a 3x phone is 67% linear resolution (44% of the full-resolution fragment work).
    static let maximumScale: CGFloat = 2.0

    var cappedNativeScale: CGFloat {
        min(window?.screen.scale ?? traitCollection.displayScale, Self.maximumScale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyScaleCap()
    }

    override func layoutSubviews() {
        applyScaleCap()
        super.layoutSubviews()
    }

    private func applyScaleCap() {
        let scale = cappedNativeScale
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
    }
}

struct Jak1MetalView: UIViewRepresentable {
    let contentURL: URL?
    /// When false the game keeps running but sees a neutral pad (e.g. title attract mode behind the start screen).
    var acceptsInput = true
    /// Called once, when the game's title is loaded and held on black (waiting for startsTitleIntro).
    var onTitleIntroReady: (() -> Void)?
    /// Set to start the held title logo sequence.
    var startsTitleIntro = false
    /// Called once, when the game's title starts showing "press start".
    var onTitleReadyForStart: (() -> Void)?
    /// Called when a controller's Start is pressed while the game isn't taking input.
    var onStartPressed: (() -> Void)?
    let onBootstrapReadiness: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(contentURL: contentURL, onBootstrapReadiness: onBootstrapReadiness)
    }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.acceptsInput = acceptsInput
        context.coordinator.onTitleIntroReady = onTitleIntroReady
        context.coordinator.onTitleReadyForStart = onTitleReadyForStart
        context.coordinator.onStartPressed = onStartPressed
        return context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.acceptsInput = acceptsInput
        context.coordinator.startsTitleIntro = startsTitleIntro
        context.coordinator.onTitleIntroReady = onTitleIntroReady
        context.coordinator.onTitleReadyForStart = onTitleReadyForStart
        context.coordinator.onStartPressed = onStartPressed
        context.coordinator.updateContentURL(contentURL)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var acceptsInput = true
        var onTitleIntroReady: (() -> Void)?
        var startsTitleIntro = false
        private var hasStartedTitleIntro = false
        var onTitleReadyForStart: (() -> Void)?
        var onStartPressed: (() -> Void)?
        private var hasReportedTitleIntroReady = false
        private var hasReportedTitleReadyForStart = false
        private var wasStartHeld = false
        private let device: MTLDevice
        private var runtime: OGJak1RuntimeHost?
        private let onBootstrapReadiness: (String) -> Void
        private var configuredContentURL: URL?
        private var drawableSize: CGSize = .zero
        private var physicalDrawableSize: CGSize = .zero
        private var appliedDrawableSize: CGSize = .zero
        private var configuredRefreshRate = 0
        private var requestedAspectRatio: CGFloat?

        init(contentURL: URL?, onBootstrapReadiness: @escaping (String) -> Void) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("This device does not support Metal.")
            }

            self.device = device
            self.onBootstrapReadiness = onBootstrapReadiness
            self.configuredContentURL = contentURL
            super.init()

            Task.detached(priority: .userInitiated) { [weak self] in
                let host = OGJak1RuntimeHost(device: device, contentURL: contentURL)
                host.configureContentURL(contentURL)
                let readiness = host.bootstrapReadiness()

                await MainActor.run {
                    self?.runtime = host
                    self?.applyDrawableSizeIfNeeded(to: host)
                    onBootstrapReadiness(readiness)
                }
            }
        }

        func makeView() -> MTKView {
            let view = ScaledMTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            // The runtime acquires drawables and owns the depth target on its render thread.
            view.depthStencilPixelFormat = .invalid
            view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
            view.preferredFramesPerSecond = 60
            // The game owns its internal render resolution. Core Animation scales this drawable to
            // the view's bounds, so changing Graphics > Resolution has an immediate visible effect.
            view.autoResizeDrawable = false
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.delegate = self
            return view
        }

        func updateContentURL(_ contentURL: URL?) {
            guard configuredContentURL != contentURL else {
                return
            }

            configuredContentURL = contentURL
            if let runtime = runtime {
                runtime.configureContentURL(contentURL)
                let readiness = runtime.bootstrapReadiness()
                onBootstrapReadiness(readiness)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = size
            physicalDrawableSize = defaultDrawableSize(for: view)
            if let runtime {
                applyDrawableSizeIfNeeded(to: runtime)
            }
        }

        func draw(in view: MTKView) {
            guard let runtime = runtime else { return }
            let maximumFrameRate = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
            if configuredRefreshRate != maximumFrameRate {
                configuredRefreshRate = maximumFrameRate
                runtime.configureDisplayRefreshRate(maximumFrameRate)
            }
            let preferredFrameRate = runtime.preferredFrameRate()
            if view.preferredFramesPerSecond != preferredFrameRate {
                view.preferredFramesPerSecond = preferredFrameRate
            }
            let currentPhysicalSize = defaultDrawableSize(for: view)
            if physicalDrawableSize != currentPhysicalSize {
                physicalDrawableSize = currentPhysicalSize
            }
            applyDrawableSizeIfNeeded(to: runtime)
            let requestedSize = runtime.gameResolution()
            if requestedSize.width > 0,
               requestedSize.height > 0,
               physicalDrawableSize.width > 0,
               physicalDrawableSize.height > 0 {
                let newAspectRatio = requestedSize.width / requestedSize.height
                if let requestedAspectRatio,
                   abs(requestedAspectRatio - newAspectRatio) > 0.001 {
                    refreshMenuLayout(in: view, preferredFrameRate: preferredFrameRate)
                }
                requestedAspectRatio = newAspectRatio
                // Allow the 1.5x supersampled menu choice; Core Animation downscales it to bounds.
                let requestedScale = min(
                    1.5,
                    max(
                        requestedSize.width / physicalDrawableSize.width,
                        requestedSize.height / physicalDrawableSize.height
                    )
                )
                let drawableSize = CGSize(
                    width: max(1, (physicalDrawableSize.width * requestedScale).rounded()),
                    height: max(1, (physicalDrawableSize.height * requestedScale).rounded())
                )
                if view.drawableSize != drawableSize {
                    view.drawableSize = drawableSize
                }
            }
            if drawableSize != view.drawableSize {
                drawableSize = view.drawableSize
            }
            runtime.setTitleAttractMode(!acceptsInput)
            if !hasReportedTitleReadyForStart && runtime.isTitleWaitingForStart() {
                hasReportedTitleReadyForStart = true
                onTitleReadyForStart?()
            }
            let menuOpen = runtime.isMenuOpen()
            if TouchInputState.shared.isMenuOpen != menuOpen {
                TouchInputState.shared.isMenuOpen = menuOpen
            }
            let onCollectionPage = menuOpen && runtime.isMenuOnCollectionPage()
            if TouchInputState.shared.isOnCollectionPage != onCollectionPage {
                TouchInputState.shared.isOnCollectionPage = onCollectionPage
            }
            let warpGateActive = runtime.isWarpGateActive()
            if TouchInputState.shared.isWarpGateActive != warpGateActive {
                TouchInputState.shared.isWarpGateActive = warpGateActive
            }
            let cutsceneActive = runtime.isCutsceneActive()
            if TouchInputState.shared.isCutsceneActive != cutsceneActive {
                TouchInputState.shared.isCutsceneActive = cutsceneActive
            }
            let onZoomer = runtime.isOnZoomer()
            if TouchInputState.shared.isOnZoomer != onZoomer {
                TouchInputState.shared.isOnZoomer = onZoomer
            }
            let gameVisible = runtime.isGameVisible()
            if TouchInputState.shared.isGameVisible != gameVisible {
                TouchInputState.shared.isGameVisible = gameVisible
            }
            let onTitleScreen = runtime.isOnTitleScreen() && !menuOpen
            if TouchInputState.shared.isOnTitleScreen != onTitleScreen {
                TouchInputState.shared.isOnTitleScreen = onTitleScreen
            }
            let swipeCameraEnabled = runtime.isSwipeCameraEnabled()
            if TouchInputState.shared.isSwipeCameraEnabled != swipeCameraEnabled {
                TouchInputState.shared.isSwipeCameraEnabled = swipeCameraEnabled
                TouchInputState.shared.trackCameraTouch(at: nil)
                TouchInputState.shared.rightX = 0
                TouchInputState.shared.rightY = 0
            }
            let floatingRightJoystick = runtime.isFloatingRightJoystickEnabled()
            if TouchInputState.shared.isFloatingRightJoystickEnabled != floatingRightJoystick {
                TouchInputState.shared.isFloatingRightJoystickEnabled = floatingRightJoystick
                TouchInputState.shared.rightX = 0
                TouchInputState.shared.rightY = 0
            }
            let floatingLeftJoystick = runtime.isFloatingLeftJoystickEnabled()
            if TouchInputState.shared.isFloatingLeftJoystickEnabled != floatingLeftJoystick {
                TouchInputState.shared.isFloatingLeftJoystickEnabled = floatingLeftJoystick
                TouchInputState.shared.leftX = 0
                TouchInputState.shared.leftY = 0
            }
            TouchInputState.shared.isHapticFeedbackEnabled = runtime.isHapticFeedbackEnabled()
            if TouchInputState.shared.pendingNewGameMirrorToggle {
                TouchInputState.shared.pendingNewGameMirrorToggle = false
                if acceptsInput { runtime.setNewGameMirrorChecked(!runtime.isNewGameMirrorChecked()) }
            }
            let mirrorOptionVisible = runtime.isNewGameMirrorOptionVisible()
            if TouchInputState.shared.isNewGameMirrorOptionVisible != mirrorOptionVisible {
                TouchInputState.shared.isNewGameMirrorOptionVisible = mirrorOptionVisible
            }
            let mirrorChecked = runtime.isNewGameMirrorChecked()
            if TouchInputState.shared.isNewGameMirrorChecked != mirrorChecked {
                TouchInputState.shared.isNewGameMirrorChecked = mirrorChecked
            }
            runtime.setTouchMenuStyle(TouchInputState.shared.isTouchControlsActive)
            // A controller replaced the touch controls: nothing they report may reach the game.
            TouchInputState.shared.releaseIfTouchControlsInactive()
            // Taps, swipes and Back from the touch menu layer.
            for event in TouchInputState.shared.takeMenuEvents() where acceptsInput {
                switch event {
                case let .press(point, viewAspect):
                    runtime.menuPress(atX: point.x, y: point.y, viewAspect: viewAspect)
                case .pressCancel:
                    runtime.menuPressCancel()
                case let .tap(point, viewAspect):
                    runtime.menuTap(atX: point.x, y: point.y, viewAspect: viewAspect)
                case let .scroll(rows, startsSwipe):
                    runtime.menuScroll(byRows: rows, startsSwipe: startsSwipe)
                case let .horizontal(steps, startsSwipe):
                    runtime.menuStepHorizontal(steps, startsSwipe: startsSwipe)
                case .back:
                    runtime.menuBack()
                }
            }
            // In the main third-person camera, swipes turn the camera directly (no stick speed cap);
            // otherwise they stay pending and currentInput() plays them back on the right stick.
            if !TouchInputState.shared.isSwipeCameraEnabled {
                _ = TouchInputState.shared.takeCameraSwipe()
            } else if runtime.isCameraAimingMode() {
                // Aiming is done with the left stick; swipes are dropped so they don't move the view.
                _ = TouchInputState.shared.takeCameraSwipe()
            } else if runtime.isDirectCameraLookAvailable() {
                let swipe = TouchInputState.shared.takeCameraSwipe()
                // Sent every frame (zeroed while the game ignores input) so the runtime always
                // knows when the thumb has lifted.
                runtime.addCameraLookYaw(
                    acceptsInput ? swipe.yaw : 0,
                    zoom: acceptsInput ? swipe.zoom : 0,
                    touching: acceptsInput && TouchInputState.shared.isCameraTouchActive
                )
            }
            let (controllerInput, touchPresses) = GameControllerInputReader.currentInput()
            // While the game sees a neutral pad, still let a controller's Start reach the app.
            if !acceptsInput && controllerInput.menu && !wasStartHeld {
                onStartPressed?()
            }
            wasStartHeld = controllerInput.menu
            let input = acceptsInput ? controllerInput : .neutral
            let presses = acceptsInput ? touchPresses : .neutral
            // Before the update, so a pad read in between can't see the new state without its press.
            runtime.notePresses(
                withButtonA: presses.buttonA,
                buttonB: presses.buttonB,
                buttonX: presses.buttonX,
                buttonY: presses.buttonY,
                leftShoulder: presses.leftShoulder,
                rightShoulder: presses.rightShoulder,
                leftTrigger: presses.leftTrigger > 0.5,
                rightTrigger: presses.rightTrigger > 0.5,
                menu: presses.menu,
                select: presses.select,
                leftThumb: presses.leftThumb,
                rightThumb: presses.rightThumb,
                dpadUp: presses.dpadUp,
                dpadDown: presses.dpadDown,
                dpadLeft: presses.dpadLeft,
                dpadRight: presses.dpadRight
            )
            runtime.update(
                withLeftX: input.leftX,
                leftY: input.leftY,
                rightX: input.rightX,
                rightY: input.rightY,
                buttonA: input.buttonA,
                buttonB: input.buttonB,
                buttonX: input.buttonX,
                buttonY: input.buttonY,
                leftShoulder: input.leftShoulder,
                rightShoulder: input.rightShoulder,
                leftTrigger: input.leftTrigger,
                rightTrigger: input.rightTrigger,
                menu: input.menu,
                select: input.select,
                leftThumb: input.leftThumb,
                rightThumb: input.rightThumb,
                dpadUp: input.dpadUp,
                dpadDown: input.dpadDown,
                dpadLeft: input.dpadLeft,
                dpadRight: input.dpadRight
            )
            runtime.draw(in: view)
            if !hasReportedTitleIntroReady && runtime.isTitleIntroReady() {
                hasReportedTitleIntroReady = true
                onTitleIntroReady?()
            }
            if startsTitleIntro && !hasStartedTitleIntro {
                hasStartedTitleIntro = true
                runtime.startTitleIntro()
            }
        }

        private func refreshMenuLayout(in view: MTKView, preferredFrameRate: Int) {
            // Changing the frame cadence makes OpenGOAL rebuild the active progress/menu frame.
            // Use the same refresh pulse after an aspect change, then restore the selected rate.
            let refreshFrameRate = preferredFrameRate > 1 ? preferredFrameRate - 1 : 2
            view.preferredFramesPerSecond = refreshFrameRate
            DispatchQueue.main.async { [weak view] in
                view?.preferredFramesPerSecond = preferredFrameRate
            }
        }

        private func applyDrawableSizeIfNeeded(to runtime: OGJak1RuntimeHost) {
            guard physicalDrawableSize.width > 0,
                  physicalDrawableSize.height > 0,
                  physicalDrawableSize != appliedDrawableSize else {
                return
            }

            runtime.resize(toWidth: physicalDrawableSize.width, height: physicalDrawableSize.height)
            appliedDrawableSize = physicalDrawableSize
        }

        private func defaultDrawableSize(for view: MTKView) -> CGSize {
            let scale = (view as? ScaledMTKView)?.cappedNativeScale ?? view.contentScaleFactor
            return CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        }
    }
}
