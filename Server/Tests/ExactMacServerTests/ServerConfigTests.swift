import Darwin
@testable import ExactMacServer
import XCTest

/// Tests for ServerConfig and server security settings
final class ServerConfigTests: XCTestCase {
    func testDefaultConfiguration() {
        // Save original environment
        let originalAddress = ProcessInfo.processInfo.environment["GRPC_LISTEN_ADDRESS"]
        let originalPort = ProcessInfo.processInfo.environment["GRPC_PORT"]
        let originalSocket = ProcessInfo.processInfo.environment["GRPC_UNIX_SOCKET"]

        // Clear environment
        setenv("GRPC_LISTEN_ADDRESS", "", 1)
        setenv("GRPC_PORT", "", 1)
        unsetenv("GRPC_UNIX_SOCKET")

        let config = ServerConfig.fromEnvironment()

        XCTAssertEqual(config.listenAddress, "127.0.0.1")
        XCTAssertEqual(config.port, 8080)
        XCTAssertNil(config.unixSocketPath)

        // Restore environment
        if let addr = originalAddress {
            setenv("GRPC_LISTEN_ADDRESS", addr, 1)
        }
        if let port = originalPort {
            setenv("GRPC_PORT", port, 1)
        }
        if let sock = originalSocket {
            setenv("GRPC_UNIX_SOCKET", sock, 1)
        }
    }

    func testCustomConfiguration() {
        setenv("GRPC_LISTEN_ADDRESS", "0.0.0.0", 1)
        setenv("GRPC_PORT", "9090", 1)
        setenv("GRPC_UNIX_SOCKET", "/tmp/test.sock", 1)

        let config = ServerConfig.fromEnvironment()

        XCTAssertEqual(config.listenAddress, "0.0.0.0")
        XCTAssertEqual(config.port, 9090)
        XCTAssertEqual(config.unixSocketPath, "/tmp/test.sock")

        // Cleanup
        unsetenv("GRPC_LISTEN_ADDRESS")
        unsetenv("GRPC_PORT")
        unsetenv("GRPC_UNIX_SOCKET")
    }

    func testEmptyUnixSocketUsesTCPConfiguration() {
        setenv("GRPC_UNIX_SOCKET", "", 1)
        defer { unsetenv("GRPC_UNIX_SOCKET") }

        let config = ServerConfig.fromEnvironment()

        XCTAssertNil(config.unixSocketPath)
    }

    func testServerProcessUmaskPreservesOwnerTraversal() {
        // Owner-only files and directories must still be traversable. A 0177
        // umask masks the owner execute bit and breaks macOS framework caches.
        XCTAssertEqual(ServerProcessPolicy.umask, 0o077)
        XCTAssertEqual(0o666 & ~ServerProcessPolicy.umask, 0o600)
        XCTAssertEqual(0o777 & ~ServerProcessPolicy.umask, 0o700)
    }
}

/// C10's configuration, and the rule that governs it: every default is FAIL-CLOSED, so a
/// server started with nothing configured is the one least able to do anything.
final class AuthorizationConfigurationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        for key in [
            "EXACTMAC_CONSOLE_SOCKET", "EXACTMAC_CONSENT_TIMEOUT_SECONDS",
            "EXACTMAC_MAX_ENVELOPE_SECONDS", "EXACTMAC_POSTURE",
        ] {
            setenv(key, "", 1)
            defer { unsetenv(key) }
        }
    }

    func testTheDefaultsDenyRatherThanPermit() {
        let config = ServerConfig.fromEnvironment()
        XCTAssertNil(
            config.consoleSocketPath,
            "a server with no console socket must not go looking for one",
        )
        XCTAssertEqual(
            config.defaultPosture, .strict,
            "the default posture is the strictest of the three, not the recommended one",
        )
        XCTAssertGreaterThan(config.consentTimeoutSeconds, 0, "a zero timeout denies everything")
        XCTAssertGreaterThan(config.maximumEnvelopeSeconds, 0, "a zero envelope ceiling is not a ceiling")
    }

    func testAnUnparseableSettingTakesTheDefaultRatherThanSomethingLooser() {
        setenv("EXACTMAC_CONSENT_TIMEOUT_SECONDS", "not-a-number", 1)
        setenv("EXACTMAC_MAX_ENVELOPE_SECONDS", "-1", 1)
        setenv("EXACTMAC_POSTURE", "permissive", 1)
        let config = ServerConfig.fromEnvironment()
        XCTAssertEqual(config.consentTimeoutSeconds, ServerConfig.defaultConsentTimeoutSeconds)
        // A NEGATIVE ceiling is refused rather than clamped: it is a configuration mistake
        // worth seeing in the log, not a number to guess at.
        XCTAssertEqual(config.maximumEnvelopeSeconds, ServerConfig.defaultMaximumEnvelopeSeconds)
        // An unrecognised posture is the STRICTEST one, because a server that guessed
        // "balanced" on a typo would be the opposite of what the operator wrote.
        XCTAssertEqual(config.defaultPosture, .strict)
    }

    func testRealValuesAreHonoured() {
        setenv("EXACTMAC_CONSOLE_SOCKET", "/tmp/console.sock", 1)
        setenv("EXACTMAC_CONSENT_TIMEOUT_SECONDS", "45", 1)
        setenv("EXACTMAC_MAX_ENVELOPE_SECONDS", "3600", 1)
        setenv("EXACTMAC_POSTURE", "Balanced", 1)
        let config = ServerConfig.fromEnvironment()
        XCTAssertEqual(config.consoleSocketPath, "/tmp/console.sock")
        XCTAssertEqual(config.consentTimeoutSeconds, 45)
        XCTAssertEqual(config.maximumEnvelopeSeconds, 3600)
        XCTAssertEqual(config.defaultPosture, .balanced, "the posture name is matched case-insensitively")
    }

    func testEveryPostureNameIsRecognised() {
        for (name, expected) in [
            ("strict", Posture.strict), ("balanced", Posture.balanced),
            ("lockedDown", Posture.lockedDown), ("locked_down", Posture.lockedDown),
        ] {
            setenv("EXACTMAC_POSTURE", name, 1)
            XCTAssertEqual(ServerConfig.fromEnvironment().defaultPosture, expected, name)
        }
    }
}
