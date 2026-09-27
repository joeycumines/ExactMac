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
struct InputDisconnectLifetimeGRPCTests {
    @Test
    func `abrupt production disconnect retains cleanup through service drain`() async throws {
        let cleanup = InputDisconnectCleanupProbe()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await cleanup.execute(action: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputDisconnectTopologyProvider(),
        )
        let inputName = "applications/-/inputs/abrupt-disconnect"

        try await withInputDisconnectClients(composition) { victim, control, disconnectVictim in
            try await prewarmInputDisconnectControlClient(control)
            let victimResult = InputDisconnectVictimResult()
            let victimCall = Task {
                do {
                    let _: Exactmac_V1_Input = try await inputDisconnectUnary(
                        client: victim,
                        request: inputDisconnectCreateRequest(),
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                    victimResult.record(.succeeded)
                } catch let error as RPCError {
                    victimResult.record(.rpcError(error.code))
                } catch is CancellationError {
                    victimResult.record(.taskCancelled)
                } catch {
                    victimResult.record(.unexpected(String(describing: error)))
                }
            }
            var shutdown: Task<Void, Never>?

            do {
                try await cleanup.waitUntilExecutionStarted()
                try await waitForInputDisconnectCondition("executing input publication") {
                    await composition.stateStore.getInput(name: inputName)?.state == .executing
                }

                disconnectVictim()
                try await cleanup.waitUntilCleanupStarted()
                try await victimResult.waitUntilFinished()
                #expect(victimResult.outcome == .rpcError(.unavailable))
                await victimCall.value

                let executingBeforeDrain = try await getInputThroughControlClient(
                    control,
                    name: inputName,
                )
                #expect(executingBeforeDrain.state == .executing)
                #expect(executingBeforeDrain.deliveryResult.commitment == .unspecified)
                #expect(await composition.stateStore.inputStateHistory(name: inputName) == [
                    .pending,
                    .executing,
                ])
                #expect(await composition.automationCoordinator.activeMutationCount() == 1)
                #expect(await composition.stateStore.activeInputIdentityCount() == 1)
                #expect(cleanup.outstandingCleanupObligationCount == 2)
                #expect(await coordinator.mutationGate.lifecycleState() == .accepting)
                #expect(await coordinator.mutationGate.pendingCount() == 0)
                #expect(await composition.serviceLifetime.lifecycleState() == .accepting)

                shutdown = Task {
                    await composition.serviceLifetime.shutdown()
                }
                try await waitForInputDisconnectDrain(composition)

                let executingDuringDrain = try await getInputThroughControlClient(
                    control,
                    name: inputName,
                )
                #expect(executingDuringDrain == executingBeforeDrain)
                #expect(await composition.automationCoordinator.activeMutationCount() == 1)
                #expect(await composition.stateStore.activeInputIdentityCount() == 1)
                #expect(cleanup.outstandingCleanupObligationCount == 2)
                #expect(await composition.serviceLifetime.lifecycleState() == .draining)
                #expect(await coordinator.mutationGate.lifecycleState() == .draining)

                cleanup.releaseCleanup()
                await shutdown?.value

                let terminal = try await getInputThroughControlClient(
                    control,
                    name: inputName,
                )
                #expect(terminal.state == .cancelled)
                #expect(terminal.hasCompleteTime)
                #expect(terminal.deliveryResult.commitment == .possiblyCommitted)
                #expect(terminal.deliveryResult.postedEventCount == 1)
                #expect(terminal.deliveryResult.routedDeliveryObserved)
                #expect(await composition.stateStore.inputStateHistory(name: inputName) == [
                    .pending,
                    .executing,
                    .cancelled,
                ])
                #expect(cleanup.outstandingCleanupObligationCount == 0)
                #expect(await composition.automationCoordinator.activeMutationCount() == 0)
                #expect(await composition.stateStore.activeInputIdentityCount() == 0)
                #expect(await composition.serviceLifetime.lifecycleState() == .drained)
                #expect(await coordinator.mutationGate.lifecycleState() == .drained)
                #expect(await coordinator.mutationGate.pendingCount() == 0)
            } catch {
                disconnectVictim()
                victimCall.cancel()
                cleanup.releaseCleanup()
                if shutdown == nil {
                    shutdown = Task {
                        await composition.serviceLifetime.shutdown()
                    }
                }
                await shutdown?.value
                await victimCall.value
                throw error
            }
        }
    }
}

private final class InputDisconnectCleanupProbe: @unchecked Sendable {
    private let executionStarted = InputDisconnectOneShotSignal()
    private let cleanupStarted = InputDisconnectOneShotSignal()
    private let cancellationBoundary = InputDisconnectCancellationBoundary()
    private let cleanupRelease = InputDisconnectOneShotSignal()
    private let lock = NSLock()
    private var outstandingObligations = 0

    @MainActor
    func execute(
        action _: ExactMac.InputAction,
        route: ExactMac.InputDeliveryRoute,
    ) async throws -> ExactMac.InputExecutionReceipt {
        executionStarted.signal()
        do {
            try await cancellationBoundary.wait()
            throw InputDisconnectTestError.unexpectedCancellationBoundaryReturn
        } catch {
            lock.withLock {
                outstandingObligations = 2
            }
            cleanupStarted.signal()
            await cleanupRelease.wait()
            lock.withLock {
                outstandingObligations = 0
            }
            throw ExactMac.InputExecutionFailure(
                underlying: error,
                route: route,
                postedEventCount: 1,
                routedDeliveryObserved: true,
                physicalEffectOccurred: true,
            )
        }
    }

    func waitUntilExecutionStarted() async throws {
        try await waitForInputDisconnectCondition("input executor entry") {
            self.executionStarted.isSignalled
        }
    }

    func waitUntilCleanupStarted() async throws {
        try await waitForInputDisconnectCondition("input cleanup entry") {
            self.cleanupStarted.isSignalled
        }
    }

    func releaseCleanup() {
        cleanupRelease.signal()
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { outstandingObligations }
    }
}

private final class InputDisconnectVictimResult: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case pending
        case succeeded
        case rpcError(RPCError.Code)
        case taskCancelled
        case unexpected(String)
    }

    private let lock = NSLock()
    private var storedOutcome = Outcome.pending

    func record(_ outcome: Outcome) {
        lock.withLock {
            precondition(storedOutcome == .pending, "victim call result recorded twice")
            storedOutcome = outcome
        }
    }

    func waitUntilFinished() async throws {
        try await waitForInputDisconnectCondition("victim connection failure") {
            self.outcome != .pending
        }
    }

    var outcome: Outcome {
        lock.withLock { storedOutcome }
    }
}

private final class InputDisconnectOneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !signalled else {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !signalled else {
                return []
            }
            signalled = true
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    var isSignalled: Bool {
        lock.withLock { signalled }
    }
}

private final class InputDisconnectCancellationBoundary: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case waiting(CheckedContinuation<Void, any Error>)
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.awaitingContinuation

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    switch state {
                    case .awaitingContinuation:
                        state = .waiting(continuation)
                        return false
                    case .cancelled:
                        return true
                    case .waiting:
                        preconditionFailure("input disconnect cancellation boundary installed twice")
                    }
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                switch state {
                case .awaitingContinuation:
                    state = .cancelled
                    return nil
                case let .waiting(continuation):
                    state = .cancelled
                    return continuation
                case .cancelled:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private struct InputDisconnectTopologyProvider: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
                isMain: true,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 10, y: 20)
    }
}

private func inputDisconnectCreateRequest() -> Exactmac_V1_CreateInputRequest {
    Exactmac_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = "abrupt-disconnect"
        $0.input.target.desktop = true
        $0.input.action.mouseClick.position = Exactmac_Type_Point.with {
            $0.x = 10
            $0.y = 20
        }
    }
}

private func getInputThroughControlClient(
    _ client: GRPCClient<HTTP2ClientTransport.Posix>,
    name: String,
) async throws -> Exactmac_V1_Input {
    try await inputDisconnectUnary(
        client: client,
        request: Exactmac_V1_GetInputRequest.with {
            $0.name = name
        },
        descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
    )
}

private func prewarmInputDisconnectControlClient(
    _ client: GRPCClient<HTTP2ClientTransport.Posix>,
) async throws {
    do {
        let _: Exactmac_V1_Input = try await getInputThroughControlClient(
            client,
            name: "applications/-/inputs/control-prewarm-missing",
        )
        throw InputDisconnectTestError.unexpectedControlPrewarmSuccess
    } catch let error as RPCError {
        guard error.code == .notFound else {
            throw error
        }
    }
}

private func inputDisconnectUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<HTTP2ClientTransport.Posix>,
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

private func withInputDisconnectClients(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (
        GRPCClient<HTTP2ClientTransport.Posix>,
        GRPCClient<HTTP2ClientTransport.Posix>,
        @escaping @Sendable () -> Void,
    ) async throws -> Void,
) async throws {
    let socketPath = "/tmp/exactmac-func004-input-disconnect-\(UUID().uuidString).sock"
    let serverTransport = HTTP2ServerTransport.Posix(
        address: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext,
    )
    let server = GRPCServer(
        transport: productionServerTransport(serverTransport),
        services: [composition.exactMacService],
        interceptors: handlerContractTestInterceptors(),
    )
    let serverTask = Task { try await server.serve() }
    do {
        try await waitForInputDisconnectCondition("production UDS server bind") {
            FileManager.default.fileExists(atPath: socketPath)
        }
    } catch let startupError {
        server.beginGracefulShutdown()
        _ = await serverTask.result
        try removeExactInputDisconnectSocket(at: socketPath)
        throw startupError
    }

    let victimTransport: HTTP2ClientTransport.Posix
    let controlTransport: HTTP2ClientTransport.Posix
    do {
        victimTransport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
        )
        controlTransport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext,
        )
    } catch let clientSetupError {
        server.beginGracefulShutdown()
        _ = await serverTask.result
        try removeExactInputDisconnectSocket(at: socketPath)
        throw clientSetupError
    }

    let victim = GRPCClient(transport: victimTransport)
    let control = GRPCClient(transport: controlTransport)
    let victimConnections = Task { try await victim.runConnections() }
    let controlConnections = Task { try await control.runConnections() }
    let disconnectVictim: @Sendable () -> Void = {
        victimConnections.cancel()
    }

    var operationError: (any Error)?
    do {
        try await operation(victim, control, disconnectVictim)
    } catch {
        operationError = error
    }

    victim.beginGracefulShutdown()
    control.beginGracefulShutdown()
    victimConnections.cancel()
    _ = await victimConnections.result
    let controlResult = await controlConnections.result
    server.beginGracefulShutdown()
    let serverResult = await serverTask.result
    try removeExactInputDisconnectSocket(at: socketPath)

    try controlResult.get()
    try serverResult.get()
    if let operationError {
        throw operationError
    }
}

private func removeExactInputDisconnectSocket(at socketPath: String) throws {
    if FileManager.default.fileExists(atPath: socketPath) {
        try FileManager.default.removeItem(atPath: socketPath)
    }
    guard !FileManager.default.fileExists(atPath: socketPath) else {
        throw InputDisconnectTestError.socketCleanupFailed(socketPath)
    }
}

private func waitForInputDisconnectDrain(
    _ composition: ExactMacServiceComposition,
) async throws {
    try await waitForInputDisconnectCondition("input cleanup drain ownership") {
        let lifetime = await composition.serviceLifetime.lifecycleState()
        let gate = await composition.automationCoordinator.mutationGate.lifecycleState()
        return lifetime == .draining && gate == .draining
    }
}

private func waitForInputDisconnectCondition(
    _ label: String,
    operation: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await !operation() {
        guard clock.now < deadline else {
            throw InputDisconnectTestError.timeout(label)
        }
        await Task.yield()
    }
}

private enum InputDisconnectTestError: Error {
    case timeout(String)
    case unexpectedCancellationBoundaryReturn
    case unexpectedControlPrewarmSuccess
    case socketCleanupFailed(String)
}
