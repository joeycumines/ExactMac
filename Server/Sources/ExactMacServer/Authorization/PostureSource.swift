import Foundation
import Synchronization

/// THE OPERATOR'S STANDING CHOICE, LIVE.
///
/// The posture is enforcement state and is re-derived PER REQUEST — never cached in a
/// decision, because a decision already made must not change when the operator changes
/// their mind. `AuthorizationRuntime.posture` was a value captured at construction, so
/// the console's settings control had nothing real to write into: the interceptor read a
/// frozen copy of the posture the server started with, and the control was a lie.
///
/// THE SOURCE IS A MUTEX-WRAPPED VALUE with a read the interceptor consults at
/// evaluation time and a write the console's settings control performs. It is Sendable
/// because it is read from every RPC and written from the main actor; the mutex is the
/// whole synchronization story, and there is no cache to invalidate because nothing
/// caches.
///
/// THE ENVIRONMENT OVERRIDE LIVES ABOVE THE STORE, not beside it: `EXACTMAC_POSTURE`,
/// when set, is a deployment-level statement that wins over an operator preference, so a
/// headless or LaunchAgent deployment keeps the posture it was configured with no matter
/// what a console in the same process writes. The stored preference is what the operator
/// chose in the console; the override is what the deployment chose at launch; the
/// fallback is `.strict`, which is the engine's own default and the fail-closed
/// direction.
public final class PostureSource: Sendable {
    private let stored = Mutex<Posture?>(nil)
    private let override: Posture?

    /// `override` is the posture the ENVIRONMENT named, or nil when it named none. It is
    /// fixed for the life of the process: an environment variable does not change under a
    /// running deployment, and pretending it could would make the control's meaning
    /// depend on when it was read.
    public init(override: Posture?) {
        self.override = override
    }

    /// The posture actually in force, read at the moment a decision needs it.
    public var current: Posture {
        if let override {
            return override
        }
        return stored.withLock { $0 } ?? .strict
    }

    /// Whether the environment override holds, which the control states when it does —
    /// an operator changing a setting that is not taking effect deserves to be told why.
    public var isOverriddenByEnvironment: Bool {
        override != nil
    }

    /// The operator's own choice, which is what the control displays when no override
    /// holds. NIL when nothing has been stored, which is the initial-display truth: the
    /// control shows the fallback the engine actually applies, not a preference nobody
    /// expressed.
    public var storedPreference: Posture? {
        stored.withLock { $0 }
    }

    /// Records the operator's choice. The write is durable through `persist` and takes
    /// effect on the NEXT request, because the interceptor reads `current` per request.
    public func setStoredPreference(_ posture: Posture) {
        stored.withLock { $0 = posture }
    }

    // MARK: Persistence

    /// The file the stored preference survives in, beside the grant store and the audit
    /// log in the state directory the server already owns at 0700. THE OVERRIDE IS NOT
    /// PERSISTED — it is read from the environment every launch, so persisting it would
    /// make a deployment setting survive the deployment that set it.
    public static func storedPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ExactMacRuntimePaths.stateDirectory(environment: environment) + "/posture.json"
    }

    /// Writes the stored preference to disk, at 0600 in the 0700 state directory. THE
    /// WRITE IS NOT TEMP-AND-RENAME ATOMIC: the file is truncated in place, so a crash
    /// mid-write can leave it short. That residual is accepted deliberately, because the
    /// read side fails closed — a truncated file parses as nothing and the preference
    /// falls back to strict, which is the safe direction — while a rename-based write
    /// would need the recovery discipline `DecisionAudit` carries, which a preference
    /// whose worst case is "the operator re-picks strict" does not justify. A FAILED
    /// PERSIST DOES NOT FAIL THE WRITE — the in-memory preference is already in force
    /// for every later request, and the honest report of a failed persist is that the
    /// choice will not survive a relaunch, which is what the caller is told.
    public func persist(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let path = Self.storedPath(environment: environment)
        let posture = stored.withLock { $0 }
        let body = "{\"posture\":\"\(posture?.rawValue ?? "")\"}"
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

    /// Reads a stored preference written by `persist`. NIL when the file is absent,
    /// unreadable, or does not name one of the three postures — an unreadable preference
    /// file is NOT a preference, and the fallback is the engine's own strict rather than
    /// a guess. It does NOT read the override: the environment is consulted separately,
    /// at construction, and wins regardless of what is stored.
    public static func loadStoredPreference(
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Posture? {
        let path = storedPath(environment: environment)
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = object["posture"]
        else {
            return nil
        }
        return Posture(rawValue: raw)
    }
}
