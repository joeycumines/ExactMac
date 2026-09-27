import Foundation

/// The console half of the consent channel.
///
/// IT AUTHENTICATES THE SERVER TOO, and that is not symmetry for its own sake. A one-way
/// authenticated channel is a channel any process that found the path can drive, and the
/// thing on the other end of a forged console is the operator's consent. So the client
/// requires the server's token BEFORE it presents its own — a console talking to a process
/// that cannot produce the token learns nothing, because it never spoke.
///
/// EVERY READ IS DEADLINED. A blocking read on a socket with no data parks the thread
/// forever, and the caller is the menu-bar app's main actor: a channel that could park it
/// would freeze the UI for as long as the server had nothing to say.
final class ConsoleChannelClient: @unchecked Sendable {
    private let socketPath: String
    private let token: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var authenticated = false
    private var buffer = Data()

    static let readTimeout: Duration = .milliseconds(250)
    static let handshakeTimeout: Duration = .seconds(5)

    init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    /// The production client, configured the way the deployment documents it.
    static func live() -> ConsoleChannelClient {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConsoleChannelClient(
            socketPath: "\(home.path)/Library/Application Support/ExactMac/console.sock",
            // Read from the owner-private file, never from the environment: an environment
            // variable is readable from the environment of every process the operator starts
            // and is inherited by every child, which is a far larger surface than a 0600 file.
            token: (try? String(
                contentsOfFile: "\(home.path)/Library/Application Support/ExactMac/console.token",
                encoding: .utf8,
            ))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        )
    }

    var isConnected: Bool {
        lock.withLock { descriptor >= 0 && authenticated }
    }

    /// Connects and authenticates, off the caller's executor.
    func connect() async throws {
        try await Task.detached { [self] in try connectBlocking() }.value
    }

    private func connectBlocking() throws {
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "socket failed with errno \(errno)")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(connection)
            throw ConsoleChannelError.unavailable(reason: "the console socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                for (index, byte) in bytes.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
                chars[bytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connected == 0 else {
            Darwin.close(connection)
            throw ConsoleChannelError.unavailable(reason: "connect failed with errno \(errno)")
        }
        // The server's token first. A server that will not identify itself, or that says
        // nothing at all, is refused on a DEADLINE rather than by blocking.
        guard case .readable = SocketWait.waitReadable(
            connection, timeout: ConsoleChannelClient.handshakeTimeout,
        ) else {
            Darwin.close(connection)
            throw ConsoleChannelError.unauthenticated
        }
        guard case let .hello(hello) = try FrameReader.readFrame(from: connection),
              hello.version == ConsoleHello.currentVersion,
              ConsoleToken.matches(token, hello.token)
        else {
            Darwin.close(connection)
            throw ConsoleChannelError.unauthenticated
        }
        try FrameReader.write(
            .hello(ConsoleHello(token: token, version: ConsoleHello.currentVersion)),
            to: connection,
        )
        lock.withLock {
            descriptor = connection
            authenticated = true
        }
    }

    /// The next frame, or nil when the channel is quiet or has gone.
    ///
    /// A quiet channel is nil and not an error: a menu-bar console spends almost all of its
    /// life waiting, and a timeout is the normal case rather than a fault.
    func nextFrame(timeout: Duration) async throws -> ConsoleFrame? {
        try await Task.detached { [self] in try readWithin(timeout) }.value
    }

    private func readWithin(_ timeout: Duration) throws -> ConsoleFrame? {
        let connection = lock.withLock { descriptor }
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "the console is not connected")
        }
        switch SocketWait.waitReadable(connection, timeout: timeout) {
        case .readable: return try FrameReader.readFrame(from: connection)
        case .timedOut, .closed: return nil
        case let .failed(code):
            throw ConsoleChannelError.unavailable(reason: "poll failed with errno \(code)")
        }
    }

    func post(_ decision: ConsentDecision) async throws {
        try await Task.detached { [self] in try write(.decision(decision)) }.value
    }

    func query(_ kind: QueryKind) async throws {
        try await Task.detached { [self] in try write(.query(kind)) }.value
    }

    private func write(_ frame: ConsoleFrame) throws {
        let connection = lock.withLock { descriptor }
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "the console is not connected")
        }
        try FrameReader.write(frame, to: connection)
    }

    func disconnect() {
        let connection = lock.withLock { () -> Int32 in
            authenticated = false
            let current = descriptor
            descriptor = -1
            return current
        }
        if connection >= 0 {
            _ = Darwin.close(connection)
        }
    }
}
