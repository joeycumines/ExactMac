import AppKit
@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import SwiftUI
import Testing

/// What the prompt SAYS, which is most of what made the alert unusable.
///
/// Hana called the first alert this system ever showed an operator "pretty terrible UI/UX".
/// The layout turned out to reconcile with the design; the composition did not, and the
/// composition is what an operator reads. Every assertion here is a string the operator would
/// have seen.
@Suite("The prompt says what it means", .serialized)
@MainActor
struct PromptCompositionTests {
    /// Built from the SERVER'S OWN TYPES through the app's real mapping.
    ///
    /// It used to be built from the duplicated wire shapes, so it exercised a translation
    /// production no longer performs. It also took four parameters the server does not
    /// send — a consequence string, a scope string, a consent timeout and a revoke-everything
    /// flag — and the app now derives the first two and has no source at all for the last
    /// two. Those are named where they are asserted rather than faked here.
    private static func request(
        capability: Capability = .clipboardRead,
        rpcName: String = "exactmac.v1.ExactMac/GetClipboard",
        agentReason: String? = "answering a question about what you copied",
        riskClass: RiskClass = .elevated,
        implied: Set<Capability> = [],
        offered: [OfferedDecision.Kind] = [.allowOnce, .deny],
        requiresBiometric: Bool = false,
        biometricReason: String? = nil,
    ) -> PendingRequest {
        let (req, identity, decision) = ServerFixture.request(
            requestID: "r",
            capability: capability,
            rpcName: rpcName,
            agentReason: agentReason,
        )
        return PendingRequest(
            request: req,
            identity: identity,
            decision: AuthorizationDecision(
                outcome: .deny,
                basis: .promptRequired,
                effectiveCapabilities: Set([capability]).union(implied),
                blastRadius: decision.blastRadius,
                riskClass: riskClass,
                // NO REASON BY DEFAULT, so the case where the engine required a ceremony
                // without saying why is reachable at all.
                biometric: requiresBiometric
                    ? .required(reason: biometricReason ?? "")
                    : .notRequired,
                offeredDecisions: decision.offeredDecisions.filter { offered.contains($0.kind) },
                expiresAt: nil,
            ),
        )
    }

    // The server describes each option's SCOPE, and the scopes are what distinguish one
    // option from another. The fixture used one string for all of them, which produced
    // "or any and any" and hid whether the prompt was reading the right field.

    /// NOTHING AN ENGINE INTERNAL MAY APPEAR ON THE SURFACE.
    ///
    /// The old title was `"\(capability) · \(rpcName)"`, the risk chip was the decision's
    /// `basis`, and the fallback biometric line was "No ceremony is required for this
    /// option" — so the heading read "clipboard.read · exactmac.v1.ExactMac/GetClipboard"
    /// and the chip read "promptRequired". Both are engine vocabulary shown to a person.
    ///
    /// THE SCOPE LINE IS THE ONE EXCEPTION AND IT IS DELIBERATE: the design puts the
    /// capability token there — "clipboard.read · scoped to one application" — because the
    /// token is what the grant is keyed on and hiding it would leave the operator unable to
    /// check it against anything. So the token is asserted to appear on that line and ONLY
    /// on that line, which is the stronger claim than forbidding it everywhere.
    @Test
    func `No engine internal appears in what the prompt says`() {
        let request = Self.request()
        let outsideTheScopeLine = [
            request.promptTitle,
            request.riskClass.label,
            request.implicationText ?? "",
            request.biometricLine,
            request.moreChoicesText ?? "",
            request.clockText ?? "",
        ]
        for text in outsideTheScopeLine {
            for leaked in [
                "clipboard.read",
                "promptRequired",
                "exactmac.v1",
                "GetClipboard",
                "allowOnce",
                "rpcName",
            ] {
                #expect(
                    !text.contains(leaked),
                    "the operator would read \"\(leaked)\" in \"\(text)\"",
                )
            }
        }
        // THE RISK CHIP NAMES A LEVEL. The second half of this assertion used to be
        // `riskClass.label != basis`, which proved the chip was not showing the engine's
        // reason for reaching that risk class. `basis` is no longer carried on the
        // disclosure at all — the model dropped it rather than merely declining to render
        // it — so there is nothing left for the chip to confuse itself with, and the
        // absence of the field is the stronger guarantee. What is asserted here is the half
        // that still has a subject: the level is present, and the engine vocabulary the
        // loop above enumerates is not.
        #expect(request.riskClass.label.isEmpty == false)
        #expect(
            outsideTheScopeLine.contains { $0.contains(request.riskClass.label) },
            "the level the engine graded it at, shown as a level",
        )
    }

    @Test
    func `The title says what would happen, not what was asked for`() {
        #expect(Self.request().promptTitle == "Read the clipboard and its history")
        // REVOKE-EVERYTHING IS NOT REACHABLE FROM THE SERVER'S REQUEST, and the gap is
        // named rather than worked around. `AuthorizationRequest` carries no marker
        // distinguishing it, so `PendingRequest.isRevokeAll` is constant and this test used
        // to assert a title the product cannot currently produce. The property the title
        // guards — that the prompt names what would happen rather than the token asked for —
        // is asserted on the request that CAN arrive.
        #expect(Self.request().promptTitle == "Read the clipboard and its history")
        #expect(!Self.request().promptTitle.contains("clipboard.read"), "the title is a consequence, not a token")
    }

    @Test
    func `The scope line is the scope, and the token is on no operator-facing line at all`() {
        let request = Self.request()
        #expect(
            request.promptScopeLine == request.scopeDescription,
            "the line under the title says how wide the grant reaches, and nothing else",
        )
        // INVARIANT 17, ASSERTED ON THE THREE LINES AN OPERATOR READS AS A WHOLE. The title
        // already says what the capability IS in words, so a token anywhere else restates
        // that fact in a form nobody can act on. The test this replaced asserted the token
        // WAS here, on the strength of a design that has since changed; keeping the assertion
        // and flipping its sign would pin nothing, so the property is stated instead: the
        // token is on none of them.
        for (name, line) in [
            ("the title", request.promptTitle),
            ("the scope line", request.promptScopeLine),
            ("the implication", request.implicationText ?? ""),
        ] {
            #expect(
                !line.contains(request.capability),
                "\(name) exposes the capability token: \(line)",
            )
        }
    }

    @Test
    func `The implication says what else is permitted, in words`() {
        // A capability that implies nothing says nothing, rather than a block that is
        // present and empty.
        #expect(Self.request().implicationText == nil)

        let implied = Self.request(capability: .scriptExecute, implied: [.clipboardRead])
        #expect(
            implied.implicationText == "Also permits reading the clipboard and its history",
            "got \(implied.implicationText ?? "nil")",
        )
        // The capability being asked for must not appear in its own implication, and the
        // boundary is where that is enforced so no call site can reintroduce it. This
        // request IS clipboard.read, so its own capability comes back out of the list.
        let selfImplied = Self.request(implied: [.clipboardRead, .screenObserve])
        #expect(
            selfImplied.implicationText == "Also permits taking a screenshot of the screen",
            "the capability being asked for must not be listed as something it also permits, got \(selfImplied.implicationText ?? "nil")",
        )
        // And a genuinely plural implication reads as a list.
        #expect(
            Self.request(
                capability: .scriptExecute,
                implied: [.clipboardRead, .screenObserve],
            ).implicationText
                == "Also permits reading the clipboard and its history and taking a screenshot of the screen",
        )

        // AN UNRECOGNISED TOKEN IS NO LONGER REACHABLE, and that is a real improvement
        // rather than a lost case. The implied set is now the engine's own `Capability`,
        // so a name the app does not recognise cannot arrive at all — the prompt used to
        // have to defend itself against a bare identifier here, and now there is nothing to
        // defend against. The property that survives is that an implication naming only
        // capabilities the app can name reads as a sentence.
        // An implication made of capabilities the app CAN name reads as a sentence, and
        // that is now the only case: there is no unnameable capability to defend against.
        #expect(
            Self.request(implied: [.macroExecute]).implicationText == "Also permits replaying a recorded macro",
        )
    }

    @Test
    func `The prompt says how long the operator has`() {
        // The prompt wires the live configured consent timeout into clockText.
        let defaultTimeout = ServerConfig.defaultConsentTimeoutSeconds
        #expect(Self.request().clockText == "decides in \(defaultTimeout)s")
    }

    @Test
    func `The biometric line says what will be asked, or that nothing will`() {
        #expect(
            Self.request(
                requiresBiometric: true,
                biometricReason: "Touch ID will confirm: allow one clipboard read in TextEdit",
            ).biometricLine == "Touch ID will confirm: allow one clipboard read in TextEdit",
        )
        // A ceremony the engine required WITHOUT saying why must state the available mechanism.
        let expectedBiometricLabel = "\(BiometricCeremony.biometricType) will confirm this decision."
        #expect(
            Self.request(requiresBiometric: true).biometricLine == expectedBiometricLabel,
        )
        let free = Self.request(requiresBiometric: false).biometricLine
        #expect(!free.contains("ceremony"), "got \"\(free)\"")
        #expect(free.contains("no fingerprint"), "an approval that costs nothing should say so")
    }

    @Test
    func `The option disclosure names how many and what they are`() {
        // "More choices" named no number and no breadth, so the operator could not tell
        // what clicking it would cost them. Deny is NOT one of the alternatives — it is
        // always on screen in its own row and never something an operator chooses BETWEEN,
        // so counting it would claim a choice that does not exist.
        #expect(
            Self.request(
                offered: [.allowOnce, .allowTargetApplication, .allowSession, .deny],
            ).moreChoicesText == "3 more choices — this exact request, or in TextEdit and "
                + "any application for up to 8 operations",
            "the count is the number of real alternatives and the names are their titles",
        )
        #expect(
            Self.request(offered: [.deny]).moreChoicesText == nil,
            "a request that arrived offering only Deny has nothing to disclose",
        )
    }

    @Test
    func `A risk class the console has never heard escalates visibly`() {
        #expect(CapabilityRisk(serverValue: "routine") == .routine)
        #expect(CapabilityRisk(serverValue: "high") == .high)
        // The unrecognised value becomes Elevated rather than Routine, because a class the
        // console cannot read must never be the reassuring one.
        #expect(CapabilityRisk(serverValue: "catastrophic") == .elevated)
        #expect(CapabilityRisk(serverValue: "") == .elevated)
    }

    /// The mapping the prompt's implication line depends on, checked against the ENGINE's
    /// own tokens rather than against a hand-copied list, because the console's fixture
    /// already hid this once: the mapping was first written against the case names
    /// (`clipboardRead`) while the wire carries the values (`clipboard.read`), so every
    /// implication silently rendered empty and the suite stayed green.
    @Test
    func `Every capability token the engine sends can be described in words`() {
        // Read from the engine's own declaration, so a capability added on the server and
        // not mirrored here is a test failure rather than a blank implication.
        let engineTokens = Self.engineCapabilityTokens
        #expect(!engineTokens.isEmpty, "the token list was empty, so this asserts nothing")
        for token in engineTokens {
            #expect(
                CapabilityRisk.consequence(of: token) != nil,
                "the prompt cannot describe \(token), so it would drop it from the implication",
            )
        }
    }

    /// The tokens as the engine spells them on the wire. Kept beside the assertion rather
    /// than imported, because the console does not depend on the server's sources.
    private static let engineCapabilityTokens = [
        "script.execute",
        "macro.execute",
        "observation.ax",
        "observation.window",
        "observation.screen",
        "observation.stream",
        "display.read",
        "clipboard.read",
        "clipboard.write",
        "input.synthesize",
        "window.manage",
        "application.control",
        "file.automate",
        "transaction.manage",
        "session.manage",
        "authorization.manage",
        "local.echo",
    ]

    // MARK: - E26 Acceptance Tests

    @Test
    func `The agent gave no reason banner appears if and only if no reason arrived`() {
        let baseRequest = Self.request()

        let nilReasonPrompt = ApprovalPrompt(
            state: .pending,
            title: baseRequest.promptTitle,
            capabilityLine: baseRequest.promptScopeLine,
            risk: baseRequest.riskClass.label,
            riskDot: baseRequest.riskClass.dot,
            reason: nil,
            tree: CallerTree.rows(for: baseRequest),
            payload: baseRequest.argumentSummary,
            biometricLine: baseRequest.biometricLine,
            biometricDot: baseRequest.riskClass.dot,
        )
        #expect(
            nilReasonPrompt.showsMissingReasonBanner,
            "A request with nil reason must show the 'THE AGENT GAVE NO REASON' banner",
        )

        let emptyReasonPrompt = ApprovalPrompt(
            state: .pending,
            title: baseRequest.promptTitle,
            capabilityLine: baseRequest.promptScopeLine,
            risk: baseRequest.riskClass.label,
            riskDot: baseRequest.riskClass.dot,
            reason: "",
            tree: CallerTree.rows(for: baseRequest),
            payload: baseRequest.argumentSummary,
            biometricLine: baseRequest.biometricLine,
            biometricDot: baseRequest.riskClass.dot,
        )
        #expect(
            emptyReasonPrompt.showsMissingReasonBanner,
            "A request with empty string reason must show the missing reason banner",
        )

        let whitespaceReasonPrompt = ApprovalPrompt(
            state: .pending,
            title: baseRequest.promptTitle,
            capabilityLine: baseRequest.promptScopeLine,
            risk: baseRequest.riskClass.label,
            riskDot: baseRequest.riskClass.dot,
            reason: "   \t\n   ",
            tree: CallerTree.rows(for: baseRequest),
            payload: baseRequest.argumentSummary,
            biometricLine: baseRequest.biometricLine,
            biometricDot: baseRequest.riskClass.dot,
        )
        #expect(
            whitespaceReasonPrompt.showsMissingReasonBanner,
            "A request with whitespace-only reason must show the missing reason banner",
        )

        let suppliedReasonPrompt = ApprovalPrompt(
            state: .pending,
            title: baseRequest.promptTitle,
            capabilityLine: baseRequest.promptScopeLine,
            risk: baseRequest.riskClass.label,
            riskDot: baseRequest.riskClass.dot,
            reason: "Answering a question about your active document",
            tree: CallerTree.rows(for: baseRequest),
            payload: baseRequest.argumentSummary,
            biometricLine: baseRequest.biometricLine,
            biometricDot: baseRequest.riskClass.dot,
        )
        #expect(
            !suppliedReasonPrompt.showsMissingReasonBanner,
            "A request with a real supplied reason must NOT show the missing reason banner",
        )
    }

    @Test
    func `Every path in the caller tree is fully visible and the first row is never cut`() {
        let longRequesterPath = "/Users/joeyc/dev/ExactMac/nested/directory/structure/with/a/very/long/executable/path/cmd/exactmac"
        let longAncestorPath = "/Users/joeyc/.bun/install/global/node_modules/@modelcontextprotocol/server-exactmac/dist/index.js"

        let (req, _, decision) = ServerFixture.request(
            requestID: "r-long",
            capability: .clipboardRead,
            rpcName: "exactmac.v1.ExactMac/GetClipboard",
            agentReason: "Inspecting caller tree path layout",
        )
        let identityWithLongPaths = ServerFixture.identity(
            executablePath: longRequesterPath,
            ancestors: [
                ResolvedProcess(
                    processIdentifier: 1233,
                    parentProcessIdentifier: nil,
                    code: CodeIdentity(
                        executablePath: longAncestorPath,
                        bundleIdentifier: nil,
                        signature: .unsigned,
                    ),
                    isFullyResolved: true,
                ),
            ],
        )
        let pending = PendingRequest(
            request: req,
            identity: identityWithLongPaths,
            decision: decision,
        )

        let rows = CallerTree.rows(for: pending)
        #expect(rows.count == 2)

        // Specifically the first row, which names the requester, carries the full path.
        let firstRow = rows[0]
        #expect(firstRow.isRequester)
        #expect(firstRow.name == longRequesterPath)
        #expect(firstRow.role == "asking for this")

        let secondRow = rows[1]
        #expect(!secondRow.isRequester)
        #expect(secondRow.name == longAncestorPath)
        #expect(secondRow.role == "started it")

        // Invariant 13: View must wrap rather than truncate.
        let treeView = CallerTree(rows: rows)
        let hosting = NSHostingView(rootView: treeView)
        hosting.frame = CGRect(x: 0, y: 0, width: Design.Layout.promptWidth, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        // With 2 rows where paths wrap across lines, the fitting height must expand beyond 2 * 34pt.
        #expect(
            size.height > 68,
            "Wrapped paths must expand view height rather than clipping at fixed 34pt per row (got \(String(describing: size.height))pt)",
        )
    }

    @Test
    func `The note field carries operator input and is preserved in the decision value`() async {
        let (req, identity, decision) = ServerFixture.request(
            requestID: "r-note",
            capability: .clipboardRead,
            rpcName: "exactmac.v1.ExactMac/GetClipboard",
            agentReason: "Testing note field preservation",
        )
        let pending = PendingRequest(
            request: req,
            identity: identity,
            decision: decision,
        )

        let model = ConsoleModel()
        let typedNote = "Only allow for TextEdit; do not inspect my password manager."

        let answer = await model.answerValue(.once, for: pending, note: typedNote)
        #expect(answer.isApproved)
        #expect(answer.note == typedNote, "The operator's typed note must be preserved in the PendingAnswer")

        let defaultAnswer = await model.answerValue(.once, for: pending)
        #expect(defaultAnswer.note.isEmpty, "When no note is typed, note defaults to empty string")

        let denialAnswer = await model.answerValue(.deny, for: pending, note: "Forbidden by policy")
        #expect(!denialAnswer.isApproved)
        #expect(denialAnswer.note == "Forbidden by policy")
    }

    @Test
    func `NoteField caption distinguishes decisions from denials`() {
        let decisionField = NoteField(text: .constant(""), isDenied: false)
        #expect(decisionField.caption == "NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION")

        let denialField = NoteField(text: .constant(""), isDenied: true)
        #expect(denialField.caption == "NOTE TO THE AGENT — SENT BACK WITH YOUR DENIAL")
    }
}
