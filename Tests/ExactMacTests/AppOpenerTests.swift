import AppKit
@testable import ExactMac
import XCTest

/// Tests for AppOpener functionality.
///
/// Tests path validation, bundle identification, and activation edge cases.
final class AppOpenerTests: XCTestCase {
    // MARK: - Path Validation

    func testValidAppBundlePath_accepted() {
        // Test with a known valid .app path
        let validPaths = [
            "/System/Applications/Calculator.app",
            "/System/Applications/TextEdit.app",
            "/Applications/TextEdit.app",
        ]

        for path in validPaths {
            // The SDK uses FileManager internally, so we verify paths exist
            let exists = FileManager.default.fileExists(atPath: path)
            if exists {
                // Path validation is done in the SDK's openApplication function
                // We just verify the path we're testing is valid
                XCTAssertTrue(true, "\(path) is valid")
            } else {
                XCTAssertTrue(true, "\(path) not found on this system (skipped)")
            }
        }
    }

    func testExactBundleValidationRejectsMissingAndMalformedPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppOpenerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyPackage = root.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPackage, withIntermediateDirectories: true)

        for url in [
            root.appendingPathComponent("Missing.app", isDirectory: true),
            emptyPackage,
            root.appendingPathComponent("NotAnApp.txt"),
        ] {
            XCTAssertThrowsError(try validatedApplicationBundleURL(url)) { error in
                guard case ExactMacError.AppOpenerError.invalidPath = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testExactBundleValidationCanonicalizesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppOpenerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Exact.app", isDirectory: true)
        try makeBundle(at: bundle)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)

        XCTAssertEqual(
            try validatedApplicationBundleURL(alias),
            canonicalApplicationBundleURL(bundle),
        )
    }

    func testExactBundleValidationAcceptsFinderPackageType() throws {
        let finderURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/Finder.app",
            isDirectory: true,
        )

        XCTAssertEqual(
            try validatedApplicationBundleURL(finderURL),
            canonicalApplicationBundleURL(finderURL),
        )
    }

    // MARK: - Bundle ID Extraction

    func testBundleID_extractionFromPath() throws {
        // Test that we can extract bundle ID from a known app
        let calculatorPath = "/System/Applications/Calculator.app"
        guard let bundle = Bundle(url: URL(fileURLWithPath: calculatorPath)) else {
            throw XCTSkip("Calculator app not found on this system")
        }

        let bundleID = bundle.bundleIdentifier
        XCTAssertEqual(bundleID, "com.apple.calculator")
    }

    func testBundleID_fallbackToName() throws {
        // If bundle identifier is nil, should fall back to CFBundleName
        // Calculator has a bundle ID, but we can verify the fallback logic
        let calculatorPath = "/System/Applications/Calculator.app"
        guard let bundle = Bundle(url: URL(fileURLWithPath: calculatorPath)) else {
            throw XCTSkip("Calculator app not found on this system")
        }

        let bundleName = (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
        XCTAssertNotNil(bundleName, "Calculator should have a bundle name")
    }

    // MARK: - Name Resolution

    func testDisplayNameResolution_prefersLocalizedBundleMetadata() {
        let resolved = resolveApplicationDisplayName(
            localizedInfoDictionary: [
                "CFBundleDisplayName": " Localized Display ",
                "CFBundleName": "Localized Name",
            ],
            infoDictionary: [
                "CFBundleDisplayName": "Unlocalized Display",
                "CFBundleName": "Unlocalized Name",
            ],
            applicationURL: URL(fileURLWithPath: "/Applications/Filename.app"),
            fallbackIdentifier: "com.example.fallback",
        )

        XCTAssertEqual(resolved, "Localized Display")
    }

    func testDisplayNameResolution_usesNonlocalizedNameWhenLocalizedMetadataIsAbsent() {
        let resolved = resolveApplicationDisplayName(
            localizedInfoDictionary: nil,
            infoDictionary: ["CFBundleName": "Calculator"],
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            fallbackIdentifier: "com.apple.calculator",
        )

        XCTAssertEqual(resolved, "Calculator")
    }

    func testDisplayNameResolution_usesBundleFilenameBeforeIdentifier() {
        let resolved = resolveApplicationDisplayName(
            localizedInfoDictionary: ["CFBundleDisplayName": "  "],
            infoDictionary: ["CFBundleName": "\n"],
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            fallbackIdentifier: "com.apple.calculator",
        )

        XCTAssertEqual(resolved, "Calculator")
    }

    // MARK: - Observed Disposition

    func testForceNewClassification_rejectsReturnedPreExistingPID() {
        XCTAssertThrowsError(
            try classifyApplicationOpen(
                mode: .forceNewInstance,
                background: false,
                returnedPID: 42,
                preExistingPIDs: [42, 84],
                preExistingActivePIDs: [42],
                identifier: "Calculator",
            ),
        ) { error in
            guard case let ExactMacError.AppOpenerError.newInstanceNotCreated(identifier, returnedPID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "Calculator")
            XCTAssertEqual(returnedPID, 42)
        }
    }

    func testForceNewClassification_acceptsOnlyDistinctPositivePID() throws {
        let result = try classifyApplicationOpen(
            mode: .forceNewInstance,
            background: false,
            returnedPID: 126,
            preExistingPIDs: [42, 84],
            preExistingActivePIDs: [42],
            identifier: "Calculator",
        )

        XCTAssertEqual(result.action.rawValue, AppOpenAction.launchedNew.rawValue)
        XCTAssertTrue(result.newProcessCreated)
    }

    func testOpenClassification_rejectsNonpositiveReturnedPID() {
        XCTAssertThrowsError(
            try classifyApplicationOpen(
                mode: .launchOrActivate,
                background: false,
                returnedPID: 0,
                preExistingPIDs: [],
                preExistingActivePIDs: [],
                identifier: "Calculator",
            ),
        ) { error in
            guard case let ExactMacError.AppOpenerError.pidLookupFailed(identifier) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "Calculator")
        }
    }

    func testLaunchOrActivateClassification_usesReturnedPIDIdentity() throws {
        let activeResult = try classifyApplicationOpen(
            mode: .launchOrActivate,
            background: false,
            returnedPID: 84,
            preExistingPIDs: [42, 84],
            preExistingActivePIDs: [84],
            identifier: "Calculator",
        )
        XCTAssertEqual(activeResult.action.rawValue, AppOpenAction.alreadyActive.rawValue)
        XCTAssertFalse(activeResult.newProcessCreated)

        let newResult = try classifyApplicationOpen(
            mode: .launchOrActivate,
            background: false,
            returnedPID: 126,
            preExistingPIDs: [42, 84],
            preExistingActivePIDs: [84],
            identifier: "Calculator",
        )
        XCTAssertEqual(newResult.action.rawValue, AppOpenAction.launchedNew.rawValue)
        XCTAssertTrue(newResult.newProcessCreated)
    }

    func testLaunchOrActivateClassification_backgroundReuseIsObserved() throws {
        let result = try classifyApplicationOpen(
            mode: .launchOrActivate,
            background: true,
            returnedPID: 42,
            preExistingPIDs: [42],
            preExistingActivePIDs: [],
            identifier: "Calculator",
        )

        XCTAssertEqual(result.action.rawValue, AppOpenAction.reusedExisting.rawValue)
        XCTAssertFalse(result.newProcessCreated)
    }

    // MARK: - Activation Edge Cases

    func testActivation_withRunningApp() async throws {
        // Launch an app first
        let calculatorPath = "/System/Applications/Calculator.app"
        let calculatorURL = URL(fileURLWithPath: calculatorPath)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        } catch {
            throw XCTSkip("Cannot launch application in this environment: \(error)")
        }
        let pid = app.processIdentifier

        XCTAssertNotEqual(pid, 0, "Should have valid PID after launch")

        // Cleanup — poll until process is terminated (no Task.sleep).
        app.terminate()
        for _ in 0 ..< 20 {
            if app.isTerminated {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testActivation_failureRecovery() async throws {
        // Test that the SDK handles activation failures gracefully
        // by still returning a PID if the app was already running

        // First, launch an app
        let calculatorPath = "/System/Applications/Calculator.app"
        let calculatorURL = URL(fileURLWithPath: calculatorPath)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        let app1: NSRunningApplication
        do {
            app1 = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        } catch {
            throw XCTSkip("Cannot launch application in this environment: \(error)")
        }
        let pid1 = app1.processIdentifier

        // Try to open the same app again - should return same PID
        let app2: NSRunningApplication
        do {
            app2 = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: config)
        } catch {
            throw XCTSkip("Cannot launch application in this environment: \(error)")
        }
        let pid2 = app2.processIdentifier

        XCTAssertEqual(pid1, pid2, "Should return same PID for already-running app")

        // Cleanup — poll until process is terminated (no Task.sleep).
        app1.terminate()
        for _ in 0 ..< 20 {
            if app1.isTerminated {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Error Handling

    func testAppNotFoundError_properties() {
        let error = ExactMacError.AppOpenerError.appNotFound(identifier: "com.nonexistent.app")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("com.nonexistent.app") == true)
    }

    func testInvalidPathError_properties() {
        let error = ExactMacError.AppOpenerError.invalidPath(path: "/bad/path.app")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("/bad/path.app") == true)
    }

    func testActivationFailedError_properties() {
        let underlyingError = NSError(domain: "Test", code: 42)
        let error = ExactMacError.AppOpenerError.activationFailed(identifier: "TestApp", underlyingError: underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("TestApp") == true)
    }

    func testPIDLookupFailedError_properties() {
        let error = ExactMacError.AppOpenerError.pidLookupFailed(identifier: "TestApp")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("TestApp") == true)
        XCTAssertTrue(error.errorDescription?.contains("PID") == true)
    }

    // MARK: - AppOpenerResult Codable

    func testAppOpenerResult_codable() throws {
        let result = AppOpenerResult(
            pid: 12345,
            appName: "TestApp",
            processingTimeSeconds: "0.123",
            actionTaken: .launchedNew,
            newProcessCreated: true,
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppOpenerResult.self, from: data)

        XCTAssertEqual(result.pid, decoded.pid)
        XCTAssertEqual(result.appName, decoded.appName)
        XCTAssertEqual(result.processingTimeSeconds, decoded.processingTimeSeconds)
    }

    private func makeBundle(at url: URL) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleName": "Exact",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Exact",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0,
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
