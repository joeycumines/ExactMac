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

    /// The height the view ASKS for, measured rather than declared.
    ///
    /// THE RENDERS USED TO BE DRAWN AT A HARDCODED 710pt — the design's measured height for
    /// the prompt — while the composition in this file measures taller, so the PNG showed the
    /// top and bottom of the card cut off at the window edge. The artefact was then cited as
    /// evidence that the alert fits, which it visibly did not: the risk chip was bisected at
    /// the top and the options summary was cut at the bottom. A render that lies about its
    /// own clipping is worse than no render.
    ///
    /// Measuring is also what the window host does at runtime (`ConsoleWindowHost.present`
    /// takes `fittingSize`), so the artefact and the window now agree by construction rather
    /// than by two people remembering the same number.
    @MainActor
    static func fittedHeight(
        of view: some View,
        width: CGFloat,
        ceiling: CGFloat = ConsoleWindowHost.maximumWindowHeight,
    ) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.layoutSubtreeIfNeeded()
        return min(max(hosting.fittingSize.height, 1), ceiling)
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

    /// Renders go to a COMMITTED path, not a temporary one.
    ///
    /// THEY USED TO GO TO `NSTemporaryDirectory()`, and an autopsy of this work found zero
    /// raster files tracked anywhere in the repository: every visual claim in this project's
    /// history was backed by a PNG that existed only while the machine that produced it was
    /// running. Under this project's own standing rule — the only acceptable evidence for
    /// anything visual is a rendered artefact THAT WAS READ — an artefact nobody else can
    /// open is not evidence, it is a claim. So the output directory is in the tree, the
    /// files are committed, and a reviewer can look at exactly what was looked at.
    static let outputDirectory = ProcessInfo.processInfo
        .environment["EXACTMAC_RENDER_DIR"]
        ?? repositoryRelativeRenderDirectory

    /// Resolved from `#filePath` rather than from the working directory, so the path does not
    /// depend on where the test runner happens to be launched from.
    static let repositoryRelativeRenderDirectory: String = {
        let testFile = URL(fileURLWithPath: #filePath)
        // Console/Tests/ExactMacConsoleTests/RenderHarness.swift -> repository root
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // TWO COMPONENTS, NOT ONE WITH A SLASH: `appendingPathComponent("docs/render/")`
        // appends the whole string as a single component, so the separator is swallowed and
        // the files land as `docs/renderprompt-light.png`.
        return root
            .appendingPathComponent("docs")
            .appendingPathComponent("render")
            .path + "/"
    }()
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
    func `the prompt renders its scroll rails in both schemes`() throws {
        // THE ARTEFACT, because a rail is a visual claim and the two states differ only in
        // whether a thumb is drawn: with a short reason the reason field hugs and shows
        // nothing, while the disclosure's 329pt of content in a 236pt viewport always
        // overflows and always shows one. A regression that silently removed the rail
        // would leave every assertion in the suite green.
        let longReason = String(
            repeating: "The agent must walk the accessibility tree to confirm the layout "
                + "before it rewrites the view controller, and it needs the focused "
                + "window's role, title and value at every level to do that. ",
            count: 6,
        )
        for (name, reason) in [("short", "Refactoring the parser."), ("long", longReason)] {
            let view = ApprovalPrompt(
                state: .pending,
                title: "Read the accessibility tree of any application",
                capabilityLine: "observation.ax  ·  every application  ·  continuous",
                risk: "High",
                riskDot: Design.Ink.danger,
                clock: "decides in 1:28",
                reason: reason,
                implication: "Also permits screen capture and reading the focused window's text.",
                tree: [
                    .init(id: 1, name: "Terminal", role: "host", depth: 0, signature: .signed, isRequester: false),
                    .init(id: 2, name: "/bin/zsh", role: "login shell", depth: 1, signature: .unresolved, isRequester: false),
                    .init(id: 3, name: "/usr/local/bin/node", role: "agent host", depth: 2, signature: .unsigned, isRequester: false),
                    .init(id: 5, name: "/usr/local/bin/exactmac", role: "requesting", depth: 3, signature: .unnotarized, isRequester: true),
                ],
                target: "/Users/joeyc/secret-project/notes.txt",
                payload: "AXUIElementCopyAttributeValue(AXFocusedApplication, "
                    + "kAXFocusedWindowAttribute), walking children to depth 12 and returning "
                    + "role, title, value and enabled for every node whose role is in "
                    + "{AXTextField, AXTextArea, AXStaticText}",
                biometricLine: "Touch ID will confirm: allow one clipboard read in TextEdit",
                biometricDot: Design.Ink.success,
                moreChoicesLabel: "4 more choices — scope, session, batch, always",
                showOptionsLabel: "Show options",
                selectedOption: .once,
            )
            let hosting = NSHostingView(rootView: view)
            hosting.layoutSubtreeIfNeeded()
            let fitted = hosting.fittingSize
            for mode in RenderHarness.AppearanceMode.allCases {
                try RenderHarness.png(
                    view,
                    size: fitted,
                    appearance: mode,
                    to: RenderHarness.outputDirectory + "prompt-rails-\(name)\(mode.suffix)",
                )
            }
        }
    }

    @Test
    func `the prompt renders what the app actually composes`() throws {
        // THE ARTEFACT FOR E7'S FIRST HALF, and it is built from a real `PendingRequest`
        // rather than from literal strings, so it renders the composition the operator
        // actually gets. Every earlier render of this surface was written by hand and could
        // therefore show a prompt the product never builds — which is how an alert made of
        // engine enums passed a review of its own layout.
        // BUILT FROM THE SERVER'S OWN TYPES, through the same mapping the app performs.
        // The hand-written wire shapes this replaced were a second copy of the server's
        // types that existed only to cross a socket, so this render could show a prompt the
        // product does not build -- which is how an alert made of engine enums passed a
        // review of its own layout.
        let (authorizationRequest, identity, decision) = ServerFixture.request(
            requestID: "r",
            capability: .accessibilityTraverse,
            rpcName: "exactmac.v1.ExactMac/GetAccessibilityTree",
            argumentSummary: "AXUIElementCopyAttributeValue(AXFocusedApplication, "
                + "kAXFocusedWindowAttribute), walking children to depth 12",
            agentReason: "Refactoring the view controller, which needs the real layout "
                + "rather than the one in the storyboard.",
        )
        let request = PendingRequest(
            request: authorizationRequest,
            identity: identity,
            decision: decision,
        )

        let view = ApprovalPrompt(
            state: .pending,
            title: request.promptTitle,
            capabilityLine: request.promptScopeLine,
            risk: request.riskClass.label,
            riskDot: request.riskClass.dot,
            clock: request.clockText,
            reason: request.agentReason,
            implication: request.implicationText,
            tree: CallerTree.rows(for: request),
            // NIL, as the model composes it: the wire carries one scope string and the
            // prompt had two places for it. A render that fills the target anyway is
            // showing a surface the product does not build, which is what this artefact
            // exists to rule out.
            target: nil,
            payload: request.argumentSummary,
            biometricLine: request.biometricLine,
            biometricDot: request.requiresBiometric ? request.riskClass.dot : Design.Ink.success,
            moreChoicesLabel: request.moreChoicesText,
            showOptionsLabel: "Show options",
            selectedOption: request.offeredKinds.first,
        )
        // SIZED FROM THE CONTENT, so the artefact shows the card whole or shows the window
        // ceiling honestly. A render drawn at a remembered 710pt showed a composition that
        // measures taller cut off at both ends, and that PNG was cited as proof the alert
        // fits.
        let height = RenderHarness.fittedHeight(of: view, width: Design.Layout.promptWidth)
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                view,
                size: CGSize(width: Design.Layout.promptWidth, height: height),
                appearance: mode,
                to: RenderHarness.outputDirectory + "prompt-composed\(mode.suffix)",
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
    func `the popover renders at 360pt and hugs its content`() throws {
        let model = ConsoleModel()
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
