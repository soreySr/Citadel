import GameController
import SwiftUI
import UIKit

struct RuntimeShellView: View {
    let contentURL: URL?
    /// False while the game plays its title attract sequence behind the start screen:
    /// the game gets no input and no runtime controls or status are drawn.
    var isInteractive = true
    /// Reports the bootstrap result once the host has initialized (ready flag, readiness message).
    var onBootstrapFinished: ((Bool, String) -> Void)?
    /// Called once the game's title is loaded and held on black (waiting for startsTitleIntro).
    var onTitleIntroReady: (() -> Void)?
    /// Set to start the held title logo sequence.
    var startsTitleIntro = false
    /// Called once the game's title starts showing "press start".
    var onTitleReadyForStart: (() -> Void)?
    /// Called when a controller's Start is pressed while not interactive.
    var onStartPressed: (() -> Void)?
    let dismiss: () -> Void
    @State private var bootstrapReadiness = "Checking bundled AOT bootstrap plan…"
    @State private var isControllerConnected = false
    @ObservedObject private var touchState = TouchInputState.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Jak1MetalView(
                contentURL: contentURL,
                acceptsInput: isInteractive,
                onTitleIntroReady: onTitleIntroReady,
                startsTitleIntro: startsTitleIntro,
                onTitleReadyForStart: onTitleReadyForStart,
                onStartPressed: onStartPressed
            ) { readiness in
                withAnimation(.easeOut(duration: 0.3)) {
                    bootstrapReadiness = readiness
                }
                onBootstrapFinished?(Self.isKernelReady(readiness), readiness)
            }
            .ignoresSafeArea()

            // A physical controller replaces the on-screen pad.
            if isInteractive && !isControllerConnected {
                if touchState.isOnTitleScreen {
                    // No pad on the title (e.g. after backing out of the title menu): a tap
                    // anywhere is pressing start, like the first "press start".
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture(perform: pressStart)
                        .accessibilityElement()
                        .accessibilityLabel("Press start")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { pressStart() }
                } else if touchState.isMenuOpen || touchState.isGameVisible {
                    // Hidden on black loading screens; appears as the game fades in.
                    TouchControlsOverlay()
                        .transition(.opacity)
                }
            }

            // New Game slot screen: offer mirror mode for the new save once the game was beaten.
            // Above the touch layer so the checkbox takes its own taps.
            if isInteractive && touchState.isNewGameMirrorOptionVisible {
                NewGameMirrorCheckbox(
                    isChecked: touchState.isNewGameMirrorChecked,
                    showsControllerHint: isControllerConnected
                ) {
                    touchState.pendingNewGameMirrorToggle = true
                }
                // Hugs the right edge (past the safe area) so it stays clear of the save slots.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
                .ignoresSafeArea(edges: .horizontal)
                .transition(.opacity)
            }

            // Status is only useful while booting (or if boot fails); hide it once the kernel runs.
            if isInteractive && !isKernelReady {
                VStack(alignment: .leading) {
                    RuntimeBootstrapStatus(readiness: bootstrapReadiness)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .transition(.opacity)
            }
        }
        // Don't defer the bottom-edge system gesture: while deferred, iOS withholds single
        // touches near that edge (Cross and SELECT/START) until release so it can watch for
        // the first home swipe, which makes those buttons impossible to hold.
        .persistentSystemOverlays(.hidden)
        .onChange(of: touchState.isOnTitleScreen) { _, onTitle in
            // The pad goes away mid-press (Triangle backing out of the menu); release it.
            if onTitle { touchState.reset() }
        }
        .onChange(of: touchState.isGameVisible) { _, visible in
            // The pad also goes away when the screen fades to black; release anything held.
            if !visible && !touchState.isMenuOpen { touchState.reset() }
        }
        .animation(.easeOut(duration: 0.3), value: touchState.isGameVisible)
        .animation(.easeOut(duration: 0.2), value: touchState.isNewGameMirrorOptionVisible)
        .task {
            await observeControllerConnection()
        }
    }

    private func observeControllerConnection() async {
        refreshControllerConnection()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: .GCControllerDidConnect) {
                    refreshControllerConnection()
                }
            }
            group.addTask { @MainActor in
                for await notification in NotificationCenter.default.notifications(named: .GCControllerDidDisconnect) {
                    // GCController.controllers() can still list the controller that is going
                    // away while this is delivered, which left the touch controls hidden. Leave
                    // it out, then check again once the list has settled.
                    let disconnected = notification.object as? GCController
                    refreshControllerConnection(ignoring: disconnected)
                    try? await Task.sleep(for: .milliseconds(500))
                    refreshControllerConnection(ignoring: disconnected)
                }
            }
        }
    }

    /// A Start tap: latched for one input frame even though press and release land together.
    private func pressStart() {
        touchState.setButton(\.menu, pressed: true)
        touchState.setButton(\.menu, pressed: false)
    }

    /// Shows the touch controls whenever no usable controller is attached (gameplay or menus).
    /// `ignoring` is a controller that just disconnected but may still be listed.
    private func refreshControllerConnection(ignoring disconnected: GCController? = nil) {
        let connected = GameControllerInputReader.isPhysicalControllerConnected(ignoring: disconnected)
        // Menus drop their highlighted-option color while the touch controls are in use.
        touchState.isTouchControlsActive = !connected
        guard connected != isControllerConnected else { return }
        // The pad is swapping (overlay going away, or coming back after a disconnect); start from
        // nothing held either way.
        TouchInputState.shared.reset()
        withAnimation(.easeOut(duration: 0.25)) {
            isControllerConnected = connected
        }
    }

    private var isKernelReady: Bool {
        Self.isKernelReady(bootstrapReadiness)
    }

    private static func isKernelReady(_ readiness: String) -> Bool {
        readiness.hasPrefix("The signed GOAL kernel is ready")
    }
}

/// The Mirror Mode checkbox beside the New Game save slots, in the setup screen's orange
/// Ottselesque lettering with a black outline.
private struct NewGameMirrorCheckbox: View {
    let isChecked: Bool
    /// A controller is attached: R1 toggles it too.
    let showsControllerHint: Bool
    let toggle: () -> Void

    /// The setup screen's orange (ContentView JakTheme.orange).
    private static let orange = Color(red: 1.0, green: 0.58, blue: 0.12)

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Self.orange, lineWidth: 3)
                        .frame(width: 28, height: 28)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(Self.orange)
                    }
                }
                .blackOutline()
                VStack(alignment: .leading, spacing: 2) {
                    Text("MIRROR MODE")
                        .font(.custom("Ottselesque-Regular", size: 22))
                    if showsControllerHint {
                        Text("R1")
                            .font(.custom("Ottselesque-Regular", size: 14))
                    }
                }
                .foregroundStyle(Self.orange)
                .blackOutline()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mirror mode")
        .accessibilityValue(isChecked ? "On" : "Off")
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }
}

private extension View {
    /// Stacked tight shadows approximating a black stroke, like the setup screen's lettering.
    func blackOutline(width: CGFloat = 1.5) -> some View {
        shadow(color: .black, radius: 0, x: width, y: width)
            .shadow(color: .black, radius: 0, x: -width, y: -width)
            .shadow(color: .black, radius: 0, x: width, y: -width)
            .shadow(color: .black, radius: 0, x: -width, y: width)
    }
}

private struct RuntimeBootstrapStatus: View {
    let readiness: String

    var body: some View {
        Label(readiness, systemImage: "wrench.and.screwdriver")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Runtime status: \(readiness)")
    }
}
