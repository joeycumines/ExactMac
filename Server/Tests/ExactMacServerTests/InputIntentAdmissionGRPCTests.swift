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
struct InputIntentAdmissionGRPCTests {
    @Test
    func `target and output-only intent reject before state identity history or sinks`() async throws {
        let recorder = InputIntentRecorder()
        let overlayRecorder = InputIntentOverlayRecorder()
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action: action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
            inputOverlayPresenter: InputOverlayPresenter { presentation in
                await overlayRecorder.record(presentation)
            },
        )
        let probes: [(
            label: String,
            mutate: @Sendable (inout Exactmac_V1_CreateInputRequest) -> Void,
        )] = [
            (
                "absent target",
                { $0.input.clearTarget() },
            ),
            (
                "empty target message",
                { $0.input.target = Exactmac_V1_InputTarget() },
            ),
            (
                "empty application target",
                { $0.input.target.application = "" },
            ),
            (
                "false desktop target",
                { $0.input.target.desktop = false },
            ),
            (
                "mismatched application target",
                {
                    $0.parent = "applications/owner"
                    $0.input.target.application = "applications/other"
                },
            ),
            (
                "caller-supplied resource name",
                { $0.input.name = "applications/-/inputs/forged" },
            ),
            (
                "caller-supplied state",
                { $0.input.state = .pending },
            ),
            (
                "caller-supplied create time",
                {
                    $0.input.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(
                        date: Date(timeIntervalSince1970: 1),
                    )
                },
            ),
            (
                "caller-supplied complete time",
                {
                    $0.input.completeTime = SwiftProtobuf.Google_Protobuf_Timestamp(
                        date: Date(timeIntervalSince1970: 2),
                    )
                },
            ),
            (
                "caller-supplied terminal error",
                { $0.input.error = "forged success evidence" },
            ),
            (
                "caller-supplied delivery result",
                {
                    $0.input.deliveryResult = Exactmac_V1_InputDeliveryResult.with {
                        $0.commitment = .committedAndSettled
                        $0.postedEventCount = 2
                        $0.routedDeliveryObserved = true
                    }
                },
            ),
        ]

        try await withInputIntentClient(composition) { client in
            for (index, probe) in probes.enumerated() {
                var request = makeCreateInputRequest(
                    action: makeInputAction(visualFeedback: false, animationDuration: 0) {
                        $0.mouseClick = makeClick()
                    },
                    id: "invalid-envelope-\(index)",
                )
                probe.mutate(&request)
                do {
                    let _: Exactmac_V1_Input = try await inputIntentUnary(
                        client: client,
                        request: request,
                        descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    )
                    Issue.record("\(probe.label) was accepted")
                } catch let error as RPCError {
                    #expect(
                        error.code == .invalidArgument,
                        Comment(rawValue: "\(probe.label): \(error)"),
                    )
                } catch {
                    Issue.record("\(probe.label) returned an unexpected error: \(error)")
                }
            }
        }

        let state = await composition.stateStore.currentState()
        #expect(state.inputs.isEmpty)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.stateStore.inputStateHistoryCount() == 0)
        #expect(await recorder.snapshot().isEmpty)
        #expect(await overlayRecorder.snapshot().isEmpty)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `contradictory and unsupported input intent rejects before state or sinks`() async throws {
        let recorder = InputIntentRecorder()
        let overlayRecorder = InputIntentOverlayRecorder()
        let overlayPresenter = InputOverlayPresenter { presentation in
            await overlayRecorder.record(presentation)
        }
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action: action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
            inputOverlayPresenter: overlayPresenter,
        )
        let invalidActions: [(String, Exactmac_V1_InputAction)] = [
            (
                "false animation with duration",
                makeInputAction(visualFeedback: false, animationDuration: 0.25) {
                    $0.mouseClick = makeClick()
                },
            ),
            (
                "text custom animation duration",
                makeInputAction(visualFeedback: true, animationDuration: 0.25) {
                    $0.textInput = Exactmac_V1_TextInput.with { $0.text = "must-not-type" }
                },
            ),
            (
                "held key visualization",
                makeInputAction(visualFeedback: true, animationDuration: 0) {
                    $0.keyPress = Exactmac_V1_KeyPress.with {
                        $0.key = "return"
                        $0.holdDuration = 0.1
                    }
                },
            ),
            (
                "drag visualization",
                makeInputAction(visualFeedback: true, animationDuration: 0) {
                    $0.mouseDrag = makeDrag()
                },
            ),
            (
                "scroll visualization",
                makeInputAction(visualFeedback: true, animationDuration: 0) {
                    $0.scrollAction = Exactmac_V1_Scroll.with { $0.vertical = 1 }
                },
            ),
            (
                "hover visualization",
                makeInputAction(visualFeedback: true, animationDuration: 0) {
                    $0.hoverAction = Exactmac_V1_Hover.with {
                        $0.position = Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 }
                        $0.duration = 0.1
                    }
                },
            ),
            (
                "unknown key",
                makeInputAction(visualFeedback: false, animationDuration: 0) {
                    $0.keyPress = Exactmac_V1_KeyPress.with { $0.key = "definitely-not-a-key" }
                },
            ),
        ]

        try await withInputIntentClient(composition) { client in
            for (index, invalid) in invalidActions.enumerated() {
                await expectInvalidInput(
                    client: client,
                    action: invalid.1,
                    id: "invalid-generated-\(index)",
                    label: invalid.0,
                )
            }

            let rawProbes: [(String, [UInt8])] = try [
                (
                    "explicit zero click count",
                    rawCreateInputRequest(
                        action: rawClickAction(appending: [0x18, 0x00]),
                        id: "invalid-click-count-zero",
                    ),
                ),
                (
                    "explicit unspecified click button",
                    rawCreateInputRequest(
                        action: rawClickAction(appending: [0x10, 0x00]),
                        id: "invalid-click-button-unspecified",
                    ),
                ),
                (
                    "explicit unspecified drag button",
                    rawCreateInputRequest(
                        action: rawDragAction(appending: [0x20, 0x00]),
                        id: "invalid-drag-button-unspecified",
                    ),
                ),
                (
                    "removed gesture arm 17",
                    rawCreateInputRequest(
                        action: rawClickAction(appending: lengthDelimitedField(number: 17, payload: [])),
                        id: "invalid-removed-17",
                    ),
                ),
                (
                    "removed button-down arm 18",
                    rawCreateInputRequest(
                        action: rawClickAction(appending: lengthDelimitedField(number: 18, payload: [])),
                        id: "invalid-removed-18",
                    ),
                ),
                (
                    "removed button-up arm 19",
                    rawCreateInputRequest(
                        action: rawClickAction(appending: lengthDelimitedField(number: 19, payload: [])),
                        id: "invalid-removed-19",
                    ),
                ),
            ]
            for probe in rawProbes {
                await expectRawInvalidInput(
                    client: client,
                    bytes: probe.1,
                    label: probe.0,
                )
            }
        }

        #expect(await recorder.snapshot().isEmpty)
        #expect(await overlayRecorder.snapshot().isEmpty)
        let rejectedState = await composition.stateStore.currentState()
        #expect(rejectedState.inputs.isEmpty)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.stateStore.inputStateHistoryCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `omitted defaults and supported animation intent reach the executor exactly`() async throws {
        let recorder = InputIntentRecorder()
        let overlayRecorder = InputIntentOverlayRecorder()
        let overlayPresenter = InputOverlayPresenter { presentation in
            await overlayRecorder.record(presentation)
        }
        let applicationName = "applications/424246"
        let keyboardSource = KeyboardInputSourceIdentity(
            sourceID: "com.example.input-intent",
            unicodeLayoutSHA256: String(repeating: "1", count: 64),
            keyboardType: 40,
        )
        let system = MockSystemOperations(
            axAttributes: [kAXFrontmostAttribute as String: true],
        )
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputKeyResolver: { key in
                if key == "v" {
                    return ResolvedInputKey(keyCode: 9, sourceIdentity: keyboardSource)
                }
                return ResolvedInputKey(
                    keyCode: ExactMac.KEY_RETURN,
                    sourceIdentity: nil,
                )
            },
            keyboardInputSourceIdentityProvider: { keyboardSource },
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action: action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
            inputOverlayPresenter: overlayPresenter,
        )
        let actions: [Exactmac_V1_InputAction] = [
            makeInputAction(visualFeedback: true, animationDuration: 0.2) { $0.mouseClick = makeClick() },
            makeInputAction(visualFeedback: true, animationDuration: 0) {
                $0.textInput = Exactmac_V1_TextInput.with { $0.text = "visible" }
            },
            makeInputAction(visualFeedback: true, animationDuration: 0.3) {
                $0.keyPress = Exactmac_V1_KeyPress.with { $0.key = "return" }
            },
            makeInputAction(visualFeedback: true, animationDuration: 0.4) {
                $0.mouseMove = Exactmac_V1_MouseMove.with {
                    $0.position = Exactmac_Type_Point.with { $0.x = 3; $0.y = 4 }
                }
            },
            makeInputAction(visualFeedback: false, animationDuration: 0) {
                $0.mouseClick = Exactmac_V1_MouseClick.with {
                    $0.position = Exactmac_Type_Point.with { $0.x = 5; $0.y = 6 }
                }
            },
            makeInputAction(visualFeedback: false, animationDuration: 0) { $0.mouseDrag = makeDrag() },
        ]

        try await withInputIntentClient(composition) { client in
            for (index, action) in actions.enumerated() {
                var request = makeCreateInputRequest(action: action, id: "valid-\(index)")
                if index == 1 {
                    request.parent = applicationName
                    request.input.target.application = applicationName
                }
                let response: Exactmac_V1_Input = try await inputIntentUnary(
                    client: client,
                    request: request,
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                #expect(response.state == .completed)
            }
        }

        let captured = await recorder.snapshot()
        #expect(captured.count == 6)
        let overlays = await overlayRecorder.snapshot()
        #expect(overlays.map(\.duration) == [0.2, 0.5, 0.3, 0.4])
        #expect(overlays.map(\.content) == [.circle, .caption, .caption, .circle])
        if captured.count == 6 {
            if case let .clickSequence(_, button, count, _) = captured[4].action {
                #expect(button == .left)
                #expect(count == 1)
            } else {
                Issue.record("Expected omitted click fields to produce one left click")
            }
            if case let .dragPath(_, button, _, _) = captured[5].action {
                #expect(button == .left)
            } else {
                Issue.record("Expected omitted drag button to produce a left drag")
            }
        }
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `post access denial rejects before state mutation executor or AX sinks`() async throws {
        let recorder = InputIntentRecorder()
        let overlayRecorder = InputIntentOverlayRecorder()
        let overlayPresenter = InputOverlayPresenter { presentation in
            await overlayRecorder.record(presentation)
        }
        let system = MockSystemOperations()
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { false },
            inputActionExecutor: { action, route, _ in
                await recorder.record(action: action)
                return committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            automationCoordinator: coordinator,
            inputOverlayPresenter: overlayPresenter,
        )

        try await withInputIntentClient(composition) { client in
            do {
                let _: Exactmac_V1_Input = try await inputIntentUnary(
                    client: client,
                    request: makeCreateInputRequest(
                        action: makeInputAction(visualFeedback: false, animationDuration: 0) {
                            $0.mouseClick = makeClick()
                        },
                        id: "denied",
                    ),
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                )
                Issue.record("Input post-access denial was accepted")
            } catch let error as RPCError {
                #expect(error.code == .permissionDenied)
            } catch {
                Issue.record("Input post-access denial returned an unexpected error: \(error)")
            }

            await expectInvalidInput(
                client: client,
                action: makeInputAction(visualFeedback: false, animationDuration: 0) {
                    $0.keyPress = Exactmac_V1_KeyPress.with {
                        $0.key = "definitely-not-a-key"
                    }
                },
                id: "invalid-precedes-permission",
                label: "malformed intent must precede permission admission",
            )
        }

        #expect(await recorder.snapshot().isEmpty)
        #expect(await overlayRecorder.snapshot().isEmpty)
        let deniedState = await composition.stateStore.currentState()
        #expect(deniedState.inputs.isEmpty)
        #expect(await composition.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.stateStore.inputStateHistoryCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        await composition.serviceLifetime.shutdown()
    }
}

private struct CapturedInputIntent: Sendable {
    let action: ExactMac.InputAction
}

private actor InputIntentRecorder {
    private var entries: [CapturedInputIntent] = []

    func record(action: ExactMac.InputAction) {
        entries.append(
            CapturedInputIntent(
                action: action,
            ),
        )
    }

    func snapshot() -> [CapturedInputIntent] {
        entries
    }
}

private actor InputIntentOverlayRecorder {
    private var entries: [InputOverlayPresentation] = []

    func record(_ presentation: InputOverlayPresentation) {
        entries.append(presentation)
    }

    func snapshot() -> [InputOverlayPresentation] {
        entries
    }
}

private func makeInputAction(
    visualFeedback: Bool,
    animationDuration: Double,
    configure: (inout Exactmac_V1_InputAction) -> Void,
) -> Exactmac_V1_InputAction {
    var action = Exactmac_V1_InputAction()
    action.visualFeedback = visualFeedback
    action.animationDuration = animationDuration
    configure(&action)
    return action
}

private func makeClick() -> Exactmac_V1_MouseClick {
    Exactmac_V1_MouseClick.with {
        $0.position = Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 }
        $0.clickType = .left
        $0.clickCount = 1
    }
}

private func makeDrag() -> Exactmac_V1_MouseDrag {
    Exactmac_V1_MouseDrag.with {
        $0.startPosition = Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 }
        $0.endPosition = Exactmac_Type_Point.with { $0.x = 3; $0.y = 4 }
    }
}

private func makeCreateInputRequest(
    action: Exactmac_V1_InputAction,
    id: String,
) -> Exactmac_V1_CreateInputRequest {
    Exactmac_V1_CreateInputRequest.with {
        $0.parent = "applications/-"
        $0.inputID = id
        $0.input.target.desktop = true
        $0.input.action = action
    }
}

private func expectInvalidInput(
    client: GRPCClient<InProcessTransport.Client>,
    action: Exactmac_V1_InputAction,
    id: String,
    label: String,
) async {
    do {
        let _: Exactmac_V1_Input = try await inputIntentUnary(
            client: client,
            request: makeCreateInputRequest(action: action, id: id),
            descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
        )
        Issue.record("\(label) was accepted")
    } catch let error as RPCError {
        #expect(error.code == .invalidArgument, Comment(rawValue: "\(label): \(error)"))
    } catch {
        Issue.record("\(label) returned an unexpected error: \(error)")
    }
}

private func expectRawInvalidInput(
    client: GRPCClient<InProcessTransport.Client>,
    bytes: [UInt8],
    label: String,
) async {
    do {
        let _: [UInt8] = try await client.unary(
            request: ClientRequest(message: bytes),
            descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            serializer: InputIntentRawSerializer(),
            deserializer: InputIntentRawDeserializer(),
            options: .defaults,
        ) { response in
            try response.message
        }
        Issue.record("\(label) was accepted")
    } catch let error as RPCError {
        #expect(error.code == .invalidArgument, Comment(rawValue: "\(label): \(error)"))
    } catch {
        Issue.record("\(label) returned an unexpected error: \(error)")
    }
}

private func rawClickAction(appending bytes: [UInt8]) throws -> [UInt8] {
    var click = try Array(
        Exactmac_V1_MouseClick.with {
            $0.position = Exactmac_Type_Point.with { $0.x = 1; $0.y = 2 }
        }.serializedData(),
    )
    click.append(contentsOf: bytes)
    return lengthDelimitedField(number: 10, payload: click)
}

private func rawDragAction(appending bytes: [UInt8]) throws -> [UInt8] {
    var drag = try Array(makeDrag().serializedData())
    drag.append(contentsOf: bytes)
    return lengthDelimitedField(number: 14, payload: drag)
}

private func rawCreateInputRequest(action: [UInt8], id: String) -> [UInt8] {
    // Input.target (field 7) contains InputTarget.desktop (field 4) = true.
    // Keeping the required target valid ensures each raw-wire oracle reaches
    // the intended malformed InputAction field instead of passing for the
    // unrelated missing-target guard.
    let desktopTarget = lengthDelimitedField(number: 7, payload: [0x20, 0x01])
    let input = lengthDelimitedField(number: 2, payload: action) + desktopTarget
    return lengthDelimitedField(number: 1, payload: Array("applications/-".utf8)) +
        lengthDelimitedField(number: 2, payload: input) +
        lengthDelimitedField(number: 3, payload: Array(id.utf8))
}

private func lengthDelimitedField(number: Int, payload: [UInt8]) -> [UInt8] {
    encodeVarint(UInt64(number << 3 | 2)) + encodeVarint(UInt64(payload.count)) + payload
}

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while value != 0
    return bytes
}

private func withInputIntentClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
    let inProcess = InProcessTransport()
    let server = GRPCServer(
        transport: productionServerTransport(inProcess.server),
        services: [composition.exactMacService],
        interceptors: handlerContractTestInterceptors(),
    )
    let client = GRPCClient(transport: inProcess.client)
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

private func inputIntentUnary<
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

private struct InputIntentRawSerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes {
        Bytes(message)
    }
}

private struct InputIntentRawDeserializer: MessageDeserializer {
    func deserialize(_ serializedMessageBytes: some GRPCContiguousBytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}
