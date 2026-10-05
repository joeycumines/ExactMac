import Darwin
@testable import ExactMacServer
import Foundation
import XCTest

/// The console's write into the decision log, and the two properties the acceptance
/// turns on: EVERY operator-action attempt lands on the log with its outcome, and a host
/// with no registered audit fails closed — an unrecordable change is not applied.
///
/// THE ENTRY IS ALSO READ BACK AND VERIFIED, because "record returned true" is not the
/// acceptance: the row has to name the action, the outcome, the refusal when there was
/// one, and carry this process as the caller — and the chain the entry joined must still
/// verify, because an entry that broke the chain is a record that poisons the log it
/// claims to serve.
final class OperatorActionAuditTests: XCTestCase {
    private var stateDirectory: String!
    private var environment: [String: String] {
        ["EXACTMAC_STATE_DIRECTORY": stateDirectory]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = NSTemporaryDirectory() + "emc-opaction-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
    }

    override func tearDownWithError() throws {
        ServerInspectionService.unregister()
        try? FileManager.default.removeItem(atPath: stateDirectory)
        try super.tearDownWithError()
    }

    private func registerLiveAudit() throws -> DecisionAudit {
        let clock = SystemMonotonicClock()
        let audit = try DecisionAudit(
            path: stateDirectory + "/audit.log",
            clock: clock,
        )
        let store = try GrantStore.openStore(
            path: stateDirectory + "/grants.json",
            clock: clock,
            maximumEnvelopeSeconds: 86400,
        )
        ServerInspectionService.register(
            store: store,
            audit: audit,
            clock: clock,
            stateDirectory: stateDirectory,
        )
        return audit
    }

    private func readEntries() throws -> [AuditEntry] {
        try AuditEntry.readAll(from: stateDirectory + "/audit.log").whole
    }

    func testAnUnregisteredHostFailsClosedAndRecordsNothing() {
        // No register call: the shape of a host that never started a runtime.
        let recorded = ServerInspectionService.recordOperatorAction(
            action: "the console biometric gate was turned off",
            approved: true,
            biometricObtained: true,
            refusalReason: nil,
            environment: environment,
        )
        XCTAssertFalse(
            recorded,
            "with no live audit the record must fail; the caller must treat the change as not having happened",
        )
        let path = stateDirectory + "/audit.log"
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "a failed record must not leave a log behind — nothing was written by anybody",
        )
    }

    func testAnApprovedToggleLandsOnTheLogAndTheChainStillVerifies() throws {
        let audit = try registerLiveAudit()

        let recorded = ServerInspectionService.recordOperatorAction(
            action: "the console biometric gate was turned off",
            approved: true,
            biometricObtained: true,
            refusalReason: nil,
            environment: environment,
        )
        XCTAssertTrue(recorded, "the registered live audit must take the record")

        let entries = try readEntries()
        XCTAssertEqual(entries.count, 1, "exactly one entry for exactly one attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.decision, "allow", "an approved toggle is an allow")
        XCTAssertEqual(entry.rpcName, "console.operatorAction")
        XCTAssertEqual(entry.argumentSummary, "the console biometric gate was turned off")
        XCTAssertTrue(entry.biometricObtained, "the ceremony that gated the change is on the record")
        XCTAssertNil(entry.refusalReason)
        // THE CALLER IS THIS PROCESS, resolved rather than labelled: the executable path
        // is the test runner's, and it resolved.
        XCTAssertEqual(entry.identity.processIdentifier, getpid())
        XCTAssertEqual(entry.identity.effectiveUserIdentifier, getuid())
        XCTAssertFalse(entry.identity.executablePath.isEmpty)

        XCTAssertTrue(
            audit.verify().isIntact,
            "the operator-action entry must join the chain without breaking it",
        )
    }

    func testARefusedAttemptIsADeniedEntryNamingTheRefusal() throws {
        let audit = try registerLiveAudit()

        let recorded = ServerInspectionService.recordOperatorAction(
            action: "the console biometric gate was turned off",
            approved: false,
            biometricObtained: false,
            refusalReason: .biometricUnavailable,
            environment: environment,
        )
        XCTAssertTrue(recorded)

        let entry = try XCTUnwrap(try readEntries().first)
        XCTAssertEqual(entry.decision, "deny", "a failed ceremony is a denied entry")
        XCTAssertEqual(entry.refusalReason, "biometricUnavailable")
        XCTAssertFalse(entry.biometricObtained)
        XCTAssertEqual(entry.operatorNote, "The change was not applied.")
        XCTAssertTrue(
            audit.verify().isIntact,
            "the refusal must join the chain without breaking it",
        )
    }

    func testSuccessiveEntriesContinueOneChainAcrossBothKinds() throws {
        let audit = try registerLiveAudit()

        // A refusal first, then the successful retry the acceptance's flow produces.
        _ = ServerInspectionService.recordOperatorAction(
            action: "the console biometric gate was turned off",
            approved: false,
            biometricObtained: false,
            refusalReason: .biometricUnavailable,
            environment: environment,
        )
        _ = ServerInspectionService.recordOperatorAction(
            action: "the console biometric gate was turned off",
            approved: true,
            biometricObtained: true,
            refusalReason: nil,
            environment: environment,
        )

        let entries = try readEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].sequence, 1)
        XCTAssertEqual(entries[1].sequence, 2)
        // The refusal is still on the record even though the retry succeeded: the log is
        // asked for history, not for the latest state.
        XCTAssertEqual(entries[0].refusalReason, "biometricUnavailable")
        XCTAssertEqual(entries[1].decision, "allow")
        XCTAssertTrue(audit.verify().isIntact)
    }
}
