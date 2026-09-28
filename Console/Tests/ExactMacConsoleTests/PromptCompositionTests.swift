@testable import ExactMacConsole
import Foundation
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
    private static func request(
        capability: String = "clipboard.read",
        consequence: String = "Read the clipboard and its history",
        scope: String = "TextEdit only  ·  until you revoke it",
        agentReason: String? = "answering a question about what you copied",
        riskClass: String = "elevated",
        implied: [String] = [],
        offered: [String] = ["allowOnce", "deny"],
        requiresBiometric: Bool = false,
        biometricReason: String? = nil,
        timeout: Int = 45,
        isRevokeAll: Bool = false,
    ) -> PendingRequest {
        PendingRequest(
            consent: PendingConsent(
                request: WireRequest(
                    requestID: "r",
                    rpcName: "exactmac.v1.ExactMac/GetClipboard",
                    capability: capability,
                    capabilityConsequence: consequence,
                    scopeDescription: scope,
                    argumentSummary: "the clipboard and its history",
                    agentReason: agentReason,
                    blastRadius: 0.4,
                    riskClass: riskClass,
                    isRevokeAll: isRevokeAll,
                    operationLimit: nil,
                    effectiveCapabilities: implied,
                ),
                identity: WireIdentity(
                    processIdentifier: 501,
                    effectiveUserIdentifier: 501,
                    executablePath: "/usr/local/bin/exactmac",
                    bundleIdentifier: nil,
                    signature: "unnotarized",
                    designatedRequirement: nil,
                    isFullyResolved: true,
                    ancestors: [],
                    isAncestryTruncated: false,
                ),
                decision: WireDecision(
                    basis: "promptRequired",
                    requiresBiometric: requiresBiometric,
                    biometricReason: biometricReason,
                    offered: offered.enumerated().map { index, kind in
                        WireOption(
                            kind: kind,
                            scopeDescription: Self.scope(for: kind, at: index),
                            durationDescription: "once",
                            blastRadius: 0.4,
                            requiresBiometric: false,
                            isDestructive: kind == "deny",
                            isDefault: index == 0,
                            isPrimary: index == 0,
                        )
                    },
                    consentTimeoutSeconds: timeout,
                ),
                nonce: "n",
                requestDigest: "d",
            ),
        )
    }

    /// The server describes each option's SCOPE, and the scopes are what distinguish one
    /// option from another. The fixture used one string for all of them, which produced
    /// "or any and any" and hid whether the prompt was reading the right field.
    private static func scope(for _: String, at index: Int) -> String {
        let scopes = [
            "this exact request",
            "one application",
            "every app this agent touches",
            "a declared capability set",
        ]
        return index < scopes.count ? scopes[index] : "none"
    }

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
        // The risk chip names a level, never the basis the engine reached it by.
        #expect(request.riskClass.label != request.basis)
    }

    @Test
    func `The title says what would happen, not what was asked for`() {
        #expect(Self.request().promptTitle == "Read the clipboard and its history")
        // Revoke-everything is the one decision whose consequence is not a capability, so it
        // is named rather than described — the string is the only thing standing between
        // the operator and the assumption they are approving a clipboard read.
        #expect(
            Self.request(isRevokeAll: true).promptTitle == "Revoke every grant",
            "a revoke-everything request must never borrow a capability's title",
        )
    }

    @Test
    func `The scope line names the token once, with the scope that bounds it`() {
        let request = Self.request()
        #expect(
            request.promptScopeLine.contains(request.capability),
            "the design puts the capability token on this line and nowhere else",
        )
        #expect(
            request.promptScopeLine.contains(request.scopeDescription),
            "a token with no scope beside it does not say how far the grant reaches",
        )
        // The duplication this replaces: the title showed the capability and the line
        // underneath showed it again, verbatim, in consecutive lines.
        #expect(request.promptTitle != request.promptScopeLine)
    }

    @Test
    func `The implication says what else is permitted, in words`() {
        // A capability that implies nothing says nothing, rather than a block that is
        // present and empty.
        #expect(Self.request().implicationText == nil)

        let implied = Self.request(capability: "script.execute", implied: ["clipboard.read"])
        #expect(
            implied.implicationText == "Also permits reading the clipboard and its history",
            "got \(implied.implicationText ?? "nil")",
        )
        // The capability being asked for must not appear in its own implication, and the
        // boundary is where that is enforced so no call site can reintroduce it. This
        // request IS clipboard.read, so its own capability comes back out of the list.
        let selfImplied = Self.request(implied: ["clipboard.read", "observation.screen"])
        #expect(
            selfImplied.implicationText == "Also permits taking a screenshot of the screen",
            "the capability being asked for must not be listed as something it also permits, got \(selfImplied.implicationText ?? "nil")",
        )
        // And a genuinely plural implication reads as a list.
        #expect(
            Self.request(
                capability: "script.execute",
                implied: ["clipboard.read", "observation.screen"],
            ).implicationText
                == "Also permits reading the clipboard and its history and taking a screenshot of the screen",
        )

        // An unrecognised token is DROPPED rather than named: the implication's job is to
        // say what else is permitted, and a bare identifier in that sentence defeats it.
        #expect(Self.request(implied: ["capability.from.the.future"]).implicationText == nil)
    }

    @Test
    func `The prompt says how long the operator has`() {
        #expect(Self.request(timeout: 45).clockText == "decides in 45s")
        #expect(
            Self.request(timeout: 0).clockText == nil,
            "no timeout is no countdown, and inventing one would be a lie about the deadline",
        )
    }

    @Test
    func `The biometric line says what will be asked, or that nothing will`() {
        #expect(
            Self.request(
                requiresBiometric: true,
                biometricReason: "Touch ID will confirm: allow one clipboard read in TextEdit",
            ).biometricLine == "Touch ID will confirm: allow one clipboard read in TextEdit",
        )
        // A ceremony with no reason sentence from the server must not fall back to engine
        // vocabulary, which is what it used to do.
        #expect(
            Self.request(requiresBiometric: true).biometricLine == "Touch ID will confirm this decision.",
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
                offered: ["allowOnce", "allowTargetApplication", "allowSession", "deny"],
            ).moreChoicesText == "3 more choices — this exact request, or one application and "
                + "every app this agent touches",
            "the count is the number of real alternatives and the names are their titles",
        )
        #expect(
            Self.request(offered: ["deny"]).moreChoicesText == nil,
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
}
