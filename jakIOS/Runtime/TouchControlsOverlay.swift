import SwiftUI
import UIKit

/// Reports one finger from the instant it touches down until it lifts. SwiftUI gestures held a
/// control's touch-down back (quick taps arrived as down+up together on release, holds only
/// registered after a moment), so pad controls track touches with a UIKit recognizer instead:
/// recognizers see touches before any delayed delivery to views.
private final class ImmediatePressGestureRecognizer: UIGestureRecognizer {
    private(set) var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A finger whose lift never reached us must not keep the control from taking new ones
        // (every later touch would be ignored and the button would seem dead).
        if let trackedTouch, trackedTouch.phase == .ended || trackedTouch.phase == .cancelled {
            self.trackedTouch = nil
        }
        if trackedTouch == nil, let touch = touches.first {
            trackedTouch = touch
            // Still recognizing (the stale finger above): the new finger carries on as a change.
            state = state == .possible ? .began : .changed
        }
        // Extra fingers on the same control don't affect it.
        for touch in touches where touch !== trackedTouch {
            ignore(touch, for: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) {
            state = .cancelled
        }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}

/// Touch view that can limit hits to the circle inscribed in its bounds, so enlarged hit areas of
/// neighboring round buttons don't overlap at their corners.
private final class TouchSurfaceView: UIView {
    var isCircular = false
    var containsPoint: ((CGPoint) -> Bool)?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if let containsPoint {
            return containsPoint(point)
        }
        guard isCircular else { return true }
        let radius = min(bounds.width, bounds.height) / 2
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }
}

/// Transparent touch area that calls `onTouch` with the finger's location while it is down
/// (immediately on touch-down, then on every move) and with `nil` when it lifts.
private struct PressTrackingSurface: UIViewRepresentable {
    /// Only touches inside the inscribed circle count.
    var isCircular = false
    /// Touches that start where this returns true (window coordinates) are ignored.
    var excludesTouch: (CGPoint) -> Bool = { _ in false }
    let onTouch: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TouchSurfaceView()
        view.isCircular = isCircular
        view.backgroundColor = .clear
        let recognizer = ImmediatePressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePress(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        (view as? TouchSurfaceView)?.isCircular = isCircular
        context.coordinator.onTouch = onTouch
        context.coordinator.excludesTouch = excludesTouch
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouch: onTouch, excludesTouch: excludesTouch)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouch: (CGPoint?) -> Void
        var excludesTouch: (CGPoint) -> Bool
        /// The finger last reported as down.
        private weak var reportedTouch: UITouch?

        init(onTouch: @escaping (CGPoint?) -> Void, excludesTouch: @escaping (CGPoint) -> Bool) {
            self.onTouch = onTouch
            self.excludesTouch = excludesTouch
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !excludesTouch(touch.location(in: nil))
        }

        @objc func handlePress(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let touch = (recognizer as? ImmediatePressGestureRecognizer)?.trackedTouch
                if let touch, let reportedTouch, reportedTouch !== touch {
                    // A new finger replaced a stale one: release first so it is a fresh press.
                    onTouch(nil)
                }
                reportedTouch = touch
                onTouch(touch?.location(in: recognizer.view))
            default:
                reportedTouch = nil
                onTouch(nil)
            }
        }

        // Every control must track its own finger while others are held (e.g. run + jump).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Shared look for every on-screen control, modeled on the Jak and Daxter pause menu:
/// dark recessed sockets set in bronze/copper rings over warm orange "Precursor" glass.
private enum PadStyle {
    static let bronzeLight = Color(red: 0.95, green: 0.72, blue: 0.42)
    static let bronze = Color(red: 0.72, green: 0.43, blue: 0.19)
    static let bronzeDark = Color(red: 0.30, green: 0.16, blue: 0.06)
    static let glow = Color(red: 1.0, green: 0.62, blue: 0.22)

    /// Metallic rim: the angular sweep fakes light catching a rounded bronze edge.
    static let ring = AngularGradient(
        colors: [bronzeLight, bronze, bronzeDark, bronze, bronzeLight, bronze, bronzeDark, bronze, bronzeLight],
        center: .center
    )

    /// Dark brown socket that each button sits in.
    static let socket = RadialGradient(
        colors: [
            Color(red: 0.32, green: 0.19, blue: 0.10),
            Color(red: 0.10, green: 0.05, blue: 0.02)
        ],
        center: UnitPoint(x: 0.35, y: 0.3),
        startRadius: 1,
        endRadius: 60
    )

    /// Translucent orange glass behind the sticks.
    static let glass = RadialGradient(
        colors: [
            Color(red: 1.0, green: 0.66, blue: 0.30).opacity(0.45),
            Color(red: 0.80, green: 0.34, blue: 0.08).opacity(0.32)
        ],
        center: .center,
        startRadius: 4,
        endRadius: 90
    )

    /// Fully opaque counterpart used by fixed sticks so their resting location stays obvious.
    static let opaqueGlass = RadialGradient(
        colors: [
            Color(red: 1.0, green: 0.66, blue: 0.30),
            Color(red: 0.80, green: 0.34, blue: 0.08)
        ],
        center: .center,
        startRadius: 4,
        endRadius: 90
    )

    /// Yellow-to-orange lettering like the menu's "CATCH THE SCULPTOR'S MUSE".
    static let label = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.90, blue: 0.38),
            Color(red: 0.98, green: 0.55, blue: 0.14)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static func labelFont(_ scale: CGFloat) -> Font {
        .system(size: 13 * scale, weight: .heavy, design: .rounded)
    }
}

private extension View {
    /// Applies the socket fill, bronze rim, and pressed glow shared by every button.
    func padSurface<S: InsettableShape>(_ shape: S, isPressed: Bool) -> some View {
        background {
            shape
                .fill(PadStyle.socket)
                .shadow(
                    color: isPressed ? PadStyle.glow.opacity(0.9) : .black.opacity(0.6),
                    radius: isPressed ? 9 : 5,
                    y: isPressed ? 0 : 3
                )
        }
        .overlay {
            shape.strokeBorder(PadStyle.ring, lineWidth: 2.5)
        }
        .overlay {
            // Inner highlight that brightens on press, like a lit Precursor socket.
            shape
                .inset(by: 3)
                .strokeBorder(PadStyle.glow.opacity(isPressed ? 0.7 : 0.15), lineWidth: 1)
        }
        .scaleEffect(isPressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

/// Movement stick that appears wherever the thumb lands in its area and hides when it lifts.
/// The touch-down point becomes the stick's center (kept far enough from the edges for the whole
/// ring to show); dragging away from it tilts the stick, up to the ring's radius.
struct FloatingJoystick: View {
    let title: String
    var scale: CGFloat = 1
    let onChange: (Float, Float) -> Void

    /// Where the stick is drawn. Kept after release so the stick fades out in place.
    @State private var center: CGPoint?
    /// Whether a touch is currently driving the stick.
    @State private var isActive = false
    /// Drives the fade; animated separately from `isActive` so input stays immediate.
    @State private var isVisible = false
    @State private var thumbOffset: CGSize = .zero
    private var joystickRadius: CGFloat { 60 * scale }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Touch-down registers immediately (UIKit recognizer), like the pad buttons.
                PressTrackingSurface { location in
                    update(location, in: proxy.size)
                }

                if let center {
                    JoystickGraphic(scale: scale, thumbOffset: thumbOffset)
                        // Twice as see-through as the old always-visible stick.
                        .opacity(isVisible ? 0.5 : 0)
                        .position(center)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Touch and drag anywhere in this area")
    }

    private func update(_ location: CGPoint?, in size: CGSize) {
        guard let location else {
            isActive = false
            onChange(0, 0)
            // Fade out where it was released, letting the thumb glide back to center meanwhile.
            withAnimation(.easeOut(duration: 0.25)) {
                isVisible = false
                thumbOffset = .zero
            }
            return
        }
        let stickCenter: CGPoint
        if isActive, let center {
            stickCenter = center
        } else {
            // First contact: center the stick under the thumb, nudged in from the edges.
            stickCenter = CGPoint(
                x: min(max(location.x, joystickRadius), max(joystickRadius, size.width - joystickRadius)),
                y: min(max(location.y, joystickRadius), max(joystickRadius, size.height - joystickRadius))
            )
            isActive = true
            center = stickCenter
            withAnimation(.easeIn(duration: 0.12)) {
                isVisible = true
            }
        }

        let dx = location.x - stickCenter.x
        let dy = location.y - stickCenter.y
        let distance = hypot(dx, dy)
        let clampedDistance = min(distance, joystickRadius)
        let angle = atan2(dy, dx)
        let x = distance > 0 ? clampedDistance * cos(angle) : 0
        let y = distance > 0 ? clampedDistance * sin(angle) : 0
        thumbOffset = CGSize(width: x, height: y)
        onChange(Float(x / joystickRadius), Float(-y / joystickRadius))
    }
}

/// An always-visible, fully opaque stick anchored near the lower inside corner of its half-screen.
/// Unlike `FloatingJoystick`, the well never moves to the initial touch position.
struct StaticJoystick: View {
    let title: String
    var scale: CGFloat = 1
    let centerX: CGFloat
    let centerY: CGFloat
    let onChange: (Float, Float) -> Void

    @State private var thumbOffset: CGSize = .zero
    private var joystickRadius: CGFloat { 60 * scale }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(
                x: min(max(centerX, joystickRadius), proxy.size.width - joystickRadius),
                y: min(max(centerY, joystickRadius), proxy.size.height - joystickRadius)
            )
            ZStack(alignment: .topLeading) {
                // Acquire only touches that begin on the visible well. Once acquired, UIKit keeps
                // delivering that finger as it drags outside this circle until it lifts.
                PressTrackingSurface(isCircular: true) { location in
                    update(
                        location,
                        center: CGPoint(x: joystickRadius, y: joystickRadius)
                    )
                }
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)
                .position(center)
                JoystickGraphic(scale: scale, thumbOffset: thumbOffset, isOpaque: true)
                    .position(center)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Drag from the visible stick")
    }

    private func update(_ location: CGPoint?, center: CGPoint) {
        guard let location else {
            thumbOffset = .zero
            onChange(0, 0)
            return
        }
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = hypot(dx, dy)
        let clampedDistance = min(distance, joystickRadius)
        let angle = atan2(dy, dx)
        let x = distance > 0 ? clampedDistance * cos(angle) : 0
        let y = distance > 0 ? clampedDistance * sin(angle) : 0
        thumbOffset = CGSize(width: x, height: y)
        onChange(Float(x / joystickRadius), Float(-y / joystickRadius))
    }
}

/// The stick's look: an orange glass well in a bronze ring with a Precursor-orb thumb.
private struct JoystickGraphic: View {
    var scale: CGFloat = 1
    let thumbOffset: CGSize
    var isOpaque = false

    private var joystickRadius: CGFloat { 60 * scale }
    private var thumbRadius: CGFloat { 27 * scale }

    var body: some View {
        ZStack {
            Circle()
                .fill(isOpaque ? PadStyle.opaqueGlass : PadStyle.glass)
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)
                .overlay {
                    Circle().strokeBorder(PadStyle.ring, lineWidth: 3)
                }
                .overlay {
                    Circle()
                        .strokeBorder(PadStyle.bronzeDark.opacity(0.6), lineWidth: 1)
                        .padding(9)
                }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            // Thumb styled like a Precursor orb: glowing amber core in a bronze rim.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.82, blue: 0.48),
                            Color(red: 0.92, green: 0.48, blue: 0.14),
                            Color(red: 0.45, green: 0.20, blue: 0.05)
                        ],
                        center: UnitPoint(x: 0.38, y: 0.32),
                        startRadius: 1,
                        endRadius: thumbRadius * 1.3
                    )
                )
                .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                .overlay {
                    Circle().strokeBorder(PadStyle.ring, lineWidth: 3)
                }
                .overlay {
                    Circle()
                        .strokeBorder(PadStyle.bronzeDark.opacity(0.7), lineWidth: 1)
                        .padding(9)
                }
                .shadow(
                    color: thumbOffset == .zero ? .black.opacity(0.6) : PadStyle.glow.opacity(0.8),
                    radius: thumbOffset == .zero ? 5 : 9,
                    y: thumbOffset == .zero ? 3 : 0
                )
                .offset(thumbOffset)
        }
        .frame(width: joystickRadius * 2, height: joystickRadius * 2)
    }
}

/// The very slight tap played on an on-screen button's touch-down when Haptic Feedback is on
/// (Game Options > Input Options > Touch Options). Joysticks never play it.
@MainActor
private enum ButtonHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func buttonPressed() {
        guard TouchInputState.shared.isHapticFeedbackEnabled else { return }
        generator.impactOccurred(intensity: 1.0)
        // Keep the Taptic Engine warm so rapid presses aren't delayed.
        generator.prepare()
    }
}

/// A press-and-hold button in any shape, reporting `true` on touch down and `false` on release.
struct PadButton<Label: View, ButtonShape: InsettableShape>: View {
    let accessibilityName: String
    let shape: ButtonShape
    let width: CGFloat
    let height: CGFloat
    /// How far the touch area reaches past the drawn button on every side.
    let hitOutset: CGFloat
    /// Round buttons take touches in a circle (the enlarged area of neighbors can't overlap).
    let circularHitArea: Bool
    let action: (Bool) -> Void
    let label: Label

    @State private var isPressed = false

    init(
        _ accessibilityName: String,
        shape: ButtonShape,
        width: CGFloat,
        height: CGFloat,
        hitOutset: CGFloat = 0,
        circularHitArea: Bool = false,
        action: @escaping (Bool) -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityName = accessibilityName
        self.shape = shape
        self.width = width
        self.height = height
        self.hitOutset = hitOutset
        self.circularHitArea = circularHitArea
        self.action = action
        self.label = label()
    }

    var body: some View {
        label
            .frame(width: width, height: height)
            .padSurface(shape, isPressed: isPressed)
            .overlay {
                // Pressed for as long as the finger is down, starting at touch-down.
                PressTrackingSurface(isCircular: circularHitArea) { location in
                    let pressed = location != nil
                    guard pressed != isPressed else { return }
                    isPressed = pressed
                    if pressed { ButtonHaptics.buttonPressed() }
                    action(pressed)
                }
                .padding(-hitOutset)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityAddTraits(.isButton)
    }
}

/// Reports every finger on its view from touch-down until lift, like
/// `ImmediatePressGestureRecognizer` but for any number of fingers.
private final class MultiPressGestureRecognizer: UIGestureRecognizer {
    private(set) var activeTouches: [UITouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Fingers whose lift never reached us must not stay pressed.
        activeTouches.removeAll { $0.phase == .ended || $0.phase == .cancelled }
        activeTouches.append(contentsOf: touches)
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.removeAll { touches.contains($0) }
        state = activeTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.removeAll { touches.contains($0) }
        state = activeTouches.isEmpty ? .cancelled : .changed
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
    }
}

/// Transparent touch area that calls `onTouches` with the location of every finger on it,
/// immediately on touch-down and on every move or lift (empty once all have lifted).
private struct MultiPressTrackingSurface: UIViewRepresentable {
    var containsPoint: (CGPoint) -> Bool = { _ in true }
    let onTouches: ([CGPoint]) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TouchSurfaceView()
        view.containsPoint = containsPoint
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let recognizer = MultiPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePress(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        (view as? TouchSurfaceView)?.containsPoint = containsPoint
        context.coordinator.onTouches = onTouches
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouches: onTouches)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouches: ([CGPoint]) -> Void

        init(onTouches: @escaping ([CGPoint]) -> Void) {
            self.onTouches = onTouches
        }

        @objc func handlePress(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let touches = (recognizer as? MultiPressGestureRecognizer)?.activeTouches ?? []
                onTouches(touches.map { $0.location(in: recognizer.view) })
            default:
                onTouches([])
            }
        }

        // Every control must track its own finger while others are held (e.g. run + jump).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// The four face buttons, in diamond order around the cluster center.
private enum FaceButton: CaseIterable {
    case triangle, circle, cross, square

    var name: String {
        switch self {
        case .triangle: "Triangle"
        case .circle: "Circle"
        case .cross: "Cross"
        case .square: "Square"
        }
    }

    var symbol: String {
        switch self {
        case .triangle: "triangle"
        case .circle: "circle"
        case .cross: "xmark"
        case .square: "square"
        }
    }

    var color: Color {
        switch self {
        case .triangle: Color(red: 0.38, green: 0.88, blue: 0.55)
        case .circle: Color(red: 1.0, green: 0.36, blue: 0.42)
        case .cross: Color(red: 0.42, green: 0.68, blue: 1.0)
        case .square: Color(red: 0.94, green: 0.48, blue: 0.86)
        }
    }

    var control: ReferenceWritableKeyPath<TouchInputState, Bool> {
        switch self {
        case .triangle: \.buttonY
        case .circle: \.buttonB
        case .cross: \.buttonA
        case .square: \.buttonX
        }
    }

    /// Offset from the cluster center, in units of the button spacing.
    var direction: CGPoint {
        switch self {
        case .triangle: CGPoint(x: 0, y: -1)
        case .circle: CGPoint(x: 1, y: 0)
        case .cross: CGPoint(x: 0, y: 1)
        case .square: CGPoint(x: -1, y: 0)
        }
    }
}

/// The face buttons share one touch surface, so a finger is pressing whichever button it is on:
/// sliding from one button onto another releases the first and presses the second, and a finger
/// that lands in a gap presses a button once it slides onto it. Each finger presses at most one
/// button; several fingers can hold several.
private struct FaceButtonCluster: View {
    let scale: CGFloat
    /// Button layout in unscaled points (see TouchControlsOverlay).
    let diameter: CGFloat
    let spacing: CGFloat
    /// Extra touch radius around each button.
    let hitOutset: CGFloat
    /// How far the touch circles reach past the cluster frame; the touch surface covers it.
    let hitOverhang: CGFloat
    let onChange: (FaceButton, Bool) -> Void

    @State private var pressed: Set<FaceButton> = []

    var body: some View {
        let size = spacing * 3 * scale

        ZStack {
            ForEach(FaceButton.allCases, id: \.self) { button in
                buttonGraphic(button)
                    .offset(x: button.direction.x * spacing * scale, y: button.direction.y * spacing * scale)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            MultiPressTrackingSurface(containsPoint: { location in
                isInsideButtonTouchArea(location, clusterSize: size)
            }) { locations in
                update(locations, clusterSize: size)
            }
            .padding(-hitOverhang * scale)
            .accessibilityHidden(true)
        }
        // Swapped out (menu opened) while held: the surface never delivers the lift.
        .onDisappear { update([], clusterSize: size) }
    }

    private func buttonGraphic(_ button: FaceButton) -> some View {
        // Symbol keeps its original proportion to the button (19 pt on a 46 pt button).
        Image(systemName: button.symbol)
            .font(.system(size: diameter * 19 / 46 * scale, weight: .heavy))
            .foregroundStyle(button.color)
            .shadow(color: button.color.opacity(0.6), radius: 3)
            .frame(width: diameter * scale, height: diameter * scale)
            .padSurface(Circle(), isPressed: pressed.contains(button))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(button.name)
            .accessibilityAddTraits(.isButton)
    }

    /// Only the enlarged circular button areas intercept touches. Transparent gaps pass through
    /// to the camera swipe surface underneath.
    private func isInsideButtonTouchArea(_ location: CGPoint, clusterSize: CGFloat) -> Bool {
        let center = clusterSize / 2 + hitOverhang * scale
        let reach = (diameter / 2 + hitOutset) * scale
        return FaceButton.allCases.contains { button in
            let x = center + button.direction.x * spacing * scale
            let y = center + button.direction.y * spacing * scale
            return hypot(location.x - x, location.y - y) <= reach
        }
    }

    /// `locations` are in the touch surface's coordinates (the cluster grown by `hitOverhang`).
    private func update(_ locations: [CGPoint], clusterSize: CGFloat) {
        let center = clusterSize / 2 + hitOverhang * scale
        let reach = (diameter / 2 + hitOutset) * scale
        var nowPressed: Set<FaceButton> = []
        for location in locations {
            // The nearest button whose touch circle the finger is in.
            let hit = FaceButton.allCases
                .map { button -> (FaceButton, CGFloat) in
                    let x = center + button.direction.x * spacing * scale
                    let y = center + button.direction.y * spacing * scale
                    return (button, hypot(location.x - x, location.y - y))
                }
                .filter { $0.1 <= reach }
                .min { $0.1 < $1.1 }
            if let hit {
                nowPressed.insert(hit.0)
            }
        }
        guard nowPressed != pressed else { return }
        // Release before press, so sliding between buttons never holds both.
        for button in FaceButton.allCases where pressed.contains(button) && !nowPressed.contains(button) {
            onChange(button, false)
        }
        for button in FaceButton.allCases where nowPressed.contains(button) && !pressed.contains(button) {
            ButtonHaptics.buttonPressed()
            onChange(button, true)
        }
        pressed = nowPressed
    }
}

/// Full-screen touch layer for the game's menus. A tap selects and engages what is under it; a
/// vertical swipe scrolls the list (or steps through levels on the pause screen), a horizontal
/// one presses Left/Right. The runtime maps taps onto the menu's own layout.
private struct MenuTouchSurface: View {
    @ObservedObject var state = TouchInputState.shared
    @State private var tracker = MenuGestureTracker()

    var body: some View {
        GeometryReader { proxy in
            PressTrackingSurface { location in
                tracker.update(location, in: proxy.size, state: state)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Menu")
        .accessibilityHint("Tap an option to choose it. Swipe up or down to scroll.")
    }
}

/// One finger's menu gesture: a tap until it travels far enough, then a scroll in one direction.
@MainActor
private final class MenuGestureTracker {
    private enum Mode {
        case undecided, vertical, horizontal
    }

    /// Movement that turns a tap into a swipe.
    private let tapSlop: CGFloat = 12
    /// Horizontal travel that makes a swipe press Left/Right (once per swipe).
    private let horizontalStep: CGFloat = 60

    private var start: CGPoint?
    private var anchor: CGPoint = .zero
    private var mode = Mode.undecided
    /// The current swipe has already scrolled (or stepped sideways).
    private var hasScrolled = false

    func update(_ location: CGPoint?, in size: CGSize, state: TouchInputState) {
        guard let location else {
            // Lifted: a touch that never became a swipe is a tap where it started.
            if let start, mode == .undecided, size.width > 0, size.height > 0 {
                state.sendMenuEvent(.tap(
                    CGPoint(x: start.x / size.width, y: start.y / size.height),
                    viewAspect: Double(size.width / size.height)
                ))
            }
            start = nil
            mode = .undecided
            return
        }
        guard let start else {
            start = location
            anchor = location
            hasScrolled = false
            // Light up the option under the finger while it's held.
            if size.width > 0, size.height > 0 {
                state.sendMenuEvent(.press(
                    CGPoint(x: location.x / size.width, y: location.y / size.height),
                    viewAspect: Double(size.width / size.height)
                ))
            }
            return
        }
        if mode == .undecided {
            let dx = location.x - start.x
            let dy = location.y - start.y
            guard hypot(dx, dy) > tapSlop else { return }
            mode = abs(dy) >= abs(dx) ? .vertical : .horizontal
            state.sendMenuEvent(.pressCancel)
        }
        switch mode {
        case .vertical:
            // About one menu row of travel (rows are ~11% of the screen height) per row scrolled.
            let rowStep = max(28, size.height * 0.09)
            // Thumb up reveals the rows below, like scrolling a list.
            let rows = Int((anchor.y - location.y) / rowStep)
            if rows != 0 {
                state.sendMenuEvent(.scroll(rows: rows, startsSwipe: !hasScrolled))
                hasScrolled = true
                anchor.y -= CGFloat(rows) * rowStep
            }
        case .horizontal:
            // One Left/Right per swipe, however far or fast it goes (carousels, Yes/No).
            guard !hasScrolled else { break }
            let travel = location.x - anchor.x
            if abs(travel) >= horizontalStep {
                state.sendMenuEvent(.horizontal(steps: travel > 0 ? 1 : -1, startsSwipe: true))
                hasScrolled = true
            }
        case .undecided:
            break
        }
    }
}

/// Full-screen swipe layer while a warp gate chooses a destination. Like the menu carousels, each
/// swipe moves exactly one destination, and the list follows the finger: swiping left brings in
/// the next one from the right (D-pad Right).
private struct WarpGateSwipeSurface: View {
    @ObservedObject var state = TouchInputState.shared
    /// Horizontal travel that counts as a swipe.
    private let swipeDistance: CGFloat = 40
    /// The game ignores presses while it turns to the next destination, so swipes that close
    /// together are spaced out rather than lost or doubled.
    private let minimumInterval: TimeInterval = 0.3
    @State private var start: CGPoint?
    @State private var hasSwiped = false
    @State private var lastSwipeTime: TimeInterval = 0

    var body: some View {
        PressTrackingSurface { location in
            guard let location else {
                start = nil
                return
            }
            guard let start else {
                self.start = location
                hasSwiped = false
                return
            }
            let dx = location.x - start.x
            guard !hasSwiped, abs(dx) > swipeDistance, abs(dx) > abs(location.y - start.y) else { return }
            hasSwiped = true
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSwipeTime >= minimumInterval else { return }
            lastSwipeTime = now
            // A tap: pressed and released at once, latched until the game's next input frame.
            let button: ReferenceWritableKeyPath<TouchInputState, Bool> = dx < 0 ? \.dpadRight : \.dpadLeft
            state.setButton(button, pressed: true)
            state.setButton(button, pressed: false)
        }
        .accessibilityElement()
        .accessibilityLabel("Warp gate destination")
        .accessibilityHint("Swipe left or right to choose a destination.")
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject var state = TouchInputState.shared
    /// The face button cluster in window coordinates, so camera swipes can't start around it.
    @State private var faceButtonsFrame: CGRect = .null
    // Face button layout (unscaled points). Each button sits `faceButtonSpacing` from the cluster
    // center, and the outer edges stay 1 pt inside the cluster frame, so growing the buttons grows
    // the cluster inward and keeps the same distance from the screen edges.
    private let faceButtonDiameter: CGFloat = 54
    private let faceButtonSpacing: CGFloat = 56
    private var faceButtonClusterSize: CGFloat { faceButtonSpacing * 3 }
    /// Extra touch radius around each face button. Diagonal neighbors are 56·√2 ≈ 79 pt apart and
    /// draw 27 pt radii, so up to ~12 pt keeps their touch circles from overlapping.
    private let faceButtonHitOutset: CGFloat = 9
    /// Extra height above the bottom padding. Keeps the bottom row's (Cross, R1) touch circles
    /// 24 pt above the screen edge, clear of the ~21 pt home-indicator gesture zone: touches that
    /// start in that zone are held back or cancelled by the system, so presses there were dropped.
    private let faceButtonLift: CGFloat = 16
    /// Clearance beyond the face buttons' touch circles where camera swipes can't start.
    private let faceButtonSwipeClearance: CGFloat = 6
    /// On the zoomer, how far R1's center sits above the Triangle row.
    private let zoomerR1Raise: CGFloat = 14
    /// How far the touch circles reach past the cluster frame (the outer buttons' far side).
    private var faceButtonHitOverhang: CGFloat {
        max(0, faceButtonSpacing + faceButtonDiameter / 2 + faceButtonHitOutset - faceButtonClusterSize / 2)
    }
    /// Radius of each circular camera no-swipe-start zone.
    private var faceButtonNoSwipeRadius: CGFloat {
        faceButtonDiameter / 2 + faceButtonHitOutset + faceButtonSwipeClearance
    }

    var body: some View {
        GeometryReader { proxy in
            // Sized for a ~780×360 pt landscape area; shrink uniformly on smaller screens.
            let scale = min(1, proxy.size.width / 780, proxy.size.height / 360)
            let overlayFrame = proxy.frame(in: .global)
            let fallbackButtonLineY = proxy.size.height -
                (16 + faceButtonLift + faceButtonClusterSize / 2) * scale
            let buttonLineY = faceButtonsFrame.isNull ? fallbackButtonLineY :
                faceButtonsFrame.minY - overlayFrame.minY +
                    faceButtonCenter(.square, scale: scale).y
            let fallbackCircleClearance =
                (20 + faceButtonClusterSize + faceButtonSpacing -
                 (faceButtonClusterSize / 2 + faceButtonSpacing) -
                 faceButtonDiameter / 2) * scale
            let circleCenterX = faceButtonsFrame.isNull ?
                proxy.size.width - fallbackCircleClearance - faceButtonDiameter * scale / 2 :
                faceButtonsFrame.minX - overlayFrame.minX +
                    faceButtonCenter(.circle, scale: scale).x
            let circleRightClearance = max(
                0,
                proxy.size.width - circleCenterX - faceButtonDiameter * scale / 2
            )
            let leftStickCenterX = proxy.size.height - buttonLineY

            ZStack {
                // Swipe on the right half of the screen, outside the controls, to turn the camera
                // (replaces the right stick). The left half is left alone so a thumb that misses the
                // left stick doesn't move the camera. The controls sit on top, so touches that
                // start on them never reach this layer. Nor do touches in the gaps between and just
                // around the face buttons, so a slightly missed press doesn't turn the camera instead.
                if !state.isMenuOpen && state.isWarpGateActive {
                    // Warp gate: swipes pick the destination, like a menu carousel. Circle warps
                    // and Triangle leaves, on the face buttons as usual.
                    WarpGateSwipeSurface()
                        .ignoresSafeArea()
                } else if !state.isMenuOpen && !state.isCutsceneActive {
                    if state.isSwipeCameraEnabled {
                        // Camera swipes can start in the gaps between buttons, but not inside each
                        // button's enlarged circular touch area and its surrounding clearance.
                        PressTrackingSurface(excludesTouch: { location in
                            isInsideFaceButtonNoSwipeZone(location, scale: scale)
                        }) { location in
                            state.trackCameraTouch(at: location)
                        }
                        .frame(width: proxy.size.width / 2 + proxy.safeAreaInsets.trailing)
                        .offset(x: proxy.safeAreaInsets.trailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                    } else if state.isFloatingRightJoystickEnabled {
                        FloatingJoystick(title: "Right stick", scale: scale) { x, y in
                            state.rightX = x
                            state.rightY = y
                        }
                        .frame(width: proxy.size.width / 2 + proxy.safeAreaInsets.trailing)
                        .offset(x: proxy.safeAreaInsets.trailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    } else {
                        let squareCenterX = faceButtonsFrame.isNull ?
                            circleCenterX - faceButtonSpacing * 2 * scale :
                            faceButtonsFrame.minX - overlayFrame.minX +
                                faceButtonCenter(.square, scale: scale).x
                        let rightHalfOriginX = proxy.size.width / 2
                        let rightStickCenterX = squareCenterX - rightHalfOriginX -
                            faceButtonDiameter * scale / 2 - circleRightClearance * 1.5 - 60 * scale
                        StaticJoystick(
                            title: "Right stick",
                            scale: scale,
                            centerX: rightStickCenterX,
                            centerY: buttonLineY
                        ) { x, y in
                            state.rightX = x
                            state.rightY = y
                        }
                        .frame(width: proxy.size.width / 2 + proxy.safeAreaInsets.trailing)
                        .offset(x: proxy.safeAreaInsets.trailing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }

                    if state.isFloatingLeftJoystickEnabled {
                        FloatingJoystick(title: "Left stick", scale: scale) { x, y in
                            state.leftX = x
                            state.leftY = y
                        }
                        .frame(width: proxy.size.width / 2 + proxy.safeAreaInsets.leading)
                        .offset(x: -proxy.safeAreaInsets.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        StaticJoystick(
                            title: "Left stick",
                            scale: scale,
                            centerX: leftStickCenterX,
                            centerY: buttonLineY
                        ) { x, y in
                            state.leftX = x
                            state.leftY = y
                        }
                        .frame(width: proxy.size.width / 2 + proxy.safeAreaInsets.leading)
                        .offset(x: -proxy.safeAreaInsets.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }

                if state.isMenuOpen {
                    // Menus are tapped and swiped directly (title menu, pause menu, options).
                    MenuTouchSurface()
                        .ignoresSafeArea()
                    menuControls(scale: scale)
                } else if state.isCutsceneActive {
                    cutsceneControls(scale: scale)
                } else {
                    controls(
                        scale: scale,
                        trailingSafeAreaInset: proxy.safeAreaInsets.trailing
                    )
                    if state.isOnZoomer {
                        // Zoomer: R1 sits under Pause (centered on it), a little above the
                        // Triangle row, so the left thumb can reach it while steering.
                        r1Button(scale: scale)
                            .position(
                                x: (20 + 66 / 2) * scale,
                                y: buttonLineY - (faceButtonSpacing + zoomerR1Raise) * scale
                            )
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .vertical)
        .onChange(of: state.isMenuOpen) { releaseSwappedControls() }
        .onChange(of: state.isWarpGateActive) { releaseSwappedControls() }
        // R1 moves sides under a held finger, which never delivers its release.
        .onChange(of: state.isOnZoomer) { state.setButton(\.rightShoulder, pressed: false) }
        .onChange(of: state.isCutsceneActive) { _, active in
            // The hidden controls never deliver their release; let go of anything held.
            if active {
                state.reset()
            } else {
                // Subtitles (Square) is hidden when the cutscene ends, possibly mid-press.
                state.setButton(\.buttonX, pressed: false)
            }
        }
    }

    /// The control being swapped out never delivers its release, so clear it here.
    private func releaseSwappedControls() {
        state.leftX = 0
        state.leftY = 0
        state.rightX = 0
        state.rightY = 0
        state.trackCameraTouch(at: nil)
        state.setButton(\.dpadUp, pressed: false)
        state.setButton(\.dpadDown, pressed: false)
        state.setButton(\.dpadLeft, pressed: false)
        state.setButton(\.dpadRight, pressed: false)
        // Pause / Resume are swapped out while held (the menu opens or closes under the finger).
        state.setButton(\.menu, pressed: false)
    }

    /// Menus only get Back (Resume on the pause menu's collectible pages), in Start's corner.
    private func menuControls(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if state.isOnCollectionPage {
                    resumeButton(scale: scale)
                } else {
                    backButton(scale: scale)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 16 * scale)
    }

    /// Cutscenes only get Pause, in its usual corner, and Subtitles in HUD's place.
    private func cutsceneControls(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                startButton(scale: scale)
                Spacer(minLength: 0)
                subtitlesButton(scale: scale)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 16 * scale)
    }

    private func controls(scale: CGFloat, trailingSafeAreaInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Pause in the top-left corner, HUD top right.
            HStack(alignment: .top) {
                startButton(scale: scale)
                Spacer(minLength: 0)
                hudButton(scale: scale)
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 0) {
                directionalSlot(scale: scale)

                Spacer(minLength: 0)

                faceButtons(scale: scale)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        faceButtonsFrame = frame
                    }
                    // Move through the trailing safe area so R1's physical-screen clearance
                    // matches the bottom clearance, while keeping the whole cluster together.
                    .offset(x: trailingSafeAreaInset)
                    .padding(.bottom, faceButtonLift * scale)
            }
        }
        .padding(.horizontal, 20 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 16 * scale)
    }

    // MARK: - D-pad / left stick

    /// Keeps the face buttons' row height. The slot itself is empty: the left stick floats under
    /// the thumb anywhere on the left half (see `body`), and menus are tapped directly.
    private func directionalSlot(scale: CGFloat) -> some View {
        Color.clear
            .frame(width: 144 * scale, height: 144 * scale)
            .allowsHitTesting(false)
    }

    // MARK: - HUD

    private func hudButton(scale: CGFloat) -> some View {
        PadButton("HUD", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            state.setTrigger(\.rightTrigger, pressed: pressed)
        } label: {
            padLabel("HUD", scale: scale * 0.8)
        }
    }

    /// Cutscenes only: Square, which toggles subtitles in-game.
    private func subtitlesButton(scale: CGFloat) -> some View {
        PadButton("Subtitles", shape: Capsule(), width: 96 * scale, height: 28 * scale) { pressed in
            state.setButton(\.buttonX, pressed: pressed)
        } label: {
            padLabel("SUBTITLES", scale: scale * 0.8)
        }
    }

    // MARK: - Start

    private func startButton(scale: CGFloat) -> some View {
        PadButton("Pause", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            state.setButton(\.menu, pressed: pressed)
        } label: {
            padLabel("PAUSE", scale: scale * 0.8)
        }
    }

    /// The pause menu's collectible pages: Start, which closes the menu and resumes the game.
    private func resumeButton(scale: CGFloat) -> some View {
        PadButton("Resume", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            state.setButton(\.menu, pressed: pressed)
        } label: {
            padLabel("RESUME", scale: scale * 0.8)
        }
    }

    /// Goes back one menu.
    private func backButton(scale: CGFloat) -> some View {
        PadButton("Back", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            if pressed { state.sendMenuEvent(.back) }
        } label: {
            padLabel("BACK", scale: scale * 0.8)
        }
    }

    // MARK: - Face buttons

    private func isInsideFaceButtonNoSwipeZone(_ location: CGPoint, scale: CGFloat) -> Bool {
        guard !faceButtonsFrame.isNull else { return false }
        let radius = faceButtonNoSwipeRadius * scale
        let localLocation = CGPoint(
            x: location.x - faceButtonsFrame.minX,
            y: location.y - faceButtonsFrame.minY
        )
        let faceButtonCenters = FaceButton.allCases.map { faceButtonCenter($0, scale: scale) }
        let r1Centers = state.isOnZoomer ? [] : [r1Center(scale: scale)]
        return (faceButtonCenters + r1Centers).contains { center in
            hypot(localLocation.x - center.x, localLocation.y - center.y) <= radius
        }
    }

    private func faceButtonCenter(_ button: FaceButton, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: (faceButtonClusterSize / 2 + button.direction.x * faceButtonSpacing) * scale,
            y: (faceButtonClusterSize / 2 + button.direction.y * faceButtonSpacing) * scale
        )
    }

    private func r1Center(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: (faceButtonClusterSize / 2 + faceButtonSpacing * 2) * scale,
            y: (faceButtonClusterSize / 2 + faceButtonSpacing) * scale
        )
    }

    private func faceButtons(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            FaceButtonCluster(
                scale: scale,
                diameter: faceButtonDiameter,
                spacing: faceButtonSpacing,
                hitOutset: faceButtonHitOutset,
                hitOverhang: faceButtonHitOverhang
            ) { button, pressed in
                state.setButton(button.control, pressed: pressed)
            }

            // R1 continues the Triangle-to-Circle diagonal and matches the face buttons. On the
            // zoomer it moves to the left side (see `body`); its slot stays so the cluster holds still.
            if !state.isOnZoomer {
                r1Button(scale: scale)
                    .offset(
                        x: (faceButtonClusterSize / 2 + faceButtonSpacing * 2 - faceButtonDiameter / 2) * scale,
                        y: (faceButtonClusterSize / 2 + faceButtonSpacing - faceButtonDiameter / 2) * scale
                    )
            }
        }
        .frame(
            width: (faceButtonClusterSize + faceButtonSpacing) * scale,
            height: faceButtonClusterSize * scale,
            alignment: .topLeading
        )
    }

    private func r1Button(scale: CGFloat) -> some View {
        PadButton(
            "R1",
            shape: Circle(),
            width: faceButtonDiameter * scale,
            height: faceButtonDiameter * scale
        ) { pressed in
            state.setButton(\.rightShoulder, pressed: pressed)
        } label: {
            padLabel("R1", scale: scale)
        }
    }

    private func padLabel(_ text: String, scale: CGFloat) -> some View {
        Text(text)
            .font(PadStyle.labelFont(scale))
            .foregroundStyle(PadStyle.label)
            // Tight dark shadow reads as the outlined lettering used in the game's menus.
            .shadow(color: .black.opacity(0.9), radius: 0.5, x: 0, y: 1)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
    }
}
