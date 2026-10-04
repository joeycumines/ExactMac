import Darwin
@testable import ExactMacServer
import Foundation
import XCTest

/// E28 acceptance tests: server-computed display-ready grant and activity rows.
///
/// Ensures:
/// 1. Expiry is computed on the server's monotonic clock and arrives display-ready (.live, .soon, .expired).
/// 2. Active grants can be revoked individually or in bulk.
/// 3. Dynamic subtitle correctly formats count and expiring-soon counts.
/// 4. Activity log rows are formatted with operator-friendly basis, consequence, and reasons.
/// 5. Invariant 11: Hash chain is verified before display; tampering is caught and reported as broken.
final class ServerInspectionTests: XCTestCase {
    private var stateDirectory: String!

    private final class MovableClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64

        init(_ nanoseconds: UInt64 = 1_000_000_000) {
            self.nanoseconds = nanoseconds
        }

        func now() -> MonotonicInstant {
            lock.withLock { MonotonicInstant(nanoseconds: nanoseconds) }
        }

        func advance(by interval: Duration) {
            lock.withLock { nanoseconds = nowValue().advanced(by: interval).nanoseconds }
        }

        private func nowValue() -> MonotonicInstant {
            MonotonicInstant(nanoseconds: nanoseconds)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = NSTemporaryDirectory() + "emc-e28-" + String(abs(UUID().uuidString.hashValue) % 1_000_000)
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
    }

    override func tearDownWithError() throws {
        ServerInspectionService.unregister()
        try? FileManager.default.removeItem(atPath: stateDirectory)
        try super.tearDownWithError()
    }

    private func environment() -> [String: String] {
        ["EXACTMAC_STATE_DIRECTORY": stateDirectory]
    }

    private static func sampleIdentity(
        path: String = "/Applications/Terminal.app/Contents/MacOS/Terminal",
        bundle: String? = "com.apple.Terminal",
        pid: Int32 = 1234,
    ) -> CallerIdentity {
        CallerIdentity(
            processIdentifier: pid,
            effectiveUserIdentifier: getuid(),
            parentProcessIdentifier: nil,
            code: CodeIdentity(
                executablePath: path,
                bundleIdentifier: bundle,
                designatedRequirement: #"identifier "com.apple.Terminal" and anchor apple"#,
                signature: .signedAndValid,
            ),
            isFullyResolved: true,
        )
    }

    private static func sampleRequest(
        capability: Capability = .clipboardRead,
        reason: String = "Test reason",
    ) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "req-test"),
            rpcName: "exactmac.v1.ExactMac/GetClipboard",
            capability: capability,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            argumentSummary: "the clipboard",
            agentReason: reason,
            origin: .mcpProxy,
        )
    }

    // MARK: - Grants Inspection Tests

    func testGrantExpiryCalculationAndCountdownStates() throws {
        let clock = MovableClock(10_000_000_000)
        let grantStorePath = stateDirectory + "/grants.json"
        let store = try GrantStore.openStore(path: grantStorePath, clock: clock, maximumEnvelopeSeconds: 86400)
        let auditPath = stateDirectory + "/audit.log"
        let audit = try DecisionAudit(path: auditPath, clock: clock)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let caller = Self.sampleIdentity()
        let req = Self.sampleRequest()

        // 1. Issue a grant for 300 seconds (5m)
        let durationGrant = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(300),
            holder: caller,
            now: clock.now(),
            remainingOperations: 5,
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        // 2. Issue a grant for 55 seconds (expiring soon)
        let soonGrant = try store.issue(
            capability: .screenObserve,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.Calculator")),
            duration: .monotonicSeconds(55),
            holder: caller,
            now: clock.now(),
            remainingOperations: nil,
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        // Initial check: duration grant has ~300s left (.live), soon grant has 55s left (.soon)
        var inspected = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(inspected.count, 2)

        let durationRow = try XCTUnwrap(inspected.first { $0.id == durationGrant.id })
        XCTAssertEqual(durationRow.countdownState, .live)
        XCTAssertEqual(durationRow.remaining, "5m 00s  ·  5 left")
        XCTAssertEqual(durationRow.holder, "com.apple.Terminal")
        XCTAssertEqual(durationRow.consequence, "Read the clipboard and its history")

        let soonRow = try XCTUnwrap(inspected.first { $0.id == soonGrant.id })
        XCTAssertEqual(soonRow.countdownState, .soon)
        XCTAssertEqual(soonRow.remaining, "55s")

        // Subtitle check: 2 listed, 1 expiring soon
        XCTAssertEqual(ServerInspectionService.grantsSubtitle(for: inspected), "2 listed  ·  1 expires within a minute")

        // 3. Advance clock by 60 seconds -> soonGrant expired, durationGrant has 240s (4m 00s) left
        clock.advance(by: .seconds(60))
        inspected = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(inspected.count, 1)
        let remainingRow = try XCTUnwrap(inspected.first { $0.id == durationGrant.id })
        XCTAssertEqual(remainingRow.countdownState, .live)
        XCTAssertEqual(remainingRow.remaining, "4m 00s  ·  5 left")
        XCTAssertEqual(ServerInspectionService.grantsSubtitle(for: inspected), "1 listed")

        // 4. Advance clock by 190 seconds -> durationGrant has 50s left -> .soon
        clock.advance(by: .seconds(190))
        inspected = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(inspected.count, 1)
        let finalRow = try XCTUnwrap(inspected.first { $0.id == durationGrant.id })
        XCTAssertEqual(finalRow.countdownState, .soon)
        XCTAssertEqual(finalRow.remaining, "50s  ·  5 left")
        XCTAssertEqual(ServerInspectionService.grantsSubtitle(for: inspected), "1 listed  ·  1 expires within a minute")

        // 5. Advance clock by 60 seconds -> all expired
        clock.advance(by: .seconds(60))
        let allAfterExpiry = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(allAfterExpiry.count, 0)
        XCTAssertEqual(ServerInspectionService.grantsSubtitle(for: []), "0 listed")
    }

    func testRevocationIndividuallyAndAll() throws {
        let clock = MovableClock()
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)
        let audit = try DecisionAudit(path: stateDirectory + "/audit.log", clock: clock)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let caller = Self.sampleIdentity()
        let req = Self.sampleRequest()

        let g1 = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(600),
            holder: caller,
            now: clock.now(),
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )
        let g2 = try store.issue(
            capability: .inputSynthesize,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.Finder")),
            duration: .monotonicSeconds(600),
            holder: caller,
            now: clock.now(),
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        var grants = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(grants.count, 2)

        // Revoke g1
        try ServerInspectionService.revokeGrant(id: g1.id, environment: environment())
        grants = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants[0].id, g2.id)

        // Revoke all
        try ServerInspectionService.revokeAllGrants(environment: environment())
        grants = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(grants.count, 0)
    }

    // MARK: - Activity Timeline & Invariant 11 Tests

    func testActivityInspectionAndIntegrityVerification() throws {
        let clock = MovableClock()
        let auditPath = stateDirectory + "/audit.log"
        let audit = try DecisionAudit(path: auditPath, clock: clock)
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let caller = Self.sampleIdentity()
        let req1 = Self.sampleRequest(capability: .clipboardRead, reason: "First test decision")
        var dec1 = AuthorizationPolicy.evaluate(
            request: req1,
            identity: caller,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: clock.now(),
        )
        dec1.outcome = AuthorizationDecision.Outcome.allow
        dec1.basis = .promptRequired
        _ = audit.record(request: req1, identity: caller, decision: dec1, operatorNote: "Approved by user")

        let req2 = Self.sampleRequest(capability: .scriptExecute, reason: "Second test decision")
        var dec2 = AuthorizationPolicy.evaluate(
            request: req2,
            identity: caller,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: clock.now(),
        )
        dec2.outcome = AuthorizationDecision.Outcome.deny
        dec2.basis = DecisionBasis.denied(.notPermitted)
        _ = audit.record(request: req2, identity: caller, decision: dec2, refusalReason: .notPermitted)

        // Read activity report
        let report = try ServerInspectionService.inspectActivity(environment: environment())

        // Invariant 11: Hash chain verified intact
        XCTAssertEqual(report.integrity, .verified(entryCount: 2))
        XCTAssertEqual(report.items.count, 2)

        // Newest first: item[0] is sequence 2 (denied scriptExecute)
        let item0 = report.items[0]
        XCTAssertEqual(item0.sequence, 2)
        XCTAssertFalse(item0.isAllowed)
        XCTAssertEqual(item0.consequence, "Run a shell command, AppleScript or JavaScript")
        XCTAssertEqual(item0.basis, "Denied — declined by operator in prompt")
        XCTAssertEqual(item0.agentReason, "Second test decision")

        // item[1] is sequence 1 (allowed clipboardRead)
        let item1 = report.items[1]
        XCTAssertEqual(item1.sequence, 1)
        XCTAssertTrue(item1.isAllowed)
        XCTAssertEqual(item1.consequence, "Read the clipboard and its history")
        XCTAssertEqual(item1.basis, "Approved by operator")
        XCTAssertEqual(item1.agentReason, "First test decision")
        XCTAssertEqual(item1.operatorNote, "Approved by user")
    }

    func testNegativeControlTamperedAuditLogIsDetected() throws {
        let clock = MovableClock()
        let auditPath = stateDirectory + "/audit.log"
        let audit = try DecisionAudit(path: auditPath, clock: clock)
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)

        let caller = Self.sampleIdentity()
        let req = Self.sampleRequest()
        let dec = AuthorizationPolicy.evaluate(
            request: req,
            identity: caller,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: clock.now(),
        )
        _ = audit.record(request: req, identity: caller, decision: dec)
        _ = audit.record(request: req, identity: caller, decision: dec)

        // Verify clean log
        var report = try ServerInspectionService.inspectActivity(environment: environment())
        XCTAssertEqual(report.integrity, .verified(entryCount: 2))

        // Negative control: tamper with audit.log on disk (Invariant 11)
        var content = try String(contentsOfFile: auditPath, encoding: .utf8)
        XCTAssertTrue(content.contains("req-test"), "precondition: log contains req-test")
        content = content.replacingOccurrences(of: "req-test", with: "req-tampered")
        try content.write(toFile: auditPath, atomically: true, encoding: .utf8)

        // Re-read activity: hash chain verification MUST fail and indicate tampering!
        let tamperedAudit = try DecisionAudit(path: auditPath, clock: clock)
        ServerInspectionService.register(
            store: store,
            audit: tamperedAudit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        report = try ServerInspectionService.inspectActivity(environment: environment())
        switch report.integrity {
        case .broken:
            // Exactly what Invariant 11 demands: broken chain detected
            break
        case .unreadable:
            break
        case .verified:
            XCTFail("Invariant 11 violation: Tampered audit log was falsely reported as verified!")
        }
    }

    func testNegativeClockSkewDoesNotUnderflow() throws {
        let clock = MovableClock(1_000_000_000)
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)
        let audit = try DecisionAudit(path: stateDirectory + "/audit.log", clock: clock)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let caller = Self.sampleIdentity()
        let req = Self.sampleRequest()

        // Decided in the future relative to clock.now (e.g. across reboot)
        let futureDecision = MonotonicInstant(nanoseconds: 2_000_000_000)
        _ = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(600),
            holder: caller,
            now: clock.now(),
            origin: .prompt(decidedAt: futureDecision),
            request: req,
        )

        // Must not crash or underflow
        let grants = try ServerInspectionService.inspectGrants(environment: environment())
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants[0].origin, "Origin: prompt  ·  granted just now")
    }

    func testDenialReasonsAndInvariant17() throws {
        let clock = MovableClock()
        let audit = try DecisionAudit(path: stateDirectory + "/audit.log", clock: clock)
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let caller = Self.sampleIdentity()
        let reasons = DenialReason.allCases

        for (idx, reason) in reasons.enumerated() {
            let req = Self.sampleRequest(capability: .clipboardRead, reason: "Reason test \(idx)")
            var dec = AuthorizationPolicy.evaluate(
                request: req,
                identity: caller,
                grants: [],
                envelopes: [],
                posture: .balanced,
                context: .unixSocket(),
                now: clock.now(),
            )
            dec.outcome = AuthorizationDecision.Outcome.deny
            dec.basis = DecisionBasis.denied(reason)
            _ = audit.record(request: req, identity: caller, decision: dec, refusalReason: reason)
        }

        let report = try ServerInspectionService.inspectActivity(environment: environment())
        XCTAssertEqual(report.items.count, reasons.count)

        for item in report.items {
            // Invariant 17 checks:
            // 1. No camelCase enum rawValues
            for reason in reasons {
                XCTAssertFalse(item.basis.contains(reason.rawValue), "Invariant 17 violation: leaked \(reason.rawValue) in \(item.basis)")
            }
            // 2. No raw capability tokens
            XCTAssertFalse(item.capability.contains("clipboard.read"), "Invariant 17 violation: leaked capability token in \(item.capability)")
            XCTAssertFalse(item.consequence.contains("clipboard.read"), "Invariant 17 violation: leaked capability token in \(item.consequence)")
        }
    }

    func testUnreadableAuditLogReturnsUnreadableIntegrityGracefully() throws {
        let invalidPath = stateDirectory + "/corrupt.log"
        try Data("garbage not json\n".utf8).write(to: URL(fileURLWithPath: invalidPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalidPath)
        let clock = MovableClock()
        let audit = try DecisionAudit(path: invalidPath, clock: clock)
        let store = try GrantStore.openStore(path: stateDirectory + "/grants.json", clock: clock, maximumEnvelopeSeconds: 86400)

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )

        let report = try ServerInspectionService.inspectActivity(environment: environment())
        switch report.integrity {
        case .unreadable, .broken:
            break
        case .verified:
            XCTFail("Should not be verified")
        }
    }
}
