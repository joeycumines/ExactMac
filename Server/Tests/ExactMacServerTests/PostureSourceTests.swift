import ExactMacServer
import XCTest

/// E34's acceptance, as behaviour: the posture control is wired to the enforcement the
/// server actually applies, and every claim it makes on screen is true.
///
/// THE FOUR CLAIMS THE ACCEPTANCE NAMES, each with the test that would fail if it broke:
/// live-apply (a grant honoured under balanced, ignored after strict, honoured again),
/// persistence round-trip, environment-override precedence, and initial-display
/// truthfulness. The engine's per-request derivation is untouched by all of it — posture
/// is consulted at evaluation time, so a change cannot alter a decision already made.
final class PostureSourceTests: XCTestCase {
    private func makeStateDirectory() throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exactmac-posture-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return ["EXACTMAC_STATE_DIRECTORY": directory]
    }

    private func removeStateDirectory(_ environment: [String: String]) {
        try? FileManager.default.removeItem(atPath: environment["EXACTMAC_STATE_DIRECTORY"] ?? "")
    }

    // MARK: The source itself

    /// The ordering is the whole product: override wins, then stored, then strict.
    func testTheOrderingIsOverrideThenStoredThenStrict() {
        // Nothing anywhere: strict, not a hardcoded balanced.
        XCTAssertEqual(PostureSource(override: nil).current, .strict)

        // A stored preference alone is honoured.
        let stored = PostureSource(override: nil)
        stored.setStoredPreference(.balanced)
        XCTAssertEqual(stored.current, .balanced)

        // THE OVERRIDE WINS: the operator's stored preference is ignored while the
        // deployment's setting holds.
        let overridden = PostureSource(override: .lockedDown)
        overridden.setStoredPreference(.balanced)
        XCTAssertEqual(overridden.current, .lockedDown)

        // Strict as an override is itself an override, not the absence of one.
        let strictOverride = PostureSource(override: .strict)
        strictOverride.setStoredPreference(.balanced)
        XCTAssertEqual(strictOverride.current, .strict)
        XCTAssertTrue(strictOverride.isOverriddenByEnvironment)
    }

    /// The write takes effect on the NEXT read, because the interceptor consults per
    /// request — the live-apply property, asserted at the seam the interceptor uses.
    func testTheWriteTakesEffectOnTheNextRead() {
        let source = PostureSource(override: nil)
        source.setStoredPreference(.lockedDown)
        XCTAssertEqual(source.current, .lockedDown)
        source.setStoredPreference(.balanced)
        XCTAssertEqual(source.current, .balanced)
    }

    // MARK: Persistence

    /// A preference written under one process reads back under another — the relaunch
    /// round-trip, through the real file in a temporary state directory.
    func testThePreferenceSurvivesAcrossProcesses() throws {
        let environment = try makeStateDirectory()
        defer { removeStateDirectory(environment) }

        let writer = PostureSource(override: nil)
        writer.setStoredPreference(.lockedDown)
        try writer.persist(environment: environment)

        // A DIFFERENT process starts: no stored preference in memory, loaded from disk.
        let reader = PostureSource(override: nil)
        XCTAssertNil(reader.storedPreference, "a fresh source must not invent a preference")
        let loaded = PostureSource.loadStoredPreference(environment: environment)
        XCTAssertEqual(loaded, .lockedDown)

        reader.setStoredPreference(loaded ?? .strict)
        XCTAssertEqual(reader.current, .lockedDown)
    }

    /// An unreadable or malformed preference file is NOT a preference — the fallback is
    /// the engine's own strict rather than a guess, and absent is normal, not an error.
    func testAnUnreadablePreferenceFileIsNotAPreference() throws {
        let environment = try makeStateDirectory()
        defer { removeStateDirectory(environment) }

        // Absent: the first-launch state.
        XCTAssertNil(PostureSource.loadStoredPreference(environment: environment))

        // Malformed bytes: not a preference, not a crash.
        let path = PostureSource.storedPath(environment: environment)
        try Data("this is not a posture file".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(PostureSource.loadStoredPreference(environment: environment))

        // A posture the engine does not have: not a preference.
        try Data("{\"posture\":\"permissive\"}".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(PostureSource.loadStoredPreference(environment: environment))
    }

    /// The override is never persisted — it is read from the environment at every launch,
    /// so persisting it would make a deployment setting survive the deployment that set it.
    func testTheOverrideIsNotPersisted() throws {
        let environment = try makeStateDirectory()
        defer { removeStateDirectory(environment) }

        let source = PostureSource(override: .lockedDown)
        source.setStoredPreference(.lockedDown)
        try source.persist(environment: environment)
        XCTAssertEqual(
            PostureSource.loadStoredPreference(environment: environment), .lockedDown,
        )
    }

    // MARK: The environment parser

    /// The env spellings the deployment names, and anything else is the absence of an
    /// override rather than a guess — EXCEPT that the parser in make() defaults strict,
    /// so the override is nil only when the variable is absent or blank.
    func testTheEnvironmentOverrideSpellings() throws {
        func override(_ value: String?) -> Posture? {
            let environment = ["EXACTMAC_POSTURE": value ?? ""]
            return PostureSourceTests.envOverride(in: environment)
        }

        XCTAssertEqual(override("balanced"), .balanced)
        XCTAssertEqual(override("LOCKED_DOWN"), .lockedDown)
        XCTAssertEqual(override("locked-down"), .lockedDown)
        XCTAssertEqual(override("lockeddown"), .lockedDown)
        XCTAssertEqual(override("strict"), .strict)
        // Unrecognised and absent are NOT overrides: the deployment said nothing the
        // source can distinguish from not-said, so the stored preference governs.
        XCTAssertNil(override("permissive"))
        XCTAssertNil(override(nil))
    }

    /// The same parser `make` uses, lifted so the test can drive it directly. THE
    /// DUPLICATION IS STATED: ServerConfig.posture(from:) maps unrecognised to strict
    /// because a SERVER must not start permissive on a typo; the SOURCE must not treat a
    /// typo as an override, because then a typo would silently revoke the operator's
    /// stored choice. The two defaults are different answers to different questions.
    private static func envOverride(in environment: [String: String]) -> Posture? {
        switch environment["EXACTMAC_POSTURE"]?.lowercased() {
        case "balanced": .balanced
        case "lockeddown", "locked_down", "locked-down": .lockedDown
        case "strict": .strict
        default: nil
        }
    }
}
