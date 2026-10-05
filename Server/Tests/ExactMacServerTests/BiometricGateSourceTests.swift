@testable import ExactMacServer
import XCTest

/// The biometric gate: what it defaults to, what a corrupt file reads as, and that a
/// choice survives the file round trip.
///
/// THE DEFAULT IS THE CEREMONY, and every failure mode in this suite exists to prove one
/// thing: there is no input that turns the gate OFF except a stored, well-formed `false`.
/// A gate that failed open on a corrupt file would hand a silent downgrade to whoever
/// arranged the corruption.
final class BiometricGateSourceTests: XCTestCase {
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = NSTemporaryDirectory() + "exactmac-gate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
        )
        environment = ["EXACTMAC_STATE_DIRECTORY": directory]
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    private func writeGate(_ body: String) throws {
        let path = BiometricGateSource.storedPath(environment: environment)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testTheDefaultIsTheCeremonyAndAStoredChoiceRoundTripsThroughTheFile() throws {
        // DEFAULT: nothing stored, ceremony required.
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))

        let source = BiometricGateSource()
        XCTAssertTrue(source.isCeremonyRequired, "a fresh source holds the default")

        // The choice is written to disk and read back as the same choice by a SECOND
        // source — the round trip a relaunch performs.
        source.setCeremonyRequired(false)
        XCTAssertFalse(source.isCeremonyRequired, "the write takes effect immediately")
        try source.persist(environment: environment)
        XCTAssertFalse(
            BiometricGateSource.loadStoredGate(environment: environment),
            "the stored gate must survive the file round trip",
        )

        // Back on, same trip.
        source.setCeremonyRequired(true)
        try source.persist(environment: environment)
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))
    }

    func testAFileThatIsAbsentUnreadableMalformedOrMisspelledReadsAsTheCeremonyRequired() throws {
        // Absent: covered by the default test. Malformed JSON:
        try writeGate("{not json")
        XCTAssertTrue(
            BiometricGateSource.loadStoredGate(environment: environment),
            "a malformed file is not a preference; the ceremony stays",
        )

        // Wrong shape: valid JSON, wrong type.
        try writeGate("[1, 2, 3]")
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))

        // Right shape, wrong spelling: a string is not a boolean.
        try writeGate(#"{"ceremonyRequired":"false"}"#)
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))

        // A number is not a boolean either.
        try writeGate(#"{"ceremonyRequired":0}"#)
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))

        // The key nobody wrote: valid JSON, no gate in it.
        try writeGate(#"{"posture":"balanced"}"#)
        XCTAssertTrue(BiometricGateSource.loadStoredGate(environment: environment))
    }

    func testThePersistedFileIsOwnerReadWriteOnly() throws {
        let source = BiometricGateSource()
        source.setCeremonyRequired(false)
        try source.persist(environment: environment)

        let path = BiometricGateSource.storedPath(environment: environment)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(
            permissions?.uint16Value ?? 0,
            0o600,
            "the gate file is operator-private, like the posture file beside it",
        )
    }

    func testThePersistedBodyNamesTheGateAndNothingElse() throws {
        let source = BiometricGateSource()
        try source.persist(environment: environment)
        let path = BiometricGateSource.storedPath(environment: environment)
        let body = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(
            body.contains("\"ceremonyRequired\":true"),
            "the default persisted is the ceremony on, got \(body)",
        )
    }
}
