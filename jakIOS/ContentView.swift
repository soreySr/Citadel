import SwiftUI
import UniformTypeIdentifiers

/// Where the start screen is in its lifecycle. The game runtime can only boot once per launch,
/// so the title plays in the same runtime the player later takes control of.
private enum StartPhase {
    /// Static start screen, shown first on every launch. With a valid disc image the runtime is
    /// already booting and loading the village underneath it.
    case menu
    /// Background faded to black for the hand-off from the image to the game's title.
    case booting
    /// The game's own title (logo intro, then "press start") on its own, input blocked until
    /// the player presses start.
    case attract
    /// The player has control of the game.
    case playing
}

struct ContentView: View {
    @State private var importedContent: ImportedGameContent?
    @State private var importStatus: ImportStatus = .notImported
    @State private var isShowingImporter = false
    @State private var phase: StartPhase = .menu
    /// The runtime has been started (it boots once per launch and keeps running).
    @State private var isRuntimeRunning = false
    /// The game's title shows "press start" (its logo intro has finished).
    @State private var isTitleReadyForStart = false

    init() {
        let content = GameContentStore.existingImportedContentSnapshot()
        // The runtime needs the level files built from the disc; until then .task builds them.
        let levelsBuilt = content.map(GameContentStore.hasBuiltLevels(in:)) ?? false
        _importedContent = State(initialValue: content)
        _importStatus = State(initialValue: content == nil ? .notImported :
            levelsBuilt ? .imported : .buildingLevels(0, 0))
        _isRuntimeRunning = State(initialValue: content != nil && levelsBuilt)
    }

    var body: some View {
        ZStack {
            // Bottom layer, so the runtime can boot and load the village while the static image
            // still covers it.
            if isRuntimeRunning {
                RuntimeShellView(
                    contentURL: importedContent?.location,
                    isInteractive: phase == .playing,
                    onBootstrapFinished: handleBootstrapFinished,
                    onTitleIntroReady: revealTitleSequence,
                    startsTitleIntro: phase == .attract,
                    onTitleReadyForStart: { isTitleReadyForStart = true },
                    onStartPressed: play
                ) {}
            }

            if phase == .menu || phase == .booting {
                JakMenuBackground()
                    .transition(.opacity)
            }

            // Fade to black between the start screen and the game's title (held on black until
            // then, so the swap underneath is invisible).
            Color.black
                .ignoresSafeArea()
                .opacity(phase == .booting ? 1 : 0)
                .allowsHitTesting(false)

            // The start screen (dark wash + text) fades out with the image; the game's title then
            // plays on its own.
            if phase == .menu {
                JakDarkWash()
                    .transition(.opacity)
                startMenu
                    .transition(.opacity)
            }

            // Once the title shows "press start", a tap anywhere is pressing start.
            if phase == .attract && isTitleReadyForStart {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(perform: play)
                    .accessibilityElement()
                    .accessibilityLabel("Press start")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { play() }
            }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            // Any file: not every iOS version declares a type for .iso, and a mismatched type makes
            // the picker ignore taps on the disc image. importContent rejects non-ISO files.
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let sourceURL = urls.first else {
                    return
                }
                importGameContent(from: sourceURL)
            case .failure(let error):
                importStatus = .failed(error.localizedDescription)
            }
        }
        .task {
            // Always open on the static start screen. With a previous import, start the runtime
            // right away underneath it, so the title is ready as soon as possible.
            let store = GameContentStore()
            guard let content = await store.existingImportedContent() else {
                return
            }
            importedContent = content
            do {
                try await buildLevels(for: content, with: store)
            } catch {
                importStatus = .failed(error.localizedDescription)
                return
            }
            importStatus = .imported
            beginTitleSequence()
        }
    }

    private var startMenu: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                JakOutlinedText("Citadel", size: 80, color: JakTheme.orange, outlineWidth: 3)
                JakOutlinedText("opengoal", size: 30, color: JakTheme.orange, outlineWidth: 3)
            }

            // Once a disc image is in there is nothing to report ("READY" isn't shown).
            if importStatus != .imported {
                statusLine
            }

            actionLine
                .frame(minHeight: 46)
        }
        .padding(24)
        .frame(maxWidth: 560)
    }

    /// IMPORT ISO until a disc image is in (the runtime can't swap discs once booted). Afterwards
    /// the line stays empty until the game's title takes over the screen.
    @ViewBuilder
    private var actionLine: some View {
        if !isRuntimeRunning {
            JakMenuButton(title: "IMPORT ISO", badge: .triangle) {
                isShowingImporter = true
            }
            .disabled(importStatus.isWorking)
        }
    }

    /// Boots the runtime underneath the static image; the game skips its Naughty Dog logo and
    /// goes straight to the title.
    private func beginTitleSequence() {
        guard !isRuntimeRunning, importedContent != nil else {
            return
        }
        isRuntimeRunning = true
    }

    private func handleBootstrapFinished(isReady: Bool, message: String) {
        guard isRuntimeRunning, phase == .menu else {
            return
        }
        guard isReady else {
            isRuntimeRunning = false
            importStatus = .failed(message)
            return
        }
        Task {
            // The reveal normally waits for the title to be ready (revealTitleSequence); don't keep
            // the image up forever if that signal never comes.
            try? await Task.sleep(for: .seconds(30))
            revealTitleSequence()
        }
    }

    /// The game's title is loaded and held on black: quickly fade the start screen to black, swap
    /// to the (equally black) game, then start the logo sequence so all of it is seen, from the
    /// game's own fade-in.
    private func revealTitleSequence() {
        guard phase == .menu else {
            return
        }
        withAnimation(.easeIn(duration: 0.3)) {
            phase = .booting
        }
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard phase == .booting else {
                return
            }
            // No animation: both sides are black, and this releases the game's title.
            phase = .attract
        }
    }

    private func play() {
        // Start only does something once the title shows "press start" (as in the game).
        guard phase == .attract, isTitleReadyForStart else {
            return
        }
        // Clear any touches made on the start screen so they don't reach the game.
        TouchInputState.shared.reset()
        withAnimation(.easeInOut(duration: 0.5)) {
            phase = .playing
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if importStatus.isWorking {
                ProgressView()
                    .tint(JakTheme.orange)
            }
            JakOutlinedText(importStatus.text, size: 32, color: JakTheme.orange)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 24)
    }

    private func importGameContent(from sourceURL: URL) {
        importStatus = .importing

        Task {
            do {
                let store = GameContentStore()
                let content = try await store.importContent(from: sourceURL)
                importedContent = content
                try await buildLevels(for: content, with: store)
                importStatus = .imported
                beginTitleSequence()
            } catch {
                importStatus = .failed(error.localizedDescription)
            }
        }
    }

    /// Builds the level files from the imported disc if they aren't there yet, showing progress.
    private func buildLevels(for content: ImportedGameContent, with store: GameContentStore) async throws {
        guard !GameContentStore.hasBuiltLevels(in: content) else {
            return
        }
        importStatus = .buildingLevels(0, 0)
        try await store.buildLevelsIfNeeded(in: content) { completed, total in
            Task { @MainActor in
                importStatus = .buildingLevels(completed, total)
            }
        }
    }
}

private enum ImportStatus: Equatable {
    case notImported
    case importing
    /// Converting the disc's levels (completed, total; total is 0 before the first level starts).
    case buildingLevels(Int, Int)
    case imported
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .importing, .buildingLevels:
            return true
        default:
            return false
        }
    }

    var text: String {
        switch self {
        case .notImported:
            return "Select disc image"
        case .importing:
            return "LOADING..."
        case .buildingLevels(let completed, let total):
            return total == 0 ? "BUILDING LEVELS..." : "BUILDING LEVELS \(completed)/\(total)"
        case .imported:
            return "READY"
        case .failed(let message):
            return message.uppercased()
        }
    }
}

// MARK: - Jak 1 menu theme

private enum JakTheme {
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.12)
    static let outline = Color(red: 0.18, green: 0.08, blue: 0.03)
    static let bronzeLight = Color(red: 0.93, green: 0.72, blue: 0.42)
    static let bronzeDark = Color(red: 0.45, green: 0.24, blue: 0.09)

    static let bronze = LinearGradient(
        colors: [bronzeLight, bronzeDark, bronzeLight.opacity(0.9), bronzeDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Ottselesque (Jak-style) lettering with a thin dark outline, echoing the in-game menu text.
private struct JakOutlinedText: View {
    let text: String
    let size: CGFloat
    let color: Color
    /// Outline thickness in points.
    let outlineWidth: CGFloat

    init(_ text: String, size: CGFloat, color: Color, outlineWidth: CGFloat = 1) {
        self.text = text
        self.size = size
        self.color = color
        self.outlineWidth = outlineWidth
    }

    var body: some View {
        Text(text)
            .font(.custom("Ottselesque-Regular", size: size))
            .foregroundStyle(color)
            // Stacked tight shadows approximate a stroke outline.
            .shadow(color: JakTheme.outline, radius: 0, x: outlineWidth, y: outlineWidth)
            .shadow(color: JakTheme.outline, radius: 0, x: -outlineWidth, y: -outlineWidth)
            .shadow(color: JakTheme.outline, radius: 0, x: outlineWidth, y: -outlineWidth)
            .shadow(color: JakTheme.outline, radius: 0, x: -outlineWidth, y: outlineWidth)
            .minimumScaleFactor(0.6)
    }
}

/// Sandover Village artwork filling the screen; shown until the live title fly-over replaces it.
private struct JakMenuBackground: View {
    var body: some View {
        Color.black
            .overlay {
                Image("MenuBackground")
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Soft dark wash over the background (static image or live fly-over) so the menu text stays legible.
private struct JakDarkWash: View {
    var body: some View {
        RadialGradient(
            colors: [.black.opacity(0.35), .black.opacity(0.6)],
            center: .center,
            startRadius: 0,
            endRadius: 500
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum FaceButton {
    case triangle
    case cross

    var color: Color {
        switch self {
        case .triangle: return Color(red: 0.3, green: 0.9, blue: 0.6)
        case .cross: return Color(red: 0.45, green: 0.65, blue: 1.0)
        }
    }

    var symbolName: String {
        switch self {
        case .triangle: return "triangle"
        case .cross: return "xmark"
        }
    }
}

/// Bronze-rimmed capsule button with a PlayStation-style face-button badge.
private struct JakMenuButton: View {
    let title: String
    let badge: FaceButton
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: badge.symbolName)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(badge.color)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(JakTheme.bronze, lineWidth: 3))

                JakOutlinedText(title, size: 20, color: JakTheme.orange)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 22)
            .padding(.vertical, 6)
            .frame(minWidth: 200, alignment: .leading)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(JakTheme.bronze, lineWidth: 3))
            .contentShape(Capsule())
        }
        .buttonStyle(JakPressStyle())
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct JakPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.1 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}
