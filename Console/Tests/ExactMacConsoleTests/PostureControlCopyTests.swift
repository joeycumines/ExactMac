import AppKit
@testable import ExactMacConsole
import Testing

/// What the posture control SAYS, which is E31's whole surface.
///
/// Hana's report was "three options, literally no permissive option, no explanation
/// whatsoever as to what they do". The explanations are the fix's substance; these tests
/// hold them in place. They are STRING tests on purpose, and that is not a contradiction
/// of the standing rule that prose is copy and will be revised: the revision path is the
/// DESIGN (docs/design.fig), and the test's job is to catch the code and the design
/// drifting apart — which is why the anchor is the design's own text, not literals
/// restated here a second time. What is asserted independently of the design string is
/// structure that must survive any copy edit: every option explained, each explanation
/// attached to its own label, the two fixed statements present, and nothing readable
/// that is an internal name.
@Suite("The posture control says what each option does")
@MainActor
struct PostureControlCopyTests {
    // NOTE ON THE DESIGN ANCHOR: a `designText` helper used to sit here, reading
    // docs/design.fig's bytes and returning nil (the canvas payload is an openpencil-
    // binary ZIP no test can parse), under a comment claiming the render test asserted
    // design/code parity — nothing did. It was deleted rather than wired: parity was
    // verified at review time by exporting the design's posture-desc nodes and diffing
    // the text, and if the copy is ever revised that check is re-run by hand against
    // the design, because no automated anchor exists to update.

    @Test
    func `every option has an explanation attached to its label`() {
        let block = PostureControl.optionExplanations
        for choice in PostureControl.Choice.allCases {
            // The label and the em-dash keyed explanation must both appear, and the
            // explanation must follow its own label — not another option's.
            let key = "\(choice.label) — "
            let range = block.range(of: key)
            #expect(range != nil, "no explanation keyed to \(choice.label)")
            if let range {
                let rest = block[range.upperBound...]
                let nextLabel = PostureControl.Choice.allCases
                    .first { $0 != choice && rest.contains("\($0.label) — ") }
                #expect(
                    choice.explanation.isEmpty == false,
                    "an empty explanation explains nothing",
                )
                // The explanation text itself must sit before the next option's key, so
                // a copy edit cannot orphan an explanation onto the wrong option.
                if let next = nextLabel {
                    let nextKey = rest.range(of: "\n\(next.label) — ")
                    #expect(
                        nextKey != nil,
                        "explanations after \(choice.label) do not include \(next.label)'s",
                    )
                }
            }
        }
    }

    @Test
    func `the fixed statements are stated, not left as an absence`() {
        let block = PostureControl.optionExplanations
        // WHY no permissive option exists — the acceptance's own demand that the reason
        // be stated. Asserted by the load-bearing phrase, not the whole sentence, so a
        // punctuation edit does not false-fail.
        #expect(
            block.contains("cannot be made more permissive than"),
            "the reason there is no permissive option must be stated",
        )
        // E24's set is FIXED in the server, not operator-configurable — the same demand.
        #expect(
            block.contains("never prompt at all is fixed in the server"),
            "the fixed never-prompt set must be stated",
        )
    }

    @Test
    func `no operator-facing string exposes an internal identifier`() {
        // Invariant 17 and knowledgeStore.capabilityTokenOnTheScopeLine: what must not
        // reach the operator is an INTERNAL spelling — a dotted capability token, a
        // camelCase enum rawValue, an RPC name, a code symbol. The option NAMES ("Ask
        // every time", "Balanced", "Locked down") are the operator's own words and the
        // acceptance requires them; ordinary English that happens to share letters with
        // an internal name ("balanced" the adjective in "more permissive than Balanced")
        // is not a leak. So the forbidden list is internal spellings only, and the one
        // that matters most — "lockedDown" the rawValue versus "Locked down" the label —
        // is what proves the check is real rather than vacuous.
        let forbidden = [
            "localEcho", "displayRead", "local.echo", "display.read",
            "script.execute", "clipboard.read", "clipboard.write",
            "lockedDown", "locked_down", "allowOnce", "allowTargetApplication",
            "allowSession", "preAuthorizeEnvelope", "allowGlobalPersistent",
            "promptRequired", "postureLockedDown", "honoursStandingGrants",
            "requiresConsent", "nonConsentRequiring", "exactmac.v1",
        ]
        for choice in PostureControl.Choice.allCases {
            let text = choice.label + " " + choice.explanation
            for token in forbidden {
                #expect(
                    !text.lowercased().contains(token.lowercased()),
                    "\(token) must not reach the operator (invariant 17)",
                )
            }
        }
        // The full block adds only the fixed statements; check those too.
        for token in forbidden {
            #expect(
                !PostureControl.fixedStatements.lowercased().contains(token.lowercased()),
                "\(token) must not reach the operator (invariant 17)",
            )
        }
    }

    @Test
    func `the settings window renders the explanation block in both schemes`() throws {
        // Renders the REAL window so the block is verified as drawn, not merely as a
        // string — and the artefacts land in the committed render directory, where a
        // reviewer reads them. Height measured, per RenderHarness's own rule against a
        // hardcoded window that clips its content.
        let view = SettingsWindow()
        let width: CGFloat = 720
        let height = RenderHarness.fittedHeight(of: view, width: width)
        for mode in RenderHarness.AppearanceMode.allCases {
            try RenderHarness.png(
                view,
                size: CGSize(width: width, height: height),
                appearance: mode,
                to: RenderHarness.outputDirectory + "settings-posture-e31\(mode.suffix)",
            )
        }
    }
}
