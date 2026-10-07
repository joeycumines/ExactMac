import Foundation
import Synchronization

/// WHETHER OPENING THE CONSOLE'S REVEALING SURFACES COSTS A FINGERPRINT, LIVE.
///
/// The console's settings row "Require Touch ID to open the console" governs exactly two
/// surfaces — Grants and Activity, which are "what is permitted and what was asked" per the
/// row's own detail text — and nothing else. Settings stays reachable so turning the gate
/// back on costs ONE ceremony, not two, and the approval prompt is never gated, because
/// consent must not be able to deadlock on its own protection.
///
/// THE SOURCE IS A MUTEX-WRAPPED VALUE, the same shape as `PostureSource`, for the same
/// reason: the gate is read wherever an open is attempted and written by the console's
/// toggle, and there is no cache to invalidate because nothing caches. It is `Sendable`
/// because it is written from the main actor and read wherever the console asks.
///
/// THE DEFAULT IS TRUE, AND EVERY FAILURE READS AS THE DEFAULT: a missing file, an
/// unreadable file, a malformed file, and an unknown spelling all mean "the ceremony is
/// required". A gate that failed open on a corrupt file would hand a silent downgrade to
/// whoever arranged the corruption, so it cannot.
public final class BiometricGateSource: Sendable {
    private let gateOpen = Mutex<Bool>(true)

    /// `true` when opening Grants or Activity costs a ceremony, which is the default.
    public var isCeremonyRequired: Bool {
        gateOpen.withLock { $0 }
    }

    /// Records the operator's choice. `true` restores the ceremony; `false` is the
    /// downgrade, and it is the CALLER's job to have made sure a successful ceremony
    /// happened before this is called — the source stores what it is told, because the
    /// ceremony discipline lives with the decision, not with the storage.
    public func setCeremonyRequired(_ required: Bool) {
        gateOpen.withLock { $0 = required }
    }

    // MARK: Persistence

    /// The file the gate survives in, beside the posture preference in the state directory
    /// the server already owns at 0700. THE FILE MODE IS 0600: a same-uid process can read
    /// it, which is the residual the state directory already accepts for `posture.json` and
    /// the grant store — the threat the gate answers is a DIFFERENT person at the keyboard,
    /// not a process running as the operator.
    public static func storedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> String {
        ExactMacRuntimePaths.stateDirectory(environment: environment) + "/console-biometrics.json"
    }

    /// Writes the gate to disk, atomically in the write-loop sense, at 0600. A FAILED
    /// PERSIST DOES NOT FAIL THE WRITE — the in-memory gate is already in force for every
    /// later open, and the honest report of a failed persist is that the choice will not
    /// survive a relaunch, which the caller is told.
    public func persist(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let path = Self.storedPath(environment: environment)
        let required = gateOpen.withLock { $0 }
        let body = "{\"ceremonyRequired\":\(required)}"
        let data = Data(body.utf8)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ExactMacRuntimeError.systemCall(operation: "open", path: path, code: errno)
        }
        defer { close(descriptor) }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return 0 }
                return Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            throw ExactMacRuntimeError.systemCall(operation: "write", path: path, code: errno)
        }
        guard fsync(descriptor) == 0 else {
            throw ExactMacRuntimeError.systemCall(operation: "fsync", path: path, code: errno)
        }
    }

    /// Reads a stored gate written by `persist`. TRUE when the file is absent, unreadable,
    /// malformed, or carries an unknown spelling — an unreadable preference is NOT a
    /// preference, and the fallback is the ceremony, which is the fail-closed direction.
    public static func loadStoredGate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        let path = storedPath(environment: environment)
        guard let data = FileManager.default.contents(atPath: path) else {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["ceremonyRequired"]
        else {
            return true
        }
        // A JSON boolean and the NUMBER 0 or 1 are different values, and the distinction
        // is load-bearing: JSONSerialization materialises both as NSNumber, and Swift's
        // `NSNumber(0) as? Bool` SUCCEEDS — reading `{"ceremonyRequired":0}` as a stored
        // `false` would let a number spelling turn the ceremony off. The gate only
        // accepts a value Core Foundation can vouch for as a real `CFBoolean`.
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return true
        }
        return number.boolValue
    }
}
