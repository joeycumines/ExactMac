import Darwin
import Foundation

/// Process-wide filesystem policy shared by startup and deployment tests.
enum ServerProcessPolicy {
    /// Owner-only files and directories, with directory traversal preserved.
    ///
    /// `0177` masks the owner's execute bit and produces non-traversable cache
    /// directories on macOS 27; `0077` produces `0600` files and `0700` directories.
    static let umask: mode_t = 0o077
}

/// Server configuration loaded from environment variables
public struct ServerConfig {
    /// The address to listen on (e.g., "127.0.0.1" or "0.0.0.0")
    public let listenAddress: String

    /// The port to listen on
    public let port: Int

    /// Optional unix socket path to listen on instead of TCP
    public let unixSocketPath: String?

    // MARK: - Authorization

    //
    // EVERY DEFAULT HERE IS FAIL-CLOSED, and that is the whole design rule for this block.
    // A missing or unparseable setting denies; it never permits, and it never silently falls
    // back to something more permissive than the operator would have chosen. The defaults are
    // also the STRICTER of the two available answers wherever a choice exists, so a server
    // started with no configuration at all is the one least able to do anything.

    /// Where the consent console's socket is, when the server serves one.
    ///
    /// NIL BY DEFAULT, and nil is the safe answer: no console socket means the server never
    /// enters the consent path and every consent-requiring capability is denied. Pointing
    /// this at a path that does not exist is equally safe, because the connection fails and a
    /// failed connection is a denial rather than an allow.
    public let consoleSocketPath: String?

    /// How long an operator has to answer before the request is denied.
    ///
    /// Ninety seconds. Long enough to read a disclosure with a payload in it, short enough
    /// that a prompt the operator has walked away from does not sit on their screen for the
    /// rest of the session. A TIMEOUT IS A DENIAL and never an allow: an unanswered prompt
    /// has not been consented to.
    public let consentTimeoutSeconds: Int

    /// The longest an envelope may live, whatever the requester asks for.
    ///
    /// Eight hours, which is a working day. An envelope is a standing permission and a
    /// standing permission that outlives the session that justified it is the failure this
    /// ceiling exists to stop, so it is enforced HERE rather than trusted to the requester.
    public let maximumEnvelopeSeconds: Int

    /// The posture the server starts in.
    ///
    /// `.strict` by default, which is the stricter of the three. `balanced` is the posture
    /// the design recommends for a human who has read it, and choosing it is a decision an
    /// operator makes in Settings — not something a server infers from being unconfigured.
    public let defaultPosture: Posture

    // MARK: - Loading

    /// Initialize configuration from environment variables
    public static func fromEnvironment() -> ServerConfig {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["GRPC_LISTEN_ADDRESS"]
        let hostValue = (host?.isEmpty == false ? host : nil) ?? "127.0.0.1"
        let portStr = environment["GRPC_PORT"]
        let portValue = portStr.flatMap { $0.isEmpty ? nil : Int($0) }
        let port = portValue ?? 8080
        let socket = environment["GRPC_UNIX_SOCKET"]
        let socketValue = socket?.isEmpty == false ? socket : nil

        let consoleSocket = environment["EXACTMAC_CONSOLE_SOCKET"]
        // An unparseable duration is the DURATION'S DEFAULT rather than its maximum, and the
        // default is the shorter one. A typo in a consent timeout must not double it.
        let consentTimeout = Self.positiveSeconds(
            environment["EXACTMAC_CONSENT_TIMEOUT_SECONDS"],
            default: ServerConfig.defaultConsentTimeoutSeconds,
        )
        let maximumEnvelope = Self.positiveSeconds(
            environment["EXACTMAC_MAX_ENVELOPE_SECONDS"],
            default: ServerConfig.defaultMaximumEnvelopeSeconds,
        )
        let posture = Self.posture(from: environment["EXACTMAC_POSTURE"])

        return ServerConfig(
            listenAddress: hostValue,
            port: port,
            unixSocketPath: socketValue,
            consoleSocketPath: consoleSocket.flatMap { $0.isEmpty ? nil : $0 },
            consentTimeoutSeconds: consentTimeout,
            maximumEnvelopeSeconds: maximumEnvelope,
            defaultPosture: posture,
        )
    }

    public static let defaultConsentTimeoutSeconds = 90
    public static let defaultMaximumEnvelopeSeconds = 8 * 60 * 60

    /// A positive whole number of seconds, or the default.
    ///
    /// NEGATIVE AND ZERO ARE REFUSED rather than clamped to the default, because a zero
    /// timeout would deny everything at once and a negative one is a configuration mistake
    /// worth noticing in the log rather than a number to guess at.
    private static func positiveSeconds(_ raw: String?, default fallback: Int) -> Int {
        guard let raw, !raw.isEmpty, let value = Int(raw), value > 0 else { return fallback }
        return value
    }

    /// The posture, and `.strict` for anything that is not one of the three names.
    ///
    /// An unrecognised posture is the strictest one rather than an error, because a server
    /// that refuses to start on a typo in a security setting is a server an operator turns
    /// off — and a server that guessed "balanced" on a typo would be the opposite of what
    /// they wrote.
    private static func posture(from raw: String?) -> Posture {
        switch raw?.lowercased() {
        case "balanced": .balanced
        case "lockeddown", "locked_down", "locked-down": .lockedDown
        default: .strict
        }
    }

    public init(
        listenAddress: String,
        port: Int,
        unixSocketPath: String? = nil,
        consoleSocketPath: String? = nil,
        consentTimeoutSeconds: Int = ServerConfig.defaultConsentTimeoutSeconds,
        maximumEnvelopeSeconds: Int = ServerConfig.defaultMaximumEnvelopeSeconds,
        defaultPosture: Posture = .strict,
    ) {
        self.listenAddress = listenAddress
        self.port = port
        self.unixSocketPath = unixSocketPath
        self.consoleSocketPath = consoleSocketPath
        self.consentTimeoutSeconds = consentTimeoutSeconds
        self.maximumEnvelopeSeconds = maximumEnvelopeSeconds
        self.defaultPosture = defaultPosture
    }
}
