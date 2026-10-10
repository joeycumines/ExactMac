import Darwin
import Foundation

/// Centralized macOS Application Support and runtime paths for ExactMac.
///
/// Follows standard macOS platform conventions:
/// - Base Directory: `~/Library/Application Support/ExactMac` (mode 0700)
/// - Audit Log: `~/Library/Application Support/ExactMac/audit.log` (mode 0600)
/// - Unix Domain Socket: `~/Library/Application Support/ExactMac/exactmac.sock`
/// - Preferences: `UserDefaults(suiteName: "com.exactmac.console")`
/// - Grants & Envelopes: Pure in-memory (Standing Invariant 12)
public enum ExactMacPaths {
    public static let defaultDirectoryName = "ExactMac"

    /// Resolves the Application Support directory.
    /// Can be overridden via environment variable `EXACTMAC_APP_SUPPORT_DIR` or `EXACTMAC_STATE_DIRECTORY` for tests.
    public static func applicationSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment["EXACTMAC_APP_SUPPORT_DIR"], !override.isEmpty {
            return override
        }
        if let override = environment["EXACTMAC_STATE_DIRECTORY"], !override.isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return (appSupport as NSString).appendingPathComponent(defaultDirectoryName)
    }

    /// Alias for backwards compatibility with tests and callers expecting stateDirectory.
    public static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        applicationSupportDirectory(environment: environment)
    }

    /// Resolves the hash-chained decision audit log path.
    public static func auditLogPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment["EXACTMAC_AUDIT_LOG_PATH"], !override.isEmpty {
            return override
        }
        return (applicationSupportDirectory(environment: environment) as NSString).appendingPathComponent("audit.log")
    }

    /// Resolves the Unix domain socket path.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        if let override = environment["EXACTMAC_SOCKET"], !override.isEmpty {
            return override
        }
        if let override = environment["GRPC_UNIX_SOCKET"], !override.isEmpty {
            return override
        }
        return (applicationSupportDirectory(environment: environment) as NSString).appendingPathComponent("exactmac.sock")
    }

    /// Ensures the Application Support directory exists at mode 0700 (owner-only).
    public static func prepareApplicationSupportDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        let path = applicationSupportDirectory(environment: environment)
        var info = stat()
        if path.withCString({ lstat($0, &info) }) == 0 {
            guard info.st_mode & mode_t(0o170000) == mode_t(0o040000) else {
                throw ExactMacRuntimeError.statePathIsNotADirectory(path)
            }
            guard info.st_uid == geteuid() else {
                throw ExactMacRuntimeError.stateDirectoryHasWrongOwner(path, actual: info.st_uid)
            }
            let permissions = info.st_mode & 0o777
            guard permissions == 0o700 else {
                throw ExactMacRuntimeError.stateDirectoryIsNotOwnerOnly(path, actual: permissions)
            }
            return
        }
        guard errno == ENOENT else {
            throw ExactMacRuntimeError.systemCall(operation: "lstat", path: path, code: errno)
        }
        guard mkdir(path, 0o700) == 0 else {
            throw ExactMacRuntimeError.systemCall(operation: "mkdir", path: path, code: errno)
        }
    }

    /// Alias for backwards compatibility with tests and callers expecting prepareStateDirectory.
    public static func prepareStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        try prepareApplicationSupportDirectory(environment: environment)
    }
}

/// Backwards compatibility alias
public typealias ExactMacRuntimePaths = ExactMacPaths

public enum ExactMacRuntimeError: Error, CustomStringConvertible {
    case statePathIsNotADirectory(String)
    case stateDirectoryHasWrongOwner(String, actual: uid_t)
    case stateDirectoryIsNotOwnerOnly(String, actual: mode_t)
    case systemCall(operation: String, path: String, code: Int32)
    case auditUnavailable(reason: String)
    case grantStoreUnavailable(reason: String)

    public var description: String {
        switch self {
        case let .statePathIsNotADirectory(path):
            "\(path) exists and is not a directory"
        case let .stateDirectoryHasWrongOwner(path, actual):
            "\(path) is owned by uid \(actual); refusing to use a directory this user does not own"
        case let .stateDirectoryIsNotOwnerOnly(path, actual):
            "\(path) has permissions 0\(String(actual, radix: 8)); expected 0700"
        case let .systemCall(operation, path, code):
            "\(operation) failed for \(path): errno \(code)"
        case let .auditUnavailable(reason):
            "the decision audit is unavailable: \(reason)"
        case let .grantStoreUnavailable(reason):
            "the grant store is unavailable: \(reason)"
        }
    }
}
