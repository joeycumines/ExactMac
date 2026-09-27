import Darwin
@testable import ExactMacServer
import Foundation
import Testing

@Suite(.serialized)
struct ServerLifecycleTests {
    @Test
    func `shutdown signal begins drain and waits for server completion`() async throws {
        let serverRelease = AsyncStream.makeStream(of: Void.self)
        let shutdownStarted = AsyncStream.makeStream(of: Void.self)
        let cleanupRelease = AsyncStream.makeStream(of: Void.self)
        let signals = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1),
        )
        let recorder = LifecycleShutdownRecorder()
        let mutationGate = PhysicalDesktopMutationGate()
        let serverTask = Task<Void, any Error> {
            var iterator = serverRelease.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let lifecycleTask = Task {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: {
                    await mutationGate.beginDraining()
                    recorder.record()
                    shutdownStarted.continuation.yield(())
                    shutdownStarted.continuation.finish()
                    var iterator = cleanupRelease.stream.makeAsyncIterator()
                    _ = await iterator.next()
                },
            )
        }

        signals.continuation.yield(SIGTERM)
        var shutdownIterator = shutdownStarted.stream.makeAsyncIterator()
        _ = await shutdownIterator.next()

        #expect(recorder.snapshot() == 1)
        #expect(await mutationGate.lifecycleState() == .drained)

        serverRelease.continuation.yield(())
        serverRelease.continuation.finish()
        cleanupRelease.continuation.yield(())
        cleanupRelease.continuation.finish()
        try await lifecycleTask.value

        do {
            try await mutationGate.withExclusiveOperation {}
            Issue.record("Expected shutdown to close physical mutation admission")
        } catch let error as PhysicalDesktopMutationError {
            #expect(error == .admissionClosed)
        }
        signals.continuation.finish()
    }

    @Test
    func `serve failure propagates without pretending graceful shutdown`() async throws {
        let signals = AsyncStream.makeStream(of: Int32.self)
        let recorder = LifecycleShutdownRecorder()
        let serverTask = Task<Void, any Error> {
            throw InjectedServerLifecycleError.serveFailure
        }

        do {
            try await waitForServerTermination(
                serverTask: serverTask,
                shutdownSignals: signals.stream,
                beginGracefulShutdown: { recorder.record() },
            )
            Issue.record("Expected serve failure")
        } catch InjectedServerLifecycleError.serveFailure {
            // Expected exact production status propagation.
        }

        #expect(recorder.snapshot() == 0)
        signals.continuation.finish()
    }

    // MARK: - The socket node the server owns

    // The server binds its own Unix socket, so the node at that pathname is the server's to
    // manage, and the policy is the opposite of the one that applied while launchd created
    // it: a node left behind by a crash is RECLAIMED, because a server that cannot restart
    // after a crash needs an operator, and a pathname a live server holds is REFUSED,
    // because taking it would leave two listeners on one name. The claim is an advisory lock
    // the kernel releases when the holder dies, which is what makes "a live server" a fact
    // rather than a guess.

    @Test
    func `an absent Unix path needs no reclamation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("absent")).path

        let claim = try UnixSocketNode.claim(path)
        defer { try? claim.release() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `a stale Unix socket is reclaimed`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("stale")).path

        let staleDescriptor = try bindListeningSocket(at: path)
        // A crash or a reboot: the process is gone, the pathname is not. The kernel released
        // its lock with it, which is the whole reason the claim can be taken.
        _ = Darwin.close(staleDescriptor)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path) == false)

        let claim = try UnixSocketNode.claim(path)
        defer { try? claim.release() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `a live Unix socket is refused and its node is left alone`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("live")).path

        // The order production uses: the claim takes the pathname, and the bind then puts the
        // node back. A listener that is running therefore has BOTH a live claim and a node,
        // which is the state a second server has to be refused by.
        let live = try UnixSocketNode.claim(path)
        defer { try? live.release() }
        let liveDescriptor = try bindListeningSocket(at: path)
        defer { _ = Darwin.close(liveDescriptor) }
        #expect(canConnect(to: path))

        // A second server on the same pathname is refused, and refusing is NON-DESTRUCTIVE:
        // the node belongs to the first, so this one removes nothing on the way out either.
        #expect(throws: UnixSocketNodeError.pathAlreadyClaimed(path)) {
            _ = try UnixSocketNode.claim(path)
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path))
    }

    @Test
    func `a busy Unix listener is still recognised as live`() throws {
        // The accept queue is never drained, so a non-blocking connect to a LIVE listener
        // reports ECONNREFUSED — the same errno a socket with no listener reports. The
        // connect() probe this replaced would therefore have unlinked a busy server's node.
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("busy")).path

        let live = try UnixSocketNode.claim(path)
        defer { try? live.release() }
        let liveDescriptor = try bindListeningSocket(at: path, backlog: 1)
        defer { _ = Darwin.close(liveDescriptor) }

        let fill = try connectWithoutBlocking(to: path)
        defer { _ = Darwin.close(fill) }
        #expect(canConnectNonBlocking(to: path) == false, "the second connect must be refused")
        #expect(throws: UnixSocketNodeError.pathAlreadyClaimed(path)) {
            _ = try UnixSocketNode.claim(path)
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `a non-socket at the Unix path is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("nonsocket")).path
        let marker = Data("preserve-me".utf8)
        try marker.write(to: URL(fileURLWithPath: path))

        #expect(throws: UnixSocketNodeError.pathIsNotASocket(path)) {
            _ = try UnixSocketNode.claim(path)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == marker)
    }

    @Test
    func `a symlink at the Unix path is refused without following`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let marker = Data("preserve-me".utf8)
        try marker.write(to: target)
        let link = directory.appendingPathComponent(socketName("symlink"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // `lstat` never follows a symlink, so the link itself is what is found, and a link
        // is not a socket: nothing beyond the link is read and nothing is removed.
        #expect(throws: UnixSocketNodeError.pathIsNotASocket(link.path)) {
            _ = try UnixSocketNode.claim(link.path)
        }
        #expect(try Data(contentsOf: target) == marker)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test
    func `a directory at the Unix path is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdir = directory.appendingPathComponent(socketName("dir"), isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)

        #expect(throws: UnixSocketNodeError.pathIsNotASocket(subdir.path)) {
            _ = try UnixSocketNode.claim(subdir.path)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test
    func `a leftover socket readable by others is reclaimed and then hardened`() throws {
        // The mode of a node this process did not create is a property of the run that
        // crashed, so requiring it owner-only would make a server that crashed under a
        // permissive umask permanently unrestartable without an operator. What matters is
        // that the node is this user's socket, and that the node the bind goes on to create
        // is owner-only.
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("others")).path

        let stale = try bindListeningSocket(at: path)
        _ = Darwin.close(stale)
        _ = path.withCString { chmod($0, 0o666) }
        #expect(try nodeMode(at: path) == 0o666)

        let claim = try UnixSocketNode.claim(path)
        defer { try? claim.release() }
        let descriptor = try bindListeningSocket(at: path)
        defer { _ = Darwin.close(descriptor) }
        try UnixSocketNode.hardenBoundNode(at: path)
        #expect(try nodeMode(at: path) == 0o600)
    }

    @Test
    func `a bound node is made owner-only and released only while it still is`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("release")).path

        let claim = try UnixSocketNode.claim(path)
        let descriptor = try bindListeningSocket(at: path)
        defer { _ = Darwin.close(descriptor) }
        let marker = Data("not-a-socket".utf8)

        // Whatever umask the test process inherited, the node ends up owner-only.
        try UnixSocketNode.hardenBoundNode(at: path)
        #expect(try nodeMode(at: path) == 0o600)

        // A node that is no longer a socket is REPORTED rather than removed. The pathname
        // is mutable, so being a socket this user owns is the evidence that it is still the
        // node the process bound; without it, releasing is deleting whatever is at a path.
        _ = path.withCString { unlink($0) }
        try marker.write(to: URL(fileURLWithPath: path))
        #expect(throws: UnixSocketNodeError.pathIsNotASocket(path)) {
            try UnixSocketNode.unlinkSocketNode(at: path)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == marker)

        // Put the node back, because releasing removes this process's node and must not
        // remove a stranger's file that has taken the pathname since.
        _ = path.withCString { unlink($0) }
        let restored = try bindListeningSocket(at: path)
        _ = Darwin.close(restored)
        try claim.release()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: SocketPathClaim.ownerNodePath(forSocketPath: path)))
    }

    @Test
    func `a node whose mode is not yet owner-only is hardened rather than refused`() throws {
        // The regression this pins: `hardenBoundNode` used to REQUIRE the mode it exists to
        // establish. A process whose umask is not 0077 binds a 0755 node, so the check
        // refused the node the bind had just created and threw out of makeListeningChannel
        // with the listener already bound — abandoning an accepted child whose configured
        // channel nothing consumed, which SwiftNIO answers with a process-killing Fatal
        // error rather than a readable failure. The umask here is this test process's, which
        // is not the server's, which is exactly the case the check got wrong.
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(socketName("harden")).path

        let claim = try UnixSocketNode.claim(path)
        defer { try? claim.release() }
        let descriptor = try bindListeningSocket(at: path)
        defer { _ = Darwin.close(descriptor) }
        _ = path.withCString { chmod($0, 0o755) }
        #expect(try nodeMode(at: path) == 0o755)

        try UnixSocketNode.hardenBoundNode(at: path)
        #expect(try nodeMode(at: path) == 0o600)
        #expect(canConnect(to: path), "hardening the node must not disturb the listener")
    }

    @Test
    func `releasing an absent node is not an error`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try UnixSocketNode.unlinkSocketNode(at: directory.appendingPathComponent(socketName("gone")).path)
    }
}

/// A per-test socket name inside a shared short directory. Unique because two tests sharing
/// a pathname would make "the node is still there" ambiguous between them.
private func socketName(_ label: String) -> String {
    "s-\(label)-\(abs(UUID().uuidString.hashValue) % 100_000).sock"
}

private func nodeMode(at path: String) throws -> mode_t {
    var status = stat()
    guard path.withCString({ lstat($0, &status) }) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    return status.st_mode & 0o777
}

private func makeShortSocketDirectory() throws -> URL {
    let directory = URL(
        fileURLWithPath: "/tmp/exactmac-\(UUID().uuidString.prefix(8))",
        isDirectory: true,
    )
    // NOT `withIntermediateDirectories`, and not tolerated if it already exists: a shared
    // directory would let one test's node be another's evidence, and this file's whole
    // subject is whether a particular node is still there.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func makeUnixAddress(path: String) -> sockaddr_un? {
    let maximumBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    guard path.utf8.count <= maximumBytes else {
        return nil
    }
    var address = sockaddr_un()
    memset(&address, 0, MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: maximumBytes + 1) { buffer in
                _ = strncpy(buffer, source, maximumBytes)
            }
        }
    }
    return address
}

private func bindListeningSocket(at path: String, backlog: Int32 = 5) throws -> Int32 {
    _ = path.withCString { unlink($0) }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    guard var address = makeUnixAddress(path: path) else {
        _ = Darwin.close(descriptor)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG), userInfo: nil)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(descriptor, backlog) == 0 else {
        let code = Int(errno)
        _ = Darwin.close(descriptor)
        _ = path.withCString { unlink($0) }
        throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: nil)
    }
    return descriptor
}

private func connectWithoutBlocking(to path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0, var address = makeUnixAddress(path: path) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    _ = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            _ = Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return descriptor
}

private func canConnectNonBlocking(to path: String) -> Bool {
    guard let descriptor = try? connectWithoutBlocking(to: path) else { return false }
    defer { _ = Darwin.close(descriptor) }
    return canConnect(to: path)
}

private func canConnect(to path: String) -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        return false
    }
    defer { _ = Darwin.close(descriptor) }
    guard var address = makeUnixAddress(path: path) else {
        return false
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result == 0
}

private enum InjectedServerLifecycleError: Error {
    case serveFailure
}

private final class LifecycleShutdownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
