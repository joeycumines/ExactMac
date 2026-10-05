import AppKit
@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import Testing

/// Acceptance tests for Task E27:
/// "Grants and Activity are pretend buttons: two surfaces that look implemented and are wired to a string assignment"
///
/// Asserts:
/// 1. `openGrants()` and `openActivity()` read real state and open real windows.
/// 2. Neither surface writes to `pendingNotice` — opening any menu row leaves pending-request state untouched.
/// 3. No menu row action performs a bare string assignment.
/// 4. Grants displays live standing grants, computes countdown on monotonic clock, and supports revocation.
/// 5. Activity displays real decisions with hash-chain integrity verified before presentation (Invariant 11).
/// 6. Broken or unreadable logs surface as errors and NEVER as empty "No activity yet" timelines.
/// 7. Bulk revocation fails closed without an authorized biometric ceremony (Invariants 2 & 3).
/// 8. Multi-window presentation tracks window closing by instance without clobbering other open surfaces.
@Suite("Grants and Activity surfaces", .serialized)
@MainActor
struct GrantsAndActivityTests {
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

    private final class ScriptedCeremony: CeremonyPerforming {
        var outcome: BiometricCeremony.Outcome
        private(set) var reasons: [String] = []
        private(set) var nonces: [String] = []

        init(outcome: BiometricCeremony.Outcome) {
            self.outcome = outcome
        }

        func perform(nonce: String, reason: String) async -> BiometricCeremony.Outcome {
            nonces.append(nonce)
            reasons.append(reason)
            return outcome
        }
    }

    /// A model whose gate is adopted and OFF, for tests whose subject is something other
    /// than the gate: with the gate up, opening costs a ceremony, and these tests isolate
    /// pendingNotice and window tracking, not the gate. The gate's behaviour has its own
    /// suite below.
    private static func gateOffFixture() -> ConsoleModel {
        let model = ConsoleModel()
        let gate = BiometricGateSource()
        gate.setCeremonyRequired(false)
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: gate))
        return model
    }

    private static func sampleCaller(
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

    // MARK: - Decoupling from pendingNotice (Acceptance requirement)

    @Test
    func `openGrants leaves pendingNotice nil and opens grants window`() async {
        let model = Self.gateOffFixture()
        #expect(model.displayedBiometricGate == false)
        #expect(model.pendingNotice == nil)
        #expect(model.pendingPrompt == nil)
        #expect(!model.windows.isPresented(.grants))

        await model.openGrants()

        #expect(model.pendingNotice == nil, "openGrants must NEVER write to pendingNotice")
        #expect(model.pendingPrompt == nil)
        #expect(model.windows.isPresented(.grants), "openGrants must present the .grants window")
    }

    @Test
    func `openActivity leaves pendingNotice nil and opens activity window`() async {
        let model = Self.gateOffFixture()
        #expect(model.displayedBiometricGate == false)
        #expect(model.pendingNotice == nil)
        #expect(model.pendingPrompt == nil)
        #expect(!model.windows.isPresented(.activity))

        await model.openActivity()

        #expect(model.pendingNotice == nil, "openActivity must NEVER write to pendingNotice")
        #expect(model.pendingPrompt == nil)
        #expect(model.windows.isPresented(.activity), "openActivity must present the .activity window")
    }

    @Test
    func `openSettings leaves pendingNotice nil and opens settings window`() {
        let model = ConsoleModel()
        #expect(model.pendingNotice == nil)
        #expect(!model.windows.isPresented(.settings))

        model.openSettings()

        #expect(model.pendingNotice == nil, "openSettings must NEVER write to pendingNotice")
        #expect(model.windows.isPresented(.settings))
    }

    @Test
    func `no menu action performs a bare string assignment`() async {
        let model = Self.gateOffFixture()

        await model.openGrants()
        #expect(model.pendingNotice == nil)

        await model.openActivity()
        #expect(model.pendingNotice == nil)

        model.openSettings()
        #expect(model.pendingNotice == nil)
    }

    // MARK: - Multiple Window Lifecycle (Follow-Up 2)

    @Test
    func `closing one window does not untrack another`() async {
        let model = Self.gateOffFixture()
        #expect(model.displayedBiometricGate == false)

        await model.openGrants()
        await model.openActivity()

        #expect(model.windows.isPresented(.grants))
        #expect(model.windows.isPresented(.activity))

        // Close Grants
        model.windows.close(.grants)

        #expect(!model.windows.isPresented(.grants), "Grants window should be closed")
        #expect(model.windows.isPresented(.activity), "Activity window must remain presented")
    }

    // MARK: - Integrity Badge State Mapping

    @Test
    func `integrity badge maps empty verified state to nothingToVerify`() {
        let emptyState = IntegrityBadge.State(from: .verified(entryCount: 0), itemCount: 0)
        #expect(emptyState == .nothingToVerify)
        #expect(emptyState.label == "Nothing to verify")
        #expect(emptyState.dot == Design.Ink.textSecondary)
        #expect(emptyState.labelInk == Design.Ink.textPrimary)
    }

    @Test
    func `integrity badge maps populated verified state to verified`() {
        let verifiedState = IntegrityBadge.State(from: .verified(entryCount: 42), itemCount: 42)
        #expect(verifiedState == .verified(entries: 42))
        #expect(verifiedState.label == "Chain verified · 42 entries")
        #expect(verifiedState.dot == Design.Ink.success)
        #expect(verifiedState.labelInk == Design.Ink.textPrimary)
    }

    @Test
    func `integrity badge maps broken state to broken with entry sequence`() {
        let brokenState = IntegrityBadge.State(from: .broken(atSequence: 13), itemCount: 12)
        #expect(brokenState == .broken(at: 13))
        #expect(brokenState.label == "Chain broken at entry 13")
        #expect(brokenState.dot == Design.Ink.danger)
        #expect(brokenState.labelInk == Design.Ink.danger)
    }

    @Test
    func `integrity badge maps unreadable state to unchecked`() {
        let unreadableState = IntegrityBadge.State(from: .unreadable(reason: "file missing"), itemCount: 0)
        #expect(unreadableState == .unchecked)
        #expect(unreadableState.label == "Not verified")
        #expect(unreadableState.dot == Design.Ink.textSecondary)
    }

    // MARK: - Signature Mapping for Unnotarized and AdHoc (Follow-Up 3)

    @Test
    func `signature mapping correctly preserves signedUnnotarized and adHoc`() {
        #expect(SignatureBadge.State(serverValue: "signedAndValid") == .signed)
        #expect(SignatureBadge.State(serverValue: "signedUnnotarized") == .unnotarized)
        #expect(SignatureBadge.State(serverValue: "adHoc") == .adHoc)
        #expect(SignatureBadge.State(serverValue: "unsigned") == .unsigned)
        #expect(SignatureBadge.State(serverValue: "invalid") == .invalid)
        #expect(SignatureBadge.State(serverValue: "unknown") == .unresolved)
    }

    // MARK: - Live Server Inspection and Revocation

    @Test
    func `live inspection formats grants and activity correctly`() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactMacE27Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MovableClock(10_000_000_000)
        let storePath = tempDir.appendingPathComponent("grants.json").path
        let auditPath = tempDir.appendingPathComponent("audit.log").path

        let store = try GrantStore.openStore(path: storePath, clock: clock, maximumEnvelopeSeconds: 86400)
        let audit = try DecisionAudit(path: auditPath, clock: clock)

        let caller = Self.sampleCaller()
        let req = Self.sampleRequest()

        // 1. Issue a standing grant for 300 seconds (5m)
        let grant = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(300),
            holder: caller,
            now: clock.now(),
            remainingOperations: 5,
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        // 2. Record an allowed decision in the audit log
        var decision = AuthorizationPolicy.evaluate(
            request: req,
            identity: caller,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: clock.now(),
        )
        decision.outcome = .allow
        decision.basis = .promptRequired
        _ = audit.record(request: req, identity: caller, decision: decision, operatorNote: "Approved by operator")

        // Register in inspection service
        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: tempDir.path,
        )
        defer { ServerInspectionService.unregister() }

        // Test inspectGrants
        let env = ["EXACTMAC_STATE_DIRECTORY": tempDir.path]
        let displayGrants = try ServerInspectionService.inspectGrants(environment: env)
        #expect(displayGrants.count == 1)
        let firstGrant = displayGrants[0]
        #expect(firstGrant.id == grant.id)
        #expect(firstGrant.capability == "clipboard.read")
        #expect(firstGrant.countdownState == .live)
        #expect(firstGrant.remaining == "5m 00s  ·  5 left")
        #expect(firstGrant.consequence == "Read the clipboard and its history")

        // Test Model conversion
        let rowModel = GrantRow.Model(from: firstGrant)
        #expect(rowModel.id == firstGrant.id)
        #expect(rowModel.consequence == firstGrant.consequence)
        #expect(rowModel.remaining == "5m 00s  ·  5 left")
        #expect(rowModel.signature == .signed)

        // Test inspectActivity
        let activityReport = try ServerInspectionService.inspectActivity(environment: env)
        #expect(activityReport.items.count == 1)
        #expect(activityReport.integrity == .verified(entryCount: 1))
        let firstActivity = activityReport.items[0]
        #expect(firstActivity.isAllowed == true)
        #expect(firstActivity.capability == "com.apple.TextEdit")
        #expect(firstActivity.agentReason == "Test reason")

        let activityModel = ActivityRow.Model(from: firstActivity)
        #expect(activityModel.id == firstActivity.id)
        #expect(activityModel.isAllowed == true)
        #expect(activityModel.signature == .signed)

        // Test single revocation through ConsoleModel. The gate is adopted and OFF —
        // this test's subject is inspection formatting, not the gate.
        let model = Self.gateOffFixture()
        await model.openGrants()
        #expect(model.windows.isPresented(.grants))

        model.revokeGrant(id: grant.id)
        let remainingGrants = try ServerInspectionService.inspectGrants(environment: env)
        #expect(remainingGrants.isEmpty)
    }

    // MARK: - Unreadable Log Does Not Show Empty Timeline (Blocking Fix 1)

    @Test
    func `unreadable log surfaces as unreadable and never claims nothing recorded`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactMacUnreadableLogTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MovableClock(10_000_000_000)
        let storePath = tempDir.appendingPathComponent("grants.json").path
        let auditPath = tempDir.appendingPathComponent("audit.log").path

        let store = try GrantStore.openStore(path: storePath, clock: clock, maximumEnvelopeSeconds: 86400)

        // Write corrupt garbage into audit log
        try "corrupted undecodable line without proper JSON format\n".write(
            toFile: auditPath,
            atomically: true,
            encoding: .utf8,
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditPath)

        try ServerInspectionService.register(
            store: store,
            audit: DecisionAudit(path: auditPath, clock: clock),
            clock: clock,
            stateDirectory: tempDir.path,
        )
        defer { ServerInspectionService.unregister() }

        let env = ["EXACTMAC_STATE_DIRECTORY": tempDir.path]
        let report = try ServerInspectionService.inspectActivity(environment: env)

        // Must report unreadable, NOT verified(0)
        guard case .unreadable = report.integrity else {
            Issue.record("Expected integrity to be .unreadable for corrupted log, got: \(report.integrity)")
            return
        }

        // Test that IntegrityBadge maps unreadable to unchecked, NOT nothingToVerify
        let badge = IntegrityBadge.State(from: report.integrity, itemCount: report.items.count)
        #expect(badge == .unchecked)
        #expect(badge.label == "Not verified")
    }

    // MARK: - Bulk Revocation Biometric Enforcement (Follow-Up 4)

    @Test
    func `revokeAllGrants fails closed without ceremony`() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactMacRevokeAllNilTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MovableClock(10_000_000_000)
        let storePath = tempDir.appendingPathComponent("grants.json").path
        let auditPath = tempDir.appendingPathComponent("audit.log").path

        let store = try GrantStore.openStore(path: storePath, clock: clock, maximumEnvelopeSeconds: 86400)
        let audit = try DecisionAudit(path: auditPath, clock: clock)

        let caller = Self.sampleCaller()
        let req = Self.sampleRequest()

        _ = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(300),
            holder: caller,
            now: clock.now(),
            remainingOperations: 5,
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: tempDir.path,
        )
        defer { ServerInspectionService.unregister() }

        // Model with NO ceremony installed
        let model = ConsoleModel(ceremony: nil)
        await model.performRevokeAllGrants()

        // Grants must NOT be revoked — fails closed!
        let grantsAfter = try ServerInspectionService.inspectGrants(environment: ["EXACTMAC_STATE_DIRECTORY": tempDir.path])
        #expect(grantsAfter.count == 1, "Must fail closed and NOT revoke when ceremony is missing")
    }

    @Test
    func `revokeAllGrants succeeds when biometric ceremony is performed`() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExactMacRevokeAllSuccessTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clock = MovableClock(10_000_000_000)
        let storePath = tempDir.appendingPathComponent("grants.json").path
        let auditPath = tempDir.appendingPathComponent("audit.log").path

        let store = try GrantStore.openStore(path: storePath, clock: clock, maximumEnvelopeSeconds: 86400)
        let audit = try DecisionAudit(path: auditPath, clock: clock)

        let caller = Self.sampleCaller()
        let req = Self.sampleRequest()

        _ = try store.issue(
            capability: .clipboardRead,
            scope: AuthorizationScope(application: .bundleIdentifier("com.apple.TextEdit")),
            duration: .monotonicSeconds(300),
            holder: caller,
            now: clock.now(),
            remainingOperations: 5,
            origin: .prompt(decidedAt: clock.now()),
            request: req,
        )

        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: tempDir.path,
        )
        defer { ServerInspectionService.unregister() }

        // Scripted ceremony that successfully performs Touch ID
        let ceremony = ConsoleDecisionTests.ScriptedCeremony(.performed)

        let model = ConsoleModel(ceremony: ceremony)
        await model.performRevokeAllGrants()

        let grantsAfter = try ServerInspectionService.inspectGrants(environment: ["EXACTMAC_STATE_DIRECTORY": tempDir.path])
        #expect(grantsAfter.isEmpty, "Grants must be revoked when ceremony succeeds")
        #expect(ceremony.nonces.count == 1)
        #expect(ceremony.reasons.first == "ExactMac asks to revoke every grant at once")
    }
}
