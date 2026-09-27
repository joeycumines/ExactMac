import ExactMacProto
@testable import ExactMacServer
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import SwiftProtobuf
import Testing

@Suite(.serialized)
struct PublicRequestValidationGRPCTests {
    @Test
    func `every public request rejects preserved unknown wire fields before side effects`() async throws {
        let contract = try Self.loadPublicContract()
        let descriptors = contract.methods.map(\.descriptor)
        let expectedMethodCounts = Self.publicServiceMethodCounts(in: contract.descriptorSet)
        let actualMethodCounts = Dictionary(grouping: descriptors) {
            $0.service.fullyQualifiedService
        }.mapValues(\.count)
        #expect(
            actualMethodCounts == expectedMethodCounts,
            Comment(rawValue: "public service counts must be descriptor-derived"),
        )
        #expect(Set(descriptors.map(\.fullyQualifiedMethod)).count == descriptors.count)

        let system = MockSystemOperations()
        let pasteboard = RequestValidationPasteboard()
        let composition = ExactMacServiceComposition(
            system: system,
            clipboardPasteboard: pasteboard,
        )
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            // Field 2047, varint value 1. No public request declares this field.
            let unknownOnlyRequest: [UInt8] = [0xF8, 0x7F, 0x01]
            for descriptor in descriptors {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: descriptor,
                    bytes: unknownOnlyRequest,
                )
                #expect(error.code == .invalidArgument)
                #expect(error.message == "request contains unknown fields")
                let errorInfo = try extractErrorInfo(from: error)
                #expect(errorInfo.reason == "UNKNOWN_FIELD")
                #expect(errorInfo.domain == RPCErrorHelpers.domain)
                #expect(errorInfo.metadata["field"] == "request")
            }

            let malformedWireProbes: [(label: String, descriptor: MethodDescriptor, bytes: [UInt8])] = [
                (
                    "truncated tag varint",
                    Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                    [0x80],
                ),
                (
                    "overflowing scalar varint",
                    Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                    [0x08] + Array(repeating: 0xFF, count: 9) + [0x02],
                ),
                (
                    "truncated length-delimited field",
                    Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                    [0x12, 0x05, 0x61],
                ),
                (
                    "wrong wire type",
                    Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                    [0x0B, 0x0C],
                ),
                (
                    "recursive depth exhaustion",
                    Exactmac_V1_ExactMac.Method.FindElements.descriptor,
                    Self.deeplyNestedSelectorRequest(depth: 40),
                ),
            ]
            for probe in malformedWireProbes {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: probe.descriptor,
                    bytes: probe.bytes,
                )
                #expect(error.code == .invalidArgument, Comment(rawValue: probe.label))
                #expect(
                    error.message == "request contains malformed protobuf wire data",
                    Comment(rawValue: probe.label),
                )
                let errorInfo = try extractErrorInfo(from: error)
                #expect(errorInfo.reason == "MALFORMED_PROTOBUF", Comment(rawValue: probe.label))
                #expect(errorInfo.metadata["field"] == "request", Comment(rawValue: probe.label))
            }

            var nestedContentBytes = try Exactmac_V1_ClipboardContent.with {
                $0.type = .text
                $0.text = "must-not-reach-pasteboard"
            }.serializedData()
            nestedContentBytes.append(contentsOf: unknownOnlyRequest)
            let nestedContent = try Exactmac_V1_ClipboardContent(
                serializedBytes: nestedContentBytes,
            )
            let nestedError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_WriteClipboardRequest.with {
                    $0.content = nestedContent
                },
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                responseType: Exactmac_V1_WriteClipboardResponse.self,
            )
            #expect(nestedError.code == .invalidArgument)
            #expect(nestedError.message == "request contains unknown fields")
            let nestedErrorInfo = try extractErrorInfo(from: nestedError)
            #expect(nestedErrorInfo.reason == "UNKNOWN_FIELD")
            #expect(nestedErrorInfo.metadata["field"] == "request")

            let enumProbes = try Self.enumWireProbes(for: contract)
            #expect(!enumProbes.isEmpty)
            #expect(Set(enumProbes.map(\.label)).count == enumProbes.count)
            for probe in enumProbes {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: probe.descriptor,
                    bytes: probe.bytes,
                )
                try assertDescriptorAwareWireRejection(
                    error: error,
                    outputOnlyField: probe.outputOnlyField,
                    expectedMessage: "request contains an unrecognized enum value",
                    expectedReason: "INVALID_ENUM_VALUE",
                    expectedValue: String(Int32.max),
                    label: probe.label,
                )
            }

            let floatingPointProbes = try Self.nonFiniteWireProbes(for: contract)
            #expect(!floatingPointProbes.isEmpty)
            #expect(Set(floatingPointProbes.map(\.label)).count == floatingPointProbes.count)
            for probe in floatingPointProbes {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: probe.descriptor,
                    bytes: probe.bytes,
                )
                try assertDescriptorAwareWireRejection(
                    error: error,
                    outputOnlyField: probe.outputOnlyField,
                    expectedMessage: "request contains a non-finite numeric value",
                    expectedReason: "INVALID_NUMERIC_VALUE",
                    expectedValue: probe.value,
                    label: probe.label,
                )
            }

            let negativeIntegerProbes = try Self.negativeIntegerWireProbes(for: contract)
            #expect(!negativeIntegerProbes.isEmpty)
            #expect(Set(negativeIntegerProbes.map(\.label)).count == negativeIntegerProbes.count)
            for probe in negativeIntegerProbes {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: probe.descriptor,
                    bytes: probe.bytes,
                )
                try assertDescriptorAwareWireRejection(
                    error: error,
                    outputOnlyField: probe.outputOnlyField,
                    expectedMessage: "request contains a negative integer value",
                    expectedReason: "INVALID_NUMERIC_VALUE",
                    expectedValue: "-1",
                    label: probe.label,
                )
            }

            let defaultOutputOnlyProbes = try Self.defaultValuedOutputOnlyWireProbes(
                for: contract,
            )
            #expect(!defaultOutputOnlyProbes.isEmpty)
            #expect(
                Set(defaultOutputOnlyProbes.map(\.label)).count == defaultOutputOnlyProbes.count,
            )
            for probe in defaultOutputOnlyProbes {
                do {
                    let error = try await rawInvalidRequestCall(
                        client: client,
                        descriptor: probe.descriptor,
                        bytes: probe.bytes,
                    )
                    try assertDescriptorAwareWireRejection(
                        error: error,
                        outputOnlyField: probe.field,
                        expectedMessage: "",
                        expectedReason: "",
                        expectedValue: "",
                        label: probe.label,
                    )
                } catch {
                    Issue.record("\(probe.label) did not reject its encoded output-only field: \(error)")
                }
            }

            let mapEntryProbes = try Self.unknownMapEntryWireProbes(for: contract)
            #expect(!mapEntryProbes.isEmpty)
            #expect(Set(mapEntryProbes.map(\.label)).count == mapEntryProbes.count)
            for probe in mapEntryProbes {
                do {
                    let error = try await rawInvalidRequestCall(
                        client: client,
                        descriptor: probe.descriptor,
                        bytes: probe.bytes,
                    )
                    #expect(error.code == .invalidArgument, Comment(rawValue: probe.label))
                    #expect(
                        error.message == "request contains unknown fields",
                        Comment(rawValue: probe.label),
                    )
                    let errorInfo = try extractErrorInfo(from: error)
                    #expect(errorInfo.reason == "UNKNOWN_FIELD", Comment(rawValue: probe.label))
                    #expect(
                        errorInfo.metadata["field"] == "request",
                        Comment(rawValue: probe.label),
                    )
                } catch {
                    Issue.record("\(probe.label) did not reject its unknown map-entry field: \(error)")
                }
            }
        }

        #expect(await pasteboard.mutationCount == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        #expect(system.applicationTerminationCalls.isEmpty)
        #expect(system.applicationActivationCalls.isEmpty)
    }

    @Test
    func `conflicting real oneof arms reject on raw wire before admission`() async throws {
        let system = MockSystemOperations()
        let recorder = BoundaryAdmissionRecorder()
        let composition = ExactMacServiceComposition(system: system)
        let inProcess = InProcessTransport()
        let interceptors: [any ServerInterceptor] = handlerContractTestInterceptors() + [
            BoundaryAdmissionInterceptor(recorder: recorder),
        ]
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: interceptors,
        )
        let client = GRPCClient(transport: inProcess.client)
        let suffix = UUID().uuidString

        let clickArm = try Array(
            Exactmac_V1_InputAction.with {
                $0.mouseClick.position = Exactmac_Type_Point.with {
                    $0.x = 1
                    $0.y = 1
                }
            }.serializedData(),
        )
        let typeTextArm = try Array(
            Exactmac_V1_InputAction.with {
                $0.textInput.text = "must-not-execute"
            }.serializedData(),
        )
        let elementConditionArm = try Array(
            Exactmac_V1_MacroCondition.with {
                $0.elementSelector = "role=AXButton"
            }.serializedData(),
        )
        let windowConditionArm = try Array(
            Exactmac_V1_MacroCondition.with {
                $0.windowTitle = "must-not-create"
            }.serializedData(),
        )

        func inputBytes(actionBytes: [UInt8]) -> [UInt8] {
            let desktopTarget = Self.varint((UInt64(4) << 3) | 0) + Self.varint(1)
            return Self.lengthDelimitedField(number: 2, payload: actionBytes) +
                Self.lengthDelimitedField(number: 7, payload: desktopTarget)
        }

        func createInputBytes(actionBytes: [UInt8], inputID: String) -> [UInt8] {
            Self.lengthDelimitedField(
                number: 1,
                payload: Array("applications/-".utf8),
            ) + Self.lengthDelimitedField(
                number: 2,
                payload: inputBytes(actionBytes: actionBytes),
            ) +
                Self.lengthDelimitedField(number: 3, payload: Array(inputID.utf8))
        }

        func createSplitInputBytes(
            firstActionBytes: [UInt8],
            secondActionBytes: [UInt8],
            inputID: String,
        ) -> [UInt8] {
            Self.lengthDelimitedField(
                number: 1,
                payload: Array("applications/-".utf8),
            ) + Self.lengthDelimitedField(
                number: 2,
                payload: inputBytes(actionBytes: firstActionBytes),
            ) + Self.lengthDelimitedField(
                number: 2,
                payload: inputBytes(actionBytes: secondActionBytes),
            ) + Self.lengthDelimitedField(number: 3, payload: Array(inputID.utf8))
        }

        func createMacroBytes(conditionBytes: [UInt8], macroID: String) throws -> [UInt8] {
            let thenAction = try Array(validAssignmentAction().serializedData())
            let conditional = Self.lengthDelimitedField(number: 1, payload: conditionBytes) +
                Self.lengthDelimitedField(number: 2, payload: thenAction)
            let action = Self.lengthDelimitedField(number: 3, payload: conditional)
            let macro = Self.lengthDelimitedField(
                number: 2,
                payload: Array("Conflicting oneof".utf8),
            ) + Self.lengthDelimitedField(number: 4, payload: action)
            return Self.lengthDelimitedField(number: 1, payload: macro) +
                Self.lengthDelimitedField(number: 2, payload: Array(macroID.utf8))
        }

        let inputIDs = [
            "conflicting-click-text-\(suffix)",
            "conflicting-text-click-\(suffix)",
            "merged-click-text-\(suffix)",
            "merged-text-click-\(suffix)",
        ]
        let macroIDs = [
            "conflicting-element-window-\(suffix)",
            "conflicting-window-element-\(suffix)",
        ]
        let probes: [(label: String, descriptor: MethodDescriptor, bytes: [UInt8], field: String)] = try [
            (
                "InputAction click then type_text",
                Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                createInputBytes(
                    actionBytes: clickArm + typeTextArm,
                    inputID: inputIDs[0],
                ),
                "input.action.input_type",
            ),
            (
                "InputAction type_text then click",
                Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                createInputBytes(
                    actionBytes: typeTextArm + clickArm,
                    inputID: inputIDs[1],
                ),
                "input.action.input_type",
            ),
            (
                "merged InputAction click then type_text",
                Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                createSplitInputBytes(
                    firstActionBytes: clickArm,
                    secondActionBytes: typeTextArm,
                    inputID: inputIDs[2],
                ),
                "input.action.input_type",
            ),
            (
                "merged InputAction type_text then click",
                Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                createSplitInputBytes(
                    firstActionBytes: typeTextArm,
                    secondActionBytes: clickArm,
                    inputID: inputIDs[3],
                ),
                "input.action.input_type",
            ),
            (
                "nested MacroCondition element_exists then window_exists",
                Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                createMacroBytes(
                    conditionBytes: elementConditionArm + windowConditionArm,
                    macroID: macroIDs[0],
                ),
                "macro.actions.conditional.condition.condition",
            ),
            (
                "nested MacroCondition window_exists then element_exists",
                Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                createMacroBytes(
                    conditionBytes: windowConditionArm + elementConditionArm,
                    macroID: macroIDs[1],
                ),
                "macro.actions.conditional.condition.condition",
            ),
        ]

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            for probe in probes {
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: probe.descriptor,
                    bytes: probe.bytes,
                )
                guard error.code == .invalidArgument else {
                    Issue.record("\(probe.label) returned \(error) instead of INVALID_ARGUMENT")
                    continue
                }
                #expect(
                    error.message == "request sets conflicting oneof fields",
                    Comment(rawValue: probe.label),
                )
                let errorInfo = try extractErrorInfo(from: error)
                #expect(errorInfo.reason == "CONFLICTING_ONEOF", Comment(rawValue: probe.label))
                #expect(errorInfo.domain == RPCErrorHelpers.domain, Comment(rawValue: probe.label))
                #expect(
                    errorInfo.metadata["field"] == probe.field,
                    Comment(rawValue: probe.label),
                )
            }
            #expect(
                await recorder.snapshot().isEmpty,
                "conflicting arms must not reach a post-validation interceptor",
            )

            let repeatedSameArmError = try await rawInvalidRequestCall(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                bytes: createSplitInputBytes(
                    firstActionBytes: clickArm,
                    secondActionBytes: clickArm,
                    inputID: "repeated-click-\(suffix)",
                ),
            )
            #expect(repeatedSameArmError.code == .aborted)
            #expect(repeatedSameArmError.message == BoundaryAdmissionInterceptor.sentinelMessage)
        }

        #expect(
            await recorder.snapshot() == [
                Exactmac_V1_ExactMac.Method.CreateInput.descriptor.fullyQualifiedMethod,
            ],
            "only the legal repeated-arm request may cross production validation",
        )
        let conflictingInputState = await composition.exactMacService.stateStore.currentState()
        #expect(conflictingInputState.inputs.isEmpty)
        #expect(await composition.exactMacService.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.exactMacService.stateStore.inputStateHistoryCount() == 0)
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(await composition.macroExecutor.activeExecutionCount() == 0)
        for macroID in macroIDs {
            #expect(await composition.macroRegistry.getMacro(name: "macros/\(macroID)") == nil)
        }
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `every descriptor valid public request crosses production validation`() async throws {
        let contract = try Self.loadPublicContract()
        let messages = Self.messageDescriptors(in: contract.descriptorSet)
        let enums = Self.enumDescriptors(in: contract.descriptorSet)
        let recorder = BoundaryAdmissionRecorder()
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        let inProcess = InProcessTransport()
        let interceptors: [any ServerInterceptor] = handlerContractTestInterceptors() + [
            BoundaryAdmissionInterceptor(recorder: recorder),
        ]
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: interceptors,
        )
        let client = GRPCClient(transport: inProcess.client)

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            for method in contract.methods {
                let requestBytes = try Self.minimalBoundaryRequest(
                    messageName: method.inputType,
                    messages: messages,
                    enums: enums,
                )
                let error = try await rawInvalidRequestCall(
                    client: client,
                    descriptor: method.descriptor,
                    bytes: requestBytes,
                )
                #expect(
                    error.code == .aborted,
                    Comment(rawValue: "\(method.descriptor.fullyQualifiedMethod): \(error)"),
                )
                #expect(error.message == BoundaryAdmissionInterceptor.sentinelMessage)
            }
        }

        let admittedMethods = await recorder.snapshot()
        #expect(
            admittedMethods == Set(contract.methods.map(\.descriptor.fullyQualifiedMethod)),
            Comment(rawValue: "every descriptor method must cross the production request boundary"),
        )
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `required fields and real oneofs reject recursively before state or work`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: handlerContractTestInterceptors(),
        )
        let client = GRPCClient(transport: inProcess.client)
        let suffix = UUID().uuidString
        let macroProbes: [(
            label: String,
            action: Exactmac_V1_MacroAction,
            reason: String,
            field: String,
        )] = [
            (
                "conditional condition",
                Exactmac_V1_MacroAction.with {
                    $0.conditional.thenActions = [validAssignmentAction()]
                },
                "REQUIRED_FIELD_MISSING",
                "macro.actions.conditional.condition",
            ),
            (
                "loop type",
                Exactmac_V1_MacroAction.with {
                    $0.loop.actions = [validAssignmentAction()]
                },
                "REQUIRED_ONEOF_MISSING",
                "macro.actions.loop.loop_type",
            ),
            (
                "assignment value",
                Exactmac_V1_MacroAction.with {
                    $0.assignment.variable = "result"
                },
                "REQUIRED_ONEOF_MISSING",
                "macro.actions.assignment.value",
            ),
            (
                "wait duration",
                Exactmac_V1_MacroAction.with {
                    $0.wait = Exactmac_V1_WaitAction()
                },
                "REQUIRED_FIELD_MISSING",
                "macro.actions.wait.duration",
            ),
            (
                "method name",
                Exactmac_V1_MacroAction.with {
                    $0.methodCall.args = ["key": "value"]
                },
                "REQUIRED_FIELD_MISSING",
                "macro.actions.method_call.method",
            ),
        ]

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            await expectRequestValidationError(
                client: client,
                request: Exactmac_V1_CreateSessionRequest(),
                descriptor: Exactmac_V1_ExactMac.Method.CreateSession.descriptor,
                responseType: Exactmac_V1_Session.self,
                reason: "REQUIRED_FIELD_MISSING",
                field: "session",
                label: "missing CreateSession.session",
            )
            await expectRequestValidationError(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.input.target.desktop = true
                    $0.input.action = Exactmac_V1_InputAction()
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                responseType: Exactmac_V1_Input.self,
                reason: "REQUIRED_ONEOF_MISSING",
                field: "input.action.input_type",
                label: "missing InputAction.input_type",
            )
            await expectRequestValidationError(
                client: client,
                request: Exactmac_V1_WriteClipboardRequest.with {
                    $0.content.type = .text
                },
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                responseType: Exactmac_V1_WriteClipboardResponse.self,
                reason: "REQUIRED_ONEOF_MISSING",
                field: "content.content",
                label: "missing ClipboardContent.content",
            )
            await expectRequestValidationError(
                client: client,
                request: Exactmac_V1_WriteClipboardRequest.with {
                    $0.content.text = "missing-type"
                },
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                responseType: Exactmac_V1_WriteClipboardResponse.self,
                reason: "REQUIRED_FIELD_MISSING",
                field: "content.type",
                label: "missing ClipboardContent.type",
            )

            let explicitUnspecifiedContent = Exactmac_V1_WriteClipboardRequest.with {
                $0.content.type = .unspecified
                $0.content.text = "explicit-unspecified"
            }
            #expect(explicitUnspecifiedContent.content.hasType)
            let downstreamClipboardError = try await protobufRPCError(
                client: client,
                request: explicitUnspecifiedContent,
                descriptor: Exactmac_V1_ExactMac.Method.WriteClipboard.descriptor,
                responseType: Exactmac_V1_WriteClipboardResponse.self,
            )
            #expect(downstreamClipboardError.code == .invalidArgument)
            #expect(
                downstreamClipboardError.message ==
                    "Invalid clipboard content: Content type does not match its payload",
            )

            let zeroWindowError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_MoveWindowRequest.with {
                    $0.name = "applications/111/windows/1"
                    $0.x = 0
                    $0.y = 0
                },
                descriptor: Exactmac_V1_ExactMac.Method.MoveWindow.descriptor,
                responseType: Exactmac_V1_Window.self,
            )
            #expect(zeroWindowError.code == .notFound)

            let explicitFalseParameter = Exactmac_V1_MacroParameter.with {
                $0.key = "optional-value"
                $0.type = .string
                $0.required = false
            }
            #expect(explicitFalseParameter.hasRequired)
            let presenceMacroID = "presence-\(suffix)"
            let presenceMacro: Exactmac_V1_Macro = try await client.unary(
                request: ClientRequest(message: Exactmac_V1_CreateMacroRequest.with {
                    $0.macroID = presenceMacroID
                    $0.macro.displayName = "Presence"
                    $0.macro.actions = [validAssignmentAction()]
                    $0.macro.parameters = [explicitFalseParameter]
                }),
                descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                serializer: ProtobufSerializer<Exactmac_V1_CreateMacroRequest>(),
                deserializer: ProtobufDeserializer<Exactmac_V1_Macro>(),
                options: .defaults,
            ) { response in
                try response.message
            }
            #expect(presenceMacro.parameters.count == 1)
            #expect(presenceMacro.parameters[0].hasRequired)
            #expect(presenceMacro.parameters[0].required == false)
            _ = await composition.macroRegistry.deleteMacro(name: "macros/\(presenceMacroID)")

            for (index, probe) in macroProbes.enumerated() {
                await expectRequestValidationError(
                    client: client,
                    request: Exactmac_V1_CreateMacroRequest.with {
                        $0.macroID = "required-\(index)-\(suffix)"
                        $0.macro.displayName = probe.label
                        $0.macro.actions = [probe.action]
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                    responseType: Exactmac_V1_Macro.self,
                    reason: probe.reason,
                    field: probe.field,
                    label: probe.label,
                )
            }
        }

        let sessions = try await composition.sessionManager.listSessions(
            pageSize: 1000,
            pageToken: nil,
        ).sessions
        #expect(sessions.isEmpty)
        let requiredInputState = await composition.exactMacService.stateStore.currentState()
        #expect(requiredInputState.inputs.isEmpty)
        #expect(await composition.exactMacService.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.exactMacService.stateStore.inputStateHistoryCount() == 0)
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        for index in macroProbes.indices {
            let name = "macros/required-\(index)-\(suffix)"
            #expect(await composition.macroRegistry.getMacro(name: name) == nil)
            _ = await composition.macroRegistry.deleteMacro(name: name)
        }
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `empty element selector crosses validation as the documented matches-all contract`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            // A present-but-empty selector is the documented "matches ALL
            // elements" contract (selector.proto, SelectorParser,
            // ElementLocator) and must reach the handler: the wire validator
            // must not reject it as a missing required oneof.
            let emptySelectorError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = "applications/1"
                    $0.selector = Exactmac_Type_ElementSelector()
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
                responseType: Exactmac_V1_FindElementsResponse.self,
            )
            #expect(
                emptySelectorError.code != .invalidArgument
                    && !emptySelectorError.message.contains("REQUIRED_ONEOF_MISSING"),
                Comment(rawValue: "empty selector must cross wire validation: \(emptySelectorError)"),
            )

            // A selector with criteria set also crosses validation.
            let populatedSelectorError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = "applications/1"
                    $0.selector.role = "AXButton"
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
                responseType: Exactmac_V1_FindElementsResponse.self,
            )
            #expect(
                populatedSelectorError.code != .invalidArgument
                    && !populatedSelectorError.message.contains("REQUIRED_ONEOF_MISSING"),
                Comment(rawValue: "populated selector must cross wire validation: \(populatedSelectorError)"),
            )

            // Sanity: a genuinely required oneof still rejects before the handler.
            await expectRequestValidationError(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.input.target.desktop = true
                    $0.input.action = Exactmac_V1_InputAction()
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                responseType: Exactmac_V1_Input.self,
                reason: "REQUIRED_ONEOF_MISSING",
                field: "input.action.input_type",
                label: "missing InputAction.input_type still rejects",
            )
        }
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `finite timing overflow and poll ranges reject before identity or state`() async throws {
        let system = MockSystemOperations()
        let pasteboard = RequestValidationPasteboard()
        let composition = ExactMacServiceComposition(
            system: system,
            clipboardPasteboard: pasteboard,
        )
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_WatchAccessibilityRequest.with {
                        $0.name = "applications/111"
                        $0.pollInterval = 61
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WatchAccessibility.descriptor,
                    responseType: Exactmac_V1_WatchAccessibilityResponse.self,
                ),
                field: "poll_interval",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_WaitElementRequest.with {
                        $0.parent = "applications/111"
                        $0.selector.role = "button"
                        $0.timeout = .greatestFiniteMagnitude
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WaitElement.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
                field: "timeout",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_WaitElementRequest.with {
                        $0.parent = "applications/111"
                        $0.selector.role = "button"
                        $0.pollInterval = 61
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WaitElement.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
                field: "poll_interval",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_WaitElementStateRequest.with {
                        $0.parent = "applications/111"
                        $0.elementID = "element"
                        $0.condition.enabled = true
                        $0.pollInterval = 61
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.WaitElementState.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
                field: "poll_interval",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CreateObservationRequest.with {
                        $0.parent = "applications/111"
                        $0.observation.type = .windowChanges
                        $0.observation.filter.pollInterval = 61
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CreateObservation.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
                field: "observation.filter.poll_interval",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_BeginTransactionRequest.with {
                        $0.session = "sessions/session"
                        $0.timeout = .greatestFiniteMagnitude
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.BeginTransaction.descriptor,
                    responseType: Exactmac_V1_BeginTransactionResponse.self,
                ),
                field: "timeout",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_ExecuteMacroRequest.with {
                        $0.macro = "macros/macro"
                        $0.options.timeout = .greatestFiniteMagnitude
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
                field: "options.timeout",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_AutomateOpenFileDialogRequest.with {
                        $0.application = "applications/111"
                        $0.timeout = .greatestFiniteMagnitude
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.AutomateOpenFileDialog.descriptor,
                    responseType: Exactmac_V1_AutomateOpenFileDialogResponse.self,
                ),
                field: "timeout",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_AutomateSaveFileDialogRequest.with {
                        $0.application = "applications/111"
                        $0.filePath = "/tmp/file"
                        $0.timeout = .greatestFiniteMagnitude
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.AutomateSaveFileDialog.descriptor,
                    responseType: Exactmac_V1_AutomateSaveFileDialogResponse.self,
                ),
                field: "timeout",
            )
        }

        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.getActiveObservationCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        #expect(await pasteboard.mutationCount == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
    }

    @Test
    func `protobuf durations reject noncanonical and unsafe values before work`() async throws {
        let contract = try Self.loadPublicContract()
        let durationPaths = try Self.requestFieldPaths(for: contract).filter {
            $0.fields.last?.type == .message
                && Self.normalizedTypeName($0.fields.last?.typeName ?? "")
                == "google.protobuf.Duration"
        }
        #expect(
            Set(durationPaths.map(\.label)) == Set([
                "\(Exactmac_V1_ExactMac.Method.ExecuteAppleScript.descriptor.fullyQualifiedMethod):timeout",
                "\(Exactmac_V1_ExactMac.Method.ExecuteJavaScript.descriptor.fullyQualifiedMethod):timeout",
                "\(Exactmac_V1_ExactMac.Method.ExecuteShellCommand.descriptor.fullyQualifiedMethod):timeout",
                "\(Exactmac_V1_ExactMac.Method.PreauthorizeEnvelope.descriptor.fullyQualifiedMethod):requested_lifetime",
                "\(Google_Longrunning_Operations.Method.WaitOperation.descriptor.fullyQualifiedMethod):timeout",
            ]),
        )

        let system = MockSystemOperations()
        let composition = ExactMacServiceComposition(system: system)
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            try await assertInvalidTimeoutError(
                protobufRPCError(
                    client: client,
                    request: Exactmac_V1_ExecuteAppleScriptRequest.with {
                        $0.script = "return 1"
                        $0.validationOnly = true
                        $0.timeout = Google_Protobuf_Duration.with {
                            $0.seconds = 18_446_744_073
                            $0.nanos = 709_551_615
                        }
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ExecuteAppleScript.descriptor,
                    responseType: Exactmac_V1_ExecuteAppleScriptResponse.self,
                ),
            )
            try await assertInvalidTimeoutError(
                protobufRPCError(
                    client: client,
                    request: Exactmac_V1_ExecuteJavaScriptRequest.with {
                        $0.script = "1"
                        $0.validationOnly = true
                        $0.timeout = Google_Protobuf_Duration(seconds: 0, nanos: 1_000_000_000)
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ExecuteJavaScript.descriptor,
                    responseType: Exactmac_V1_ExecuteJavaScriptResponse.self,
                ),
            )
            try await assertInvalidTimeoutError(
                protobufRPCError(
                    client: client,
                    request: Exactmac_V1_ExecuteShellCommandRequest.with {
                        $0.command = "true"
                        $0.timeout = Google_Protobuf_Duration()
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ExecuteShellCommand.descriptor,
                    responseType: Exactmac_V1_ExecuteShellCommandResponse.self,
                ),
            )
            try await assertInvalidTimeoutError(
                protobufRPCError(
                    client: client,
                    request: Google_Longrunning_WaitOperationRequest.with {
                        $0.name = "operations/must-not-create-a-waiter"
                        $0.timeout = Google_Protobuf_Duration(seconds: Int64.max)
                    },
                    descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                ),
            )
        }

        #expect(await composition.scriptExecutor.activeExecutionCount() == 0)
        #expect(await composition.operationStore.waiterCount() == 0)
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
    }

    @Test
    func `every public page size uses one bounded policy`() throws {
        let contract = try Self.loadPublicContract()
        let pageSizePaths = try Self.requestFieldPaths(for: contract).filter {
            $0.fields.last?.name == "page_size" && $0.fields.last?.type == .int32
        }
        #expect(
            Set(pageSizePaths.map(\.label)) == Set([
                "\(Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListApplications.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListInputs.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.FindElements.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.FindRegionElements.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListElements.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListWindows.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListObservations.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListSessions.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListMacros.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListDisplays.descriptor.fullyQualifiedMethod):page_size",
                "\(Exactmac_V1_ExactMac.Method.ListGrants.descriptor.fullyQualifiedMethod):page_size",
                "\(Google_Longrunning_Operations.Method.ListOperations.descriptor.fullyQualifiedMethod):page_size",
            ]),
        )

        #expect(try RequestNumericValidation.pageSize(0) == 100)
        #expect(try RequestNumericValidation.pageSize(0, default: 50) == 50)
        #expect(try RequestNumericValidation.pageSize(1) == 1)
        #expect(try RequestNumericValidation.pageSize(Int32.max) == 1000)
        do {
            _ = try RequestNumericValidation.pageSize(-1)
            Issue.record("Expected negative page size rejection")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
            let errorInfo = try extractErrorInfo(from: error)
            #expect(errorInfo.reason == "INVALID_PAGE_SIZE")
            #expect(errorInfo.metadata["field"] == "page_size")
        }
    }

    @Test
    func `every public skip uses one bounded policy`() throws {
        let contract = try Self.loadPublicContract()
        let skipPaths = try Self.requestFieldPaths(for: contract).filter {
            $0.fields.last?.name == "skip" && $0.fields.last?.type == .int32
        }
        #expect(
            Set(skipPaths.map(\.label)) == Set([
                "\(Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListApplications.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListInputs.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.FindElements.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.FindRegionElements.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListElements.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListWindows.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListObservations.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListSessions.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListMacros.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListDisplays.descriptor.fullyQualifiedMethod):skip",
                "\(Exactmac_V1_ExactMac.Method.ListGrants.descriptor.fullyQualifiedMethod):skip",
            ]),
        )

        #expect(try RequestNumericValidation.skip(0) == 0)
        #expect(try RequestNumericValidation.skip(30) == 30)
        #expect(try RequestNumericValidation.skip(Int32.max) == Int(Int32.max))
        do {
            _ = try RequestNumericValidation.skip(-1)
            Issue.record("Expected negative skip rejection")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
            let errorInfo = try extractErrorInfo(from: error)
            #expect(errorInfo.reason == "INVALID_SKIP")
            #expect(errorInfo.metadata["field"] == "skip")
        }
    }

    @Test
    func `screenshot quality rejects out of range before target or capture`() async throws {
        let contract = try Self.loadPublicContract()
        let qualityPaths = try Self.requestFieldPaths(for: contract).filter {
            $0.fields.last?.name == "quality" && $0.fields.last?.type == .int32
        }
        #expect(
            Set(qualityPaths.map(\.label)) == Set([
                "\(Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor.fullyQualifiedMethod):quality",
                "\(Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor.fullyQualifiedMethod):quality",
                "\(Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor.fullyQualifiedMethod):quality",
                "\(Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor.fullyQualifiedMethod):quality",
            ]),
        )

        let system = MockSystemOperations()
        let composition = ExactMacServiceComposition(system: system)
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CaptureWindowScreenshotRequest.with {
                        $0.window = "applications/111/windows/1"
                        $0.quality = 101
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureWindowScreenshot.descriptor,
                    responseType: Exactmac_V1_CaptureWindowScreenshotResponse.self,
                ),
                field: "quality",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CaptureElementScreenshotRequest.with {
                        $0.parent = "applications/111"
                        $0.elementID = "element"
                        $0.quality = 101
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureElementScreenshot.descriptor,
                    responseType: Exactmac_V1_CaptureElementScreenshotResponse.self,
                ),
                field: "quality",
            )
            try await assertRangeError(
                error: protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CaptureRegionScreenshotRequest.with {
                        $0.region.width = 1
                        $0.region.height = 1
                        $0.quality = 101
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                    responseType: Exactmac_V1_CaptureRegionScreenshotResponse.self,
                ),
                field: "quality",
            )
        }

        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
        #expect(try RequestNumericValidation.imageQuality(0) == 85)
        #expect(try RequestNumericValidation.imageQuality(1) == 1)
        #expect(try RequestNumericValidation.imageQuality(100) == 100)
    }

    @Test
    func `removed macro execution options reject before lookup or operation creation`() async throws {
        let system = MockSystemOperations()
        let composition = ExactMacServiceComposition(system: system)
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            let removedOptions: [(label: String, bytes: [UInt8])] = [
                ("speed", [0x10, 0x01]),
                ("continue_on_error", [0x18, 0x01]),
                ("record_execution", [0x20, 0x01]),
            ]
            for removedOption in removedOptions {
                let options = try Exactmac_V1_ExecutionOptions(
                    serializedBytes: removedOption.bytes,
                )
                let error = try await protobufRPCError(
                    client: client,
                    request: Exactmac_V1_ExecuteMacroRequest.with {
                        $0.macro = "macros/not-present"
                        $0.options = options
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.ExecuteMacro.descriptor,
                    responseType: Google_Longrunning_Operation.self,
                )
                #expect(error.code == .invalidArgument, Comment(rawValue: removedOption.label))
                let errorInfo = try extractErrorInfo(from: error)
                #expect(
                    errorInfo.reason == "UNKNOWN_FIELD",
                    Comment(rawValue: removedOption.label),
                )
                #expect(errorInfo.domain == RPCErrorHelpers.domain)
                #expect(errorInfo.metadata["field"] == "request")
            }
        }

        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.macroExecutor.activeExecutionCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
    }

    @Test
    func `invalid positive input ranges reject before identity lookup or state insertion`() async throws {
        let system = MockSystemOperations()
        let composition = ExactMacServiceComposition(system: system)
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: handlerContractTestInterceptors(),
        )
        let client = GRPCClient(transport: inProcess.client)
        let invalidActions: [(label: String, action: Exactmac_V1_InputAction)] = [
            (
                "click_count",
                Exactmac_V1_InputAction.with {
                    $0.mouseClick.position = Exactmac_Type_Point.with {
                        $0.x = 1
                        $0.y = 1
                    }
                    $0.mouseClick.clickCount = 11
                },
            ),
            (
                "char_delay",
                Exactmac_V1_InputAction.with {
                    $0.textInput.text = "x"
                    $0.textInput.charDelay = 61
                },
            ),
            (
                "scroll_action.horizontal",
                Exactmac_V1_InputAction.with {
                    $0.scrollAction.horizontal = Double(Int32.max) + 1
                },
            ),
            (
                "hover_action.duration",
                Exactmac_V1_InputAction.with {
                    $0.hoverAction.position = Exactmac_Type_Point.with {
                        $0.x = 1
                        $0.y = 1
                    }
                    $0.hoverAction.duration = 3601
                },
            ),
            (
                "animation_duration",
                Exactmac_V1_InputAction.with {
                    $0.animationDuration = 3601
                    $0.mouseMove.position = Exactmac_Type_Point.with {
                        $0.x = 1
                        $0.y = 1
                    }
                },
            ),
        ]

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            for invalidAction in invalidActions {
                let error = try await protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CreateInputRequest.with {
                        $0.parent = "applications/-"
                        $0.input.target.desktop = true
                        $0.input.action = invalidAction.action
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                    responseType: Exactmac_V1_Input.self,
                )
                #expect(error.code == .invalidArgument, Comment(rawValue: invalidAction.label))
                let errorInfo = try extractErrorInfo(from: error)
                #expect(errorInfo.reason == "INVALID_INPUT", Comment(rawValue: invalidAction.label))
                #expect(errorInfo.metadata["field"] == "input.action")
            }
        }

        let invalidInputState = await composition.exactMacService.stateStore.currentState()
        #expect(invalidInputState.inputs.isEmpty)
        #expect(await composition.exactMacService.stateStore.activeInputIdentityCount() == 0)
        #expect(await composition.exactMacService.stateStore.inputStateHistoryCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
    }

    @Test
    func `invalid positive nested macro input rejects before registry insertion`() async throws {
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: handlerContractTestInterceptors(),
        )
        let client = GRPCClient(transport: inProcess.client)
        let macroID = "invalid-positive-\(UUID().uuidString)"
        let macroName = "macros/\(macroID)"
        var rejection: RPCError?

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            do {
                rejection = try await protobufRPCError(
                    client: client,
                    request: Exactmac_V1_CreateMacroRequest.with {
                        $0.macroID = macroID
                        $0.macro.displayName = "invalid positive input"
                        $0.macro.actions = [
                            Exactmac_V1_MacroAction.with {
                                $0.loop.count = 1
                                $0.loop.actions = [
                                    Exactmac_V1_MacroAction.with {
                                        $0.input.mouseClick.position = Exactmac_Type_Point.with {
                                            $0.x = 1
                                            $0.y = 1
                                        }
                                        $0.input.mouseClick.clickCount = 11
                                    },
                                ]
                            },
                        ]
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                    responseType: Exactmac_V1_Macro.self,
                )
            } catch {
                Issue.record("CreateMacro accepted invalid nested input: \(error)")
            }
        }

        let stored = await composition.macroRegistry.getMacro(name: macroName)
        _ = await composition.macroRegistry.deleteMacro(name: macroName)
        #expect(rejection?.code == .invalidArgument)
        if let rejection {
            let errorInfo = try extractErrorInfo(from: rejection)
            #expect(errorInfo.reason == "INVALID_MACRO")
            #expect(errorInfo.metadata["field"] == "macro.actions")
        }
        #expect(stored == nil)
    }

    @Test
    func `invalid positive nested macro update preserves stored actions`() async throws {
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
            interceptors: handlerContractTestInterceptors(),
        )
        let client = GRPCClient(transport: inProcess.client)
        let macroID = "invalid-update-\(UUID().uuidString)"
        let macroName = "macros/\(macroID)"
        let originalAction = Exactmac_V1_MacroAction.with {
            $0.assignment.variable = "state"
            $0.assignment.literal = "original"
        }
        _ = await composition.macroRegistry.createMacro(
            macroId: macroID,
            displayName: "preserved macro",
            description: "",
            actions: [originalAction],
            parameters: [],
            tags: [],
        )
        var rejection: RPCError?

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }

            do {
                rejection = try await protobufRPCError(
                    client: client,
                    request: Exactmac_V1_UpdateMacroRequest.with {
                        $0.macro.name = macroName
                        $0.macro.displayName = "preserved macro"
                        $0.macro.actions = [
                            Exactmac_V1_MacroAction.with {
                                $0.input.hoverAction.position = Exactmac_Type_Point.with {
                                    $0.x = 1
                                    $0.y = 1
                                }
                                $0.input.hoverAction.duration = 3601
                            },
                        ]
                        $0.updateMask.paths = ["actions"]
                    },
                    descriptor: Exactmac_V1_ExactMac.Method.UpdateMacro.descriptor,
                    responseType: Exactmac_V1_Macro.self,
                )
            } catch {
                Issue.record("UpdateMacro accepted invalid nested input: \(error)")
            }
        }

        let stored = await composition.macroRegistry.getMacro(name: macroName)
        _ = await composition.macroRegistry.deleteMacro(name: macroName)
        #expect(rejection?.code == .invalidArgument)
        if let rejection {
            let errorInfo = try extractErrorInfo(from: rejection)
            #expect(errorInfo.reason == "INVALID_MACRO")
            #expect(errorInfo.metadata["field"] == "macro.actions")
        }
        #expect(stored?.actions == [originalAction])
    }

    @Test
    func `screenshot display selectors are exact resource names`() throws {
        let contract = try Self.loadPublicContract()
        let displayPaths = try Self.requestFieldPaths(for: contract).filter {
            $0.fields.last?.name == "display"
                && [
                    Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor.fullyQualifiedMethod,
                    Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor.fullyQualifiedMethod,
                ].contains($0.method.descriptor.fullyQualifiedMethod)
        }
        #expect(displayPaths.count == 2)
        for displayPath in displayPaths {
            #expect(
                displayPath.fields.last?.type == .string,
                Comment(rawValue: displayPath.label),
            )
        }
    }

    @Test
    func `screenshot display aliases and removed index wires reject before capture`() async throws {
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        let inProcess = InProcessTransport()
        let server = GRPCServer(
            transport: productionServerTransport(inProcess.server),
            services: [composition.exactMacService, composition.operationsProvider],
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

            let fullAliasError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_CaptureScreenshotRequest.with {
                    $0.display = "displays/01"
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
                responseType: Exactmac_V1_CaptureScreenshotResponse.self,
            )
            #expect(fullAliasError.code == .invalidArgument)
            let fullAliasInfo = try extractErrorInfo(from: fullAliasError)
            #expect(fullAliasInfo.reason == "INVALID_RESOURCE_NAME")
            #expect(fullAliasInfo.metadata["field"] == "display")

            let regionAliasError = try await protobufRPCError(
                client: client,
                request: Exactmac_V1_CaptureRegionScreenshotRequest.with {
                    $0.region = Exactmac_Type_Region.with {
                        $0.width = 1
                        $0.height = 1
                    }
                    $0.display = "/displays/1"
                },
                descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                responseType: Exactmac_V1_CaptureRegionScreenshotResponse.self,
            )
            #expect(regionAliasError.code == .invalidArgument)
            let regionAliasInfo = try extractErrorInfo(from: regionAliasError)
            #expect(regionAliasInfo.reason == "INVALID_RESOURCE_NAME")
            #expect(regionAliasInfo.metadata["field"] == "display")

            let removedFullIndex = try Exactmac_V1_CaptureScreenshotRequest(
                serializedBytes: [0x28, 0x01],
            )
            let removedFullError = try await protobufRPCError(
                client: client,
                request: removedFullIndex,
                descriptor: Exactmac_V1_ExactMac.Method.CaptureScreenshot.descriptor,
                responseType: Exactmac_V1_CaptureScreenshotResponse.self,
            )
            #expect(removedFullError.code == .invalidArgument)
            #expect(try extractErrorInfo(from: removedFullError).reason == "UNKNOWN_FIELD")

            let removedRegionIndex = try Exactmac_V1_CaptureRegionScreenshotRequest(
                serializedBytes: [0x30, 0x01],
            )
            let removedRegionError = try await protobufRPCError(
                client: client,
                request: removedRegionIndex,
                descriptor: Exactmac_V1_ExactMac.Method.CaptureRegionScreenshot.descriptor,
                responseType: Exactmac_V1_CaptureRegionScreenshotResponse.self,
            )
            #expect(removedRegionError.code == .invalidArgument)
            #expect(try extractErrorInfo(from: removedRegionError).reason == "UNKNOWN_FIELD")
        }
    }

    @Test
    func `numeric request field inventory is classified`() throws {
        let contract = try Self.loadPublicContract()
        let numericPaths = try Self.requestFieldPaths(for: contract).filter { fieldPath in
            guard let fieldType = fieldPath.fields.last?.type else { return false }
            switch fieldType {
            case .double, .float,
                 .int32, .int64, .sint32, .sint64, .sfixed32, .sfixed64,
                 .uint32, .uint64, .fixed32, .fixed64:
                return true
            default:
                return false
            }
        }
        let classified = numericPaths.map { fieldPath in
            (path: fieldPath, policy: Self.numericRequestPolicy(for: fieldPath))
        }
        let unclassified = classified.compactMap { entry in
            entry.policy == nil ? entry.path.label : nil
        }.sorted()
        #expect(
            unclassified.isEmpty,
            Comment(rawValue: "Unclassified numeric request fields:\n\(unclassified.joined(separator: "\n"))"),
        )
        #expect(
            Set(classified.compactMap(\.policy)) == Set(NumericRequestPolicy.allCases),
            "Every numeric request policy must remain represented by the public descriptor",
        )
    }

    @Test
    func `request field traversal preserves repeated message types at distinct paths`() throws {
        let contract = try Self.loadPublicContract()
        let createInputMethod = Exactmac_V1_ExactMac.Method.CreateInput.descriptor
            .fullyQualifiedMethod
        let labels = try Set(
            Self.requestFieldPaths(for: contract)
                .filter { $0.method.descriptor.fullyQualifiedMethod == createInputMethod }
                .map(\.label),
        )
        let expectedPointOccurrences: Set = [
            "\(createInputMethod):input.action.mouse_click.position.x",
            "\(createInputMethod):input.action.mouse_move.position.x",
            "\(createInputMethod):input.action.mouse_drag.start_position.x",
            "\(createInputMethod):input.action.mouse_drag.end_position.x",
            "\(createInputMethod):input.action.mouse_drag.waypoints.x",
            "\(createInputMethod):input.action.hover_action.position.x",
        ]

        #expect(
            expectedPointOccurrences.isSubset(of: labels),
            Comment(
                rawValue: "Missing path-sensitive request occurrences:\n\(expectedPointOccurrences.subtracting(labels).sorted().joined(separator: "\n"))",
            ),
        )
    }

    private static func numericRequestPolicy(
        for fieldPath: RequestFieldPath,
    ) -> NumericRequestPolicy? {
        let method = fieldPath.method.descriptor.fullyQualifiedMethod
        let path = fieldPath.fields.map(\.name).joined(separator: ".")
        let exactMac = Exactmac_V1_ExactMac.Method.self

        if path == "page_size" {
            return .boundedPageSize
        }
        if path == "skip" {
            return .boundedSkip
        }
        if fieldPath.fields.dropLast().last.map({
            normalizedTypeName($0.typeName) == "google.protobuf.Duration"
        }) == true {
            return .canonicalProtobufDuration
        }
        if fieldPath.fields.contains(where: {
            $0.options.Google_Api_fieldBehavior.contains(.outputOnly)
        }) {
            return .rejectedOutputOnly
        }

        let inputActionNumericPaths: Set = [
            "animation_duration",
            "mouse_click.click_count",
            "mouse_click.position.x",
            "mouse_click.position.y",
            "mouse_drag.duration",
            "mouse_drag.end_position.x",
            "mouse_drag.end_position.y",
            "mouse_drag.waypoints.x",
            "mouse_drag.waypoints.y",
            "mouse_drag.start_position.x",
            "mouse_drag.start_position.y",
            "hover_action.duration",
            "hover_action.position.x",
            "hover_action.position.y",
            "mouse_move.duration",
            "mouse_move.position.x",
            "mouse_move.position.y",
            "key_press.hold_duration",
            "scroll_action.duration",
            "scroll_action.horizontal",
            "scroll_action.position.x",
            "scroll_action.position.y",
            "scroll_action.vertical",
            "text_input.char_delay",
        ]
        if method == exactMac.CreateInput.descriptor.fullyQualifiedMethod,
           path.hasPrefix("input.action."),
           inputActionNumericPaths.contains(String(path.dropFirst("input.action.".count)))
        {
            return .validatedInputAction
        }
        if [
            exactMac.CreateMacro.descriptor.fullyQualifiedMethod,
            exactMac.UpdateMacro.descriptor.fullyQualifiedMethod,
        ].contains(method), path.hasPrefix("macro.actions.input."),
            inputActionNumericPaths.contains(String(path.dropFirst("macro.actions.input.".count)))
        {
            return .validatedInputAction
        }

        let screenshotMethods = [
            exactMac.CaptureScreenshot.descriptor.fullyQualifiedMethod,
            exactMac.CaptureRegionScreenshot.descriptor.fullyQualifiedMethod,
            exactMac.CaptureWindowScreenshot.descriptor.fullyQualifiedMethod,
            exactMac.CaptureElementScreenshot.descriptor.fullyQualifiedMethod,
        ]
        if screenshotMethods.contains(method), path == "quality" {
            return .boundedImageQuality
        }

        let selectorMethods = [
            exactMac.ClickElement.descriptor.fullyQualifiedMethod,
            exactMac.FindElements.descriptor.fullyQualifiedMethod,
            exactMac.FindRegionElements.descriptor.fullyQualifiedMethod,
            exactMac.PerformElementAction.descriptor.fullyQualifiedMethod,
            exactMac.WaitElement.descriptor.fullyQualifiedMethod,
            exactMac.WaitElementState.descriptor.fullyQualifiedMethod,
            exactMac.WriteElementValue.descriptor.fullyQualifiedMethod,
        ]
        if selectorMethods.contains(method), [
            "selector.position.tolerance",
            "selector.position.x",
            "selector.position.y",
        ].contains(path) {
            return .validatedSelectorGeometry
        }

        if [
            exactMac.CaptureRegionScreenshot.descriptor.fullyQualifiedMethod,
            exactMac.FindRegionElements.descriptor.fullyQualifiedMethod,
        ].contains(method), ["region.height", "region.width", "region.x", "region.y"].contains(path) {
            return .validatedRegionGeometry
        }
        if method == exactMac.MoveWindow.descriptor.fullyQualifiedMethod,
           ["x", "y"].contains(path)
        {
            return .validatedWindowGeometry
        }
        if method == exactMac.ResizeWindow.descriptor.fullyQualifiedMethod,
           ["height", "width"].contains(path)
        {
            return .validatedWindowGeometry
        }

        let boundedTimingLabels: Set = [
            "\(exactMac.AutomateOpenFileDialog.descriptor.fullyQualifiedMethod):timeout",
            "\(exactMac.AutomateSaveFileDialog.descriptor.fullyQualifiedMethod):timeout",
            "\(exactMac.BeginTransaction.descriptor.fullyQualifiedMethod):timeout",
            "\(exactMac.CreateObservation.descriptor.fullyQualifiedMethod):observation.filter.poll_interval",
            "\(exactMac.ExecuteMacro.descriptor.fullyQualifiedMethod):options.timeout",
            "\(exactMac.WaitElement.descriptor.fullyQualifiedMethod):poll_interval",
            "\(exactMac.WaitElement.descriptor.fullyQualifiedMethod):timeout",
            "\(exactMac.WaitElementState.descriptor.fullyQualifiedMethod):poll_interval",
            "\(exactMac.WaitElementState.descriptor.fullyQualifiedMethod):timeout",
            "\(exactMac.WatchAccessibility.descriptor.fullyQualifiedMethod):poll_interval",
        ]
        if boundedTimingLabels.contains(fieldPath.label) {
            return .boundedTiming
        }
        if [
            "\(exactMac.CreateMacro.descriptor.fullyQualifiedMethod):macro.actions.loop.count",
            "\(exactMac.CreateMacro.descriptor.fullyQualifiedMethod):macro.actions.wait.condition.timeout",
            "\(exactMac.CreateMacro.descriptor.fullyQualifiedMethod):macro.actions.wait.duration",
            "\(exactMac.UpdateMacro.descriptor.fullyQualifiedMethod):macro.actions.loop.count",
            "\(exactMac.UpdateMacro.descriptor.fullyQualifiedMethod):macro.actions.wait.condition.timeout",
            "\(exactMac.UpdateMacro.descriptor.fullyQualifiedMethod):macro.actions.wait.duration",
        ].contains(fieldPath.label) {
            return .macroExecutionControlled
        }
        if fieldPath.label == "\(exactMac.CaptureElementScreenshot.descriptor.fullyQualifiedMethod):padding" {
            return .validatedScreenshotPadding
        }

        return nil
    }

    private static func loadPublicContract() throws -> PublicAPIContract {
        let serverDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let descriptorURL = serverDirectory
            .appendingPathComponent("Sources/ExactMacServer/DescriptorSets/exactmac_descriptors.pb")
        let descriptorSet = try Google_Protobuf_FileDescriptorSet(
            serializedBytes: Data(contentsOf: descriptorURL),
            extensions: Google_Api_FieldBehavior_Extensions,
        )
        let publicServices: Set = [
            "google.longrunning.Operations",
            "exactmac.v1.ExactMac",
        ]

        let methods = descriptorSet.file.flatMap { file in
            file.service.flatMap { service -> [PublicMethodContract] in
                let serviceName = file.package.isEmpty
                    ? service.name
                    : "\(file.package).\(service.name)"
                guard publicServices.contains(serviceName) else { return [] }
                return service.method.map { method in
                    PublicMethodContract(
                        descriptor: MethodDescriptor(
                            service: ServiceDescriptor(fullyQualifiedService: serviceName),
                            method: method.name,
                            type: Self.rpcType(
                                clientStreaming: method.clientStreaming,
                                serverStreaming: method.serverStreaming,
                            ),
                        ),
                        inputType: Self.normalizedTypeName(method.inputType),
                    )
                }
            }
        }.sorted { $0.descriptor.fullyQualifiedMethod < $1.descriptor.fullyQualifiedMethod }
        return PublicAPIContract(descriptorSet: descriptorSet, methods: methods)
    }

    private static func publicServiceMethodCounts(
        in descriptorSet: Google_Protobuf_FileDescriptorSet,
    ) -> [String: Int] {
        let publicServices: Set = [
            "google.longrunning.Operations",
            "exactmac.v1.ExactMac",
        ]
        return Dictionary(
            uniqueKeysWithValues: descriptorSet.file.flatMap { file in
                file.service.compactMap { service -> (String, Int)? in
                    let serviceName = file.package.isEmpty
                        ? service.name
                        : "\(file.package).\(service.name)"
                    guard publicServices.contains(serviceName) else { return nil }
                    return (serviceName, service.method.count)
                }
            },
        )
    }

    private static func enumWireProbes(for contract: PublicAPIContract) throws -> [EnumWireProbe] {
        try requestFieldPaths(for: contract).compactMap { fieldPath in
            guard fieldPath.fields.last?.type == .enum else { return nil }
            return EnumWireProbe(
                descriptor: fieldPath.method.descriptor,
                bytes: Self.enumWireBytes(path: fieldPath.fields),
                label: fieldPath.label,
                outputOnlyField: fieldPath.outputOnlyField,
            )
        }.sorted { $0.label < $1.label }
    }

    private static func nonFiniteWireProbes(
        for contract: PublicAPIContract,
    ) throws -> [FloatingPointWireProbe] {
        let fieldPaths = try Self.requestFieldPaths(for: contract)
        return fieldPaths.flatMap { fieldPath -> [FloatingPointWireProbe] in
            guard let field = fieldPath.fields.last else { return [] }
            let specialValues: [(name: String, bits: UInt64)]
            switch field.type {
            case .double:
                specialValues = [
                    ("nan", 0x7FF8_0000_0000_0001),
                    ("+infinity", 0x7FF0_0000_0000_0000),
                    ("-infinity", 0xFFF0_0000_0000_0000),
                ]
            case .float:
                specialValues = [
                    ("nan", UInt64(0x7FC0_0001)),
                    ("+infinity", UInt64(0x7F80_0000)),
                    ("-infinity", UInt64(0xFF80_0000)),
                ]
            default:
                return []
            }
            return specialValues.map { special in
                FloatingPointWireProbe(
                    descriptor: fieldPath.method.descriptor,
                    bytes: Self.floatingPointWireBytes(
                        path: fieldPath.fields,
                        bits: special.bits,
                    ),
                    label: "\(fieldPath.label)=\(special.name)",
                    value: special.name,
                    outputOnlyField: fieldPath.outputOnlyField,
                )
            }
        }.sorted { $0.label < $1.label }
    }

    private static func negativeIntegerWireProbes(
        for contract: PublicAPIContract,
    ) throws -> [NegativeIntegerWireProbe] {
        try requestFieldPaths(for: contract).compactMap { fieldPath in
            guard let field = fieldPath.fields.last else { return nil }
            let wireType: UInt64
            let payload: [UInt8]
            switch field.type {
            case .int32, .int64:
                wireType = 0
                payload = Self.varint(UInt64.max)
            case .sint32, .sint64:
                wireType = 0
                payload = Self.varint(1)
            case .sfixed32:
                wireType = 5
                var bits = UInt32.max.littleEndian
                payload = withUnsafeBytes(of: &bits) { Array($0) }
            case .sfixed64:
                wireType = 1
                var bits = UInt64.max.littleEndian
                payload = withUnsafeBytes(of: &bits) { Array($0) }
            default:
                return nil
            }
            return NegativeIntegerWireProbe(
                descriptor: fieldPath.method.descriptor,
                bytes: Self.wireBytes(
                    path: fieldPath.fields,
                    leafWireType: wireType,
                    leafPayload: payload,
                    leafFieldNumber: field.number,
                ),
                label: "\(fieldPath.label)=-1",
                outputOnlyField: fieldPath.outputOnlyField,
            )
        }.sorted { $0.label < $1.label }
    }

    private static func defaultValuedOutputOnlyWireProbes(
        for contract: PublicAPIContract,
    ) throws -> [DefaultValuedOutputOnlyWireProbe] {
        let messages = Self.messageDescriptors(in: contract.descriptorSet)
        let enums = Self.enumDescriptors(in: contract.descriptorSet)
        return try requestFieldPaths(for: contract).compactMap { fieldPath in
            guard let field = fieldPath.fields.last,
                  field.options.Google_Api_fieldBehavior.contains(.outputOnly),
                  field.label != .repeated
            else {
                return nil
            }
            let wireType: UInt64
            let payload: [UInt8]
            switch field.type {
            case .double, .fixed64, .sfixed64:
                wireType = 1
                payload = Array(repeating: 0, count: 8)
            case .float, .fixed32, .sfixed32:
                wireType = 5
                payload = Array(repeating: 0, count: 4)
            case .int64, .uint64, .int32, .uint32, .sint32, .sint64, .bool, .enum:
                wireType = 0
                payload = [0]
            case .string, .bytes:
                wireType = 2
                payload = [0]
            case .message, .group:
                return nil
            }
            let validRequest = try Self.minimalBoundaryRequest(
                messageName: fieldPath.method.inputType,
                messages: messages,
                enums: enums,
                preferredPath: fieldPath.fields,
            )
            return DefaultValuedOutputOnlyWireProbe(
                descriptor: fieldPath.method.descriptor,
                bytes: validRequest + Self.wireBytes(
                    path: fieldPath.fields,
                    leafWireType: wireType,
                    leafPayload: payload,
                    leafFieldNumber: field.number,
                ),
                label: fieldPath.label,
                field: fieldPath.outputOnlyField ?? field.name,
            )
        }.sorted { $0.label < $1.label }
    }

    private static func unknownMapEntryWireProbes(
        for contract: PublicAPIContract,
    ) throws -> [UnknownMapEntryWireProbe] {
        let messages = Self.messageDescriptors(in: contract.descriptorSet)
        let enums = Self.enumDescriptors(in: contract.descriptorSet)
        let unknownField: [UInt8] = [0xF8, 0x7F, 0x01]
        return try requestFieldPaths(for: contract).compactMap { fieldPath in
            guard let field = fieldPath.fields.last,
                  field.type == .message,
                  fieldPath.outputOnlyField == nil,
                  let entry = messages[Self.normalizedTypeName(field.typeName)],
                  entry.options.mapEntry
            else {
                return nil
            }
            let entryPayload = Self.varint(UInt64(unknownField.count)) + unknownField
            let validRequest = try Self.minimalBoundaryRequest(
                messageName: fieldPath.method.inputType,
                messages: messages,
                enums: enums,
                preferredPath: fieldPath.fields,
            )
            return UnknownMapEntryWireProbe(
                descriptor: fieldPath.method.descriptor,
                bytes: validRequest + Self.wireBytes(
                    path: fieldPath.fields,
                    leafWireType: 2,
                    leafPayload: entryPayload,
                    leafFieldNumber: field.number,
                ),
                label: fieldPath.label,
            )
        }.sorted { $0.label < $1.label }
    }

    private static func requestFieldPaths(
        for contract: PublicAPIContract,
    ) throws -> [RequestFieldPath] {
        let messageDescriptors = Self.messageDescriptors(in: contract.descriptorSet)
        var fieldPaths: [RequestFieldPath] = []

        for method in contract.methods {
            var queue: [(
                messageName: String,
                path: [Google_Protobuf_FieldDescriptorProto],
                ancestorTypes: Set<String>,
            )] = [
                (method.inputType, [], [method.inputType]),
            ]

            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard let message = messageDescriptors[current.messageName] else {
                    throw PublicRequestValidationTestError.missingMessageDescriptor(
                        current.messageName,
                    )
                }

                for field in message.field {
                    let path = current.path + [field]
                    fieldPaths.append(RequestFieldPath(method: method, fields: path))
                    switch field.type {
                    case .message, .group:
                        let nestedType = Self.normalizedTypeName(field.typeName)
                        guard !current.ancestorTypes.contains(nestedType) else {
                            continue
                        }
                        var ancestorTypes = current.ancestorTypes
                        ancestorTypes.insert(nestedType)
                        queue.append((nestedType, path, ancestorTypes))
                    default:
                        continue
                    }
                }
            }
        }

        return fieldPaths
    }

    private static func messageDescriptors(
        in descriptorSet: Google_Protobuf_FileDescriptorSet,
    ) -> [String: Google_Protobuf_DescriptorProto] {
        var result: [String: Google_Protobuf_DescriptorProto] = [:]

        func register(
            _ messages: [Google_Protobuf_DescriptorProto],
            prefix: String,
        ) {
            for message in messages {
                let name = prefix.isEmpty ? message.name : "\(prefix).\(message.name)"
                result[name] = message
                register(message.nestedType, prefix: name)
            }
        }

        for file in descriptorSet.file {
            register(file.messageType, prefix: file.package)
        }
        return result
    }

    private static func enumDescriptors(
        in descriptorSet: Google_Protobuf_FileDescriptorSet,
    ) -> [String: Google_Protobuf_EnumDescriptorProto] {
        var result: [String: Google_Protobuf_EnumDescriptorProto] = [:]

        func register(
            _ messages: [Google_Protobuf_DescriptorProto],
            prefix: String,
        ) {
            for message in messages {
                let name = prefix.isEmpty ? message.name : "\(prefix).\(message.name)"
                for enumDescriptor in message.enumType {
                    result["\(name).\(enumDescriptor.name)"] = enumDescriptor
                }
                register(message.nestedType, prefix: name)
            }
        }

        for file in descriptorSet.file {
            for enumDescriptor in file.enumType {
                let name = file.package.isEmpty
                    ? enumDescriptor.name
                    : "\(file.package).\(enumDescriptor.name)"
                result[name] = enumDescriptor
            }
            register(file.messageType, prefix: file.package)
        }
        return result
    }

    private static func minimalBoundaryRequest(
        messageName: String,
        messages: [String: Google_Protobuf_DescriptorProto],
        enums: [String: Google_Protobuf_EnumDescriptorProto],
        preferredPath: [Google_Protobuf_FieldDescriptorProto] = [],
        ancestors: Set<String> = [],
    ) throws -> [UInt8] {
        guard !ancestors.contains(messageName) else {
            throw PublicRequestValidationTestError.recursiveRequiredMessage(messageName)
        }
        guard let message = messages[messageName] else {
            throw PublicRequestValidationTestError.missingMessageDescriptor(messageName)
        }
        var nextAncestors = ancestors
        nextAncestors.insert(messageName)
        let preferredField = preferredPath.first
        let outputOnly: (Google_Protobuf_FieldDescriptorProto) -> Bool = {
            $0.options.Google_Api_fieldBehavior.contains(.outputOnly)
        }

        var selectedByNumber: [Int32: Google_Protobuf_FieldDescriptorProto] = [:]
        for field in message.field
            where field.options.Google_Api_fieldBehavior.contains(.required) && !outputOnly(field)
        {
            selectedByNumber[field.number] = field
        }

        let realOneofIndexes = Set(
            message.field.compactMap { field -> Int32? in
                guard field.hasOneofIndex, !field.proto3Optional else { return nil }
                return field.oneofIndex
            },
        )
        for oneofIndex in realOneofIndexes.sorted() {
            let candidates = message.field.filter {
                $0.hasOneofIndex && !$0.proto3Optional && $0.oneofIndex == oneofIndex &&
                    !outputOnly($0)
            }
            guard let candidate = candidates.first(where: {
                $0.number == preferredField?.number
            }) ?? candidates.first else {
                let oneofName = Int(oneofIndex) < message.oneofDecl.count
                    ? message.oneofDecl[Int(oneofIndex)].name
                    : String(oneofIndex)
                throw PublicRequestValidationTestError.missingOneofCandidate(
                    messageName,
                    oneofName,
                )
            }
            selectedByNumber[candidate.number] = candidate
        }

        return try selectedByNumber.values.sorted { $0.number < $1.number }.flatMap { field in
            let nestedPreferredPath = field.number == preferredField?.number
                ? Array(preferredPath.dropFirst())
                : []
            return try Self.minimalBoundaryField(
                field,
                messages: messages,
                enums: enums,
                preferredPath: nestedPreferredPath,
                ancestors: nextAncestors,
            )
        }
    }

    private static func minimalBoundaryField(
        _ field: Google_Protobuf_FieldDescriptorProto,
        messages: [String: Google_Protobuf_DescriptorProto],
        enums: [String: Google_Protobuf_EnumDescriptorProto],
        preferredPath: [Google_Protobuf_FieldDescriptorProto],
        ancestors: Set<String>,
    ) throws -> [UInt8] {
        let wireType: UInt64
        let payload: [UInt8]
        switch field.type {
        case .double:
            wireType = 1
            var bits = Double(1).bitPattern.littleEndian
            payload = withUnsafeBytes(of: &bits) { Array($0) }
        case .float:
            wireType = 5
            var bits = Float(1).bitPattern.littleEndian
            payload = withUnsafeBytes(of: &bits) { Array($0) }
        case .int64, .uint64, .int32, .uint32, .bool:
            wireType = 0
            payload = Self.varint(1)
        case .sint32, .sint64:
            wireType = 0
            payload = Self.varint(2)
        case .fixed64, .sfixed64:
            wireType = 1
            var value = UInt64(1).littleEndian
            payload = withUnsafeBytes(of: &value) { Array($0) }
        case .fixed32, .sfixed32:
            wireType = 5
            var value = UInt32(1).littleEndian
            payload = withUnsafeBytes(of: &value) { Array($0) }
        case .string:
            wireType = 2
            let value = Array("x".utf8)
            payload = Self.varint(UInt64(value.count)) + value
        case .bytes:
            wireType = 2
            payload = Self.varint(1) + [1]
        case .enum:
            wireType = 0
            let enumName = Self.normalizedTypeName(field.typeName)
            guard let enumDescriptor = enums[enumName],
                  let value = enumDescriptor.value.first(where: { $0.number != 0 })
            else {
                throw PublicRequestValidationTestError.missingNonzeroEnumValue(enumName)
            }
            payload = Self.varint(UInt64(value.number))
        case .message:
            wireType = 2
            let nestedName = Self.normalizedTypeName(field.typeName)
            let value = try Self.minimalBoundaryRequest(
                messageName: nestedName,
                messages: messages,
                enums: enums,
                preferredPath: preferredPath,
                ancestors: ancestors,
            )
            payload = Self.varint(UInt64(value.count)) + value
        case .group:
            throw PublicRequestValidationTestError.unsupportedBoundaryFieldType(
                field.name,
                field.type,
            )
        }

        return Self.varint((UInt64(field.number) << 3) | wireType) + payload
    }

    private static func enumWireBytes(
        path: [Google_Protobuf_FieldDescriptorProto],
    ) -> [UInt8] {
        guard let enumField = path.last else { return [] }
        return Self.wireBytes(
            path: path,
            leafWireType: 0,
            leafPayload: Self.varint(UInt64(Int32.max)),
            leafFieldNumber: enumField.number,
        )
    }

    private static func floatingPointWireBytes(
        path: [Google_Protobuf_FieldDescriptorProto],
        bits: UInt64,
    ) -> [UInt8] {
        guard let field = path.last else { return [] }
        let wireType: UInt64
        let payload: [UInt8]
        switch field.type {
        case .double:
            wireType = 1
            payload = withUnsafeBytes(of: bits.littleEndian) { Array($0) }
        case .float:
            wireType = 5
            var floatBits = UInt32(truncatingIfNeeded: bits).littleEndian
            payload = withUnsafeBytes(of: &floatBits) { Array($0) }
        default:
            return []
        }
        return Self.wireBytes(
            path: path,
            leafWireType: wireType,
            leafPayload: payload,
            leafFieldNumber: field.number,
        )
    }

    private static func wireBytes(
        path: [Google_Protobuf_FieldDescriptorProto],
        leafWireType: UInt64,
        leafPayload: [UInt8],
        leafFieldNumber: Int32,
    ) -> [UInt8] {
        var payload = Self.varint((UInt64(leafFieldNumber) << 3) | leafWireType)
        payload.append(contentsOf: leafPayload)
        for field in path.dropLast().reversed() {
            var wrapped = Self.varint((UInt64(field.number) << 3) | 2)
            wrapped.append(contentsOf: Self.varint(UInt64(payload.count)))
            wrapped.append(contentsOf: payload)
            payload = wrapped
        }
        return payload
    }

    private static func deeplyNestedSelectorRequest(depth: Int) -> [UInt8] {
        var selector = Self.lengthDelimitedField(number: 1, payload: Array("AXButton".utf8))
        for _ in 0 ..< depth {
            let selectors = Self.lengthDelimitedField(number: 2, payload: selector)
            let compound = [UInt8(0x08), UInt8(0x01)] + selectors
            selector = Self.lengthDelimitedField(number: 7, payload: compound)
        }
        return Self.lengthDelimitedField(number: 2, payload: selector)
    }

    private static func lengthDelimitedField(number: Int, payload: [UInt8]) -> [UInt8] {
        varint((UInt64(number) << 3) | 2) +
            varint(UInt64(payload.count)) +
            payload
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    private static func normalizedTypeName(_ name: String) -> String {
        name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    private static func rpcType(
        clientStreaming: Bool,
        serverStreaming: Bool,
    ) -> MethodDescriptor.RPCType {
        switch (clientStreaming, serverStreaming) {
        case (false, false): .unary
        case (false, true): .serverStreaming
        case (true, false): .clientStreaming
        case (true, true): .bidirectionalStreaming
        }
    }
}

private struct PublicAPIContract {
    let descriptorSet: Google_Protobuf_FileDescriptorSet
    let methods: [PublicMethodContract]
}

private struct PublicMethodContract {
    let descriptor: MethodDescriptor
    let inputType: String
}

private struct EnumWireProbe {
    let descriptor: MethodDescriptor
    let bytes: [UInt8]
    let label: String
    let outputOnlyField: String?
}

private struct FloatingPointWireProbe {
    let descriptor: MethodDescriptor
    let bytes: [UInt8]
    let label: String
    let value: String
    let outputOnlyField: String?
}

private struct NegativeIntegerWireProbe {
    let descriptor: MethodDescriptor
    let bytes: [UInt8]
    let label: String
    let outputOnlyField: String?
}

private struct DefaultValuedOutputOnlyWireProbe {
    let descriptor: MethodDescriptor
    let bytes: [UInt8]
    let label: String
    let field: String
}

private struct UnknownMapEntryWireProbe {
    let descriptor: MethodDescriptor
    let bytes: [UInt8]
    let label: String
}

private struct RequestFieldPath {
    let method: PublicMethodContract
    let fields: [Google_Protobuf_FieldDescriptorProto]

    var label: String {
        "\(method.descriptor.fullyQualifiedMethod):\(fields.map(\.name).joined(separator: "."))"
    }

    var outputOnlyField: String? {
        guard let index = fields.firstIndex(where: {
            $0.options.Google_Api_fieldBehavior.contains(.outputOnly)
        }) else {
            return nil
        }
        return fields[...index].map(\.name).joined(separator: ".")
    }
}

private enum NumericRequestPolicy: CaseIterable {
    case boundedPageSize
    case boundedSkip
    case canonicalProtobufDuration
    case validatedInputAction
    case boundedImageQuality
    case validatedSelectorGeometry
    case validatedRegionGeometry
    case validatedWindowGeometry
    case boundedTiming
    case macroExecutionControlled
    case validatedScreenshotPadding
    case rejectedOutputOnly
}

private func validAssignmentAction() -> Exactmac_V1_MacroAction {
    Exactmac_V1_MacroAction.with {
        $0.assignment.variable = "value"
        $0.assignment.literal = "valid"
    }
}

private func expectRequestValidationError(
    client: GRPCClient<InProcessTransport.Client>,
    request: some SwiftProtobuf.Message & Sendable,
    descriptor: MethodDescriptor,
    responseType: (some SwiftProtobuf.Message & Sendable).Type,
    reason: String,
    field: String,
    label: String,
) async {
    do {
        let error = try await protobufRPCError(
            client: client,
            request: request,
            descriptor: descriptor,
            responseType: responseType,
        )
        #expect(error.code == .invalidArgument, Comment(rawValue: "\(label): \(error)"))
        let errorInfo = try extractErrorInfo(from: error)
        #expect(errorInfo.reason == reason, Comment(rawValue: label))
        #expect(errorInfo.metadata["field"] == field, Comment(rawValue: label))
    } catch {
        Issue.record("\(label) did not return the required validation error: \(error)")
    }
}

private func assertDescriptorAwareWireRejection(
    error: RPCError,
    outputOnlyField: String?,
    expectedMessage: String,
    expectedReason: String,
    expectedValue: String,
    label: String,
) throws {
    #expect(error.code == .invalidArgument, Comment(rawValue: label))
    let errorInfo = try extractErrorInfo(from: error)
    #expect(errorInfo.domain == RPCErrorHelpers.domain, Comment(rawValue: label))
    if let outputOnlyField {
        #expect(error.message == "request sets an output-only field", Comment(rawValue: label))
        #expect(errorInfo.reason == "OUTPUT_ONLY_FIELD", Comment(rawValue: label))
        #expect(errorInfo.metadata["field"] == outputOnlyField, Comment(rawValue: label))
    } else {
        #expect(error.message == expectedMessage, Comment(rawValue: label))
        #expect(errorInfo.reason == expectedReason, Comment(rawValue: label))
        #expect(errorInfo.metadata["field"] == "request", Comment(rawValue: label))
        #expect(errorInfo.metadata["value"] == expectedValue, Comment(rawValue: label))
    }
}

private func assertRangeError(
    error: RPCError,
    field: String,
) throws {
    #expect(error.code == .invalidArgument)
    let errorInfo = try extractErrorInfo(from: error)
    #expect(errorInfo.reason == "OUT_OF_RANGE")
    #expect(errorInfo.domain == RPCErrorHelpers.domain)
    #expect(errorInfo.metadata["field"] == field)
}

private func assertInvalidTimeoutError(_ error: RPCError) throws {
    #expect(error.code == .invalidArgument)
    let errorInfo = try extractErrorInfo(from: error)
    #expect(errorInfo.reason == "INVALID_TIMEOUT")
    #expect(errorInfo.domain == RPCErrorHelpers.domain)
    #expect(errorInfo.metadata["field"] == "timeout")
}

private func protobufRPCError<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
    responseType _: Response.Type,
) async throws -> RPCError {
    var options = CallOptions.defaults
    options.timeout = .seconds(1)
    do {
        let _: Response = try await client.unary(
            request: ClientRequest(message: request),
            descriptor: descriptor,
            serializer: ProtobufSerializer<Request>(),
            deserializer: ProtobufDeserializer<Response>(),
            options: options,
        ) { response in
            try response.message
        }
        throw PublicRequestValidationTestError.unknownFieldsAccepted(
            descriptor.fullyQualifiedMethod,
        )
    } catch let error as RPCError {
        return error
    }
}

private func rawInvalidRequestCall(
    client: GRPCClient<InProcessTransport.Client>,
    descriptor: MethodDescriptor,
    bytes: [UInt8],
) async throws -> RPCError {
    var options = CallOptions.defaults
    options.timeout = .seconds(1)
    do {
        let _: [UInt8] = try await client.unary(
            request: ClientRequest(message: bytes),
            descriptor: descriptor,
            serializer: RequestValidationRawSerializer(),
            deserializer: RequestValidationRawDeserializer(),
            options: options,
        ) { response in
            try response.message
        }
        throw PublicRequestValidationTestError.invalidRequestAccepted(
            descriptor.fullyQualifiedMethod,
        )
    } catch let error as RPCError {
        return error
    }
}

private func extractErrorInfo(from error: RPCError) throws -> Google_Rpc_ErrorInfo {
    var statusBytes: [UInt8]?
    for bytes in error.metadata[binaryValues: "grpc-status-details-bin"] {
        statusBytes = bytes
        break
    }
    guard let statusBytes else {
        throw PublicRequestValidationTestError.missingErrorDetails
    }
    let status = try Google_Rpc_Status(serializedBytes: statusBytes)
    guard let detail = status.details.first,
          detail.isA(Google_Rpc_ErrorInfo.self)
    else {
        throw PublicRequestValidationTestError.missingErrorDetails
    }
    return try Google_Rpc_ErrorInfo(serializedBytes: detail.value)
}

private struct RequestValidationRawSerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes {
        Bytes(message)
    }
}

private struct RequestValidationRawDeserializer: MessageDeserializer {
    func deserialize(
        _ serializedMessageBytes: some GRPCContiguousBytes,
    ) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

private actor RequestValidationPasteboard: ClipboardPasteboard {
    private(set) var mutationCount = 0

    func read() -> Exactmac_V1_Clipboard {
        Exactmac_V1_Clipboard.with { $0.name = "clipboard" }
    }

    func changeCount() -> Int {
        mutationCount
    }

    func clear() {
        mutationCount += 1
    }

    func write(_: Exactmac_V1_ClipboardContent) -> Bool {
        mutationCount += 1
        return true
    }
}

private enum PublicRequestValidationTestError: Error {
    case invalidRequestAccepted(String)
    case missingNonzeroEnumValue(String)
    case missingOneofCandidate(String, String)
    case missingMessageDescriptor(String)
    case missingErrorDetails
    case recursiveRequiredMessage(String)
    case unknownFieldsAccepted(String)
    case unsupportedBoundaryFieldType(String, Google_Protobuf_FieldDescriptorProto.TypeEnum)
}

private actor BoundaryAdmissionRecorder {
    private var methods: Set<String> = []

    func record(_ method: String) {
        methods.insert(method)
    }

    func snapshot() -> Set<String> {
        methods
    }
}

private struct BoundaryAdmissionInterceptor: ServerInterceptor {
    static let sentinelMessage = "descriptor-valid request crossed production validation"

    let recorder: BoundaryAdmissionRecorder

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next _: @Sendable (
            _ request: StreamingServerRequest<Input>,
            _ context: ServerContext,
        ) async throws -> StreamingServerResponse<Output>,
    ) async throws -> StreamingServerResponse<Output> {
        var messageCount = 0
        for try await _ in request.messages {
            messageCount += 1
        }
        guard messageCount == 1 else {
            throw RPCError(
                code: .internalError,
                message: "public boundary probe received \(messageCount) request messages",
            )
        }
        await recorder.record(context.descriptor.fullyQualifiedMethod)
        throw RPCError(code: .aborted, message: Self.sentinelMessage)
    }
}
