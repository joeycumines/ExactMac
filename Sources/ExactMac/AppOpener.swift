import AppKit
import Foundation
import OSLog

private let logger = sdkLogger(category: "AppOpener")

func resolveApplicationDisplayName(
    localizedInfoDictionary: [String: Any]?,
    infoDictionary: [String: Any]?,
    applicationURL: URL,
    fallbackIdentifier: String,
) -> String {
    let candidates: [String?] = [
        localizedInfoDictionary?["CFBundleDisplayName"] as? String,
        localizedInfoDictionary?["CFBundleName"] as? String,
        infoDictionary?["CFBundleDisplayName"] as? String,
        infoDictionary?["CFBundleName"] as? String,
        applicationURL.deletingPathExtension().lastPathComponent,
        fallbackIdentifier,
    ]

    for candidate in candidates {
        let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            return normalized
        }
    }

    return ""
}

private func resolveApplicationDisplayName(
    bundle: Bundle?,
    applicationURL: URL,
    fallbackIdentifier: String,
) -> String {
    resolveApplicationDisplayName(
        localizedInfoDictionary: bundle?.localizedInfoDictionary,
        infoDictionary: bundle?.infoDictionary,
        applicationURL: applicationURL,
        fallbackIdentifier: fallbackIdentifier,
    )
}

struct ClassifiedApplicationOpen {
    let action: AppOpenAction
    let newProcessCreated: Bool
}

func classifyApplicationOpen(
    mode: AppLaunchMode,
    background: Bool,
    returnedPID: pid_t,
    preExistingPIDs: Set<pid_t>,
    preExistingActivePIDs: Set<pid_t>,
    identifier: String,
) throws -> ClassifiedApplicationOpen {
    guard returnedPID > 0 else {
        throw ExactMacError.AppOpenerError.pidLookupFailed(identifier: identifier)
    }

    switch mode {
    case .forceNewInstance:
        guard !preExistingPIDs.contains(returnedPID) else {
            throw ExactMacError.AppOpenerError.newInstanceNotCreated(
                identifier: identifier,
                returnedPID: returnedPID,
            )
        }
        return ClassifiedApplicationOpen(action: .launchedNew, newProcessCreated: true)
    case .launchOrActivate:
        guard preExistingPIDs.contains(returnedPID) else {
            return ClassifiedApplicationOpen(action: .launchedNew, newProcessCreated: true)
        }
        if background {
            return ClassifiedApplicationOpen(action: .reusedExisting, newProcessCreated: false)
        }
        if preExistingActivePIDs.contains(returnedPID) {
            return ClassifiedApplicationOpen(action: .alreadyActive, newProcessCreated: false)
        }
        return ClassifiedApplicationOpen(action: .activatedExisting, newProcessCreated: false)
    }
}

/// Validates and canonicalizes one exact application bundle URL without
/// invoking Launch Services or mutating application state.
func validatedApplicationBundleURL(
    _ applicationURL: URL,
    fileManager: FileManager = .default,
) throws -> URL {
    guard applicationURL.isFileURL else {
        throw ExactMacError.AppOpenerError.invalidPath(path: applicationURL.absoluteString)
    }

    let canonicalURL = canonicalApplicationBundleURL(applicationURL)
    var isDirectory: ObjCBool = false
    guard canonicalURL.pathExtension.lowercased() == "app",
          fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          let bundle = Bundle(url: canonicalURL),
          isSupportedApplicationBundle(bundle)
    else {
        throw ExactMacError.AppOpenerError.invalidPath(path: applicationURL.path)
    }
    return canonicalURL
}

/// Define potential errors during app opening
public extension ExactMacError {
    /// Ensure this enum is correctly defined within the extension
    enum AppOpenerError: Error, LocalizedError {
        case appNotFound(identifier: String)
        case invalidPath(path: String)
        case activationFailed(identifier: String, underlyingError: Error?)
        case pidLookupFailed(identifier: String)
        case newInstanceNotCreated(identifier: String, returnedPID: pid_t)
        case unexpectedNilURL

        public var errorDescription: String? {
            switch self {
            case let .appNotFound(id):
                return "Application not found for identifier: '\(id)'"
            case let .invalidPath(path):
                return "Provided path does not appear to be a valid application bundle: '\(path)'"
            case let .activationFailed(id, err):
                let base = "Failed to open/activate application '\(id)'"
                if let err {
                    return "\(base): \(err.localizedDescription)"
                }
                return base
            case let .pidLookupFailed(id):
                return "Could not determine PID for application '\(id)' after activation attempt."
            case let .newInstanceNotCreated(id, returnedPID):
                return "Application '\(id)' returned pre-existing PID \(returnedPID) while creating a new instance."
            case .unexpectedNilURL:
                return "Internal error: Application URL became nil unexpectedly."
            }
        }
    }
}

/// Controls how one exact application bundle is opened.
///
/// | Mode | App NOT running | App IS running |
/// |------|----------------|----------------|
/// | `launchOrActivate` | Launch new process + activate | Activate existing + bring to front |
/// | `forceNewInstance` | Launch new process + activate | Launch NEW process (separate PID) |
public enum AppLaunchMode: String, Codable, Sendable {
    /// Default: launch if not running, activate if running. Equivalent to `open -a App`.
    case launchOrActivate
    /// Always launch a new process, even if already running. Equivalent to `open -n -a App`.
    case forceNewInstance
}

/// Describes what action was taken when opening/activating an application.
public enum AppOpenAction: String, Codable, Sendable {
    /// A new process was launched (app was not running).
    case launchedNew
    /// An existing process was activated (app was already running).
    case activatedExisting
    /// The app was already active; no state change needed.
    case alreadyActive
    /// An existing process was reused without activation for a background open.
    case reusedExisting
}

/// Define the structure for the successful result
public struct AppOpenerResult: Codable, Sendable {
    public let pid: pid_t
    public let appName: String
    public let processingTimeSeconds: String
    /// What action was taken (launched new, activated existing, or already active).
    public let actionTaken: AppOpenAction
    /// Whether a new process was created (true for launchedNew and forceNewInstance).
    public let newProcessCreated: Bool
    /// Whether Launch Services reported the exact returned process active.
    public let active: Bool

    public init(
        pid: pid_t,
        appName: String,
        processingTimeSeconds: String,
        actionTaken: AppOpenAction,
        newProcessCreated: Bool,
        active: Bool = false,
    ) {
        self.pid = pid
        self.appName = appName
        self.processingTimeSeconds = processingTimeSeconds
        self.actionTaken = actionTaken
        self.newProcessCreated = newProcessCreated
        self.active = active
    }
}

/// --- Private Helper Class for State Management ---
/// Using a class instance allows managing state like stepStartTime across async calls
@MainActor
private class AppOpenerOperation {
    let applicationURL: URL
    let background: Bool
    let mode: AppLaunchMode
    let overallStartTime: Date = .init()
    var stepStartTime: Date

    init(applicationURL: URL, background: Bool, mode: AppLaunchMode) {
        self.applicationURL = applicationURL
        self.background = background
        self.mode = mode
        stepStartTime = overallStartTime
        logger.info("starting AppOpenerOperation for exact bundle URL: \(applicationURL.path, privacy: .private(mask: .hash)) background=\(background, privacy: .public) mode=\(mode.rawValue, privacy: .public)")
    }

    /// Helper to log step completion times (Method definition)
    func logStepCompletion(_ stepDescription: String) {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(stepStartTime)
        let durationStr = String(format: "%.3f", duration)
        logger.info("[\(durationStr, privacy: .public)s] finished '\(stepDescription, privacy: .public)'")
        stepStartTime = endTime // Reset for next step
    }

    /// Main logic function using async/await (Method definition)
    func execute() async throws -> AppOpenerResult {
        let workspace = NSWorkspace.shared
        let finalAppURL = try validatedApplicationBundleURL(applicationURL)
        let bundle = Bundle(url: finalAppURL)
        let finalAppName = resolveApplicationDisplayName(
            bundle: bundle,
            applicationURL: finalAppURL,
            fallbackIdentifier: finalAppURL.deletingPathExtension().lastPathComponent,
        )
        let exactPath = finalAppURL.path
        logStepCompletion("validating exact application bundle")

        // Only processes launched from this exact canonical bundle location
        // participate in disposition classification. A shared bundle ID is not
        // identity and must not collapse duplicate installations.
        let candidates = workspace.runningApplications.filter { application in
            guard application.processIdentifier > 0,
                  let bundleURL = application.bundleURL
            else {
                return false
            }
            return canonicalApplicationBundleURL(bundleURL) == finalAppURL
        }

        let preExistingPIDs = Set(candidates.map(\.processIdentifier))
        let preExistingActivePIDs = Set(candidates.filter(\.isActive).map(\.processIdentifier))
        logStepCompletion("snapshotting exact running bundle instances")

        logger.info(
            "attempting to open exact application bundle: \(exactPath, privacy: .private(mask: .hash)) (background=\(self.background, privacy: .public), mode=\(self.mode.rawValue, privacy: .public))",
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !self.background

        if self.mode == .forceNewInstance {
            configuration.createsNewApplicationInstance = true
        }

        do {
            let runningApp = try await workspace.openApplication(
                at: finalAppURL,
                configuration: configuration,
            )
            if !self.background {
                _ = runningApp.activate(options: [.activateIgnoringOtherApps])
            }
            let pidAfterOpen = runningApp.processIdentifier

            logStepCompletion("opening/activating application async call completed")

            // --- 4. Determine Final PID and Action ---
            let finalPID = pidAfterOpen
            let classification = try classifyApplicationOpen(
                mode: self.mode,
                background: self.background,
                returnedPID: finalPID,
                preExistingPIDs: preExistingPIDs,
                preExistingActivePIDs: preExistingActivePIDs,
                identifier: exactPath,
            )
            let actionTaken = classification.action
            let newProcessCreated = classification.newProcessCreated
            logger.info(
                "open observation: returned pid \(finalPID, privacy: .public), action \(actionTaken.rawValue, privacy: .public), pre-existing=\(preExistingPIDs.contains(finalPID), privacy: .public).",
            )
            logStepCompletion("determining final pid (using \(finalPID))")

            // --- 5. Prepare Result ---
            let endTime = Date()
            let processingTime = endTime.timeIntervalSince(overallStartTime)
            let formattedTime = String(format: "%.3f", processingTime)

            logger.info(
                "success: exact application bundle \(exactPath, privacy: .private(mask: .hash)) opened (pid: \(finalPID, privacy: .public), action: \(actionTaken.rawValue, privacy: .public)).",
            )
            logger.info("total processing time: \(formattedTime, privacy: .public) seconds")

            return AppOpenerResult(
                pid: finalPID,
                appName: finalAppName,
                processingTimeSeconds: formattedTime,
                actionTaken: actionTaken,
                newProcessCreated: newProcessCreated,
                active: runningApp.isActive,
            )

        } catch {
            logStepCompletion("opening/activating application (failed)")
            logger.error("activation call failed: \(error.localizedDescription, privacy: .public)")

            logger.error("Open or activation did not complete; refusing to infer success from a pre-existing PID.")
            let endTime = Date()
            let processingTime = endTime.timeIntervalSince(overallStartTime)
            let formattedTime = String(format: "%.3f", processingTime)
            logger.info("total processing time (on failure): \(formattedTime, privacy: .public) seconds")
            if let appOpenerError = error as? ExactMacError.AppOpenerError {
                throw appOpenerError
            }
            throw ExactMacError.AppOpenerError.activationFailed(
                identifier: exactPath, underlyingError: error,
            )
        }
    }
} // End of AppOpenerOperation class

/// Opens one exact macOS application bundle URL.
///
/// - Parameter applicationURL: Exact file URL of the application bundle.
/// - Parameter background: If true, the application is opened without being activated (brought to foreground). The user's current focus is preserved. Defaults to false (activates app).
/// - Returns: An `AppOpenerResult` containing the PID, application name, and processing time on success.
/// - Throws: `ExactMacError.AppOpenerError` if the application cannot be found, activated, or its PID determined.
@MainActor
public func openApplication(
    applicationURL: URL,
    background: Bool = false,
    mode: AppLaunchMode = .launchOrActivate,
) async throws -> AppOpenerResult {
    let operation = AppOpenerOperation(
        applicationURL: applicationURL,
        background: background,
        mode: mode,
    )
    return try await operation.execute()
}
