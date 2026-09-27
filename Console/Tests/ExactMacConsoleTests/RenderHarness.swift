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
    @MainActor
    static func png<V: View>(_ view: V, size: CGSize, to path: String) throws {
        // The directory has to exist before the write, and a missing one is the difference
        // between "the surface does not render" and "there was nowhere to put it".
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
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
        try RenderHarness.png(
            prompt,
            size: CGSize(width: Design.Layout.promptWidth, height: 710),
            to: RenderHarness.outputDirectory + "prompt.png",
        )
    }

    @Test
    func `the popover renders at 360pt and hugs its content`() throws {
        let model = ConsoleModel(channel: ConsoleChannelClient(socketPath: "/nonexistent", token: ""))
        try RenderHarness.png(
            MenuBarPopover(model: model),
            size: CGSize(width: Design.Layout.popoverWidth, height: 380),
            to: RenderHarness.outputDirectory + "popover.png",
        )
    }
}
