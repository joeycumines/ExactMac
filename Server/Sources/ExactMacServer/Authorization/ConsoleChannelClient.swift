import Darwin
import Foundation
import os

/// The console channel's client half: what the menu-bar app uses to receive requests and
/// post decisions.
///
/// IT AUTHENTICATES THE SERVER TOO, and that is not symmetry for its own sake. A one-way
/// authenticated channel is a channel any process that found the path can drive, and the
/// thing on the other end of a forged console is the operator's consent. So the client
/// presents its token AND requires the server to present one, and a server that does not is
/// refused before a single request is displayed.
final class ConsoleChannelClient: @unchecked Sendable {
    private let socketPath: String
    private let token: ConsoleChannelToken
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "console.channel",
    )
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var authenticated = false

    init(socketPath: String, token: ConsoleChannelToken) {
        self.socketPath = socketPath
        self.token = token
    }

    var isConnected: Bool {
        lock.withLock { descriptor >= 0 && authenticated }
    }

    /// How long a read may wait before the caller is told the channel is quiet.
    ///
    /// A read with no deadline would park the calling thread, and the caller is a SwiftUI
    /// main actor: a channel that could park it would freeze the menu-bar app for as long as
    /// the server had nothing to say.
    static let readTimeout: Duration = .milliseconds(250)

    /// How long the handshake may take before the server is assumed not to be a server.
    static let handshakeTimeout: Duration = .seconds(5)

    /// Connects and authenticates, in that order and both ways.
    ///
    /// ASYNC, and the socket work is off the caller's executor: this is called from the
    /// console's main actor and a blocking connect-and-handshake there would freeze the app
    /// for as long as a wedged server took to answer.
    ///
    /// - Throws: rather than returning a half-open client, because a console that believes it
    ///   is connected to something that is not would show a prompt nobody is watching.
    func connect() async throws {
        try await Task.detached { [self] in try connectBlocking() }.value
    }

    private func connectBlocking() throws {
        let connection = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "socket failed with errno \(errno)")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(connection)
            throw ConsoleChannelError.unavailable(reason: "the console socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { chars in
                for (index, byte) in pathBytes.enumerated() {
                    chars[index] = CChar(bitPattern: byte)
                }
                chars[pathBytes.count] = 0
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
        // The server's token first. A server that will not identify itself is not a server
        // this console talks to, and a display of operator consent is exactly the thing that
        // must not be shown to a process that merely answered on the path. A server that
        // says NOTHING is also refused, on a deadline rather than by blocking.
        guard case .readable = SocketWait.waitReadable(
            connection, timeout: ConsoleChannelClient.handshakeTimeout,
        ) else {
            Darwin.close(connection)
            throw ConsoleChannelError.unauthenticated
        }
        guard case let .hello(hello) = try FrameReader.readFrame(from: connection),
              hello.version == ConsoleHello.currentVersion,
              token.matches(hello.token)
        else {
            Darwin.close(connection)
            throw ConsoleChannelError.unauthenticated
        }
        // Then ours.
        try FrameReader.write(
            .hello(ConsoleHello(token: Self.tokenText(token), version: ConsoleHello.currentVersion)),
            to: connection,
        )
        lock.withLock {
            descriptor = connection
            authenticated = true
        }
        logger.info("Connected to the ExactMac server's consent channel.")
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

    /// Reads the next frame the server sends, or nil when the channel closes or is quiet.
    ///
    /// A quiet channel is nil and not an error, because a menu-bar console spends almost all
    /// of its life waiting and a timeout is the normal case rather than a fault.
    func receive() async throws -> ConsoleFrame? {
        try await Task.detached { [self] in try receiveBlocking() }.value
    }

    /// The next frame, or nil if none arrives inside the read window.
    func nextFrame(timeout: Duration) async throws -> ConsoleFrame? {
        try await Task.detached { [self] in try readWithin(timeout) }.value
    }

    private func receiveBlocking() throws -> ConsoleFrame? {
        try readWithin(ConsoleChannelClient.readTimeout)
    }

    /// The one place a frame is read, so the deadline is not optional anywhere.
    private func readWithin(_ timeout: Duration) throws -> ConsoleFrame? {
        let connection = lock.withLock { descriptor }
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "the console is not connected")
        }
        switch SocketWait.waitReadable(connection, timeout: timeout) {
        case .readable:
            return try FrameReader.readFrame(from: connection)
        case .timedOut, .closed:
            return nil
        case let .failed(code):
            throw ConsoleChannelError.unavailable(reason: "poll failed with errno \(code)")
        }
    }

    /// Posts the operator's answer.
    ///
    /// - Throws: when the channel is gone, which the caller must treat as a DENIAL. A
    ///   decision that could not be delivered is not a decision, and treating it as one
    ///   would let a console that lost its socket authorize something the operator agreed to
    ///   a prompt nobody can see.
    func post(_ decision: ConsentDecision) async throws {
        try await Task.detached { [self] in try postBlocking(decision) }.value
    }

    private func postBlocking(_ decision: ConsentDecision) throws {
        let connection = lock.withLock { descriptor }
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "the console is not connected")
        }
        try FrameReader.write(.decision(decision), to: connection)
    }

    /// Asks for something the server owns.
    func query(_ kind: QueryKind) async throws {
        try await Task.detached { [self] in try queryBlocking(kind) }.value
    }

    private func queryBlocking(_ kind: QueryKind) throws {
        let connection = lock.withLock { descriptor }
        guard connection >= 0 else {
            throw ConsoleChannelError.unavailable(reason: "the console is not connected")
        }
        try FrameReader.write(.query(kind), to: connection)
    }

    private static func tokenText(_ token: ConsoleChannelToken) -> String {
        if case let .shared(value) = token {
            return value
        }
        return ""
    }
}
