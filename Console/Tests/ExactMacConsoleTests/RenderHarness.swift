import AppKit
@testable import ExactMacConsole
import SwiftUI
import Testing

/// Renders the designed surfaces OFFSCREEN and writes PNGs, because the design is verified by
/// LOOKING at it and a build that compiles is not a render that matches.
///
/// Screen Recording permission is not available here, so the only honest way to see what
/// the app draws is to have the app draw it itself.
enum RenderHarness {
    enum AppearanceMode: Sendable, CaseIterable {
        case light
        case dark

        var nsAppearance: NSAppearance {
            switch self {
            case .light: NSAppearance(named: .aqua)!
            case .dark: NSAppearance(named: .darkAqua)!
            }
        }

        var colorScheme: ColorScheme {
            switch self {
            case .light: .light
            case .dark: .dark
            }
        }

        var suffix: String {
            switch self {
            case .light: "-light.png"
            case .dark: "-dark.png"
            }
        }
    }

    @MainActor
    static func png(
        _ view: some View,
        size: CGSize,
        appearance: AppearanceMode = .light,
        to path: String,
    ) throws {
        // The directory has to exist before the write, and a missing one is the difference
        // between "the surface does not render" and "there was nowhere to put it".
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let app = appearance.nsAppearance
        let hosting = NSHostingView(rootView: view.preferredColorScheme(appearance.colorScheme))
        hosting.appearance = app
        hosting.frame = CGRect(origin: .zero, size: size)
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        app.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: representation)
        }
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static let outputDirectory = ProcessInfo.processInfo
        .environment["EXACTMAC_RENDER_DIR"]
        ?? NSTemporaryDirectory() + "exactmac-render/"
}

@Suite("The designed surfaces render", .serialized)
@MainActor
struct RenderTests {
    @Test
    func `the approval prompt renders at 420pt with the reason in the non-scrolling header`() throws {
        let prompt = ApprovalPrompt(
            state: .pending,
            title: "Read the clipboard in TextEdit",
            capabilityLine: "clipboard.read  ·  scoped to one application",
            risk: "Elevated",
            riskDot: Design.Ink.caution,
            clock: "decides in 0:45",
            reason: "Pasting the test fixture into the TextEdit scratch buffer.",
            implication: "Also permits screen capture and reading the focused window's text.",
            tree: [
                .init(id: 1, name: "Terminal", role: "host", depth: 0, signature: .signed, isRequester: false),
                .init(id: 2, name: "zsh", role: "login shell", depth: 1, signature: .unresolved, isRequester: false),
                .init(id: 3, name: "opencode", role: "agent  ·  origin", depth: 2, signature: .unsigned, isRequester: false),
                .init(id: 4, name: "exactmac", role: "requesting", depth: 3, signature: .unnotarized, isRequester: true),
            ],
            target: "/Users/joeyc/dev/secret-project/notes.txt",
            payload: "AXUIElementCopyAttributeValue(AXFocusedApplication, "
                + "kAXFocusedWindowAttribute), walking children to depth 12 and returning "
                + "role, title, value and enabled for every node whose role is in "
                + "{AXTextField, AXTextArea, AXStaticText}",
            biometricLine: "Touch ID will confirm: allow one clipboard read in TextEdit",
            biometricDot: Design.Ink.success,
            moreChoicesLabel: "4 more choices — scope, session, batch, always",
            showOptionsLabel: "Show",
            selectedOption: .once,
        )
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                prompt,
                size: CGSize(width: Design.Layout.promptWidth, height: 710),
                appearance: mode,
                to: RenderHarness.outputDirectory + "prompt\(mode.suffix)",
            )
        }
    }

    @Test
    func `the render harness leaves the process appearance unchanged`() throws {
        let initialAppearance = NSAppearance.currentDrawing()
        let prompt = ApprovalPrompt(
            state: .pending,
            title: "Read the clipboard in TextEdit",
            capabilityLine: "clipboard.read · scoped to one application",
            risk: "Elevated",
            riskDot: Design.Ink.caution,
            clock: "decides in 0:45",
            reason: "Testing appearance",
            implication: nil,
            tree: [],
            target: nil,
            payload: "test",
            biometricLine: "Touch ID will confirm",
            biometricDot: Design.Ink.success,
            moreChoicesLabel: nil,
            showOptionsLabel: nil,
            selectedOption: .once,
        )
        try RenderHarness.png(
            prompt,
            size: CGSize(width: Design.Layout.promptWidth, height: 710),
            appearance: .dark,
            to: RenderHarness.outputDirectory + "appearance-check.png",
        )
        let restoredAppearance = NSAppearance.currentDrawing()
        #expect(initialAppearance == restoredAppearance)
    }

    @Test
    func `prompt disclosure geometry ensures caption is inside viewport and copy control is not cut`() {
        let tree: [CallerTree.Row] = [
            .init(id: 1, name: "Terminal", role: "host", depth: 0, signature: .signed, isRequester: false),
            .init(id: 2, name: "zsh", role: "login shell", depth: 1, signature: .unresolved, isRequester: false),
            .init(id: 3, name: "opencode", role: "agent  ·  origin", depth: 2, signature: .unsigned, isRequester: false),
            .init(id: 4, name: "exactmac", role: "requesting", depth: 3, signature: .unnotarized, isRequester: true),
        ]
        let treeView = NSHostingView(rootView: CallerTree(rows: tree).frame(width: 388))
        treeView.layoutSubtreeIfNeeded()
        let treeHeight = treeView.fittingSize.height
        #expect(abs(treeHeight - 140) <= 1.0)

        let targetView = NSHostingView(rootView: ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surface)
            SystemField(caption: .target, value: "/Users/joeyc/dev/secret-project/notes.txt")
        }.frame(width: 388, height: 35))
        targetView.layoutSubtreeIfNeeded()
        let targetHeight = targetView.fittingSize.height
        #expect(abs(targetHeight - 35) <= 1.0)

        let captionTop = Design.Space.three + treeHeight + Design.Space.component + targetHeight + Design.Space.component + Design.Space.two
        let captionHeight: CGFloat = 14.5
        let captionBottom = captionTop + captionHeight

        let viewportHeight = Design.Layout.promptScrollHeight
        #expect(viewportHeight == 236)
        #expect(captionBottom < viewportHeight)

        let copyTop = captionBottom + Design.Space.two
        #expect(copyTop >= viewportHeight)
    }

    @Test
    func `the popover renders at 360pt and hugs its content`() throws {
        let model = ConsoleModel(channel: ConsoleChannelClient(socketPath: "/nonexistent", token: ""))
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                MenuBarPopover(model: model),
                size: CGSize(width: Design.Layout.popoverWidth, height: 380),
                appearance: mode,
                to: RenderHarness.outputDirectory + "popover\(mode.suffix)",
            )
        }
    }
}

@Suite("The designed windows render", .serialized)
@MainActor
struct WindowRenderTests {
    @Test
    func `the grants manager renders at 720pt`() throws {
        let grants = [
            GrantRow.Model(
                id: "1",
                consequence: "Read the clipboard in TextEdit",
                capability: "clipboard.read",
                scope: "clipboard.read  ·  TextEdit only  ·  for 5 minutes",
                holder: "exactmac-mcp",
                signature: .unnotarized,
                origin: "Origin: prompt at 16:42  ·  granted 4 minutes ago",
                remaining: "3m 12s",
                countdown: .live,
            ),
            GrantRow.Model(
                id: "2",
                consequence: "Type and click as you, in any app",
                capability: "input.synthesize",
                scope: "input.synthesize  ·  every application  ·  for 8 hours",
                holder: "exactmac-mcp",
                signature: .unsigned,
                origin: "Origin: prompt at 16:38  ·  granted 8 minutes ago",
                remaining: "1m 04s",
                countdown: .soon,
            ),
            GrantRow.Model(
                id: "3",
                consequence: "Read the accessibility tree of any app",
                capability: "observation.ax",
                scope: "observation.ax  ·  every application  ·  inside an envelope",
                holder: "codex",
                signature: .signed,
                origin: "Origin: envelope approved at 16:30  ·  envelope has 1h 52m left",
                remaining: "1h 52m",
                countdown: .live,
            ),
            GrantRow.Model(
                id: "4",
                consequence: "Read the clipboard in any app",
                capability: "clipboard.read",
                scope: "clipboard.read  ·  every application  ·  for 15 minutes",
                holder: "codex",
                signature: .signed,
                origin: "Origin: prompt at 15:58  ·  expired 12 minutes ago",
                remaining: "expired",
                countdown: .expired,
            ),
        ]
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                GrantsManager(grants: grants),
                size: CGSize(width: 720, height: 642),
                appearance: mode,
                to: RenderHarness.outputDirectory + "grants\(mode.suffix)",
            )
        }
    }

    @Test
    func `the activity timeline renders with a broken chain`() throws {
        let rows = [
            ActivityRow.Model(
                id: "1",
                isAllowed: true,
                time: "16:42:07",
                consequence: "Read the clipboard in TextEdit",
                capability: "clipboard.read · TextEdit only",
                basis: "Allowed by a grant you approved at 16:38 · expires in 3m 12s",
                identity: "exactmac-mcp · pid 4517",
                signature: .unnotarized,
                agentReason: "Pasting the test fixture into the TextEdit scratch buffer.",
                operatorNote: nil,
            ),
            ActivityRow.Model(
                id: "2",
                isAllowed: false,
                time: "16:39:52",
                consequence: "Run a shell command in any application",
                capability: "script.execute · every application",
                basis: "Denied — no grant matched, and you declined it in the prompt",
                identity: "codex · pid 8823",
                signature: .signed,
                agentReason: "Installing the fixture dependencies before the run.",
                operatorNote: "Use the scoped option next time — this reaches every app I have open.",
            ),
        ]
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                ActivityTimeline(
                    rows: rows,
                    integrity: .broken(at: 1283),
                    subtitle: "Today · entries after 1,283 are untrusted",
                ),
                size: CGSize(width: 720, height: 824),
                appearance: mode,
                to: RenderHarness.outputDirectory + "activity\(mode.suffix)",
            )
        }
    }
}

@Suite("The remaining designed surfaces render", .serialized)
@MainActor
struct RemainingRenderTests {
    @Test
    func `the settings window renders at 720pt`() throws {
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                SettingsWindow(),
                size: CGSize(width: 720, height: 1008),
                appearance: mode,
                to: RenderHarness.outputDirectory + "settings\(mode.suffix)",
            )
        }
    }

    @Test
    func `the envelope review is a different surface from the prompt`() throws {
        let envelope = EnvelopeReview(
            requester: "Codex",
            reason: "Refactoring the parser, which needs clipboard and tree reads at each step.",
            capabilities: [
                .init(
                    id: "clipboard",
                    consequence: "Read the clipboard in any app the agent names",
                    breadth: "clipboard.read  ·  any application",
                    risk: .elevated,
                ),
                .init(
                    id: "observation",
                    consequence: "Read the accessibility tree of any app",
                    breadth: "observation.ax  ·  any application",
                    risk: .elevated,
                ),
                .init(
                    id: "input",
                    consequence: "Type and click as you, in any app",
                    breadth: "input.synthesize  ·  any application",
                    risk: .high,
                ),
            ],
            duration: "2 hours",
            maximumDuration: "8 hours",
            biometricLine: "Touch ID will confirm: pre-authorize 3 capabilities for 2 hours",
        )
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                envelope,
                size: CGSize(width: 420, height: 617),
                appearance: mode,
                to: RenderHarness.outputDirectory + "envelope\(mode.suffix)",
            )
        }
    }
}
