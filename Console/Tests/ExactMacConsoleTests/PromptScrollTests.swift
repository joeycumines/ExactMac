import AppKit
@testable import ExactMacConsole
import SwiftUI
import Testing

/// The approval dialog's scrolling, which the operator reported as absent, and which was
/// two separate defects rather than one.
///
/// THE MECHANISM WORKED AND SAID NOTHING. The disclosure has always been a 236pt ScrollView
/// and its content is 329pt, so it has always scrolled — but macOS overlay scrollbars are
/// invisible at rest, so a cut with no affordance reads as content that was withheld. The
/// design draws a rail in all five of its `body-scroll` frames and the app drew none.
///
/// THE REAL FAILURE WAS REACHABILITY. The reason is caller-supplied text of any length, the
/// field grew to fit it, and the prompt's height was unbounded: measured at 883pt with a
/// one-line reason and 1633pt with a 3,360-character one, against a window ceiling of 1008.
/// Past about 800 characters the options, the biometric line and the Deny row were pushed
/// below the bottom of a window that cannot be resized. A control the operator cannot see is
/// a control they cannot deny with.
@Suite("The approval prompt's scroll affordance and bounds", .serialized)
@MainActor
struct PromptScrollTests {
    private static let tree: [CallerTree.Row] = [
        .init(id: 1, name: "Terminal", role: "host", depth: 0, signature: .signed, isRequester: false),
        .init(id: 2, name: "/bin/zsh", role: "login shell", depth: 1, signature: .unresolved, isRequester: false),
        .init(id: 3, name: "/usr/local/bin/node", role: "agent host", depth: 2, signature: .unsigned, isRequester: false),
        .init(id: 5, name: "/usr/local/bin/exactmac", role: "requesting", depth: 3, signature: .unnotarized, isRequester: true),
    ]

    private static func prompt(
        state: ApprovalPrompt.State = .pending,
        reason: String? = "Refactoring the parser.",
    ) -> ApprovalPrompt {
        ApprovalPrompt(
            state: state,
            title: "Read the accessibility tree of any application",
            capabilityLine: "observation.ax  ·  every application  ·  continuous",
            risk: "High",
            riskDot: Design.Ink.danger,
            clock: "decides in 1:28",
            reason: reason,
            implication: "Also permits screen capture and reading the focused window's text.",
            tree: tree,
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
    }

    private static func height(of view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @Test
    func `A reason of any length leaves the prompt the same height`() {
        // THE REGRESSION GUARD, and it distinguishes the fix from the bug. Without the cap
        // the field grows to fit, so a 400-character reason measured 958 and a 3,360-
        // character one 1633, against a window ceiling of 1008 — the last option and the
        // Deny row below the bottom of a window that cannot be resized. With the cap the
        // field scrolls inside a fixed box, so every reason past the cap is the same height.
        //
        // AND NOW THE ONE-LINE CASE IS THE SAME TOO, which is a STRONGER property than the
        // one it replaces. The reason used to sit in the hugging header, so its height was
        // the prompt's height and the cap was the only thing standing between a 3,360-
        // character reason and an unreachable Deny row. It now sits inside the FIXED
        // disclosure viewport, so the reason cannot change the prompt's height at all — a
        // shorter assertion that is also a stronger guarantee, because it no longer depends
        // on a cap being set correctly.
        let sentence = "The agent must walk the accessibility tree to confirm the layout "
            + "before it rewrites the view controller, and it needs the focused window's "
            + "role, title and value at every level to do that. "
        let oneLine = Self.height(of: Self.prompt(reason: "Refactoring the parser."))
        let capped = Self.height(of: Self.prompt(reason: String(repeating: sentence, count: 4)))
        let enormous = Self.height(of: Self.prompt(reason: String(repeating: sentence, count: 40)))
        #expect(
            capped == enormous,
            "a 5,000-character reason changed the prompt's height by \(enormous - capped)pt, so the reason field is growing instead of scrolling",
        )
        #expect(
            oneLine == capped,
            "a one-line reason is \(oneLine) and a long one \(capped); inside a fixed viewport they must agree, because the reason can no longer move the prompt",
        )
        #expect(capped.reasonableHeight)
    }

    @Test
    func `The prompt's tallest state fits inside the window ceiling`() {
        // THE GUARD THAT KEEPS THE CAP HONEST. `maximumReasonHeight` was derived from a
        // measurement, and a derived number with nothing checking it is a number that goes
        // stale — six options and a long reason is the tall state, and this is what the
        // 96pt cap exists for. If a footer grows, this fails and the cap is re-derived
        // rather than the defect quietly returning.
        let sentence = "The agent must walk the accessibility tree to confirm the layout "
            + "before it rewrites the view controller, and it needs the focused window's "
            + "role, title and value at every level to do that. "
        let tall = Self.height(of: Self.prompt(state: .expanded, reason: String(repeating: sentence, count: 40)))
        #expect(
            tall <= ConsoleWindowHost.maximumWindowHeight,
            "the tallest state measures \(tall) against a ceiling of \(ConsoleWindowHost.maximumWindowHeight), so its last option is below the bottom of a window that cannot be resized",
        )
    }

    @Test
    func `A rail is drawn only where there is something to scroll`() {
        // The decision is a pure function so it can be asserted without a render, and so the
        // view cannot draw a thumb the arithmetic does not support.
        typealias Measurement = ScrollRail.Measurement

        #expect(ScrollRail.thumb(for: nil) == nil, "nothing is known, so nothing is claimed")

        let fits = Measurement(
            contentHeight: 200,
            viewportHeight: Design.Layout.promptScrollHeight,
            offset: 0,
        )
        #expect(ScrollRail.thumb(for: fits) == nil, "a region that fits needs no rail")

        // The prompt's REAL disclosure, measured rather than remembered. This used to be the
        // literal 329 in a 236 viewport, and the redesign moved the reason into the region
        // and the viewport to 320 — so the hardcoded pair was stale the moment the design
        // changed, which is the failure mode a literal in a test always has. The content is
        // asked for: the tree is four rows, the target is a fixed 35, the reason is the
        // design's single-line field, and the payload carries a caption and some monospace.
        let content = Self.disclosureContentHeight()
        #expect(
            content > Design.Layout.promptScrollHeight,
            "the disclosure measures \(content) against a \(Design.Layout.promptScrollHeight)pt viewport, so there is nothing to scroll and the rail would never appear",
        )
        let overflows = Measurement(
            contentHeight: content,
            viewportHeight: Design.Layout.promptScrollHeight,
            offset: 0,
        )
        guard let atTop = ScrollRail.thumb(for: overflows) else {
            Issue.record("a region taller than its viewport must draw a rail")
            return
        }
        // Proportional to the visible fraction, in a track inset 12pt each side.
        let track = Design.Layout.promptScrollHeight - Design.Space.three * 2
        #expect(abs(atTop.height - track * Design.Layout.promptScrollHeight / content) < 0.01)
        #expect(abs(atTop.offset) < 0.01, "a rail at the top is at the top")

        // Scrolled to the bottom, the thumb is at the bottom of its track. A rail that does
        // not move is not a scroll affordance — it tells the operator a scrollbar exists
        // without telling them where they are in it.
        let atBottom = ScrollRail.thumb(for: Measurement(
            contentHeight: content,
            viewportHeight: Design.Layout.promptScrollHeight,
            offset: content - Design.Layout.promptScrollHeight,
        ))
        guard let atBottom else {
            Issue.record("a scrolled region must still draw a rail")
            return
        }
        #expect(abs(atBottom.offset - (track - atBottom.height)) < 0.01)
        #expect(abs(atBottom.height - atTop.height) < 0.01, "scrolling moves it, not resizes it")
    }

    /// The disclosure's content height, measured from the view rather than remembered, so
    /// the rail's arithmetic is checked against the layout that actually ships.
    private static func disclosureContentHeight() -> CGFloat {
        let tree: [CallerTree.Row] = [
            .init(id: 1, name: "Terminal", role: "host", depth: 0, signature: .signed, isRequester: false),
            .init(id: 2, name: "/bin/zsh", role: "login shell", depth: 1, signature: .unresolved, isRequester: false),
            .init(id: 3, name: "/usr/local/bin/node", role: "agent host", depth: 2, signature: .unsigned, isRequester: false),
            .init(id: 5, name: "/usr/local/bin/exactmac", role: "requesting", depth: 3, signature: .unnotarized, isRequester: true),
        ]
        // The same three pieces the disclosure stacks, without the ScrollView that contains
        // them, so what is measured is the CONTENT and not the viewport.
        let content = VStack(alignment: .leading, spacing: Design.Space.component) {
            CallerTree(rows: tree)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(Design.Ink.surface)
                SystemField(caption: .target, value: "/Users/joeyc/dev/secret-project/notes.txt")
            }
            .frame(height: 35)
            UntrustedField(caption: .agentReason, value: "Refactoring the parser.")
            PayloadBlock(text: "AXUIElementCopyAttributeValue(AXFocusedApplication)")
        }
        .padding(.top, Design.Space.three)
        .padding(.horizontal, Design.Space.four)
        .padding(.bottom, Design.Space.three)
        .frame(width: Design.Layout.promptWidth)
        return Self.height(of: content)
    }

    @Test
    func `The rail is visible enough to be an affordance`() {
        // FOUND BY LOOKING AT THE RENDER, which is the only reason this is a test and not a
        // comment. The rail was drawn in `separator`, which is what the .fig drew and what
        // this first drew, and separator on surfaceSunken measures 1.27:1 in light and 1.62:1
        // in dark. WCAG 1.4.11 asks 3:1 of a non-text control. So the affordance that exists
        // to say "there is more, and here is where you are in it" was drawn at a contrast at
        // which it is not there — and a cut with an invisible rail is the defect E9 was
        // reported for, wearing a fix.
        //
        // MEASURED from the resolved colours rather than asserted as constants, because a
        // token can change and a test that reads the token's NAME proves nothing.
        var measured: [(scheme: String, ratio: CGFloat)] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else {
                Issue.record("the \(name.rawValue) appearance did not resolve")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                measured.append((
                    name.rawValue,
                    Self.contrast(Design.Ink.textSecondary, Design.Ink.surfaceSunken),
                ))
            }
        }
        #expect(measured.count == 2, "both schemes have to be measured or this proves nothing")
        for entry in measured {
            let hundredths = (entry.ratio * 100).rounded() / 100
            #expect(
                entry.ratio >= 3,
                "the rail is \(hundredths):1 in \(entry.scheme), and an affordance nobody can see is not one",
            )
        }
    }

    /// WCAG relative-luminance contrast between two SwiftUI colours, resolved in the current
    /// appearance. Reading the COLOUR and not the token name is the point: a test that
    /// asserted a token existed would still pass if the token changed to something
    /// invisible, which is exactly what happened here.
    private static func contrast(_ foreground: Color, _ background: Color) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: Color) -> CGFloat? {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return 0.2126 * channel(rgb.redComponent)
                + 0.7152 * channel(rgb.greenComponent)
                + 0.0722 * channel(rgb.blueComponent)
        }
        guard let a = luminance(foreground), let b = luminance(background) else { return 0 }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private extension CGFloat {
    /// Whether a prompt height is one this window can actually open at. A prompt that
    /// measures less than the header, the 236pt disclosure and the footer's least state
    /// together is not a prompt.
    var reasonableHeight: Bool {
        self > 600 && self < 1200
    }
}
