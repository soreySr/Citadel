import SwiftUI

/// One entry of the Action menu (L1, or ACTION on the touch controls).
struct ActionMenuEntry: Identifiable, Equatable {
    /// Handed to the runtime when chosen (`OGJak1RuntimeHost.performAction`).
    let id: String
    let title: String
    /// False when the entry is shown but can't be used here; choosing it then does nothing.
    let isAvailable: Bool
    /// Shown under an unavailable entry.
    let unavailableHint: String
}

/// The Action menu's entries. Each feature that adds an action contributes one provider, which
/// returns its entry while that feature is on (nil otherwise), so entries come and go with their
/// options. The menu (and L1 replacing crouch) is only there while at least one entry is.
@MainActor
enum ActionMenuRegistry {
    private static let providers: [(OGJak1RuntimeHost) -> ActionMenuEntry?] = [
        // Fishing (experimental): fish from a shore, a dock or the boat's deck.
        { runtime in
            guard runtime.isFishingEnabled() else { return nil }
            return ActionMenuEntry(
                id: "fish",
                title: "FISH",
                isAvailable: runtime.canFish(),
                unavailableHint: "STAND BY THE SEA OR ON THE BOAT"
            )
        },
    ]

    static func entries(for runtime: OGJak1RuntimeHost) -> [ActionMenuEntry] {
        providers.compactMap { $0(runtime) }
    }
}

/// The Action menu's touch layer. The menu itself (dimmed view, bronze-ringed disc, ACTIONS header,
/// carousel and hints) is drawn by the game in its own font, like the options menus
/// (pc/ios/ios-action-menu.gc, fed by `OGJak1RuntimeHost.setActionMenuTitles`). This covers the whole
/// screen: swipe sideways (one entry per swipe) to browse, tap the disc to use the centered entry, tap
/// outside it or BACK to close. A controller uses the D-pad, Cross and Circle instead (Jak1MetalView).
struct ActionMenuView: View {
    @ObservedObject var state = TouchInputState.shared
    /// A controller is attached: no BACK button (Circle closes the menu).
    let showsControllerHints: Bool

    /// Horizontal travel that counts as a swipe.
    private let swipeDistance: CGFloat = 40
    /// The game's disc: centered, its radius this fraction of the view height (ios-action-menu.gc: 96 of 224).
    private let discRadiusFraction: CGFloat = 96.0 / 224.0
    @State private var hasSwiped = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / 780, proxy.size.height / 360)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(swipeAndTap(in: proxy.size))
                    .accessibilityElement()
                    .accessibilityLabel("Actions")
                    .accessibilityValue(state.actionMenuEntries.indices.contains(state.actionMenuSelection) ?
                        state.actionMenuEntries[state.actionMenuSelection].title : "")
                    .accessibilityAdjustableAction { direction in
                        state.sendActionMenuCommand(.step(direction == .increment ? 1 : -1))
                    }
                    .accessibilityAction { state.sendActionMenuCommand(.choose) }

                if !showsControllerHints {
                    VStack {
                        HStack {
                            backButton(scale: scale)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20 * scale)
                    .padding(.top, 12 * scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private func backButton(scale: CGFloat) -> some View {
        PadButton("Back", shape: Capsule(), width: 66 * scale, height: 28 * scale) { pressed in
            if pressed { state.sendActionMenuCommand(.close) }
        } label: {
            Text("BACK")
                .font(PadStyle.labelFont(scale * 0.8))
                .foregroundStyle(PadStyle.label)
                .shadow(color: .black.opacity(0.9), radius: 0.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
        }
    }

    /// One carousel step per sideways swipe (swiping left brings in the next entry, as the game's
    /// carousels do on touch); a touch that doesn't travel is a tap: on the disc it uses the entry,
    /// elsewhere it closes the menu.
    private func swipeAndTap(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if value.translation == .zero { hasSwiped = false }
                let dx = value.location.x - value.startLocation.x
                guard !hasSwiped, abs(dx) > swipeDistance,
                      abs(dx) > abs(value.location.y - value.startLocation.y) else { return }
                hasSwiped = true
                state.sendActionMenuCommand(.step(dx < 0 ? 1 : -1))
            }
            .onEnded { value in
                defer { hasSwiped = false }
                let travel = hypot(value.location.x - value.startLocation.x,
                                   value.location.y - value.startLocation.y)
                guard !hasSwiped && travel < 12 else { return }
                let fromCenter = hypot(value.location.x - size.width / 2, value.location.y - size.height / 2)
                state.sendActionMenuCommand(fromCenter <= size.height * discRadiusFraction ? .choose : .close)
            }
    }
}
