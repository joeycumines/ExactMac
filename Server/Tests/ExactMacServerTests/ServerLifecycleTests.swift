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
    // manage, and the policy below is the opposite of the one that applied while launchd
    // created it: a node left behind by a crash is RECLAIMED, because a server that cannot
    // restart after a crash needs an operator, and a node that something is still serving is
    // REFUSED, because unlinking it would leave two listeners on one name.

    @Test
    func `an absent Unix path needs no reclamation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        try UnixSocketNode.reclaimStaleNode(at: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `a stale Unix socket is reclaimed`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let staleDescriptor = try bindListeningSocket(at: path)
        // A crash or a reboot: the listener is gone, the pathname is not.
        _ = Darwin.close(staleDescriptor)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path) == false)

        try UnixSocketNode.reclaimStaleNode(at: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `a live Unix socket is refused and its node is left alone`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let liveDescriptor = try bindListeningSocket(at: path)
        defer {
            _ = Darwin.close(liveDescriptor)
            _ = path.withCString { unlink($0) }
        }
        #expect(canConnect(to: path))

        #expect(throws: UnixSocketNodeError.pathAlreadyExistsAndIsLive(path)) {
            try UnixSocketNode.reclaimStaleNode(at: path)
        }
        // The live listener still owns the path: no unlink, still connectable.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(canConnect(to: path))
    }

    @Test
    func `a non-socket at the Unix path is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let marker = Data("preserve-me".utf8)
        try marker.write(to: URL(fileURLWithPath: path))

        #expect(throws: UnixSocketNodeError.pathIsNotASocket(path)) {
            try UnixSocketNode.reclaimStaleNode(at: path)
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
        let link = directory.appendingPathComponent("s.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // `lstat` never follows a symlink, so the link itself is what is found, and a link
        // is not a socket: nothing beyond the link is read and nothing is removed.
        #expect(throws: UnixSocketNodeError.pathIsNotASocket(link.path)) {
            try UnixSocketNode.reclaimStaleNode(at: link.path)
        }
        #expect(try Data(contentsOf: target) == marker)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test
    func `a directory at the Unix path is refused without mutation`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdir = directory.appendingPathComponent("s.sock", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)

        #expect(throws: UnixSocketNodeError.pathIsNotASocket(subdir.path)) {
            try UnixSocketNode.reclaimStaleNode(at: subdir.path)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: subdir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test
    func `a bound node is made owner-only and released only while it still is`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path

        let descriptor = try bindListeningSocket(at: path)
        defer { _ = Darwin.close(descriptor) }

        // Whatever umask the test process inherited, the node ends up owner-only.
        try UnixSocketNode.hardenBoundNode(at: path)
        #expect(try nodeMode(at: path) == 0o600)

        // A node that is no longer owner-only is REPORTED rather than removed. The pathname
        // is mutable, so mode 0600 is the evidence that this is still the node the process
        // bound; without it, releasing is deleting whatever is at a path.
        #expect(throws: UnixSocketNodeError.self) {
            _ = path.withCString { chmod($0, 0o666) }
            try UnixSocketNode.releaseBoundNode(at: path)
        }
        #expect(FileManager.default.fileExists(atPath: path))

        _ = path.withCString { unlink($0) }
        try UnixSocketNode.releaseBoundNode(at: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `releasing an absent node is not an error`() throws {
        let directory = try makeShortSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try UnixSocketNode.releaseBoundNode(at: directory.appendingPathComponent("gone.sock").path)
    }
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
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

private func bindListeningSocket(at path: String) throws -> Int32 {
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
    guard bindResult == 0, Darwin.listen(descriptor, 5) == 0 else {
        let code = Int(errno)
        _ = Darwin.close(descriptor)
        _ = path.withCString { unlink($0) }
        throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: nil)
    }
    return descriptor
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
