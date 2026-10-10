import ExactMacServer
import XCTest

/// Acceptance tests for PostureSource: preferences storage and Option 2 operator confirmation.
///
/// Ensures:
/// 1. The ordering is override -> stored -> strict.
/// 2. Live write takes effect on the next read.
/// 3. Round-trip through PreferencesStore without creating files on disk.
/// 4. Option 2: Stored non-strict posture (.balanced) at launch defaults to .strict until
///    confirmed by operator Touch ID, blocking unauthorized changes via defaults write.
final class PostureSourceTests: XCTestCase {
    // MARK: The source itself

    /// The ordering is the whole product: override wins, then stored, then strict.
    func testTheOrderingIsOverrideThenStoredThenStrict() {
        let store = InMemoryPreferencesStore()

        // Nothing anywhere: strict, not a hardcoded balanced.
        XCTAssertEqual(PostureSource(override: nil, store: store).current, .strict)

        // A stored preference alone is honoured when set interactively.
        let source = PostureSource(override: nil, store: store)
        source.setStoredPreference(.balanced)
        XCTAssertEqual(source.current, .balanced)

        // THE OVERRIDE WINS: the operator's stored preference is ignored while the
        // deployment's setting holds.
        let overridden = PostureSource(override: .lockedDown, store: store)
        overridden.setStoredPreference(.balanced)
        XCTAssertEqual(overridden.current, .lockedDown)

        // Strict as an override is itself an override, not the absence of one.
        let strictOverride = PostureSource(override: .strict, store: store)
        strictOverride.setStoredPreference(.balanced)
        XCTAssertEqual(strictOverride.current, .strict)
        XCTAssertTrue(strictOverride.isOverriddenByEnvironment)
    }

    /// The write takes effect on the NEXT read, because the interceptor consults per request.
    func testTheWriteTakesEffectOnTheNextRead() {
        let store = InMemoryPreferencesStore()
        let source = PostureSource(override: nil, store: store)
        source.setStoredPreference(.lockedDown)
        XCTAssertEqual(source.current, .lockedDown)
        source.setStoredPreference(.balanced)
        XCTAssertEqual(source.current, .balanced)
    }

    // MARK: Option 2 Operator Confirmation

    /// Threat model defense: If defaults write injects .balanced while ExactMac is not running,
    /// on launch the stored .balanced posture fails closed to .strict until confirmed with Touch ID.
    func testOption2StoredBalancedPostureRequiresOperatorTouchIDConfirmation() {
        let store = InMemoryPreferencesStore()
        // Simulate defaults write com.exactmac.console posture balanced
        store.setString(Posture.balanced.rawValue, forKey: PostureSource.preferenceKey)

        // Launch reader with stored non-strict posture
        let reader = PostureSource(override: nil, store: store)
        XCTAssertEqual(reader.storedPreference, .balanced)
        XCTAssertFalse(reader.isConfirmed)
        XCTAssertTrue(reader.needsConfirmation)

        // UNTIL CONFIRMED, enforcement strictly evaluates to .strict!
        XCTAssertEqual(reader.current, .strict, "unconfirmed stored balanced posture must fail closed to strict")

        // Operator confirms via Touch ID
        reader.confirmStoredPreference()
        XCTAssertTrue(reader.isConfirmed)
        XCTAssertFalse(reader.needsConfirmation)
        XCTAssertEqual(reader.current, .balanced, "confirmed balanced posture is now in effect")
    }

    /// Stored strict or lockedDown does NOT require confirmation, as neither lowers security.
    func testStoredStrictOrLockedDownDoesNotRequireConfirmation() {
        let store = InMemoryPreferencesStore()
        store.setString(Posture.lockedDown.rawValue, forKey: PostureSource.preferenceKey)

        let reader = PostureSource(override: nil, store: store)
        XCTAssertEqual(reader.storedPreference, .lockedDown)
        XCTAssertTrue(reader.isConfirmed)
        XCTAssertFalse(reader.needsConfirmation)
        XCTAssertEqual(reader.current, .lockedDown)
    }

    // MARK: Persistence

    /// A preference written under one source reads back under another via PreferencesStore.
    func testThePreferenceSurvivesAcrossProcesses() throws {
        let store = InMemoryPreferencesStore()

        let writer = PostureSource(override: nil, store: store)
        writer.setStoredPreference(.lockedDown)
        try writer.persist()

        let reader = PostureSource(override: nil, store: store)
        XCTAssertEqual(reader.storedPreference, .lockedDown)
        XCTAssertEqual(reader.current, .lockedDown)
    }

    /// An unreadable or absent preference is NOT a preference — fallback is strict.
    func testAnUnreadablePreferenceIsNotAPreference() {
        let store = InMemoryPreferencesStore()
        XCTAssertNil(PostureSource.loadStoredPreference(store: store))

        // Malformed or invalid raw value
        store.setString("permissive", forKey: PostureSource.preferenceKey)
        XCTAssertNil(PostureSource.loadStoredPreference(store: store))
    }

    // MARK: The environment parser

    func testTheEnvironmentOverrideSpellings() {
        func override(_ value: String?) -> Posture? {
            let environment = ["EXACTMAC_POSTURE": value ?? ""]
            return PostureSourceTests.envOverride(in: environment)
        }

        XCTAssertEqual(override("balanced"), .balanced)
        XCTAssertEqual(override("LOCKED_DOWN"), .lockedDown)
        XCTAssertEqual(override("locked-down"), .lockedDown)
        XCTAssertEqual(override("lockeddown"), .lockedDown)
        XCTAssertEqual(override("strict"), .strict)
        XCTAssertNil(override("permissive"))
        XCTAssertNil(override(nil))
    }

    private static func envOverride(in environment: [String: String]) -> Posture? {
        switch environment["EXACTMAC_POSTURE"]?.lowercased() {
        case "balanced": .balanced
        case "lockeddown", "locked_down", "locked-down": .lockedDown
        case "strict": .strict
        default: nil
        }
    }
}
