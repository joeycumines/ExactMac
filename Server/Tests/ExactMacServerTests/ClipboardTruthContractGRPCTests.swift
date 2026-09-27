import AppKit
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct ClipboardTruthContractGRPCTests {
    @Test
    func `generated client receives exact observed write and clear resources`() async throws {
        let pasteboard = ClipboardTruthPasteboard(
            observed: clipboardTruthResource(content: ClipboardTruthKind.url.canonical),
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            clipboardPasteboard: pasteboard,
        )

        try await withClipboardTruthClient(composition) { client in
            let writeResponse: Exactmac_V1_WriteClipboardResponse = try await clipboardTruthUnary(
                client: client,
                request: Exactmac_V1_WriteClipboardRequest.with {
                    $0.content = ClipboardTruthKind.url.requested
                },
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
            )
            let written = writeResponse.clipboard
            #expect(written == clipboardTruthResource(content: ClipboardTruthKind.url.canonical))
            #expect(await pasteboard.writtenContent() == ClipboardTruthKind.url.canonical)

            let historyAfterWrite = await composition.clipboardHistoryManager.getHistory()
            #expect(historyAfterWrite.entries.count == 1)
            #expect(historyAfterWrite.entries.first?.content == ClipboardTruthKind.url.canonical)

            let empty = clipboardTruthResource()
            await pasteboard.setObserved(empty)
            let clearResponse: Exactmac_V1_ClearClipboardResponse = try await clipboardTruthUnary(
                client: client,
                request: Exactmac_V1_ClearClipboardRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.ClearClipboard.descriptor,
            )
            let cleared = clearResponse.clipboard
            #expect(cleared == empty)
            #expect(cleared.name == "clipboard")
            #expect(!cleared.hasContent)
            #expect(cleared.availableTypes.isEmpty)
        }
    }

    @Test
    func `generated client rejects missing content before pasteboard access`() async throws {
        let pasteboard = ClipboardTruthPasteboard(observed: clipboardTruthResource())
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            clipboardPasteboard: pasteboard,
        )

        try await withClipboardTruthClient(composition) { client in
            do {
                let _: Exactmac_V1_WriteClipboardResponse = try await clipboardTruthUnary(
                    client: client,
                    request: Exactmac_V1_WriteClipboardRequest(),
                    descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                )
                Issue.record("Expected missing clipboard content to fail closed")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
            #expect(await pasteboard.recordedCalls().isEmpty)
        }
    }

    @Test(arguments: ClipboardTruthKind.allCases)
    func `manager canonicalizes each arm and publishes the exact observation`(
        kind: ClipboardTruthKind,
    ) async throws {
        let observed = clipboardTruthResource(content: kind.canonical)
        let pasteboard = ClipboardTruthPasteboard(observed: observed)
        let history = ClipboardHistoryManager(sourceApplication: { "Clipboard truth" })
        let manager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: history,
            pasteboard: pasteboard,
        )

        let returned = try await manager.writeClipboard(content: kind.requested)

        #expect(returned == observed)
        #expect(await pasteboard.writtenContent() == kind.canonical)
        #expect(await pasteboard.recordedCalls() == [.clear, .write, .read])
        let snapshot = await history.getHistory()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.content == kind.canonical)
    }

    @Test(arguments: ClipboardTruthKind.allCases)
    func `same-arm substituted readback fails with zero history`(
        kind: ClipboardTruthKind,
    ) async throws {
        let pasteboard = ClipboardTruthPasteboard(
            observed: clipboardTruthResource(content: kind.substituted),
        )
        let history = ClipboardHistoryManager(sourceApplication: { "Clipboard truth" })
        let manager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: history,
            pasteboard: pasteboard,
        )

        do {
            _ = try await manager.writeClipboard(content: kind.requested)
            Issue.record("Expected substituted \(kind) readback to fail")
        } catch let error as ClipboardError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed for \(kind), got \(error)")
                return
            }
        }

        #expect(await pasteboard.recordedCalls() == [.clear, .write, .read])
        #expect(await history.getHistory().entries.isEmpty)
    }

    @Test(arguments: ClipboardTruthInvalidContent.allCases)
    func `malformed content fails before leases clear or history`(
        invalid: ClipboardTruthInvalidContent,
    ) async throws {
        let gate = PhysicalDesktopMutationGate()
        let accessGate = ClipboardAccessGate()
        let pasteboard = ClipboardTruthPasteboard(observed: clipboardTruthResource())
        let history = ClipboardHistoryManager(sourceApplication: { "Clipboard truth" })
        let manager = ClipboardManager(
            mutationGate: gate,
            historyManager: history,
            pasteboard: pasteboard,
            accessGate: accessGate,
        )

        do {
            _ = try await manager.writeClipboard(content: invalid.content)
            Issue.record("Expected \(invalid) to fail before clipboard admission")
        } catch let error as ClipboardError {
            guard case .invalidContent = error else {
                Issue.record("Expected invalidContent for \(invalid), got \(error)")
                return
            }
        }

        #expect(await pasteboard.recordedCalls().isEmpty)
        #expect(await history.getHistory().entries.isEmpty)
        #expect(await gate.pendingCount() == 0)
        #expect(await accessGate.pendingCount() == 0)
    }

    @Test
    func `write false and residual clear content never publish success or history`() async throws {
        let failedWritePasteboard = ClipboardTruthPasteboard(
            observed: clipboardTruthResource(content: ClipboardTruthKind.text.canonical),
            writeResult: false,
        )
        let failedWriteHistory = ClipboardHistoryManager(sourceApplication: { "Clipboard truth" })
        let failedWriteManager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: failedWriteHistory,
            pasteboard: failedWritePasteboard,
        )

        do {
            _ = try await failedWriteManager.writeClipboard(
                content: ClipboardTruthKind.text.requested,
            )
            Issue.record("Expected pasteboard write failure")
        } catch let error as ClipboardError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error)")
                return
            }
        }
        #expect(await failedWritePasteboard.recordedCalls() == [.clear, .write])
        #expect(await failedWriteHistory.getHistory().entries.isEmpty)

        let residual = Exactmac_V1_Clipboard.with {
            $0.name = "clipboard"
            $0.content = ClipboardTruthKind.emptyText.canonical
        }
        let residualPasteboard = ClipboardTruthPasteboard(observed: residual)
        let residualManager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: ClipboardHistoryManager(sourceApplication: { "Clipboard truth" }),
            pasteboard: residualPasteboard,
        )
        do {
            _ = try await residualManager.clearClipboard()
            Issue.record("Expected residual clipboard content after clear to fail")
        } catch let error as ClipboardError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error)")
                return
            }
        }
        #expect(await residualPasteboard.recordedCalls() == [.clear, .read])
    }

    @Test
    func `history publication remains inside both clipboard leases`() async throws {
        let source = BlockingClipboardHistorySource()
        let gate = PhysicalDesktopMutationGate()
        let accessGate = ClipboardAccessGate()
        let history = ClipboardHistoryManager(sourceApplication: source.read)
        let observed = clipboardTruthResource(content: ClipboardTruthKind.text.canonical)
        let pasteboard = ClipboardTruthPasteboard(observed: observed)
        let manager = ClipboardManager(
            mutationGate: gate,
            historyManager: history,
            pasteboard: pasteboard,
            accessGate: accessGate,
        )

        let write = Task {
            try await manager.writeClipboard(content: ClipboardTruthKind.text.requested)
        }
        do {
            try await source.waitUntilEntered()

            let queuedRead = Task { try await manager.readClipboard() }
            let competingMutation = Task {
                try await gate.withExclusiveOperation {}
            }
            try await pollClipboardTruth("both clipboard leases to remain held") {
                let accessPending = await accessGate.pendingCount()
                let mutationPending = await gate.pendingCount()
                return accessPending == 1 && mutationPending == 1
            }

            #expect(await pasteboard.recordedCalls() == [.clear, .write, .read])

            source.release()
            let returned = try await write.value
            _ = try await queuedRead.value
            try await competingMutation.value

            #expect(returned == observed)
            #expect(await history.getHistory().entries.first?.content == observed.content)
            #expect(await accessGate.pendingCount() == 0)
            #expect(await gate.pendingCount() == 0)
        } catch {
            source.release()
            write.cancel()
            _ = await write.result
            throw error
        }
    }

    @Test
    func `representative large text is not rejected by an invented clipboard cap`() async throws {
        let largeText = String(repeating: "한🙂", count: 400_000)
        let content = Exactmac_V1_ClipboardContent.with {
            $0.type = .text
            $0.content = .text(largeText)
        }
        let pasteboard = ClipboardTruthPasteboard(
            observed: clipboardTruthResource(content: content),
        )
        let manager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: ClipboardHistoryManager(sourceApplication: { "Clipboard truth" }),
            pasteboard: pasteboard,
        )

        let observed = try await manager.writeClipboard(content: content)
        #expect(observed.content == content)
    }

    @Test
    func `native empty pasteboard is represented by absent protobuf content`() async {
        let native = NSPasteboard.withUniqueName()
        defer { native.releaseGlobally() }
        native.clearContents()
        let pasteboard = SystemClipboardPasteboard(pasteboard: native)

        let observed = await pasteboard.read()

        #expect(observed.name == "clipboard")
        #expect(!observed.hasContent)
        #expect(observed.availableTypes.isEmpty)
    }

    @Test
    func `image equality uses decoded pixels rather than PNG encoding identity`() async throws {
        let requestedData = clipboardTruthPNG(red: 19, green: 91, blue: 173)
        let observedData = clipboardTruthPNGAddingTextChunk(requestedData)
        #expect(requestedData != observedData)
        let requested = clipboardTruthContent(type: .image, content: .image(requestedData))
        let observedContent = clipboardTruthContent(type: .image, content: .image(observedData))
        let observed = clipboardTruthResource(content: observedContent)
        let pasteboard = ClipboardTruthPasteboard(observed: observed)
        let history = ClipboardHistoryManager(sourceApplication: { "Clipboard truth" })
        let manager = ClipboardManager(
            mutationGate: PhysicalDesktopMutationGate(),
            historyManager: history,
            pasteboard: pasteboard,
        )

        let returned = try await manager.writeClipboard(content: requested)

        #expect(returned == observed)
        #expect(await history.getHistory().entries.first?.content == observedContent)
    }
}

enum ClipboardTruthKind: String, CaseIterable, CustomStringConvertible, Sendable {
    case text
    case emptyText
    case rtf
    case html
    case image
    case files
    case url

    var description: String {
        rawValue
    }

    var requested: Exactmac_V1_ClipboardContent {
        switch self {
        case .text:
            clipboardTruthContent(type: .text, content: .text("Clipboard 世界 🌏"))
        case .emptyText:
            clipboardTruthContent(type: .text, content: .text(""))
        case .rtf:
            clipboardTruthContent(
                type: .rtf,
                content: .rtf(Data(#"{\rtf1\ansi Clipboard truth}"#.utf8)),
            )
        case .html:
            clipboardTruthContent(
                type: .html,
                content: .html("<p>Clipboard <strong>truth</strong> 🌏</p>"),
            )
        case .image:
            clipboardTruthContent(
                type: .image,
                content: .image(clipboardTruthPNG(red: 19, green: 91, blue: 173)),
            )
        case .files:
            clipboardTruthContent(
                type: .files,
                content: .files(
                    Exactmac_V1_FilePaths.with {
                        $0.paths = [
                            "/Users/Shared/../Shared/first.txt",
                            "/private/tmp/dir/../second.bin",
                        ]
                    },
                ),
            )
        case .url:
            clipboardTruthContent(
                type: .url,
                content: .url("https://example.com/a/../clipboard"),
            )
        }
    }

    var canonical: Exactmac_V1_ClipboardContent {
        switch self {
        case .files:
            clipboardTruthContent(
                type: .files,
                content: .files(
                    Exactmac_V1_FilePaths.with {
                        $0.paths = [
                            "/Users/Shared/first.txt",
                            "/private/tmp/second.bin",
                        ]
                    },
                ),
            )
        case .url:
            clipboardTruthContent(
                type: .url,
                content: .url("https://example.com/clipboard"),
            )
        default:
            requested
        }
    }

    var substituted: Exactmac_V1_ClipboardContent {
        switch self {
        case .text:
            clipboardTruthContent(type: .text, content: .text("substituted"))
        case .emptyText:
            clipboardTruthContent(type: .text, content: .text("not empty"))
        case .rtf:
            clipboardTruthContent(
                type: .rtf,
                content: .rtf(Data(#"{\rtf1\ansi substituted}"#.utf8)),
            )
        case .html:
            clipboardTruthContent(type: .html, content: .html("<p>substituted</p>"))
        case .image:
            clipboardTruthContent(
                type: .image,
                content: .image(clipboardTruthPNG(red: 173, green: 41, blue: 29)),
            )
        case .files:
            clipboardTruthContent(
                type: .files,
                content: .files(
                    Exactmac_V1_FilePaths.with {
                        $0.paths = ["/Users/Shared/different.txt"]
                    },
                ),
            )
        case .url:
            clipboardTruthContent(
                type: .url,
                content: .url("https://example.com/different"),
            )
        }
    }
}

enum ClipboardTruthInvalidContent: String, CaseIterable, CustomStringConvertible, Sendable {
    case invalidRTF
    case invalidImage
    case relativeURL
    case emptyFiles
    case relativeFile

    var description: String {
        rawValue
    }

    var content: Exactmac_V1_ClipboardContent {
        switch self {
        case .invalidRTF:
            clipboardTruthContent(type: .rtf, content: .rtf(Data([0x00, 0x01, 0x02])))
        case .invalidImage:
            clipboardTruthContent(type: .image, content: .image(Data([0x00, 0x01, 0x02])))
        case .relativeURL:
            clipboardTruthContent(type: .url, content: .url("../relative"))
        case .emptyFiles:
            clipboardTruthContent(
                type: .files,
                content: .files(Exactmac_V1_FilePaths()),
            )
        case .relativeFile:
            clipboardTruthContent(
                type: .files,
                content: .files(
                    Exactmac_V1_FilePaths.with {
                        $0.paths = ["relative/file.txt"]
                    },
                ),
            )
        }
    }
}

private actor ClipboardTruthPasteboard: ClipboardPasteboard {
    enum Call: Equatable, Sendable {
        case clear
        case write
        case read
    }

    private var calls: [Call] = []
    private var changeCountValue = 0
    private var observed: Exactmac_V1_Clipboard
    private var written: Exactmac_V1_ClipboardContent?
    private let writeResult: Bool

    init(
        observed: Exactmac_V1_Clipboard,
        writeResult: Bool = true,
    ) {
        self.observed = observed
        self.writeResult = writeResult
    }

    func read() -> Exactmac_V1_Clipboard {
        calls.append(.read)
        return observed
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func clear() {
        calls.append(.clear)
        changeCountValue += 1
    }

    func write(_ content: Exactmac_V1_ClipboardContent) -> Bool {
        calls.append(.write)
        written = content
        return writeResult
    }

    func setObserved(_ value: Exactmac_V1_Clipboard) {
        observed = value
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func writtenContent() -> Exactmac_V1_ClipboardContent? {
        written
    }
}

private final class BlockingClipboardHistorySource: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    func read() -> String {
        entered.signal()
        releaseSignal.wait()
        return "Blocked history source"
    }

    func waitUntilEntered() async throws {
        let semaphore = entered
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseSignal.signal()
    }
}

private enum ClipboardTruthTestError: Error {
    case timeout(String)
}

private func withClipboardTruthClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (
        GRPCClient<InProcessTransport.Client>,
    ) async throws -> Void,
) async throws {
    let transport = InProcessTransport()
    let server = GRPCServer(
        transport: productionServerTransport(transport.server),
        services: [composition.exactMacService],
        interceptors: handlerContractTestInterceptors(),
    )
    let client = GRPCClient(transport: transport.client)

    try await withThrowingDiscardingTaskGroup { group in
        group.addTask { try await server.serve() }
        group.addTask { try await client.runConnections() }
        defer {
            client.beginGracefulShutdown()
            server.beginGracefulShutdown()
        }
        try await operation(client)
    }
}

private func clipboardTruthUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: .defaults,
    ) { response in
        try response.message
    }
}

private func clipboardTruthContent(
    type: Exactmac_V1_ContentType,
    content: Exactmac_V1_ClipboardContent.OneOf_Content,
) -> Exactmac_V1_ClipboardContent {
    Exactmac_V1_ClipboardContent.with {
        $0.type = type
        $0.content = content
    }
}

private func clipboardTruthResource(
    content: Exactmac_V1_ClipboardContent? = nil,
) -> Exactmac_V1_Clipboard {
    Exactmac_V1_Clipboard.with {
        $0.name = "clipboard"
        if let content {
            $0.content = content
            $0.availableTypes = [content.type]
        }
    }
}

private func clipboardTruthPNG(
    red: UInt8,
    green: UInt8,
    blue: UInt8,
) -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 8,
        bitsPerPixel: 32,
    ),
        let data = representation.bitmapData
    else {
        preconditionFailure("Unable to allocate clipboard truth bitmap")
    }
    data[0] = red
    data[1] = green
    data[2] = blue
    data[3] = 255
    data[4] = blue
    data[5] = red
    data[6] = green
    data[7] = 255
    guard let encoded = representation.representation(using: .png, properties: [:]) else {
        preconditionFailure("Unable to encode clipboard truth PNG")
    }
    return encoded
}

private func clipboardTruthPNGAddingTextChunk(_ png: Data) -> Data {
    let iendLength = 12
    precondition(png.count >= iendLength)
    let type = Data("tEXt".utf8)
    let payload = Data("Comment\u{0}alternate encoding".utf8)
    var chunk = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
    chunk.append(type)
    chunk.append(payload)
    var crc = clipboardTruthCRC32(type + payload).bigEndian
    withUnsafeBytes(of: &crc) { chunk.append(contentsOf: $0) }

    var result = Data(png.dropLast(iendLength))
    result.append(chunk)
    result.append(png.suffix(iendLength))
    return result
}

private func clipboardTruthCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
        }
    }
    return ~crc
}

private func pollClipboardTruth(
    _ label: String,
    operation: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await !operation() {
        guard clock.now < deadline else {
            throw ClipboardTruthTestError.timeout(label)
        }
        await Task.yield()
    }
}
