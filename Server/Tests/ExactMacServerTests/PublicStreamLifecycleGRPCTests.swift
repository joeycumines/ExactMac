import CoreGraphics
@testable import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct PublicStreamLifecycleGRPCTests {
    @Test
    func `watch stream consumes disconnects and releases traversal ownership`() async throws {
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in populatedTraversalSnapshot() },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

        try await withPublicStreamClient(composition) { client, _ in
            let response = try await publicServerStreaming(
                client: client,
                request: Exactmac_V1_WatchAccessibilityRequest.with {
                    $0.name = "applications/111"
                    $0.pollInterval = 0.1
                },
                descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                responseType: Exactmac_V1_WatchAccessibilityResponse.self,
            ) { response in
                var iterator = response.messages.makeAsyncIterator()
                return try await iterator.next()
            }
            let first = try #require(response)
            #expect(first.addedElements.count == 1)

            try await pollPublicStreamCondition("watch traversal release") {
                let traversals = await coordinator.activeTraversalCount()
                let streams = await coordinator.activeTraversalStreamCount()
                return traversals == 0 && streams == 0
            }
            #expect(await coordinator.activeTraversalCount() == 0)
            #expect(await coordinator.activeTraversalStreamCount() == 0)
        }
    }

    @Test
    func `watch stream propagates persistent producer failure instead of polling forever`() async throws {
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in
                throw RPCError(code: .unavailable, message: "persistent traversal failure")
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

        try await withPublicStreamClient(composition) { client, _ in
            var options = CallOptions.defaults
            options.timeout = .seconds(1)
            do {
                let _: Int = try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_WatchAccessibilityRequest.with {
                        $0.name = "applications/111"
                        $0.pollInterval = 0.1
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                    responseType: Exactmac_V1_WatchAccessibilityResponse.self,
                    options: options,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
                Issue.record("persistent watch producer failure unexpectedly completed successfully")
            } catch let error as RPCError {
                #expect(error.code == .unavailable, Comment(rawValue: String(describing: error)))
            }

            try await pollPublicStreamCondition("failed watch traversal release") {
                let traversals = await coordinator.activeTraversalCount()
                let streams = await coordinator.activeTraversalStreamCount()
                return traversals == 0 && streams == 0
            }
            #expect(await coordinator.activeTraversalCount() == 0)
            #expect(await coordinator.activeTraversalStreamCount() == 0)
        }
    }

    @Test
    func `client disconnect cancels both advertised stream producers`() async throws {
        let system = MockSystemOperations()
        let probe = PublicTraversalProbe()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in try await probe.run() },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let observationName = "applications/111/observations/disconnect"
        _ = try await composition.observationManager.createObservation(
            name: observationName,
            type: .elementChanges,
            parent: "applications/111",
            filter: nil,
            pid: 111,
        )

        try await withPublicStreamClient(composition) { client, disconnect in
            let watch = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_WatchAccessibilityRequest.with {
                        $0.name = "applications/111"
                        $0.pollInterval = 0.1
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                    responseType: Exactmac_V1_WatchAccessibilityResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            let observation = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_StreamObservationsRequest.with { $0.name = observationName },
                    descriptor: Exactmac_V1_ExactMac.Method.StreamObservations.descriptor,
                    responseType: Exactmac_V1_StreamObservationsResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("disconnect stream ownership") {
                let watchEntered = await probe.hasEntered()
                let watchStreams = await coordinator.activeTraversalStreamCount()
                let observationContinuations = await composition.observationManager.streamContinuationCount(
                    name: observationName,
                )
                let observationProducers = await composition.observationManager.streamProducerCount()
                return watchEntered && watchStreams == 1 && observationContinuations == 1 && observationProducers == 1
            }

            disconnect()
            await expectTerminatedPublicStream(watch, label: "watch client disconnect")
            await expectTerminatedPublicStream(observation, label: "observation client disconnect")
            try await pollPublicStreamCondition("disconnected producer release") {
                let watchCancelled = await probe.cancellationObserved()
                let traversals = await coordinator.activeTraversalCount()
                let watchStreams = await coordinator.activeTraversalStreamCount()
                let observationContinuations = await composition.observationManager.streamContinuationCount(
                    name: observationName,
                )
                let observationProducers = await composition.observationManager.streamProducerCount()
                return watchCancelled && traversals == 0 && watchStreams == 0 &&
                    observationContinuations == 0 && observationProducers == 0
            }
        }
    }

    @Test
    func `watch caller cancellation and service drain join the blocked producer`() async throws {
        let system = MockSystemOperations()
        let firstProbe = PublicTraversalProbe()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in try await firstProbe.run() },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

        try await withPublicStreamClient(composition) { client, _ in
            let caller = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_WatchAccessibilityRequest.with {
                        $0.name = "applications/111"
                        $0.pollInterval = 0.1
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                    responseType: Exactmac_V1_WatchAccessibilityResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("watch caller entered producer") {
                await firstProbe.hasEntered()
            }
            caller.cancel()
            await expectCancelledPublicStream(caller, label: "watch caller cancellation")
            try await pollPublicStreamCondition("cancelled watch producer") {
                let cancellationObserved = await firstProbe.cancellationObserved()
                let traversalCount = await coordinator.activeTraversalCount()
                let streamCount = await coordinator.activeTraversalStreamCount()
                return cancellationObserved && traversalCount == 0 && streamCount == 0
            }
        }

        let drainProbe = PublicTraversalProbe()
        let drainCoordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in try await drainProbe.run() },
        )
        let drainComposition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: drainCoordinator,
        )
        try await withPublicStreamClient(drainComposition) { client, _ in
            let stream = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_WatchAccessibilityRequest.with {
                        $0.name = "applications/222"
                        $0.pollInterval = 0.1
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                    responseType: Exactmac_V1_WatchAccessibilityResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("watch drain entered producer") {
                await drainProbe.hasEntered()
            }
            await drainComposition.serviceLifetime.shutdown()
            await expectTerminatedPublicStream(stream, label: "watch service drain")
            #expect(await drainProbe.cancellationObserved())
            #expect(await drainCoordinator.activeTraversalCount() == 0)
            #expect(await drainCoordinator.activeTraversalStreamCount() == 0)
            #expect(await drainComposition.serviceLifetime.lifecycleState() == .drained)
        }
    }

    @Test
    func `observation stream consumes disconnects and removes its continuation`() async throws {
        let name = "applications/111/observations/consume"
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            accessibilityTraversalExecutor: { _, _ in populatedTraversalSnapshot() },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        _ = try await composition.observationManager.createObservation(
            name: name,
            type: .elementChanges,
            parent: "applications/111",
            filter: Exactmac_V1_ObservationFilter.with { $0.pollInterval = 0.1 },
            pid: 111,
        )

        try await withPublicStreamClient(composition) { client, _ in
            let handlerEntered = PublicAsyncSignal()
            let stream = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_StreamObservationsRequest.with { $0.name = name },
                    descriptor: Exactmac_V1_ExactMac.Method.StreamObservations.descriptor,
                    responseType: Exactmac_V1_StreamObservationsResponse.self,
                ) { response in
                    await handlerEntered.signal()
                    var iterator = response.messages.makeAsyncIterator()
                    return try await iterator.next()
                }
            }
            try await pollPublicStreamCondition("observation response handler") {
                await handlerEntered.isSignalled()
            }
            try await pollPublicStreamCondition("observation continuation registration") {
                await composition.observationManager.streamContinuationCount(name: name) == 1
            }
            try await composition.observationManager.startObservation(name: name)
            let first = try #require(try await stream.value)
            #expect(first.event.observation == name)
            #expect(first.event.eventType != nil)

            try await pollPublicStreamCondition("observation disconnect cleanup") {
                await composition.observationManager.streamContinuationCount(name: name) == 0
            }
            #expect(await composition.observationManager.streamContinuationCount(name: name) == 0)
            #expect(await composition.observationManager.streamProducerCount() == 0)
            _ = await composition.observationManager.cancelObservation(name: name)
            #expect(await composition.observationManager.monitorTaskCount() == 0)
        }
    }

    @Test
    func `observation caller cancellation producer failure and drain release every owner`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )

        try await withPublicStreamClient(composition) { client, _ in
            let cancelName = "applications/111/observations/cancel"
            _ = try await composition.observationManager.createObservation(
                name: cancelName,
                type: .windowChanges,
                parent: "applications/111",
                filter: nil,
                pid: 111,
            )
            let cancelledStream = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_StreamObservationsRequest.with { $0.name = cancelName },
                    descriptor: Exactmac_V1_ExactMac.Method.StreamObservations.descriptor,
                    responseType: Exactmac_V1_StreamObservationsResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("observation cancellation registration") {
                let continuations = await composition.observationManager.streamContinuationCount(name: cancelName)
                let producers = await composition.observationManager.streamProducerCount()
                return continuations == 1 && producers == 1
            }
            cancelledStream.cancel()
            await expectCancelledPublicStream(cancelledStream, label: "observation caller cancellation")
            try await pollPublicStreamCondition("observation cancellation cleanup") {
                let continuations = await composition.observationManager.streamContinuationCount(name: cancelName)
                let producers = await composition.observationManager.streamProducerCount()
                return continuations == 0 && producers == 0
            }

            let failureName = "applications/111/observations/failure"
            _ = try await composition.observationManager.createObservation(
                name: failureName,
                type: .windowChanges,
                parent: "applications/111",
                filter: nil,
                pid: 111,
            )
            let failedStream = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_StreamObservationsRequest.with { $0.name = failureName },
                    descriptor: Exactmac_V1_ExactMac.Method.StreamObservations.descriptor,
                    responseType: Exactmac_V1_StreamObservationsResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("failed observation registration") {
                let continuations = await composition.observationManager.streamContinuationCount(name: failureName)
                let producers = await composition.observationManager.streamProducerCount()
                return continuations == 1 && producers == 1
            }
            await composition.observationManager.failObservation(
                name: failureName,
                error: PublicStreamTestError.injectedProducerFailure,
            )
            #expect(try await failedStream.value == 0)
            #expect(await composition.observationManager.streamContinuationCount(name: failureName) == 0)
            #expect(await composition.observationManager.streamProducerCount() == 0)
            #expect(await composition.observationManager.monitorTaskCount() == 0)

            let drainName = "applications/111/observations/drain"
            _ = try await composition.observationManager.createObservation(
                name: drainName,
                type: .windowChanges,
                parent: "applications/111",
                filter: nil,
                pid: 111,
            )
            let drainedStream = Task {
                try await publicServerStreaming(
                    client: client,
                    request: Exactmac_V1_StreamObservationsRequest.with { $0.name = drainName },
                    descriptor: Exactmac_V1_ExactMac.Method.StreamObservations.descriptor,
                    responseType: Exactmac_V1_StreamObservationsResponse.self,
                ) { response in
                    try await response.messages.reduce(into: 0) { count, _ in count += 1 }
                }
            }
            try await pollPublicStreamCondition("drained observation registration") {
                let continuations = await composition.observationManager.streamContinuationCount(name: drainName)
                let producers = await composition.observationManager.streamProducerCount()
                return continuations == 1 && producers == 1
            }
            await composition.serviceLifetime.shutdown()
            _ = try? await drainedStream.value
            #expect(await composition.observationManager.streamContinuationCount(name: drainName) == 0)
            #expect(await composition.observationManager.streamProducerCount() == 0)
            #expect(await composition.observationManager.monitorTaskCount() == 0)
            #expect(await composition.observationManager.getActiveObservationCount() == 0)
            #expect(await composition.serviceLifetime.lifecycleState() == .drained)
        }
    }
}

private actor PublicAsyncSignal {
    private var signalled = false

    func signal() {
        signalled = true
    }

    func isSignalled() -> Bool {
        signalled
    }
}

private actor PublicTraversalProbe {
    private var entered = false
    private var observedCancellation = false

    func run() async throws -> AccessibilityTraversalSnapshot {
        entered = true
        do {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
            observedCancellation = true
            throw error
        }
        return populatedTraversalSnapshot()
    }

    func hasEntered() -> Bool {
        entered
    }

    func cancellationObserved() -> Bool {
        observedCancellation
    }
}

private func populatedTraversalSnapshot() -> AccessibilityTraversalSnapshot {
    AccessibilityTraversalSnapshot(
        appName: "Public Stream Fixture",
        elements: [
            ElementData(
                role: "AXButton",
                text: "Fixture",
                x: 10,
                y: 20,
                width: 100,
                height: 30,
                axElement: nil,
                enabled: true,
                focused: false,
                attributes: [:],
                path: [0],
            ),
        ],
        count: 1,
        textElementsCount: 1,
        visibleElementsCount: 1,
        roleCounts: ["AXButton": 1],
    )
}

private func withPublicStreamClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (
        GRPCClient<HTTP2ClientTransport.Posix>,
        @Sendable () -> Void,
    ) async throws -> Void,
) async throws {
    let socketPath = "/tmp/exactmac-func003-\(UUID().uuidString).sock"
    let serverTransport = HTTP2ServerTransport.Posix(
        address: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext,
    )
    let server = GRPCServer(
        transport: productionServerTransport(serverTransport),
        services: [composition.exactMacService, composition.operationsProvider],
        interceptors: handlerContractTestInterceptors(),
    )
    let serverTask = Task { try await server.serve() }
    do {
        try await pollPublicStreamCondition("public stream server bind") {
            FileManager.default.fileExists(atPath: socketPath)
        }
    } catch {
        server.beginGracefulShutdown()
        _ = await serverTask.result
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }
    let clientTransport = try HTTP2ClientTransport.Posix(
        target: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext,
    )
    let client = GRPCClient(transport: clientTransport)
    let connectionTask = Task { try await client.runConnections() }
    let disconnect: @Sendable () -> Void = { connectionTask.cancel() }

    do {
        try await operation(client, disconnect)
    } catch {
        client.beginGracefulShutdown()
        connectionTask.cancel()
        server.beginGracefulShutdown()
        _ = await connectionTask.result
        _ = await serverTask.result
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }

    client.beginGracefulShutdown()
    connectionTask.cancel()
    server.beginGracefulShutdown()
    _ = await connectionTask.result
    _ = await serverTask.result
    try? FileManager.default.removeItem(atPath: socketPath)
}

private func publicServerStreaming<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
    Result: Sendable,
>(
    client: GRPCClient<HTTP2ClientTransport.Posix>,
    request: Request,
    descriptor: MethodDescriptor,
    responseType _: Response.Type,
    options: CallOptions = .defaults,
    onResponse: @Sendable @escaping (StreamingClientResponse<Response>) async throws -> Result,
) async throws -> Result {
    var options = options
    if options.timeout == nil {
        options.timeout = .seconds(2)
    }
    return try await client.serverStreaming(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: options,
        onResponse: onResponse,
    )
}

private func pollPublicStreamCondition(
    _ label: String,
    operation: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await !operation() {
        guard clock.now < deadline else {
            throw PublicStreamTestError.timeout(label)
        }
        await Task.yield()
    }
}

private func expectCancelledPublicStream(
    _ task: Task<Int, any Error>,
    label: String,
) async {
    do {
        _ = try await task.value
    } catch is CancellationError {
        // Expected direct caller cancellation.
    } catch let error as RPCError {
        if error.code == .unknown {
            #expect(error.cause is CancellationError, Comment(rawValue: "\(label): \(error)"))
        } else {
            #expect(error.code == .cancelled, Comment(rawValue: "\(label): \(error)"))
        }
    } catch {
        Issue.record("\(label) returned unexpected error: \(error)")
    }
}

private func expectTerminatedPublicStream(
    _ task: Task<Int, any Error>,
    label: String,
) async {
    do {
        _ = try await task.value
    } catch is CancellationError {
        // Drain may surface local cancellation.
    } catch let error as RPCError {
        #expect(
            error.code == .cancelled || error.code == .unavailable,
            Comment(rawValue: "\(label): \(error)"),
        )
    } catch {
        Issue.record("\(label) returned unexpected error: \(error)")
    }
}

private enum PublicStreamTestError: Error {
    case injectedProducerFailure
    case timeout(String)
}
