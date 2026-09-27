import ApplicationServices
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
struct MacroInputTransactionGRPCTests {
    @Test
    func `every recursively physical graph requires exact application before LRO creation`() async throws {
        let sink = MacroTransactionInputSink()
        let coordinator = AutomationCoordinator(
            activationSystem: MockSystemOperations(),
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                _ = await sink.record(action: action, route: route)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            automationCoordinator: coordinator,
        )
        let probes: [(label: String, action: Exactmac_V1_MacroAction)] = [
            (
                "direct input in a zero-count loop",
                Exactmac_V1_MacroAction.with {
                    $0.loop.count = 0
                    $0.loop.actions = [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 10, y: 20)
                        },
                    ]
                },
            ),
            (
                "ClickElement in an unreachable conditional branch",
                Exactmac_V1_MacroAction.with {
                    $0.conditional.condition.variableCondition.variable = "missing"
                    $0.conditional.condition.variableCondition.value = "true"
                    $0.conditional.thenActions = [
                        Exactmac_V1_MacroAction.with {
                            $0.methodCall.method = "ClickElement"
                            $0.methodCall.args = ["selector": "role:Button"]
                        },
                    ]
                },
            ),
            (
                "TypeText nested in a loop and conditional",
                Exactmac_V1_MacroAction.with {
                    $0.loop.count = 1
                    $0.loop.actions = [
                        Exactmac_V1_MacroAction.with {
                            $0.conditional.condition.variableCondition.variable = "missing"
                            $0.conditional.condition.variableCondition.value = "true"
                            $0.conditional.thenActions = [
                                Exactmac_V1_MacroAction.with {
                                    $0.assignment.variable = "branch"
                                    $0.assignment.literal = "then"
                                },
                            ]
                            $0.conditional.elseActions = [
                                Exactmac_V1_MacroAction.with {
                                    $0.methodCall.method = "TypeText"
                                    $0.methodCall.args = ["text": "must-not-type"]
                                },
                            ]
                        },
                    ]
                },
            ),
        ]

        do {
            try await withMacroTransactionClient(composition) { client in
                for probe in probes {
                    try await withMacroTransactionMacro(
                        actions: [probe.action],
                        label: probe.label,
                        registry: composition.macroRegistry,
                    ) { macroName in
                        for application in ["", "applications/-"] {
                            await expectMacroTransactionRPCError(.invalidArgument) {
                                let _: Google_Longrunning_Operation =
                                    try await macroTransactionUnary(
                                        client: client,
                                        request: Exactmac_V1_ExecuteMacroRequest.with {
                                            $0.macro = macroName
                                            $0.application = application
                                        },
                                        descriptor:
                                        Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                                    )
                            }
                        }
                    }
                }

                let operations = await composition.operationStore.listOperations()
                #expect(operations.operations.isEmpty)
                #expect(await composition.operationStore.executionTaskCount() == 0)
                let inputState = await composition.stateStore.currentState()
                #expect(inputState.inputs.isEmpty)
                #expect(await composition.stateStore.activeInputIdentityCount() == 0)
                #expect(await composition.stateStore.inputStateHistoryCount() == 0)
                #expect(await composition.automationCoordinator.activeMutationCount() == 0)
                #expect(await sink.count() == 0)
            }
        } catch {
            await composition.serviceLifetime.shutdown()
            throw error
        }
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `nonphysical graph may omit application and completes through public operations`() async throws {
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        do {
            try await withMacroTransactionClient(composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.assignment.variable = "result"
                            $0.assignment.literal = "nonphysical"
                        },
                    ],
                    label: "nonphysical",
                    registry: composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == 0)
                    let response = try Exactmac_V1_ExecuteMacroResponse(
                        serializedBytes: terminal.response.value,
                    )
                    #expect(response.success)
                    #expect(response.executedActionCount == 1)
                }
            }
        } catch {
            await composition.serviceLifetime.shutdown()
            throw error
        }
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `supplied macro application fails closed without discovery or LRO creation`() async throws {
        let catalog = MacroTransactionCatalog()
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(),
            applicationCatalogProvider: catalog,
        )
        let probes: [(application: String, code: RPCError.Code)] = [
            ("applications/-", .invalidArgument),
            ("applications/not/a/resource", .invalidArgument),
            ("applications/\(String(repeating: "a", count: 64))", .notFound),
        ]

        do {
            try await withMacroTransactionClient(composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.assignment.variable = "value"
                            $0.assignment.literal = "nonphysical"
                        },
                    ],
                    label: "strict-application",
                    registry: composition.macroRegistry,
                ) { macroName in
                    for probe in probes {
                        await expectMacroTransactionRPCError(probe.code) {
                            let _: Google_Longrunning_Operation =
                                try await macroTransactionUnary(
                                    client: client,
                                    request: Exactmac_V1_ExecuteMacroRequest.with {
                                        $0.macro = macroName
                                        $0.application = probe.application
                                    },
                                    descriptor:
                                    Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                                )
                        }
                    }
                }
                #expect(await (composition.operationStore.listOperations()).operations.isEmpty)
                #expect(await catalog.bundleReadCount() == 0)
                #expect(await catalog.runningReadCount() == 0)
            }
        } catch {
            await composition.serviceLifetime.shutdown()
            throw error
        }
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `nested physical executions create exact ordinal Input transactions`() async throws {
        let fixture = await MacroTransactionFixture.make()
        let action = Exactmac_V1_InputAction.with {
            $0.mouseMove.position = point(x: 40, y: 50)
        }
        let nestedLoop = Exactmac_V1_MacroAction.with {
            $0.loop.count = 2
            $0.loop.actions = [
                Exactmac_V1_MacroAction.with {
                    $0.input = action
                },
            ]
        }

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [nestedLoop],
                    label: "ordinal-inputs",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == 0)

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let expectedNames = (0 ..< 2).map {
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-\($0)"
                    }
                    let listed: Exactmac_V1_ListInputsResponse =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ListInputsRequest.with {
                                $0.parent = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
                        )
                    #expect(listed.inputs.map(\.name) == expectedNames)
                    for input in listed.inputs {
                        #expect(input.action == action)
                        #expect(input.target.application == fixture.applicationName)
                        #expect(input.state == .completed)
                        #expect(input.error.isEmpty)
                        #expect(input.hasDeliveryResult)
                        #expect(input.deliveryResult.commitment == .committedAndSettled)
                        #expect(input.deliveryResult.postedEventCount == 1)
                        #expect(input.deliveryResult.routedDeliveryObserved)
                        #expect(await fixture.composition.stateStore.inputStateHistory(
                            name: input.name,
                        ) == [.pending, .executing, .completed])
                    }
                    #expect(await fixture.sink.count() == 2)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `ClickElement and TypeText create exact ordinal Input transactions`() async throws {
        let fixture = await MacroTransactionFixture.make()
        await fixture.composition.elementRegistry.bindApplication(
            name: fixture.applicationName,
            pid: fixture.identity.pid,
        )
        let elementID = try await fixture.composition.elementRegistry.registerElement(
            Exactmac_V1_Element.with {
                $0.role = "AXButton"
                $0.x = 20
                $0.y = 30
                $0.width = 40
                $0.height = 20
            },
            pid: fixture.identity.pid,
        )
        let actions = [
            Exactmac_V1_MacroAction.with {
                $0.methodCall.method = "ClickElement"
                $0.methodCall.args = ["elementId": elementID]
            },
            Exactmac_V1_MacroAction.with {
                $0.methodCall.method = "TypeText"
                $0.methodCall.args = ["text": "exact"]
            },
        ]

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: actions,
                    label: "method-inputs",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == 0)

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let listed: Exactmac_V1_ListInputsResponse =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ListInputsRequest.with {
                                $0.parent = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
                        )
                    #expect(listed.inputs.map(\.name) == [
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0",
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-1",
                    ])
                    if listed.inputs.count == 2 {
                        #expect(listed.inputs[0].action.mouseClick.position == point(x: 40, y: 40))
                        #expect(listed.inputs[1].action.textInput.text == "exact")
                        for input in listed.inputs {
                            #expect(input.target.application == fixture.applicationName)
                            #expect(input.state == .completed)
                            #expect(input.deliveryResult.commitment == .committedAndSettled)
                            #expect(input.deliveryResult.postedEventCount > 0)
                            #expect(input.deliveryResult.routedDeliveryObserved)
                            #expect(await fixture.composition.stateStore.inputStateHistory(
                                name: input.name,
                            ) == [.pending, .executing, .completed])
                        }
                    }
                    #expect(await fixture.sink.count() == 2)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `terminal failed Input stops the physical macro graph`() async throws {
        let fixture = await MacroTransactionFixture.make(failFirstInput: true)

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 45, y: 55)
                        },
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 65, y: 75)
                        },
                    ],
                    label: "failed-input-stops-graph",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.internalError.rawValue))

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let firstName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    let secondName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-1"
                    let failed: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = firstName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(failed.state == .failed)
                    #expect(!failed.error.isEmpty)
                    #expect(failed.deliveryResult.commitment == .noEffect)
                    #expect(failed.deliveryResult.postedEventCount == 0)
                    #expect(!failed.deliveryResult.routedDeliveryObserved)
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: firstName,
                    ) == [.pending, .executing, .failed])
                    await expectMacroTransactionRPCError(.notFound) {
                        let _: Exactmac_V1_Input = try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = secondName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    }
                    #expect(await fixture.sink.count() == 0)
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: secondName,
                    ).isEmpty)
                    #expect(await fixture.composition.macroRegistry.getMacro(name: macroName)?.executionCount == 0)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `CancelOperation stays pending until nested Input cleanup settles`() async throws {
        let blocker = MacroTransactionBlockingSink()
        let fixture = await MacroTransactionFixture.make(blocker: blocker)
        let action = Exactmac_V1_InputAction.with {
            $0.mouseMove.position = point(x: 60, y: 70)
        }

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with { $0.input = action },
                    ],
                    label: "cancel-owned-input",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    try await blocker.waitUntilEntered()

                    let executing: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(executing.state == .executing)

                    let _: Google_Protobuf_Empty = try await macroTransactionUnary(
                        client: client,
                        request: Google_Longrunning_CancelOperationRequest.with {
                            $0.name = operation.name
                        },
                        descriptor: Google_Longrunning_Operations.Method.CancelOperation.descriptor,
                    )
                    try await blocker.waitUntilCancellationObserved()

                    let pending: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Google_Longrunning_GetOperationRequest.with {
                                $0.name = operation.name
                            },
                            descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
                        )
                    #expect(!pending.done)
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 1)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 1)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 1)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 1)

                    blocker.release()
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.cancelled.rawValue))
                    let cancelled: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(cancelled.state == .cancelled)
                    #expect(cancelled.deliveryResult.commitment == .noEffect)
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: inputName,
                    ) == [.pending, .executing, .cancelled])
                    try await waitForMacroTransactionCondition {
                        let operationCount =
                            await fixture.composition.operationStore.executionTaskCount()
                        let macroCount =
                            await fixture.composition.macroExecutor.activeExecutionCount()
                        let mutationCount =
                            await fixture.composition.automationCoordinator.activeMutationCount()
                        let identityCount =
                            await fixture.composition.stateStore.activeInputIdentityCount()
                        return operationCount == 0
                            && macroCount == 0
                            && mutationCount == 0
                            && identityCount == 0
                    }
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 0)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 0)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                }
            }
        } catch {
            blocker.release()
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `macro timeout publishes only after nested Input cleanup settles`() async throws {
        let blocker = MacroTransactionBlockingSink()
        let deadline = MacroTransactionDeadlineTrigger()
        let fixture = await MacroTransactionFixture.make(
            blocker: blocker,
            deadlineTrigger: deadline,
        )

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 80, y: 90)
                        },
                    ],
                    label: "timeout-owned-input",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                                $0.options.timeout = 3600
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    try await blocker.waitUntilEntered()
                    deadline.fire()
                    try await blocker.waitUntilCancellationObserved()

                    let pending: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Google_Longrunning_GetOperationRequest.with {
                                $0.name = operation.name
                            },
                            descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
                        )
                    #expect(!pending.done)
                    let executing: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(executing.state == .executing)

                    blocker.release()
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.deadlineExceeded.rawValue))
                    let cancelled: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(cancelled.state == .cancelled)
                    try await waitForMacroTransactionCondition {
                        let operationCount =
                            await fixture.composition.operationStore.executionTaskCount()
                        let macroCount =
                            await fixture.composition.macroExecutor.activeExecutionCount()
                        let mutationCount =
                            await fixture.composition.automationCoordinator.activeMutationCount()
                        let identityCount =
                            await fixture.composition.stateStore.activeInputIdentityCount()
                        return operationCount == 0
                            && macroCount == 0
                            && mutationCount == 0
                            && identityCount == 0
                    }
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 0)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 0)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                }
            }
        } catch {
            blocker.release()
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `DeleteOperation does not cancel nested Input or resurrect its public record`() async throws {
        let blocker = MacroTransactionBlockingSink()
        let fixture = await MacroTransactionFixture.make(blocker: blocker)

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 100, y: 110)
                        },
                    ],
                    label: "delete-owned-input",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    try await blocker.waitUntilEntered()

                    let _: Google_Protobuf_Empty = try await macroTransactionUnary(
                        client: client,
                        request: Google_Longrunning_DeleteOperationRequest.with {
                            $0.name = operation.name
                        },
                        descriptor: Google_Longrunning_Operations.Method.DeleteOperation.descriptor,
                    )
                    await expectMacroTransactionRPCError(.notFound) {
                        let _: Google_Longrunning_Operation =
                            try await macroTransactionUnary(
                                client: client,
                                request: Google_Longrunning_GetOperationRequest.with {
                                    $0.name = operation.name
                                },
                                descriptor:
                                Google_Longrunning_Operations.Method.GetOperation.descriptor,
                            )
                    }
                    #expect(!blocker.cancellationWasObserved())
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 1)

                    blocker.release()
                    try await waitForMacroTransactionCondition {
                        await fixture.composition.operationStore.executionTaskCount() == 0
                    }
                    let completed: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(completed.state == .completed)
                    #expect(completed.deliveryResult.commitment == .committedAndSettled)
                    #expect(!blocker.cancellationWasObserved())
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 0)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.macroRegistry.getMacro(name: macroName)?.executionCount == 1)
                    await expectMacroTransactionRPCError(.notFound) {
                        let _: Google_Longrunning_Operation =
                            try await macroTransactionUnary(
                                client: client,
                                request: Google_Longrunning_GetOperationRequest.with {
                                    $0.name = operation.name
                                },
                                descriptor:
                                Google_Longrunning_Operations.Method.GetOperation.descriptor,
                            )
                    }
                }
            }
        } catch {
            blocker.release()
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `service drain cancels and joins a deleted operation producer`() async throws {
        let blocker = MacroTransactionBlockingSink()
        let fixture = await MacroTransactionFixture.make(blocker: blocker)

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 115, y: 125)
                        },
                    ],
                    label: "deleted-producer-drain",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    try await blocker.waitUntilEntered()

                    let _: Google_Protobuf_Empty = try await macroTransactionUnary(
                        client: client,
                        request: Google_Longrunning_DeleteOperationRequest.with {
                            $0.name = operation.name
                        },
                        descriptor: Google_Longrunning_Operations.Method.DeleteOperation.descriptor,
                    )
                    let shutdown = Task {
                        await fixture.composition.serviceLifetime.shutdown()
                    }
                    try await blocker.waitUntilCancellationObserved()

                    #expect(await fixture.composition.serviceLifetime.lifecycleState() == .draining)
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 1)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 1)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 1)
                    #expect(await fixture.composition.stateStore.getInput(name: inputName)?.state == .executing)

                    blocker.release()
                    await shutdown.value
                    #expect(await fixture.composition.serviceLifetime.lifecycleState() == .drained)
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 0)
                    #expect(await fixture.composition.operationStore.waiterCount() == 0)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 0)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                    #expect(await fixture.composition.operationStore.getOperation(
                        name: operation.name,
                    ) == nil)
                    #expect(await fixture.composition.stateStore.getInput(
                        name: inputName,
                    )?.state == .cancelled)
                    #expect(await fixture.composition.macroRegistry.getMacro(name: macroName)?.executionCount == 0)
                }
            }
        } catch {
            blocker.release()
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
    }

    @Test
    func `retired application generation prevents the next physical ordinal`() async throws {
        let fixture = await MacroTransactionFixture.make(
            retireApplicationAfterFirstInput: true,
        )

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.loop.count = 2
                            $0.loop.actions = [
                                Exactmac_V1_MacroAction.with {
                                    $0.input.mouseMove.position = point(x: 120, y: 130)
                                },
                            ]
                        },
                    ],
                    label: "generation-retirement",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.notFound.rawValue))
                    #expect(
                        terminal.error.message
                            == "Application not found or process identity is stale",
                    )

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let firstName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    let secondName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-1"
                    let first: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = firstName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(first.state == .completed)
                    await expectMacroTransactionRPCError(.notFound) {
                        let _: Exactmac_V1_Input = try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = secondName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    }
                    #expect(await fixture.sink.count() == 1)
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: secondName,
                    ).isEmpty)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `generation replacement inside Input remains canonical NOT_FOUND`() async throws {
        try await assertMidTransactionRetirementIsCanonical(
            retireApplicationBeforeEffectValidation: true,
        )
    }

    @Test
    func `kernel route retirement inside Input remains canonical NOT_FOUND`() async throws {
        try await assertMidTransactionRetirementIsCanonical(
            retireKernelBeforeRouteValidation: true,
        )
    }

    @Test
    func `prepublication kernel retirement remains canonical NOT_FOUND`() async throws {
        let fixture = await MacroTransactionFixture.make(
            retireKernelDuringPrepublicationRevalidation: true,
        )

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 122, y: 132)
                        },
                    ],
                    label: "prepublication-generation-retirement",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.notFound.rawValue))
                    #expect(
                        terminal.error.message
                            == "Application not found or process identity is stale",
                    )

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    await expectMacroTransactionRPCError(.notFound) {
                        let _: Exactmac_V1_Input =
                            try await macroTransactionUnary(
                                client: client,
                                request: Exactmac_V1_GetInputRequest.with {
                                    $0.name = inputName
                                },
                                descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                            )
                    }
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: inputName,
                    ).isEmpty)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                    #expect(await fixture.sink.count() == 0)
                    #expect(await fixture.composition.macroRegistry.getMacro(name: macroName)?.executionCount == 0)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `published application with dead kernel generation fails before LRO creation`() async throws {
        let fixture = await MacroTransactionFixture.make(kernelGenerationIsRunning: false)

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 120, y: 130)
                        },
                    ],
                    label: "dead-kernel-generation",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    await expectMacroTransactionRPCError(
                        .notFound,
                        message: "Application not found or process identity is stale",
                    ) {
                        let _: Google_Longrunning_Operation =
                            try await macroTransactionUnary(
                                client: client,
                                request: Exactmac_V1_ExecuteMacroRequest.with {
                                    $0.macro = macroName
                                    $0.application = fixture.applicationName
                                },
                                descriptor:
                                Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                            )
                    }
                    #expect(await fixture.composition.operationStore.listOperations().operations.isEmpty)
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                    #expect(await fixture.sink.count() == 0)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }

    @Test
    func `service drain keeps LRO nonterminal until nested Input cleanup joins`() async throws {
        let blocker = MacroTransactionBlockingSink()
        let fixture = await MacroTransactionFixture.make(blocker: blocker)

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 140, y: 150)
                        },
                    ],
                    label: "drain-owned-input",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    try await blocker.waitUntilEntered()
                    let waiter = Task {
                        try await waitForMacroTransactionOperation(
                            client: client,
                            name: operation.name,
                        )
                    }
                    try await waitForMacroTransactionCondition {
                        await fixture.composition.operationStore.waiterCount(
                            name: operation.name,
                        ) == 1
                    }

                    let shutdown = Task {
                        await fixture.composition.serviceLifetime.shutdown()
                    }
                    try await blocker.waitUntilCancellationObserved()

                    let stillPending = await fixture.composition.operationStore.getOperation(
                        name: operation.name,
                    )
                    #expect(stillPending?.done == false)
                    #expect(await fixture.composition.operationStore.waiterCount(
                        name: operation.name,
                    ) == 1)
                    #expect(await fixture.composition.serviceLifetime.lifecycleState() == .draining)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 1)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 1)
                    let executing = await fixture.composition.stateStore.getInput(name: inputName)
                    #expect(executing?.state == .executing)

                    blocker.release()
                    let terminal = try await waiter.value
                    await shutdown.value
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.cancelled.rawValue))
                    #expect(await fixture.composition.serviceLifetime.lifecycleState() == .drained)
                    #expect(await fixture.composition.operationStore.executionTaskCount() == 0)
                    #expect(await fixture.composition.operationStore.waiterCount() == 0)
                    #expect(await fixture.composition.macroExecutor.activeExecutionCount() == 0)
                    #expect(await fixture.composition.automationCoordinator.activeMutationCount() == 0)
                    #expect(await fixture.composition.stateStore.activeInputIdentityCount() == 0)
                }
            }
        } catch {
            blocker.release()
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
    }

    private func assertMidTransactionRetirementIsCanonical(
        retireApplicationBeforeEffectValidation: Bool = false,
        retireKernelBeforeRouteValidation: Bool = false,
    ) async throws {
        let fixture = await MacroTransactionFixture.make(
            retireApplicationBeforeEffectValidation: retireApplicationBeforeEffectValidation,
            retireKernelBeforeRouteValidation: retireKernelBeforeRouteValidation,
        )

        do {
            try await withMacroTransactionClient(fixture.composition) { client in
                try await withMacroTransactionMacro(
                    actions: [
                        Exactmac_V1_MacroAction.with {
                            $0.input.mouseMove.position = point(x: 121, y: 131)
                        },
                    ],
                    label: "mid-input-generation-retirement",
                    registry: fixture.composition.macroRegistry,
                ) { macroName in
                    let operation: Google_Longrunning_Operation =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_ExecuteMacroRequest.with {
                                $0.macro = macroName
                                $0.application = fixture.applicationName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                        )
                    let terminal = try await waitForMacroTransactionOperation(
                        client: client,
                        name: operation.name,
                    )
                    #expect(terminal.done)
                    #expect(terminal.error.code == Int32(RPCError.Code.notFound.rawValue))
                    #expect(
                        terminal.error.message
                            == "Application not found or process identity is stale",
                    )

                    let operationID = try ParsingHelpers.parseOperationName(
                        operation.name,
                    ).operationId
                    let inputName =
                        "\(fixture.applicationName)/inputs/macro-\(operationID)-0"
                    let failed: Exactmac_V1_Input =
                        try await macroTransactionUnary(
                            client: client,
                            request: Exactmac_V1_GetInputRequest.with {
                                $0.name = inputName
                            },
                            descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                        )
                    #expect(failed.state == .failed)
                    #expect(failed.deliveryResult.commitment == .noEffect)
                    #expect(await fixture.composition.stateStore.inputStateHistory(
                        name: inputName,
                    ) == [.pending, .executing, .failed])
                    #expect(await fixture.sink.count() == 0)
                    #expect(await fixture.composition.macroRegistry.getMacro(name: macroName)?.executionCount == 0)
                }
            }
        } catch {
            await fixture.composition.serviceLifetime.shutdown()
            throw error
        }
        await fixture.composition.serviceLifetime.shutdown()
    }
}

private struct MacroTransactionFixture {
    let identity: ApplicationProcessIdentity
    let applicationName: String
    let composition: ExactMacServiceComposition
    let sink: MacroTransactionInputSink

    static func make(
        blocker: MacroTransactionBlockingSink? = nil,
        deadlineTrigger: MacroTransactionDeadlineTrigger? = nil,
        retireApplicationAfterFirstInput: Bool = false,
        retireApplicationBeforeEffectValidation: Bool = false,
        retireKernelBeforeRouteValidation: Bool = false,
        retireKernelDuringPrepublicationRevalidation: Bool = false,
        failFirstInput: Bool = false,
        kernelGenerationIsRunning: Bool = true,
    ) async -> MacroTransactionFixture {
        let identity = ApplicationProcessIdentity(
            pid: 7711,
            startTimeSeconds: 700,
            startTimeMicroseconds: 11,
            bundleIdentifier: "com.example.MacroTransaction",
            executablePath: "/Applications/MacroTransaction.app/Contents/MacOS/MacroTransaction",
        )
        let kernelAuthority = MacroTransactionKernelAuthority(
            identity: identity,
            isRunning: kernelGenerationIsRunning,
            retireOnCheck: retireKernelDuringPrepublicationRevalidation ? 4 : nil,
        )
        let applicationName = applicationResourceName(for: identity)
        let hitElement = SendableAXUIElement(
            AXUIElementCreateApplication(identity.pid),
        )
        let system = MockSystemOperations(
            axAttributes: [
                kAXFrontmostAttribute as String: true,
            ],
            setAXAttributeResult: AXError.success.rawValue,
            applySuccessfulAXWritesToAttributes: true,
            applicationIdentities: [identity.pid: identity],
            applicationProcessRunningHandler: { candidate in
                kernelAuthority.isRunning(candidate)
            },
            axElementAtPositionHandler: { _ in
                AXElementRead(
                    errorCode: AXError.success.rawValue,
                    element: hitElement.element,
                )
            },
            axElementPIDHandler: { _ in
                AXElementPIDRead(
                    errorCode: AXError.success.rawValue,
                    pid: identity.pid,
                )
            },
            runningPIDs: kernelGenerationIsRunning ? [identity.pid] : [],
            runningApplicationIdentities: kernelGenerationIsRunning ? [identity] : [],
        )
        let sink = MacroTransactionInputSink()
        let stateStore = AppStateStore()
        await stateStore.addTarget(
            Exactmac_V1_Application.with {
                $0.name = applicationName
                $0.pid = Int32(identity.pid)
                $0.displayName = "Macro Transaction"
            },
            processIdentity: identity,
        )
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, boundary in
                if let blocker {
                    try await blocker.execute(action: action, route: route)
                }
                if retireApplicationBeforeEffectValidation {
                    _ = await stateStore.removeTarget(name: applicationName)
                }
                switch action {
                case let .move(point):
                    try await boundary.validateEffect(
                        .mouseMove(point: point, modifiers: []),
                    )
                case let .movePointer(point, _, modifiers):
                    try await boundary.validateEffect(
                        .mouseMove(point: point, modifiers: modifiers),
                    )
                case let .clickSequence(point, button, count, modifiers):
                    try await boundary.validateEffect(
                        .mouseDown(
                            point: point,
                            button: button,
                            modifiers: modifiers,
                            clickCount: Int64(count),
                        ),
                    )
                case .type, .typeText:
                    try await boundary.validateEffect(.unicodeKeyDown)
                default:
                    Issue.record(
                        "Unexpected macro transaction action \(String(describing: action))",
                    )
                }
                if retireKernelBeforeRouteValidation {
                    kernelAuthority.retire()
                }
                if case let .process(pid) = route {
                    try boundary.validateProcessRoute(pid)
                } else {
                    Issue.record("Macro input did not use its exact process route")
                }
                if failFirstInput, await sink.count() == 0 {
                    throw MacroTransactionInjectedError.deliveryFailed
                }
                let executionCount = await sink.record(action: action, route: route)
                if retireApplicationAfterFirstInput, executionCount == 1 {
                    _ = await stateStore.removeTarget(name: applicationName)
                }
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        return MacroTransactionFixture(
            identity: identity,
            applicationName: applicationName,
            composition: ExactMacServiceComposition(
                stateStore: stateStore,
                system: system,
                automationCoordinator: coordinator,
                displayTopologyProvider: MacroTransactionTopology(),
                macroDeadlineWaiter: { deadline in
                    if let deadlineTrigger {
                        try await deadlineTrigger.wait()
                    } else {
                        try await ContinuousClock().sleep(until: deadline)
                    }
                },
            ),
            sink: sink,
        )
    }
}

private final class MacroTransactionKernelAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let identity: ApplicationProcessIdentity
    private let retireOnCheck: Int?
    private var running: Bool
    private var checkCount = 0

    init(
        identity: ApplicationProcessIdentity,
        isRunning: Bool,
        retireOnCheck: Int? = nil,
    ) {
        self.identity = identity
        self.retireOnCheck = retireOnCheck
        running = isRunning
    }

    func isRunning(_ candidate: ApplicationProcessIdentity) -> Bool {
        lock.withLock {
            checkCount += 1
            if let retireOnCheck, checkCount == retireOnCheck {
                running = false
            }
            return running && candidate == identity
        }
    }

    func retire() {
        lock.withLock {
            running = false
        }
    }
}

private actor MacroTransactionInputSink {
    private var entries: [(action: ExactMac.InputAction, route: InputDeliveryRoute)] = []

    func record(
        action: ExactMac.InputAction,
        route: InputDeliveryRoute,
    ) -> Int {
        entries.append((action, route))
        return entries.count
    }

    func count() -> Int {
        entries.count
    }
}

private enum MacroTransactionInjectedError: Error {
    case deliveryFailed
}

private actor MacroTransactionCatalog: ApplicationCatalogProvider {
    private var bundleReads = 0
    private var runningReads = 0

    func applicationBundles() async -> [ApplicationBundleInfo] {
        bundleReads += 1
        return []
    }

    func runningApplications() async -> [RunningApplicationInfo] {
        runningReads += 1
        return []
    }

    func bundleReadCount() -> Int {
        bundleReads
    }

    func runningReadCount() -> Int {
        runningReads
    }
}

private final class MacroTransactionBlockingSink: @unchecked Sendable {
    private struct State {
        var entered = false
        var cancellationObserved = false
        var released = false
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func execute(
        action _: ExactMac.InputAction,
        route _: InputDeliveryRoute,
    ) async throws {
        markEntered()
        try await withTaskCancellationHandler {
            await waitUntilReleased()
            try Task.checkCancellation()
        } onCancel: {
            self.markCancellationObserved()
        }
    }

    func waitUntilEntered() async throws {
        try await waitUntil { $0.entered }
    }

    func waitUntilCancellationObserved() async throws {
        try await waitUntil { $0.cancellationObserved }
    }

    func cancellationWasObserved() -> Bool {
        lock.withLock { state.cancellationObserved }
    }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !state.released else { return [] }
            state.released = true
            defer { state.releaseWaiters.removeAll() }
            return state.releaseWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func markEntered() {
        lock.withLock {
            state.entered = true
        }
    }

    private func markCancellationObserved() {
        lock.withLock {
            state.cancellationObserved = true
        }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable (State) -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while lock.withLock({ !predicate(state) }) {
            guard clock.now < deadline else {
                throw MacroTransactionConditionTimeout()
            }
            await Task.yield()
        }
    }

    private func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if state.released {
                lock.unlock()
                continuation.resume()
            } else {
                state.releaseWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class MacroTransactionDeadlineTrigger: @unchecked Sendable {
    private struct State {
        var fired = false
        var cancelled = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let lock = NSLock()
    private var state = State()

    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Result<Void, any Error>? in
                    if state.fired {
                        return .success(())
                    }
                    if state.cancelled {
                        return .failure(CancellationError())
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func fire() {
        resolve(.success(()))
    }

    private func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Void, any Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard !state.fired, !state.cancelled else { return [] }
            switch result {
            case .success:
                state.fired = true
            case .failure:
                state.cancelled = true
            }
            defer { state.waiters.removeAll(keepingCapacity: false) }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}

private struct MacroTransactionTopology: DisplayTopologyProviding {
    func snapshot() async throws -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(displays: [
            DisplayTopologyDisplay(
                displayID: 1,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 780),
                isMain: true,
                scale: 2,
            ),
        ])
    }

    func cursorLocation() async throws -> CGPoint {
        CGPoint(x: 100, y: 100)
    }
}

private func point(x: Double, y: Double) -> Exactmac_Type_Point {
    Exactmac_Type_Point.with {
        $0.x = x
        $0.y = y
    }
}

private func withMacroTransactionMacro<T: Sendable>(
    actions: [Exactmac_V1_MacroAction],
    label: String,
    registry: MacroRegistry,
    operation: (String) async throws -> T,
) async throws -> T {
    let macroID = "macro-transaction-\(UUID().uuidString)"
    // The macro must live in the composition's registry so the gRPC ExecuteMacro
    // handler (driven by `operation`) can resolve it. A standalone registry would
    // be invisible to the service.
    let macro = await registry.createMacro(
        macroId: macroID,
        displayName: label,
        description: "",
        actions: actions,
        parameters: [],
        tags: [],
    )
    do {
        let value = try await operation(macro.name)
        _ = await registry.deleteMacro(name: macro.name)
        return value
    } catch {
        _ = await registry.deleteMacro(name: macro.name)
        throw error
    }
}

private func withMacroTransactionClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let transport = InProcessTransport()
    let server = GRPCServer(
        transport: productionServerTransport(transport.server),
        services: [composition.exactMacService, composition.operationsProvider],
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

private func macroTransactionUnary<
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

private func waitForMacroTransactionOperation(
    client: GRPCClient<InProcessTransport.Client>,
    name: String,
) async throws -> Google_Longrunning_Operation {
    try await macroTransactionUnary(
        client: client,
        request: Google_Longrunning_WaitOperationRequest.with {
            $0.name = name
            $0.timeout = Google_Protobuf_Duration.with { $0.seconds = 2 }
        },
        descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
    )
}

private struct MacroTransactionConditionTimeout: Error {}

private func waitForMacroTransactionCondition(
    _ condition: @escaping @Sendable () async -> Bool,
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await !condition() {
        guard clock.now < deadline else {
            throw MacroTransactionConditionTimeout()
        }
        await Task.yield()
    }
}

private func expectMacroTransactionRPCError(
    _ expected: RPCError.Code,
    message: String? = nil,
    operation: () async throws -> Void,
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected) RPC error")
    } catch let error as RPCError {
        #expect(error.code == expected)
        if let message {
            #expect(error.message == message)
        }
    } catch {
        Issue.record("Expected RPCError, got \(String(describing: error))")
    }
}
