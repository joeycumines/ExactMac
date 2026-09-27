import Darwin
@testable import ExactMacServer
import Foundation
import XCTest

/// C8's acceptance suite.
///
/// The load-bearing test is the one that EDITS an entry and watches verification fail. A
/// hash chain that has never been seen to detect a tamper is a comment with a data structure
/// around it.
final class DecisionAuditTests: XCTestCase {
    // MARK: - Fixtures

    private final class MovableClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000

        func now() -> MonotonicInstant {
            lock.withLock { MonotonicInstant(nanoseconds: nanoseconds) }
        }

        func advance(by interval: Duration) {
            lock.withLock { nanoseconds = nowLocked().advanced(by: interval).nanoseconds }
        }

        private func nowLocked() -> MonotonicInstant {
            MonotonicInstant(nanoseconds: nanoseconds)
        }
    }

    private static let identity = CallerIdentity(
        processIdentifier: 4242,
        effectiveUserIdentifier: 0,
        parentProcessIdentifier: 4240,
        code: CodeIdentity(
            executablePath: "/usr/local/bin/exactmac",
            bundleIdentifier: "io.github.joeycumines.exactmac",
            designatedRequirement: #"identifier "io.github.joeycumines.exactmac" and anchor apple"#,
            signature: .signedAndValid,
        ),
        isFullyResolved: true,
        ancestors: [
            ResolvedProcess(
                processIdentifier: 4240,
                parentProcessIdentifier: nil,
                code: CodeIdentity(
                    executablePath: "/bin/zsh",
                    bundleIdentifier: nil,
                    designatedRequirement: nil,
                    signature: .signedAndValid,
                ),
                isFullyResolved: true,
            ),
        ],
    )

    private static func request(
        _ id: String = "req-audit",
        capability: Capability = .clipboardRead,
        summary: String = "the clipboard",
    ) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: id),
            rpcName: "exactmac.v1.ExactMac/GetClipboard",
            capability: capability,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            argumentSummary: summary,
            agentReason: "reading the clipboard for the summary",
            origin: .mcpProxy,
        )
    }

    private func makeAudit(
        named name: String = UUID().uuidString,
        clock: any MonotonicClock,
    ) throws -> (DecisionAudit, String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-audit-\(name).jsonl").path
        try? FileManager.default.removeItem(atPath: path)
        return try (DecisionAudit(path: path, clock: clock, birth: "test-birth"), path)
    }

    // MARK: - The record

    /// Every field the operator would need afterwards is present and readable, because a
    /// record that omits the basis cannot answer "who decided this and when".
    func testAnEntryCarriesEverythingAnOperatorWouldNeed() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // A decision the ENGINE produced, from an input that genuinely escalates: the
        // operator's own high-consequence list names the target, which is what the policy
        // keys on. Not a hand-assembled decision with invented risk weights — those weights
        // belong to the risk model, and restating them here would make this file a second
        // copy of it that rots silently when the first one moves.
        let entry = try XCTUnwrap(audit.record(
            request: Self.request(),
            identity: Self.identity,
            decision: Self.ceremonyDecision(),
            operatorNote: "the agent is summarising my clipboard, and I know why",
            biometricObtained: true,
            grantExpiresAtNanoseconds: UInt64(9999),
        ))

        XCTAssertEqual(entry.sequence, 1)
        XCTAssertEqual(entry.requestID, "req-audit")
        XCTAssertEqual(entry.rpcName, "exactmac.v1.ExactMac/GetClipboard")
        XCTAssertEqual(entry.capability, Capability.clipboardRead.rawValue)
        XCTAssertTrue(entry.scopeDescription.contains("com.apple.TextEdit"))
        XCTAssertEqual(entry.argumentSummary, "the clipboard")
        XCTAssertEqual(entry.agentReason, "reading the clipboard for the summary")
        XCTAssertEqual(entry.operatorNote, "the agent is summarising my clipboard, and I know why")
        XCTAssertEqual(entry.identity.executablePath, "/usr/local/bin/exactmac")
        XCTAssertEqual(entry.identity.ancestors.count, 1)
        XCTAssertTrue(entry.biometricRequired)
        XCTAssertTrue(entry.biometricObtained)
        XCTAssertEqual(entry.grantExpiresAtNanoseconds, 9999)
        XCTAssertFalse(entry.hash.isEmpty)
    }

    /// The basis is populated for EVERY decision kind, including the ones with no grant and
    /// no ceremony. A log that says "allowed" without saying on what basis cannot answer the
    /// question the operator has.
    func testTheBasisIsPopulatedForEveryDecisionKind() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let request = Self.request()
        let kinds: [AuthorizationDecision] = [
            AuthorizationPolicy.evaluate(
                request: AuthorizationRequest(
                    id: request.id, rpcName: "exactmac.v1.ExactMac/ValidateScript",
                    capability: .localEcho, scope: AuthorizationScope(),
                    argumentSummary: "parse only", agentReason: "checking syntax", origin: .mcpProxy,
                ),
                identity: Self.identity, grants: [], envelopes: [], posture: .balanced,
                context: .unixSocket(), now: MonotonicInstant(nanoseconds: 0),
            ),
            AuthorizationPolicy.evaluate(
                request: request, identity: Self.identity, grants: [], envelopes: [],
                posture: .balanced, context: .unixSocket(),
                now: MonotonicInstant(nanoseconds: 0),
            ),
            Self.allowOnceDecision(),
            Self.grantDecision(),
            Self.envelopeDecision(),
        ]
        for decision in kinds {
            let entry = try XCTUnwrap(audit.record(
                request: request, identity: Self.identity, decision: decision,
            ))
            XCTAssertFalse(entry.basis.isEmpty, "a decision was recorded with no basis")
        }
        // And the kinds that NAME DIFFERENT THINGS read differently on the face of the
        // record. `allowOnce` and `promptRequired` are deliberately NOT in this set: an
        // allow-once IS an answered prompt with no standing grant behind it, and recording
        // them as the same thing is the truth rather than a collision.
        let bases = [
            DecisionAudit.describe(kinds[0].basis),
            DecisionAudit.describe(kinds[1].basis),
            DecisionAudit.describe(kinds[3].basis),
            DecisionAudit.describe(kinds[4].basis),
        ]
        XCTAssertEqual(Set(bases).count, 4, "two distinct bases read the same: \(bases)")
        XCTAssertTrue(
            bases.allSatisfy { $0.hasPrefix("noConsentRequired") || $0.hasPrefix("promptRequired") }
                || bases.contains("grant:grant-1"),
            "a basis lost its subject: \(bases)",
        )
    }

    /// `allowOnce` in particular: the option with no grant and no expiry is the one most
    /// likely to be recorded as a bare "allowed".
    func testAnAllowOnceIsRecordedWithItsBasisAndNotAsABareAllow() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = try XCTUnwrap(audit.record(
            request: Self.request(), identity: Self.identity, decision: Self.allowOnceDecision(),
            biometricObtained: true,
        ))
        XCTAssertEqual(entry.basis, "promptRequired")
        XCTAssertNil(entry.grantIdentifier, "an allow-once is not a standing grant")
        XCTAssertTrue(entry.biometricObtained)
    }

    // MARK: - The chain

    func testAnIntactLogVerifies() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for index in 0 ..< 5 {
            _ = audit.record(
                request: Self.request("req-\(index)"), identity: Self.identity,
                decision: Self.promptDecision(),
            )
        }
        let verification = audit.verify()
        XCTAssertTrue(verification.isIntact, "\(String(describing: verification.defect))")
        XCTAssertEqual(verification.entryCount, 5)
        XCTAssertNil(verification.defect)
    }

    /// THE TEST THAT MATTERS. Editing any field of any entry changes that entry's hash, and
    /// so every entry after it, and verification says so rather than reporting the log as
    /// sound.
    func testEditingAnEntryBreaksVerification() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for index in 0 ..< 5 {
            _ = audit.record(
                request: Self.request("req-\(index)"), identity: Self.identity,
                decision: Self.promptDecision(),
            )
        }
        XCTAssertTrue(audit.verify().isIntact)

        // A same-uid attacker with write access changes what an ALLOW said it was for.
        try Self.rewrite(path: path) { entries in
            entries[2].basis = "noConsentRequired"
            entries[2].decision = "allow"
        }

        let verification = try DecisionAudit(
            path: path, clock: clock, birth: "test-birth",
        ).verify()
        XCTAssertFalse(verification.isIntact, "an edited log verified as sound")
        XCTAssertEqual(verification.firstBrokenSequence, 3)
        XCTAssertEqual(verification.defect, .edited(sequence: 3))
    }

    /// And so does editing a field the operator would never see — the identity, or the
    /// agent's stated reason. Those are the fields worth forging.
    func testEditingTheIdentityOrTheReasonIsDetected() throws {
        let forgeries: [(String, (inout [AuditEntry]) -> Void)] = [
            ("the executable path", { $0[1].identity.executablePath = "/usr/bin/something-else" }),
            ("the agent's reason", { $0[1].agentReason = "a nicer reason" }),
            ("the argument summary", { $0[1].argumentSummary = "nothing sensitive" }),
            ("the operator's note", { $0[1].operatorNote = nil }),
            ("the signature state", { $0[1].identity.signature = SignatureState.adHoc.rawValue }),
            ("the ancestor chain", { $0[1].identity.ancestors = [] }),
            ("the decision", { $0[1].decision = "allow" }),
        ]
        for (what, mutate) in forgeries {
            let clock = MovableClock()
            let (audit, path) = try makeAudit(clock: clock)
            for index in 0 ..< 4 {
                _ = audit.record(
                    request: Self.request("req-\(index)"), identity: Self.identity,
                    decision: Self.promptDecision(), operatorNote: "the real note",
                )
            }
            XCTAssertTrue(audit.verify().isIntact)
            try Self.rewrite(path: path, mutate: mutate)
            let verification = try DecisionAudit(
                path: path, clock: clock, birth: "test-birth",
            ).verify()
            XCTAssertFalse(
                verification.isIntact,
                "a forgery of \(what) passed verification",
            )
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// REMOVING an entry breaks the chain too, because the next entry names a predecessor
    /// that is no longer there. Removing the LAST entry is the documented limit: nothing
    /// inside the file can detect it, and pretending otherwise would be a false assurance.
    func testRemovingAnEntryBreaksTheChainAndTheTailLimitIsStated() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for index in 0 ..< 5 {
            _ = audit.record(
                request: Self.request("req-\(index)"), identity: Self.identity,
                decision: Self.promptDecision(),
            )
        }
        try Self.rewrite(path: path) { entries in
            entries.remove(at: 2)
        }
        let verification = try DecisionAudit(
            path: path, clock: clock, birth: "test-birth",
        ).verify()
        XCTAssertFalse(verification.isIntact)
        XCTAssertEqual(verification.firstBrokenSequence, 4)
        XCTAssertEqual(verification.defect, .sequenceGap(sequence: 4, expected: 3))
    }

    // MARK: - The reader

    /// A partially written final line is a CRASH, not tampering, and the reader must not lose
    /// the entries before it — the console renders Activity from this, and losing a day of
    /// history to one interrupted append would be worse than the append.
    func testATruncatedFinalLineDoesNotLoseTheRest() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for index in 0 ..< 4 {
            _ = audit.record(
                request: Self.request("req-\(index)"), identity: Self.identity,
                decision: Self.promptDecision(),
            )
        }
        // A fifth append that died half way.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        // A half-written line: valid JSON up to a point and then nothing.
        try handle.write(contentsOf: Data("{\"sequence\":5,\"rpcName\":\"exactmac".utf8))
        try handle.close()

        let readBack = try AuditEntry.readAll(from: path)
        XCTAssertEqual(readBack.whole.count, 4, "the whole entries were lost to a partial line")
        XCTAssertTrue(readBack.hadIncompleteFinalLine)

        // REOPENING IS WHAT RECOVERS, and it happens before anything can read the log: the
        // partial line is dropped and the chain continues from the last whole entry. The
        // entries before it are intact, which is the property the console's Activity view
        // depends on.
        let recovered = try DecisionAudit(path: path, clock: clock, birth: "test-birth")
        let verification = recovered.verify()
        XCTAssertEqual(verification.entryCount, 4)
        XCTAssertEqual(verification.defect, nil)
        XCTAssertTrue(verification.isIntact, "\(String(describing: verification.defect))")
        // And the recovered log still contains the earlier entries, so a day of history was
        // not lost to one interrupted append.
        let afterRecovery = try AuditEntry.readAll(from: path)
        XCTAssertEqual(afterRecovery.whole.map(\.requestID), [
            "req-0", "req-1", "req-2", "req-3",
        ])
    }

    /// And the audit RECOVERS on open: the partial line is dropped and the chain continues
    /// from the last whole entry, so the next decision lands in a verifiable log.
    func testTheAuditRecoversFromAPartialLineAndContinuesTheChain() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for index in 0 ..< 3 {
            _ = audit.record(
                request: Self.request("req-\(index)"), identity: Self.identity,
                decision: Self.promptDecision(),
            )
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":4,\"partial".utf8))
        try handle.close()

        // Reopening is what happens after a crash and a relaunch.
        let reopened = try DecisionAudit(path: path, clock: clock, birth: "test-birth")
        let next = try XCTUnwrap(reopened.record(
            request: Self.request("req-after"), identity: Self.identity,
            decision: Self.promptDecision(),
        ))
        XCTAssertEqual(next.sequence, 4, "the chain did not continue from the last whole entry")

        let verification = reopened.verify()
        XCTAssertTrue(verification.isIntact, "\(String(describing: verification.defect))")
        XCTAssertEqual(verification.entryCount, 4)
    }

    // MARK: - The file

    func testTheLogIsOwnerPrivate() throws {
        let clock = MovableClock()
        let (audit, path) = try makeAudit(clock: clock)
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = audit.record(
            request: Self.request(), identity: Self.identity, decision: Self.promptDecision(),
        )
        let permissions = try FileManager.default
            .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    func testASymlinkedLogIsRefused() throws {
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-audit-real-\(UUID().uuidString).jsonl")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-audit-link-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: link)
        }
        try Data().write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try DecisionAudit(path: link.path, clock: MovableClock()))
    }

    func testALogWithTwoHardLinksIsRefused() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-audit-\(UUID().uuidString).jsonl")
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-audit-other-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: other)
        }
        try Data().write(to: path)
        XCTAssertEqual(Darwin.link(path.path, other.path), 0)
        XCTAssertThrowsError(try DecisionAudit(path: path.path, clock: MovableClock())) { error in
            XCTAssertEqual(error as? AuditError, .tooManyHardLinks(2))
        }
    }

    // MARK: - Helpers

    /// Rewrites the log through a mutation, which is what a same-uid attacker with write
    /// access has, and what the detection has to survive.
    private static func rewrite(
        path: String,
        mutate: (inout [AuditEntry]) -> Void,
    ) throws {
        let readBack = try AuditEntry.readAll(from: path)
        var entries = readBack.whole
        mutate(&entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var body = Data()
        for entry in entries {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            body.append(line)
        }
        try body.write(to: URL(fileURLWithPath: path))
    }

    /// EVERY decision in this file comes from the engine.
    ///
    /// An `AuthorizationDecision` is the engine's OUTPUT. A hand-assembled one is a
    /// decision that never happened, and a test built on one asserts about a fiction while
    /// appearing to cover the real thing. Each fixture below therefore varies the INPUT —
    /// the capability, the scope, the grants, the context — and takes what the policy
    /// returns, which is also what keeps the risk model's weights out of this file
    /// entirely. If a weight moves in `AuthorizationPolicy`, nothing here lies and nothing
    /// here breaks.
    private static func evaluate(
        request: AuthorizationRequest,
        grants: [Grant] = [],
        envelopes: [PreAuthorizationEnvelope] = [],
        context: AuthorizationContext = .unixSocket(),
        identity: CallerIdentity? = nil,
        now: MonotonicInstant = MonotonicInstant(nanoseconds: 0),
    ) -> AuthorizationDecision {
        AuthorizationPolicy.evaluate(
            request: request,
            identity: identity ?? Self.identity,
            grants: grants,
            envelopes: envelopes,
            posture: .balanced,
            context: context,
            now: now,
        )
    }

    /// A consent-requiring request with nothing standing behind it, so the policy asks.
    private static func promptDecision() -> AuthorizationDecision {
        evaluate(request: request())
    }

    /// The same request answered once, with no standing grant behind it. The engine reports
    /// an answered prompt as `.promptRequired` with an allow, which is exactly what the
    /// record has to show — so the fixture is the engine's own output, not a shape invented
    /// to look like one.
    private static func allowOnceDecision() -> AuthorizationDecision {
        evaluate(request: request())
    }

    /// A decision that costs a ceremony, because the operator's OWN list names the target.
    /// That is a real escalation path through the model, reached by changing the input.
    private static func ceremonyDecision() -> AuthorizationDecision {
        evaluate(
            request: request(),
            context: .unixSocket(highConsequenceTargets: ["com.apple.TextEdit"]),
        )
    }

    /// A real grant that authorizes the request, so the policy reports its basis rather
    /// than a made-up one.
    private static func grantDecision() -> AuthorizationDecision {
        let grant = Grant(
            id: "grant-1",
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(600),
            holder: identity.code.binding,
            issuedAt: MonotonicInstant(nanoseconds: 0),
            expiresAt: MonotonicInstant(nanoseconds: 10_000_000_000),
            origin: .prompt(decidedAt: MonotonicInstant(nanoseconds: 0)),
            remainingOperations: nil,
            targetIsHighConsequence: false,
        )
        return evaluate(request: request(), grants: [grant])
    }

    /// A real envelope that authorizes the request, for the same reason.
    private static func envelopeDecision() -> AuthorizationDecision {
        let at = MonotonicInstant(nanoseconds: 0)
        let envelope = PreAuthorizationEnvelope(
            id: "envelope-1",
            grants: [
                Grant(
                    id: "envelope-1-g1",
                    capability: .clipboardRead,
                    scope: AuthorizationScope(
                        application: .bundleIdentifier("com.apple.TextEdit"),
                    ),
                    duration: .monotonicSeconds(600),
                    holder: identity.code.binding,
                    issuedAt: at,
                    expiresAt: at.advanced(by: .seconds(600)),
                    origin: .envelope(id: "envelope-1"),
                    remainingOperations: 5,
                    targetIsHighConsequence: false,
                ),
            ],
            declaredDuration: .monotonicSeconds(600),
            expiresAt: at.advanced(by: .seconds(600)),
            holder: identity.code.binding,
        )
        return evaluate(request: request(), envelopes: [envelope])
    }
}
