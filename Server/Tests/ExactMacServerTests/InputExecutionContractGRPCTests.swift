import CoreGraphics
import ExactMac
@testable import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct InputExecutionContractGRPCTests {
    @Test
    func `duplicate input id executes exactly once and returns already exists`() async throws {
        let recorder = BlockingInputContractExecutor()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )

        try await withInputExecutionClient(composition) { client in
            let request = inputExecutionCreateRequest(id: "one-execution")
            let first = Task {
                try await inputExecutionUnary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                ) as Exactmac_V1_Input
            }
            try await waitForInputExecutionCount(recorder, count: 1)

            let second = Task { () -> RPCError.Code? in
                do {
                    let _: Exactmac_V1_Input = try await inputExecutionUnary(
                        client: client,
                        request: request,
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                    return nil
                } catch let error as RPCError {
                    return error.code
                } catch {
                    Issue.record("Duplicate input returned unexpected error: \(error)")
                    return .unknown
                }
            }

            let secondCode = await second.value
            #expect(secondCode == .alreadyExists)
            await recorder.releaseFirst()
            let firstResponse = try await first.value
            expectCommittedInput(
                firstResponse,
                name: "applications/-/inputs/one-execution",
            )
        }

        #expect(await recorder.executionCount() == 1)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `queued input remains pending until physical admission`() async throws {
        let gate = PhysicalDesktopMutationGate(capacity: 2)
        let coordinator = AutomationCoordinator(
            mutationGate: gate,
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let blocker = InputMutationGateBlocker()
        let occupying = Task {
            try await coordinator.handlePhysicalMutation { _ in
                await blocker.hold()
            }
        }
        try await blocker.waitUntilEntered()

        try await withInputExecutionClient(composition) { client in
            let create = Task {
                try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(id: "queued"),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                ) as Exactmac_V1_Input
            }
            let name = "applications/-/inputs/queued"
            try await waitForInputGatePending(gate, count: 1)
            let queued = try #require(await composition.stateStore.getInput(name: name))
            #expect(queued.state == .pending)

            await blocker.release()
            try await occupying.value
            let completed = try await create.value
            expectCommittedInput(
                completed,
                name: "applications/-/inputs/queued",
            )
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `existing input identity wins over a target that later disappears`() async throws {
        let recorder = BlockingInputContractExecutor()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                try await recorder.execute(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/disappeared-target"
        await composition.stateStore.seedInputForTesting(
            Exactmac_V1_Input.with {
                $0.name = name
                $0.target.display = "displays/2"
                $0.action.mouseClick.position = Exactmac_Type_Point.with {
                    $0.x = 10
                    $0.y = 20
                }
                $0.state = .failed
                $0.error = "Target disappeared after the original reservation"
                $0.deliveryResult.commitment = .noEffect
                $0.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            },
        )
        let request = Exactmac_V1_CreateInputRequest.with {
            $0.parent = "applications/-"
            $0.inputID = "disappeared-target"
            $0.input.target.display = "displays/2"
            $0.input.action.mouseClick.position = Exactmac_Type_Point.with {
                $0.x = 10
                $0.y = 20
            }
        }

        try await withInputExecutionClient(composition) { client in
            do {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Expected duplicate input identity rejection")
            } catch let error as RPCError {
                #expect(error.code == .alreadyExists)
            }
        }

        #expect(await recorder.executionCount() == 0)
        #expect(await composition.stateStore.getInput(name: name)?.state == .failed)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `display target rejects cross display points while desktop accepts the active union`() async throws {
        let recorder = InputExecutionCountRecorder()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )

        try await withInputExecutionClient(composition) { client in
            let crossDisplay = inputExecutionClickRequest(
                id: "cross-display",
                target: .display("displays/1"),
                point: CGPoint(x: 2500, y: 20),
            )
            do {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: crossDisplay,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Expected exact display containment rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
            #expect(await recorder.executionCount() == 0)
            #expect(
                await composition.stateStore.getInput(
                    name: "applications/-/inputs/cross-display",
                ) == nil,
            )
            #expect(
                await composition.stateStore.inputStateHistory(
                    name: "applications/-/inputs/cross-display",
                ).isEmpty,
            )

            let desktop: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: inputExecutionClickRequest(
                    id: "desktop-union",
                    target: .desktop(true),
                    point: CGPoint(x: 2500, y: 20),
                ),
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            expectCommittedInput(
                desktop,
                name: "applications/-/inputs/desktop-union",
            )
            #expect(await recorder.executionCount() == 1)

            let crossDisplayDrag = Exactmac_V1_CreateInputRequest.with {
                $0.parent = "applications/-"
                $0.inputID = "cross-display-drag"
                $0.input.target.display = "displays/1"
                $0.input.action.mouseDrag.waypoints = [
                    Exactmac_Type_Point.with { $0.x = 10; $0.y = 20 },
                    Exactmac_Type_Point.with { $0.x = 2500; $0.y = 20 },
                    Exactmac_Type_Point.with { $0.x = 30; $0.y = 40 },
                ]
            }
            do {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: crossDisplayDrag,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Expected drag waypoint containment rejection")
            } catch let error as RPCError {
                #expect(error.code == .invalidArgument)
            }
            #expect(await recorder.executionCount() == 1)

            let retriedDisplay: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: inputExecutionClickRequest(
                    id: "cross-display",
                    target: .display("displays/1"),
                    point: CGPoint(x: 40, y: 50),
                ),
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            expectCommittedInput(
                retriedDisplay,
                name: "applications/-/inputs/cross-display",
                target: .display("displays/1"),
            )
            #expect(await recorder.executionCount() == 2)
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `display target rejects points claimed by overlapping active displays`() async throws {
        let recorder = InputExecutionCountRecorder()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: OverlappingInputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/ambiguous-display-point"

        try await withInputExecutionClient(composition) { client in
            await expectInputExecutionRPCError(.failedPrecondition) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionClickRequest(
                        id: "ambiguous-display-point",
                        target: .display("displays/1"),
                        point: CGPoint(x: 40, y: 50),
                    ),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
        }

        #expect(await recorder.executionCount() == 0)
        #expect(await composition.stateStore.getInput(name: name) == nil)
        #expect(await composition.stateStore.inputStateHistory(name: name).isEmpty)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `executor receipt on the wrong route cannot complete an input`() async throws {
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, _, _ in
                committedInputExecutionReceipt(
                    for: action,
                    route: .process(999),
                )
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/wrong-route"

        try await withInputExecutionClient(composition) { client in
            do {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(id: "wrong-route"),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Expected wrong-route receipt rejection")
            } catch let error as RPCError {
                #expect(error.code == .internalError)
            }
        }

        let failed = try #require(
            await composition.stateStore.getInput(name: name),
        )
        #expect(failed.state == .failed)
        #expect(failed.deliveryResult.commitment == .possiblyCommitted)
        #expect(failed.deliveryResult.postedEventCount == 2)
        #expect(!failed.deliveryResult.routedDeliveryObserved)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `overlay failure after physical receipt preserves possibly committed evidence`() async throws {
        let physical = InputExecutionCountRecorder()
        let overlay = FailingInputOverlayRecorder()
        let presenter = InputOverlayPresenter { presentation in
            try await overlay.render(presentation)
        }
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await physical.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            inputOverlayPresenter: presenter,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/overlay-failure"
        var configuredRequest = inputExecutionCreateRequest(id: "overlay-failure")
        configuredRequest.input.action.visualFeedback = true
        configuredRequest.input.action.animationDuration = 0.25
        let request = configuredRequest

        try await withInputExecutionClient(composition) { client in
            let failed: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: request,
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            #expect(failed.name == name)
            #expect(failed.state == .failed)
            #expect(failed.deliveryResult.commitment == .possiblyCommitted)
            #expect(failed.deliveryResult.postedEventCount == 2)
            #expect(failed.deliveryResult.routedDeliveryObserved)
            #expect(!failed.error.isEmpty)
        }

        #expect(await physical.executionCount() == 1)
        #expect(await overlay.presentationCount() == 1)
        #expect(await presenter.activeReservationCount() == 0)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `partial and malformed executor receipts fail with conservative terminal evidence`() async throws {
        struct ReceiptCase: Sendable {
            let id: String
            let postedEventCount: Int
            let observed: Bool
            let persistedCount: Int32
        }
        let cases = [
            ReceiptCase(
                id: "partial",
                postedEventCount: 1,
                observed: true,
                persistedCount: 1,
            ),
            ReceiptCase(
                id: "negative",
                postedEventCount: Int.min,
                observed: false,
                persistedCount: 0,
            ),
            ReceiptCase(
                id: "zero-observed",
                postedEventCount: 0,
                observed: true,
                persistedCount: 1,
            ),
            ReceiptCase(
                id: "extra",
                postedEventCount: 3,
                observed: true,
                persistedCount: 3,
            ),
            ReceiptCase(
                id: "overflow",
                postedEventCount: Int.max,
                observed: true,
                persistedCount: Int32.max,
            ),
        ]

        for receiptCase in cases {
            let coordinator = AutomationCoordinator(
                activationSystem: MockSystemOperations(),
                inputPostAccessChecker: { true },
                inputActionExecutor: { _, route, _ in
                    ExactMac.InputExecutionReceipt(
                        route: route,
                        postedEventCount: receiptCase.postedEventCount,
                        routedDeliveryObserved: receiptCase.observed,
                    )
                },
            )
            let composition = ExactMacServiceComposition(
                system: MockSystemOperations(),
                automationCoordinator: coordinator,
                displayTopologyProvider: InputExecutionTopologyProvider(),
            )
            let name = "applications/-/inputs/\(receiptCase.id)"

            try await withInputExecutionClient(composition) { client in
                await expectInputExecutionRPCError(.internalError) {
                    let _: Exactmac_V1_Input = try await inputExecutionUnary(
                        client: client,
                        request: inputExecutionCreateRequest(id: receiptCase.id),
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                }
            }

            let failed = try #require(
                await composition.stateStore.getInput(name: name),
            )
            #expect(failed.state == .failed)
            #expect(failed.deliveryResult.commitment == .possiblyCommitted)
            #expect(failed.deliveryResult.postedEventCount == receiptCase.persistedCount)
            #expect(
                failed.deliveryResult.routedDeliveryObserved
                    == receiptCase.observed,
            )
            #expect(await composition.stateStore.activeInputIdentityCount() == 0)
            await composition.serviceLifetime.shutdown()
        }
    }

    @Test
    func `successful cursor sink cannot be persisted as no effect`() async throws {
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { _, route, _ in
                throw ExactMac.InputExecutionFailure(
                    underlying: InputExecutionContractError.convergence(
                        "failed after cursor warp",
                    ),
                    route: route,
                    postedEventCount: 0,
                    routedDeliveryObserved: false,
                    physicalEffectOccurred: true,
                )
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/cursor-effect"

        try await withInputExecutionClient(composition) { client in
            let terminal: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: inputExecutionCreateRequest(id: "cursor-effect"),
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            #expect(terminal.state == .failed)
            #expect(terminal.deliveryResult.commitment == .possiblyCommitted)
            #expect(terminal.deliveryResult.postedEventCount == 0)
            #expect(!terminal.deliveryResult.routedDeliveryObserved)
        }

        let stored = try #require(
            await composition.stateStore.getInput(name: name),
        )
        #expect(stored.state == .failed)
        #expect(stored.deliveryResult.commitment == .possiblyCommitted)
        #expect(stored.deliveryResult.postedEventCount == 0)
        #expect(!stored.deliveryResult.routedDeliveryObserved)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `executor consumes supplied boundary and stops after topology drift`() async throws {
        let topology = MutableInputExecutionTopologyProvider()
        let effect = ExactMac.InputPhysicalEffect.mouseDown(
            point: CGPoint(x: 10, y: 20),
            button: .left,
            modifiers: [],
            clickCount: 1,
        )
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { _, _, boundary in
                try await boundary.validateEffect(effect)
                topology.replaceWithShiftedTopology()
                try await boundary.validateEffect(effect)
                Issue.record("Topology drift should reject the next effect")
                throw InputExecutionContractError.convergence(
                    "topology drift was ignored",
                )
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: topology,
        )
        let name = "applications/-/inputs/boundary-topology-drift"

        try await withInputExecutionClient(composition) { client in
            await expectInputExecutionRPCError(.failedPrecondition) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(
                        id: "boundary-topology-drift",
                    ),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
        }

        let stored = try #require(
            await composition.stateStore.getInput(name: name),
        )
        #expect(stored.state == .failed)
        #expect(stored.deliveryResult.commitment == .noEffect)
        #expect(stored.deliveryResult.postedEventCount == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `duplicate identity wins before dynamic admission and executes no new work`() async throws {
        let admission = LockedInputAdmissionProbe(postAccess: false)
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputKeyResolver: admission.resolveKey,
            inputPostAccessChecker: admission.checkPostAccess,
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/permanent-duplicate"
        await composition.stateStore.seedInputForTesting(
            terminalInputFixture(name: name),
        )
        var request = inputExecutionCreateRequest(id: "permanent-duplicate")
        request.input.action = Exactmac_V1_InputAction.with {
            $0.keyPress.key = "a"
        }
        let duplicateRequest = request

        try await withInputExecutionClient(composition) { client in
            await expectInputExecutionRPCError(.alreadyExists) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: duplicateRequest,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
        }

        #expect(admission.snapshot().postAccessChecks == 0)
        #expect(admission.snapshot().keyCodeResolutions == 0)
        #expect(await composition.stateStore.getInput(name: name)?.state == .failed)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `duplicate modifiers and display keyboard targets fail before dynamic admission`() async throws {
        let admission = LockedInputAdmissionProbe(postAccess: true)
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputKeyResolver: admission.resolveKey,
            inputPostAccessChecker: admission.checkPostAccess,
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )

        try await withInputExecutionClient(composition) { client in
            var duplicateModifiers = inputExecutionCreateRequest(id: "duplicate-modifiers")
            duplicateModifiers.input.action.mouseClick.modifiers = [.shift, .shift]
            await expectInputExecutionRPCError(.invalidArgument) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: duplicateModifiers,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }

            let displayKeyboard = Exactmac_V1_CreateInputRequest.with {
                $0.parent = "applications/-"
                $0.inputID = "display-keyboard"
                $0.input.target.display = "displays/1"
                $0.input.action.keyPress.key = "a"
            }
            await expectInputExecutionRPCError(.invalidArgument) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: displayKeyboard,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
        }

        let admissionSnapshot = admission.snapshot()
        #expect(admissionSnapshot.postAccessChecks == 0)
        #expect(admissionSnapshot.keyCodeResolutions == 0)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.stateStore.listInputs(parent: "applications/-").isEmpty)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `layout dependent keys require a source fingerprint while named keys do not`() async throws {
        let recorder = InputExecutionCountRecorder()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputKeyResolver: { _ in
                ResolvedInputKey(keyCode: 36, sourceIdentity: nil)
            },
            keyboardInputSourceIdentityProvider: { nil },
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )

        try await withInputExecutionClient(composition) { client in
            var character = inputExecutionCreateRequest(id: "missing-layout-fingerprint")
            character.input.action = Exactmac_V1_InputAction.with {
                $0.keyPress.key = "a"
            }
            await expectInputExecutionRPCError(.invalidArgument) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: character,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }

            var named = inputExecutionCreateRequest(id: "layout-independent-return")
            named.input.action = Exactmac_V1_InputAction.with {
                $0.keyPress.key = "return"
            }
            let completed: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: named,
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            expectCommittedInput(
                completed,
                name: "applications/-/inputs/layout-independent-return",
            )
        }

        #expect(
            await composition.stateStore.getInput(
                name: "applications/-/inputs/missing-layout-fingerprint",
            ) == nil,
        )
        #expect(await recorder.executionCount() == 1)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `get and list preserve terminal application input after owner exit`() async throws {
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let identity = ApplicationProcessIdentity(
            pid: 7711,
            startTimeSeconds: 123,
            startTimeMicroseconds: 456,
            bundleIdentifier: "com.example.TerminalHistory",
            executablePath: "/Applications/TerminalHistory.app/Contents/MacOS/TerminalHistory",
        )
        let parent = applicationResourceName(for: identity)
        let application = Exactmac_V1_Application.with {
            $0.name = parent
            $0.pid = Int32(identity.pid)
            $0.displayName = "Terminal History"
        }
        await composition.stateStore.addTarget(application, processIdentity: identity)
        let input = terminalInputFixture(
            name: "\(parent)/inputs/persisted",
            target: .application(parent),
        )
        await composition.stateStore.seedInputForTesting(input)
        _ = await composition.stateStore.removeTarget(name: parent)

        try await withInputExecutionClient(composition) { client in
            let fetched: Exactmac_V1_Input = try await inputExecutionUnary(
                client: client,
                request: Exactmac_V1_GetInputRequest.with { $0.name = input.name },
                descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
            )
            #expect(fetched == input)

            let listed: Exactmac_V1_ListInputsResponse = try await inputExecutionUnary(
                client: client,
                request: Exactmac_V1_ListInputsRequest.with { $0.parent = parent },
                descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
            )
            #expect(listed.inputs == [input])
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `rpc cancellation joins resistant prepublication work and releases identity`() async throws {
        let topology = BlockingInputExecutionTopologyProvider()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputKeyResolver: { _ in
                ResolvedInputKey(keyCode: 0, sourceIdentity: nil)
            },
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: topology,
        )
        let cancellation = ServerContext.RPCCancellationHandle()
        let context = ServerContext(
            descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            remotePeer: "in-process:input-transaction-tests",
            localPeer: "in-process:server",
            cancellation: cancellation,
        )
        let request = inputExecutionCreateRequest(id: "cancel-before-publish")
        let call = Task {
            try await composition.exactMacService.createInput(
                request: ServerRequest(metadata: Metadata(), message: request),
                context: context,
            )
        }

        await topology.waitUntilEntered()
        cancellation.cancel()
        try await waitForActiveInputIdentityCount(composition.stateStore, count: 1)
        #expect(await composition.automationCoordinator.activeMutationCount() == 1)
        #expect(
            await composition.stateStore.getInput(
                name: "applications/-/inputs/cancel-before-publish",
            ) == nil,
        )

        await topology.release()
        await expectInputExecutionRPCError(.cancelled) {
            _ = try await call.value
        }
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(
            await composition.stateStore.getInput(
                name: "applications/-/inputs/cancel-before-publish",
            ) == nil,
        )

        let retried = try await composition.exactMacService.createInput(
            request: ServerRequest(metadata: Metadata(), message: request),
            context: ServerContext(
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                remotePeer: "in-process:input-transaction-tests",
                localPeer: "in-process:server",
                cancellation: ServerContext.RPCCancellationHandle(),
            ),
        )
        try expectCommittedInput(
            retried.message,
            name: "applications/-/inputs/cancel-before-publish",
        )
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `duplicate identity wins during drain while new identity is unavailable`() async throws {
        let topology = DrainBlockingInputExecutionTopologyProvider()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
            displayTopologyProvider: topology,
        )
        let name = "applications/-/inputs/drain-duplicate"

        try await withInputExecutionClient(composition) { client in
            defer { topology.release() }
            let first = Task<Exactmac_V1_Input, any Error> {
                try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(id: "drain-duplicate"),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
            try await topology.waitUntilEntered()
            #expect(await composition.stateStore.activeInputIdentityCount() == 1)
            #expect(await composition.stateStore.getInput(name: name) == nil)

            let shutdown = Task {
                await composition.serviceLifetime.shutdown()
            }
            try await waitForInputDrain(
                composition.serviceLifetime,
                gate: composition.automationCoordinator.mutationGate,
            )

            await expectInputExecutionRPCError(.alreadyExists) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(id: "drain-duplicate"),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }
            await expectInputExecutionRPCError(.unavailable) {
                let _: Exactmac_V1_Input = try await inputExecutionUnary(
                    client: client,
                    request: inputExecutionCreateRequest(id: "new-during-drain"),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
            }

            #expect(await composition.automationCoordinator.activeMutationCount() == 1)
            #expect(await composition.stateStore.activeInputIdentityCount() == 1)
            #expect(await composition.stateStore.getInput(name: name) == nil)
            topology.release()
            await expectInputExecutionTaskCancellation(first)
            await shutdown.value
        }

        #expect(await composition.stateStore.getInput(name: name) == nil)
        #expect(
            await composition.stateStore.getInput(
                name: "applications/-/inputs/new-during-drain",
            ) == nil,
        )
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(await composition.serviceLifetime.lifecycleState() == .drained)
    }

    @Test
    func `generated client deadline and drain retain executing cleanup ownership`() async throws {
        let cleanup = ResistantInputCleanupProbe()
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
            displayTopologyProvider: InputExecutionTopologyProvider(),
        )
        let name = "applications/-/inputs/cancel-during-cleanup"

        try await withInputExecutionClient(composition) { client in
            defer { cleanup.releaseCleanup() }
            let request = inputExecutionCreateRequest(id: "cancel-during-cleanup")
            var metadata = Metadata()
            metadata.addString("100m", forKey: "grpc-timeout")
            let call = Task {
                try await inputExecutionUnary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    metadata: metadata,
                ) as Exactmac_V1_Input
            }

            try await cleanup.waitUntilExecutionStarted()
            try await waitForInputState(
                composition.stateStore,
                name: name,
                state: .executing,
            )
            try await cleanup.waitUntilCleanupStarted()

            let shutdown = Task {
                await composition.serviceLifetime.shutdown()
            }
            try await waitForInputDrain(
                composition.serviceLifetime,
                gate: composition.automationCoordinator.mutationGate,
            )

            #expect(await composition.automationCoordinator.activeMutationCount() == 1)
            #expect(await composition.stateStore.activeInputIdentityCount() == 1)
            #expect(await composition.stateStore.getInput(name: name)?.state == .executing)
            #expect(cleanup.outstandingCleanupObligationCount == 2)
            #expect(await composition.serviceLifetime.lifecycleState() == .draining)
            #expect(
                await composition.automationCoordinator.mutationGate.lifecycleState()
                    == .draining,
            )

            cleanup.releaseCleanup()
            do {
                _ = try await call.value
                Issue.record("Expected generated client deadline cancellation")
            } catch let error as RPCError {
                #expect(error.code == .cancelled)
            } catch {
                Issue.record("Expected cancellation RPCError, got \(error)")
            }
            await shutdown.value
        }

        let terminal = try #require(
            await composition.stateStore.getInput(name: name),
        )
        #expect(terminal.state == .cancelled)
        #expect(terminal.deliveryResult.commitment == .possiblyCommitted)
        #expect(terminal.deliveryResult.postedEventCount == 1)
        #expect(terminal.deliveryResult.routedDeliveryObserved)
        #expect(cleanup.outstandingCleanupObligationCount == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.serviceLifetime.lifecycleState() == .drained)
        #expect(
            await composition.automationCoordinator.mutationGate.lifecycleState()
                == .drained,
        )
    }
}

private final class ResistantInputCleanupProbe: @unchecked Sendable {
    private let executionStarted = InputExecutionOneShotSignal()
    private let cleanupStarted = InputExecutionOneShotSignal()
    private let cancellationBoundary = InputExecutionCancellationBoundary()
    private let cleanupRelease = InputExecutionOneShotSignal()
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
            throw InputExecutionContractError.convergence(
                "input executor cancellation",
            )
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
        try await waitForInputExecutionSignal(
            executionStarted,
            label: "input executor entry",
        )
    }

    func waitUntilCleanupStarted() async throws {
        try await waitForInputExecutionSignal(
            cleanupStarted,
            label: "input cleanup entry",
        )
    }

    func releaseCleanup() {
        cleanupRelease.signal()
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock { outstandingObligations }
    }
}

private final class InputExecutionOneShotSignal: @unchecked Sendable {
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

private final class InputExecutionCancellationBoundary: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case waiting(CheckedContinuation<Void, any Error>)
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .awaitingContinuation

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
                        preconditionFailure(
                            "input cancellation boundary installed twice",
                        )
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

private actor BlockingInputContractExecutor {
    private var count = 0
    private var firstRelease: CheckedContinuation<Void, Never>?

    func execute(_: ExactMac.InputAction) async throws {
        count += 1
        guard count == 1 else { return }
        await withCheckedContinuation { continuation in
            firstRelease = continuation
        }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func executionCount() -> Int {
        count
    }
}

private actor InputMutationGateBlocker {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async throws {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor InputExecutionCountRecorder {
    private var actions: [ExactMac.InputAction] = []

    func record(_ action: ExactMac.InputAction) {
        actions.append(action)
    }

    func executionCount() -> Int {
        actions.count
    }
}

private actor FailingInputOverlayRecorder {
    private var presentations: [InputOverlayPresentation] = []

    func render(_ presentation: InputOverlayPresentation) throws {
        presentations.append(presentation)
        throw InputExecutionContractError.convergence("injected overlay failure")
    }

    func presentationCount() -> Int {
        presentations.count
    }
}

private final class LockedInputAdmissionProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let postAccessChecks: Int
        let keyCodeResolutions: Int
    }

    private let lock = NSLock()
    private let postAccess: Bool
    private var postAccessChecks = 0
    private var keyCodeResolutions = 0

    init(postAccess: Bool) {
        self.postAccess = postAccess
    }

    func checkPostAccess() -> Bool {
        lock.lock()
        postAccessChecks += 1
        let allowed = postAccess
        lock.unlock()
        return allowed
    }

    func resolveKey(_: String) -> ResolvedInputKey? {
        lock.lock()
        keyCodeResolutions += 1
        lock.unlock()
        return ResolvedInputKey(keyCode: 0, sourceIdentity: nil)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            postAccessChecks: postAccessChecks,
            keyCodeResolutions: keyCodeResolutions,
        )
        lock.unlock()
        return snapshot
    }
}

private actor BlockingInputExecutionTopologyProvider: DisplayTopologyProviding {
    private var shouldBlock = true
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func snapshot() async throws -> DisplayTopologySnapshot {
        if shouldBlock {
            shouldBlock = false
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return try await InputExecutionTopologyProvider().snapshot()
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 10, y: 20)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class DrainBlockingInputExecutionTopologyProvider:
    DisplayTopologyProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let entered = InputExecutionOneShotSignal()
    private let released = InputExecutionOneShotSignal()
    private var firstSnapshot = true

    func snapshot() async throws -> DisplayTopologySnapshot {
        let shouldBlock = lock.withLock {
            defer { firstSnapshot = false }
            return firstSnapshot
        }
        if shouldBlock {
            entered.signal()
            await released.wait()
        }
        return try await InputExecutionTopologyProvider().snapshot()
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 10, y: 20)
    }

    func waitUntilEntered() async throws {
        try await waitForInputExecutionSignal(
            entered,
            label: "drain-blocked target resolution",
        )
    }

    func release() {
        released.signal()
    }
}

private func inputExecutionCreateRequest(
    id: String,
) -> Exactmac_V1_CreateInputRequest {
    Exactmac_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = id
        $0.input.target.desktop = true
        $0.input.action.mouseClick = Exactmac_V1_MouseClick.with {
            $0.position = Exactmac_Type_Point.with {
                $0.x = 10
                $0.y = 20
            }
        }
    }
}

private func inputExecutionClickRequest(
    id: String,
    target: Exactmac_V1_InputTarget.OneOf_Destination,
    point: CGPoint,
) -> Exactmac_V1_CreateInputRequest {
    Exactmac_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = id
        $0.input.target.destination = target
        $0.input.action.mouseClick.position = Exactmac_Type_Point.with {
            $0.x = point.x
            $0.y = point.y
        }
    }
}

private func expectCommittedInput(
    _ input: Exactmac_V1_Input,
    name: String,
    target: Exactmac_V1_InputTarget.OneOf_Destination = .desktop(true),
) {
    #expect(input.name == name)
    #expect(input.state == .completed)
    #expect(input.target.destination == target)
    #expect(input.hasCreateTime)
    #expect(input.hasCompleteTime)
    #expect(input.error.isEmpty)
    #expect(input.deliveryResult.commitment == .committedAndSettled)
    #expect(input.deliveryResult.postedEventCount == 2)
    #expect(input.deliveryResult.routedDeliveryObserved)
}

private func terminalInputFixture(
    name: String,
    target: Exactmac_V1_InputTarget.OneOf_Destination = .desktop(true),
) -> Exactmac_V1_Input {
    Exactmac_V1_Input.with {
        $0.name = name
        $0.action.mouseClick.position = Exactmac_Type_Point.with {
            $0.x = 10
            $0.y = 20
        }
        $0.target.destination = target
        $0.state = .failed
        $0.error = "persisted terminal fixture"
        $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp.with { $0.seconds = 1 }
        $0.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp.with { $0.seconds = 2 }
        $0.deliveryResult.commitment = .noEffect
    }
}

private struct InputExecutionTopologyProvider: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
                isMain: true,
                scale: 2,
            ),
            DisplayTopologyDisplay(
                displayID: 2,
                frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 1920, y: 24, width: 1920, height: 1056),
                isMain: false,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 10, y: 20)
    }
}

private final class MutableInputExecutionTopologyProvider:
    DisplayTopologyProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var shifted = false

    func snapshot() async throws -> DisplayTopologySnapshot {
        let originX = lock.withLock { shifted ? 4000.0 : 0.0 }
        return DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(
                    x: originX,
                    y: 0,
                    width: 1920,
                    height: 1080,
                ),
                visibleFrame: CGRect(
                    x: originX,
                    y: 24,
                    width: 1920,
                    height: 1056,
                ),
                isMain: true,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 10, y: 20)
    }

    func replaceWithShiftedTopology() {
        lock.withLock {
            shifted = true
        }
    }
}

private struct OverlappingInputExecutionTopologyProvider: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
                isMain: true,
                scale: 2,
            ),
            DisplayTopologyDisplay(
                displayID: 2,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
                isMain: false,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 40, y: 50)
    }
}

private func waitForInputExecutionCount(
    _ recorder: BlockingInputContractExecutor,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await recorder.executionCount() < count {
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence("executor count")
        }
        await Task.yield()
    }
}

private func waitForInputGatePending(
    _ gate: PhysicalDesktopMutationGate,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await gate.pendingCount() != count {
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence("mutation queue")
        }
        await Task.yield()
    }
}

private func waitForActiveInputIdentityCount(
    _ store: AppStateStore,
    count: Int,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await store.activeInputIdentityCount() != count {
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence("active input identity count")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitForInputState(
    _ store: AppStateStore,
    name: String,
    state: Exactmac_V1_Input.State,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await store.getInput(name: name)?.state != state {
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence(
                "input state \(state)",
            )
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitForInputExecutionSignal(
    _ signal: InputExecutionOneShotSignal,
    label: String,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !signal.isSignalled {
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence(label)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitForInputDrain(
    _ lifetime: ServiceLifetime,
    gate: PhysicalDesktopMutationGate,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while true {
        let lifetimeState = await lifetime.lifecycleState()
        let gateState = await gate.lifecycleState()
        if lifetimeState == .draining, gateState != .accepting {
            return
        }
        guard clock.now < deadline else {
            throw InputExecutionContractError.convergence(
                "input service drain ownership",
            )
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func expectInputExecutionRPCError(
    _ expectedCode: RPCError.Code,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected RPC error \(expectedCode)")
    } catch let error as RPCError {
        #expect(error.code == expectedCode, Comment(rawValue: String(describing: error)))
    } catch {
        Issue.record("Expected RPCError, got \(error)")
    }
}

private func expectInputExecutionTaskCancellation(
    _ task: Task<Exactmac_V1_Input, any Error>,
) async {
    do {
        _ = try await task.value
        Issue.record("Expected input task cancellation")
    } catch let error as RPCError {
        #expect(error.code == .cancelled)
    } catch {
        Issue.record("Expected cancellation RPCError, got \(error)")
    }
}

private func withInputExecutionClient(
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

private func inputExecutionUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
    metadata: Metadata = Metadata(),
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request, metadata: metadata),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: .defaults,
    ) { response in
        try response.message
    }
}

private enum InputExecutionContractError: Error {
    case convergence(String)
}
