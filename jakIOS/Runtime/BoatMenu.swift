import SwiftUI

/// The Boat menu's touch layer (boat-upgrades-plan.md). The menu itself (dimmed view, bronze-framed panel, BOAT LVL,
/// power cells and the UPGRADE button) is drawn by the game in its own font (pc/ios/ios-action-menu.gc,
/// ios-boat-menu-draw, fed by `OGJak1RuntimeHost.setBoatMenuOpen`). This covers the whole screen: tap UPGRADE to
/// upgrade, tap outside the panel or BACK to close. A controller uses Cross and Circle instead (Jak1MetalView).
struct BoatMenuView: View {
    @ObservedObject var state = TouchInputState.shared
    /// A controller is attached: no BACK button (Circle closes the menu).
    let showsControllerHints: Bool

    var body: some View {
        ZStack {
            // Taps, over the whole screen like the game's drawing.
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        tap(at: location, in: proxy.size)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Boat")
                    .accessibilityAction(named: "Upgrade") { state.sendBoatMenuCommand(.upgrade) }
                    .accessibilityAction { state.sendBoatMenuCommand(.close) }
            }
            .ignoresSafeArea()

            // BACK exactly where PAUSE sits on the touch controls: same geometry as TouchControlsOverlay
            // (horizontal safe area kept, scale from that size, 20 x 12 padding).
            if !showsControllerHints {
                GeometryReader { proxy in
                    let scale = min(1, proxy.size.width / 780, proxy.size.height / 360)
                    VStack(spacing: 0) {
                        HStack(alignment: .top) {
                            backButton(scale: scale)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20 * scale)
                    .padding(.top, 12 * scale)
                }
                .ignoresSafeArea(edges: .vertical)
            }
        }
    }

    private func backButton(scale: CGFloat) -> some View {
        PadButton("Back", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            if pressed { state.sendBoatMenuCommand(.close) }
        } label: {
            Text("BACK")
                .font(PadStyle.labelFont(scale * 0.8))
                .foregroundStyle(PadStyle.label)
                .shadow(color: .black.opacity(0.9), radius: 0.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
        }
    }

    private func tap(at location: CGPoint, in size: CGSize) {
        let layout = BoatMenuLayout(viewSize: size, atMaxLevel: state.isBoatAtMaxLevel)
        if let button = layout.upgradeButton, button.contains(location) {
            state.sendBoatMenuCommand(.upgrade)
        } else if !layout.panel.contains(location) {
            state.sendBoatMenuCommand(.close)
        }
    }
}

/// Where ios-boat-menu-draw puts the panel and the UPGRADE button, in view points. The game draws in 512 x 224 units
/// stretched over the whole view; keep these numbers in step with ios-action-menu.gc.
struct BoatMenuLayout {
    let panel: CGRect
    /// Nil at the top level (no button).
    let upgradeButton: CGRect?

    init(viewSize size: CGSize, atMaxLevel: Bool) {
        let unitX = size.width / 512
        let unitY = size.height / 224
        // (/ 512.0 (* 224.0 aspect-ratio)): game units per screen-height unit horizontally
        let aspect = 512 / (224 * max(0.5, size.width / max(1, size.height)))
        let halfHeight: CGFloat = 62
        let halfWidth = min(236, halfHeight * aspect * (atMaxLevel ? 1.3 : 2.6))
        panel = CGRect(x: (256 - halfWidth) * unitX, y: (112 - halfHeight) * unitY,
                       width: 2 * halfWidth * unitX, height: 2 * halfHeight * unitY)
        if atMaxLevel {
            upgradeButton = nil
        } else {
            // Drawn half-size 0.34 hw x 11 at (256 + hw / 2, 142); a little extra all round for fingers.
            let margin: CGFloat = 5
            let buttonHalfWidth = 0.34 * halfWidth + margin
            let buttonHalfHeight = 11 + margin
            let centerX = 256 + 0.5 * halfWidth
            let centerY: CGFloat = 112 + 30
            upgradeButton = CGRect(x: (centerX - buttonHalfWidth) * unitX, y: (centerY - buttonHalfHeight) * unitY,
                                   width: 2 * buttonHalfWidth * unitX, height: 2 * buttonHalfHeight * unitY)
        }
    }
}
