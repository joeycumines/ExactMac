import ExactMacServer
import XCTest

/// Acceptance tests for BiometricGateSource: preferences storage and Option 2 operator confirmation.
///
/// Ensures:
/// 1. Default is ceremony required (true).
/// 2. Stored preferences round-trip through PreferencesStore without creating files on disk.
/// 3. Option 2: A stored relaxed gate (false) loaded at launch defaults to ceremony required (true)
///    until confirmed interactively by Touch ID, preventing defaults write bypass.
final class BiometricGateSourceTests: XCTestCase {
    func testTheDefaultIsTheCeremonyAndAStoredChoiceRoundTrips() throws {
        let store = InMemoryPreferencesStore()

        // DEFAULT: nothing stored, ceremony required.
        XCTAssertTrue(BiometricGateSource.loadStoredGate(store: store))

        let source = BiometricGateSource(store: store)
        XCTAssertTrue(source.isCeremonyRequired, "a fresh source holds the default true")

        // Operator explicitly sets gate to false (interactive, confirmed)
        source.setCeremonyRequired(false)
        XCTAssertFalse(source.isCeremonyRequired, "interactive change takes effect immediately")
        try source.persist()

        XCTAssertFalse(
            BiometricGateSource.loadStoredGate(store: store),
            "the stored gate survives round trip",
        )

        // Set back to true
        source.setCeremonyRequired(true)
        try source.persist()
        XCTAssertTrue(BiometricGateSource.loadStoredGate(store: store))
    }

    // MARK: Option 2 Operator Confirmation

    /// Threat model defense: If defaults write injects ceremonyRequired = false, on launch
    /// the relaxed gate fails closed to requiring ceremony (true) until confirmed by operator Touch ID.
    func testOption2StoredRelaxedGateRequiresOperatorTouchIDConfirmation() {
        let store = InMemoryPreferencesStore()
        // Simulate defaults write com.exactmac.console ceremonyRequired -bool false
        store.setBool(false, forKey: BiometricGateSource.preferenceKey)

        // Fresh launch
        let reader = BiometricGateSource(store: store)
        XCTAssertFalse(reader.isConfirmed)
        XCTAssertTrue(reader.needsConfirmation)

        // UNTIL CONFIRMED, ceremony is REQUIRED (fails closed)!
        XCTAssertTrue(reader.isCeremonyRequired, "unconfirmed stored relaxed gate must fail closed to requiring ceremony")

        // Operator confirms via Touch ID
        reader.confirmStoredGate()
        XCTAssertTrue(reader.isConfirmed)
        XCTAssertFalse(reader.needsConfirmation)
        XCTAssertFalse(reader.isCeremonyRequired, "confirmed relaxed gate is now active")
    }

    func testStoredStrictGateDoesNotRequireConfirmation() {
        let store = InMemoryPreferencesStore()
        store.setBool(true, forKey: BiometricGateSource.preferenceKey)

        let reader = BiometricGateSource(store: store)
        XCTAssertTrue(reader.isConfirmed)
        XCTAssertFalse(reader.needsConfirmation)
        XCTAssertTrue(reader.isCeremonyRequired)
    }

    func testZeroDiskStateForBiometricGate() {
        let store = InMemoryPreferencesStore()
        let source = BiometricGateSource(store: store)
        source.setCeremonyRequired(false)
        try? source.persist()

        // Verify that no console-biometrics.json file exists on disk
        let tmpPath = NSTemporaryDirectory() + "console-biometrics.json"
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath))
    }
}
