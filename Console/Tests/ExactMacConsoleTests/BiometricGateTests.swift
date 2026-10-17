import AppKit
@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import Testing

/// E22's acceptance, as behaviour on the console side.
///
/// THE ORDER IS THE ACCEPTANCE: a toggle click performs the ceremony FIRST (in both
/// directions — disabling is the downgrade and re-enabling is a change to what the
/// ceremony protects), then records the attempt to the decision log, then applies — and
/// an attempt whose record did not land applies NOTHING. The state is the server's, not
/// @State, so it survives a relaunch, and the row cannot contradict the four locked
/// capability rows because it governs a different thing (reading what is permitted) and
/// says so.
@Suite("The biometric gate", .serialized)
@MainActor
struct BiometricGateTests {
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

    /// A fresh temporary state directory, so neither the audit nor the gate file touches
    /// the operator's real state.
    private static func temporaryStateDirectory() -> String {
        let directory = NSTemporaryDirectory() + "exactmac-gate-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A model whose state directory has a LIVE, REGISTERED audit — what the model's
    /// write path needs for `recordOperatorAction` to take, because the registered live
    /// audit is the only audit it writes through. Registration is torn down after each
    /// use by `unregisterRegisteredAudit`.
    private static func makeModel(
        ceremony: (any CeremonyPerforming)?,
        stateDirectory: String,
    ) throws -> ConsoleModel {
        try registerLiveAudit(stateDirectory: stateDirectory)
        return ConsoleModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            stateEnvironment: ["EXACTMAC_STATE_DIRECTORY": stateDirectory],
        )
    }

    private static func registerLiveAudit(stateDirectory: String) throws {
        try FileManager.default.createDirectory(
            atPath: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let clock = SystemMonotonicClock()
        let audit = try DecisionAudit(path: stateDirectory + "/audit.log", clock: clock)
        let store = GrantStore(
            clock: clock,
            maximumEnvelopeSeconds: 86400,
        )
        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )
    }

    private static func unregisterRegisteredAudit() {
        ServerInspectionService.unregister()
    }

    // MARK: The toggle flow

    @Test
    func `disabling the gate costs a ceremony, records the change, and applies it`() async throws {
        let stateDirectory = Self.temporaryStateDirectory()
        let ceremony = ScriptedCeremony(outcome: .performed)
        let model = try Self.makeModel(ceremony: ceremony, stateDirectory: stateDirectory)
        defer { Self.unregisterRegisteredAudit() }
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))
        #expect(model.displayedBiometricGate == true, "the default is the ceremony")

        // THE FLOW IS DRIVEN AS AN AWAITED VALUE, not polled: `setBiometricGate` is the
        // row's fire-and-forget entry, and this is the same flow awaited so the
        // assertions are deterministic.
        await model.performBiometricGateChange(false)
        #expect(!model.displayedBiometricGate)

        #expect(ceremony.nonces.count == 1, "exactly one ceremony for exactly one toggle")
        #expect(ceremony.reasons.first?.contains("Grants and Activity") == true)
        #expect(model.displayedBiometricGate == false)

        // THE RECORD IS ON THE LOG, and it names the downgrade as an allow with the
        // ceremony on the record.
        let entries = try AuditEntry.readAll(from: stateDirectory + "/audit.log").whole
        let entry = try #require(entries.last)
        #expect(entry.decision == "allow")
        #expect(entry.biometricObtained == true)
        #expect(entry.argumentSummary.contains("turned off"))
    }

    @Test
    func `re-enabling the gate also costs a ceremony`() async throws {
        let stateDirectory = Self.temporaryStateDirectory()
        let ceremony = ScriptedCeremony(outcome: .performed)
        let model = try Self.makeModel(ceremony: ceremony, stateDirectory: stateDirectory)
        defer { Self.unregisterRegisteredAudit() }
        let gate = BiometricGateSource()
        gate.setCeremonyRequired(false)
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: gate))
        #expect(model.displayedBiometricGate == false)

        await model.performBiometricGateChange(true)

        #expect(ceremony.nonces.count == 1, "re-enabling is also a change to what the ceremony protects")
        #expect(ceremony.reasons.first?.contains("require Touch ID again") == true)
        #expect(model.displayedBiometricGate == true)
    }

    @Test
    func `a failed ceremony records the refusal and changes nothing`() async throws {
        let stateDirectory = Self.temporaryStateDirectory()
        let ceremony = ScriptedCeremony(outcome: .unavailable(.hardwareUnavailable))
        let model = try Self.makeModel(ceremony: ceremony, stateDirectory: stateDirectory)
        defer { Self.unregisterRegisteredAudit() }
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))

        await model.performBiometricGateChange(false)

        #expect(model.displayedBiometricGate == true, "a failed ceremony must not apply the downgrade")

        // THE ATTEMPT IS ON THE LOG even though nothing changed.
        let entries = try AuditEntry.readAll(from: stateDirectory + "/audit.log").whole
        let entry = try #require(entries.last)
        #expect(entry.decision == "deny")
        #expect(entry.refusalReason == "biometricUnavailable")
        #expect(entry.biometricObtained == false)
    }

    @Test
    func `a change the log cannot record is not applied`() async throws {
        // THE UNRECORDABLE SHAPE: the ceremony succeeds, but the registered audit is
        // GONE by the time the write happens — the shape of a host whose runtime was
        // torn down under the console. The model must refuse to apply the downgrade.
        let stateDirectory = Self.temporaryStateDirectory()
        let ceremony = ScriptedCeremony(outcome: .performed)
        let model = try Self.makeModel(ceremony: ceremony, stateDirectory: stateDirectory)
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))

        ServerInspectionService.unregister()
        await model.performBiometricGateChange(false)

        #expect(
            model.displayedBiometricGate == true,
            "an unrecordable downgrade is not applied — unrecordable means unapplied",
        )
        #expect(
            model.pendingNotice?.contains("not changed") == true,
            "the operator is told the change did not happen, not left to assume it did",
        )
    }

    // MARK: The gate survives a relaunch

    @Test
    func `the gate state survives the preference store round trip a relaunch performs`() throws {
        let store = InMemoryPreferencesStore()
        let gate = BiometricGateSource(store: store)
        gate.setCeremonyRequired(false)
        try gate.persist()

        // A "relaunch" is a fresh source reading the same store.
        #expect(
            BiometricGateSource.loadStoredGate(store: store) == false,
            "the operator's choice is in PreferencesStore, not in @State",
        )
    }

    // MARK: The gated opens

    @Test
    func `a gated open performs the ceremony and opens nothing when it fails`() async {
        let ceremony = ScriptedCeremony(outcome: .unavailable(.hardwareUnavailable))
        let model = ConsoleModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            stateEnvironment: ["EXACTMAC_STATE_DIRECTORY": Self.temporaryStateDirectory()],
        )
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))
        #expect(model.displayedBiometricGate == true)

        await model.openGrants()

        #expect(ceremony.nonces.count == 1)
        #expect(!model.windows.isPresented(.grants), "a refused gate opens nothing")
        #expect(model.pendingNotice == nil, "the refusal is not a consent-prompt event")
    }

    @Test
    func `a gated open that passes the ceremony opens the surface`() async {
        let ceremony = ScriptedCeremony(outcome: .performed)
        let model = ConsoleModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            stateEnvironment: ["EXACTMAC_STATE_DIRECTORY": Self.temporaryStateDirectory()],
        )
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))

        await model.openActivity()

        #expect(ceremony.nonces.count == 1)
        #expect(model.windows.isPresented(.activity))
    }

    @Test
    func `with the gate off, opens cost no ceremony`() async {
        let ceremony = ScriptedCeremony(outcome: .performed)
        let model = ConsoleModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            stateEnvironment: ["EXACTMAC_STATE_DIRECTORY": Self.temporaryStateDirectory()],
        )
        let gate = BiometricGateSource()
        gate.setCeremonyRequired(false)
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: gate))

        await model.openGrants()

        #expect(ceremony.nonces.isEmpty, "the operator spent friction to turn this off; it stays off")
        #expect(model.windows.isPresented(.grants))
    }

    // MARK: Operable Touch ID rules

    @Test
    func `the settings window displays the gate and operable touch id rules`() {
        let model = makeTestConsoleModel()
        model.adoptBiometricGateHandle(HostedBiometricGateHandle(source: BiometricGateSource()))
        let window = SettingsWindow(model: model)
        _ = window

        #expect(model.displayedBiometricGate == true)
        #expect(model.touchIDRules.scriptsAndTerminal == true)
        #expect(model.touchIDRules.broadApprovals == true)
        #expect(model.touchIDRules.unsignedCallers == true)
        #expect(model.touchIDRules.consoleOpen == true)
    }

    // MARK: Non-strict stored posture Touch ID confirmation

    @Test
    func `unconfirmed stored non-strict posture requires Touch ID confirmation and activates upon ceremony`() async {
        let store = InMemoryPreferencesStore(strings: [PostureSource.preferenceKey: Posture.balanced.rawValue])
        let source = PostureSource(override: nil, store: store)
        let handle = HostedPostureHandle(source: source)
        #expect(handle.needsConfirmation == true)
        #expect(handle.current == .strict, "unconfirmed non-strict posture fails closed to .strict")

        let ceremony = ScriptedCeremony(outcome: .performed)
        let windows = ConsoleWindowHost()
        let settingsVM = SettingsViewModel(
            presentation: ServerHosting.current(),
            windows: windows,
            ceremony: ceremony,
        )
        settingsVM.adoptPostureHandle(handle)
        #expect(settingsVM.displayedPosture == .strict)

        let confirmed = await settingsVM.confirmStoredPosture()
        #expect(confirmed == true)
        #expect(ceremony.nonces.count == 1)
        #expect(ceremony.reasons.first?.contains("Balanced") == true)
        #expect(settingsVM.displayedPosture == .balanced)
        #expect(handle.needsConfirmation == false)
    }

    @Test
    func `failed ceremony leaves unconfirmed non-strict posture as strict`() async {
        let store = InMemoryPreferencesStore(strings: [PostureSource.preferenceKey: Posture.balanced.rawValue])
        let source = PostureSource(override: nil, store: store)
        let handle = HostedPostureHandle(source: source)
        #expect(handle.needsConfirmation == true)

        let ceremony = ScriptedCeremony(outcome: .unavailable(.hardwareUnavailable))
        let windows = ConsoleWindowHost()
        let settingsVM = SettingsViewModel(
            presentation: ServerHosting.current(),
            windows: windows,
            ceremony: ceremony,
        )
        settingsVM.adoptPostureHandle(handle)
        #expect(settingsVM.displayedPosture == .strict)

        let confirmed = await settingsVM.confirmStoredPosture()
        #expect(confirmed == false)
        #expect(settingsVM.displayedPosture == .strict, "failed ceremony does not activate non-strict posture")
        #expect(handle.needsConfirmation == true)
    }
}
