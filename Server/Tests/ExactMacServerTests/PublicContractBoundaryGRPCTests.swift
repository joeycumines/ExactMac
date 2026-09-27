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
struct PublicContractBoundaryGRPCTests {
    @Test
    func `every public collection rejects the legacy query-unbound token family`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let legacyToken = Data(#"{"offset":0}"#.utf8).base64EncodedString()

        try await withPublicContractClient(composition) { client in
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListApplicationBundlesRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
                responseType: Exactmac_V1_ListApplicationBundlesResponse.self,
                code: .invalidArgument,
                label: "ListApplicationBundles legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListApplicationsRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
                responseType: Exactmac_V1_ListApplicationsResponse.self,
                code: .invalidArgument,
                label: "ListApplications legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListInputsRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
                responseType: Exactmac_V1_ListInputsResponse.self,
                code: .invalidArgument,
                label: "ListInputs legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_FindElementsRequest.with {
                    $0.parent = "applications/111"
                    $0.selector.role = "AXButton"
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
                responseType: Exactmac_V1_FindElementsResponse.self,
                code: .invalidArgument,
                label: "FindElements legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_FindRegionElementsRequest.with {
                    $0.parent = "applications/111"
                    $0.region.width = 10
                    $0.region.height = 10
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.FindRegionElements.descriptor,
                responseType: Exactmac_V1_FindRegionElementsResponse.self,
                code: .invalidArgument,
                label: "FindRegionElements legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListElementsRequest.with {
                    $0.parent = "applications/111"
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                responseType: Exactmac_V1_ListElementsResponse.self,
                code: .invalidArgument,
                label: "ListElements legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = "applications/111"
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                responseType: Exactmac_V1_ListWindowsResponse.self,
                code: .invalidArgument,
                label: "ListWindows legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListObservationsRequest.with {
                    $0.parent = "applications/111"
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListObservations.descriptor,
                responseType: Exactmac_V1_ListObservationsResponse.self,
                code: .invalidArgument,
                label: "ListObservations legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListSessionsRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListSessions.descriptor,
                responseType: Exactmac_V1_ListSessionsResponse.self,
                code: .invalidArgument,
                label: "ListSessions legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListMacrosRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListMacros.descriptor,
                responseType: Exactmac_V1_ListMacrosResponse.self,
                code: .invalidArgument,
                label: "ListMacros legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListDisplaysRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                responseType: Exactmac_V1_ListDisplaysResponse.self,
                code: .invalidArgument,
                label: "ListDisplays legacy token",
            )
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_ListOperationsRequest.with {
                    $0.pageToken = legacyToken
                },
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
                responseType: Google_Longrunning_ListOperationsResponse.self,
                code: .invalidArgument,
                label: "ListOperations legacy token",
            )
        }
    }

    @Test
    func `collections honor changed page size on continuation`() async throws {
        let composition = ExactMacServiceComposition(
            system: MockSystemOperations(cgWindowList: []),
            legacyPIDResourceNamesForTests: true,
            elementDiscoveryExecutor: { _, _, _ in
                AccessibilityTraversalSnapshot(appName: "Pagination fixture")
            },
        )
        let selector = Exactmac_Type_ElementSelector.with { $0.role = "AXButton" }
        let region = Exactmac_Type_Region.with {
            $0.width = 1
            $0.height = 1
        }

        try await withPublicContractClient(composition) { client in
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListApplicationBundles.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListApplicationBundles",
                    parameters: [
                        ("order_by", ""), ("filter", ""), ("view", "0"),

                    ],
                ),
                responseType: Exactmac_V1_ListApplicationBundlesResponse.self,
                label: "ListApplicationBundles",
            ) { pageSize, token in
                Exactmac_V1_ListApplicationBundlesRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListApplications.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListApplications",
                    parameters: [
                        ("order_by", ""), ("filter", ""), ("view", "0"),

                    ],
                ),
                responseType: Exactmac_V1_ListApplicationsResponse.self,
                label: "ListApplications",
            ) { pageSize, token in
                Exactmac_V1_ListApplicationsRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListInputs",
                    parameters: [
                        ("parent", "applications/-"), ("filter_state", ""),

                    ],
                ),
                responseType: Exactmac_V1_ListInputsResponse.self,
                label: "ListInputs",
            ) { pageSize, token in
                Exactmac_V1_ListInputsRequest.with {
                    $0.parent = "applications/-"
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.FindElements.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "FindElements",
                    parameters: [
                        ("parent", "applications/1"),
                        ("selector", ParsingHelpers.selectorQueryIdentity(selector)),
                        ("visible_only", "false"),
                        ("cache_bypass", "false"),

                    ],
                ),
                responseType: Exactmac_V1_FindElementsResponse.self,
                label: "FindElements",
            ) { pageSize, token in
                Exactmac_V1_FindElementsRequest.with {
                    $0.parent = "applications/1"
                    $0.selector = selector
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.FindRegionElements.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "FindRegionElements",
                    parameters: [
                        ("parent", "applications/1"),
                        ("region", region.serializedData().base64EncodedString()),
                        ("selector", ""),
                        ("cache_bypass", "false"),

                    ],
                ),
                responseType: Exactmac_V1_FindRegionElementsResponse.self,
                label: "FindRegionElements",
            ) { pageSize, token in
                Exactmac_V1_FindRegionElementsRequest.with {
                    $0.parent = "applications/1"
                    $0.region = region
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListElements.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListElements",
                    parameters: [("parent", "applications/1")],
                ),
                responseType: Exactmac_V1_ListElementsResponse.self,
                label: "ListElements",
            ) { pageSize, token in
                Exactmac_V1_ListElementsRequest.with {
                    $0.parent = "applications/1"
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListObservations.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListObservations",
                    parameters: [("parent", "applications/1")],
                ),
                responseType: Exactmac_V1_ListObservationsResponse.self,
                label: "ListObservations",
            ) { pageSize, token in
                Exactmac_V1_ListObservationsRequest.with {
                    $0.parent = "applications/1"
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListSessions.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListSessions",
                    parameters: [],
                ),
                responseType: Exactmac_V1_ListSessionsResponse.self,
                label: "ListSessions",
            ) { pageSize, token in
                Exactmac_V1_ListSessionsRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListMacros.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListMacros",
                    parameters: [],
                ),
                responseType: Exactmac_V1_ListMacrosResponse.self,
                label: "ListMacros",
            ) { pageSize, token in
                Exactmac_V1_ListMacrosRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Exactmac_V1_ExactMac.Method.ListDisplays.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListDisplays",
                    parameters: [],
                ),
                responseType: Exactmac_V1_ListDisplaysResponse.self,
                label: "ListDisplays",
            ) { pageSize, token in
                Exactmac_V1_ListDisplaysRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
            try await assertPublicPageSizeContinuation(
                client: client,
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
                queryBinding: ParsingHelpers.pageTokenQuery(
                    method: "ListOperations",
                    parameters: [
                        ("name", ""),
                        ("done", ""),
                        ("return_partial_success", "false"),

                    ],
                ),
                responseType: Google_Longrunning_ListOperationsResponse.self,
                label: "ListOperations",
            ) { pageSize, token in
                Google_Longrunning_ListOperationsRequest.with {
                    $0.pageSize = pageSize
                    $0.pageToken = token
                }
            }
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `known query mask resource and force intent fails closed before lookup or mutation`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )

        try await withPublicContractClient(composition) { client in
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListInputsRequest.with {
                    $0.filter = "state = UNKNOWN"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
                responseType: Exactmac_V1_ListInputsResponse.self,
                code: .invalidArgument,
                label: "unsupported ListInputs filter",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = "applications/111"
                    $0.filter = "visible=true AND mystery=true"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                responseType: Exactmac_V1_ListWindowsResponse.self,
                code: .invalidArgument,
                label: "partially recognized window filter",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = "applications/111"
                    $0.orderBy = "mystery desc"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                responseType: Exactmac_V1_ListWindowsResponse.self,
                code: .invalidArgument,
                label: "unknown window ordering",
            )
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_ListOperationsRequest.with {
                    $0.filter = "done=maybe"
                },
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
                responseType: Google_Longrunning_ListOperationsResponse.self,
                code: .invalidArgument,
                label: "unknown Operations filter",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_GetWindowRequest.with {
                    $0.name = "applications/111/windows/1"
                    $0.readMask.paths = ["unknown_field"]
                },
                descriptor: Exactmac_V1_ExactMac.Method.GetWindow.descriptor,
                responseType: Exactmac_V1_Window.self,
                code: .invalidArgument,
                label: "unknown read mask before window lookup",
            )

            let malformedResources: [PublicUnaryErrorProbe] = [
                .init(
                    label: "malformed session name",
                    call: {
                        await expectPublicRPCError(
                            client: client,
                            request: Exactmac_V1_GetSessionRequest.with { $0.name = "sessions//alias" },
                            descriptor: Exactmac_V1_ExactMac.Method.GetSession.descriptor,
                            responseType: Exactmac_V1_Session.self,
                            code: .invalidArgument,
                            label: "malformed session name",
                        )
                    },
                ),
                .init(
                    label: "malformed macro name",
                    call: {
                        await expectPublicRPCError(
                            client: client,
                            request: Exactmac_V1_GetMacroRequest.with { $0.name = "macros//alias" },
                            descriptor: Exactmac_V1_ExactMac.Method.GetMacro.descriptor,
                            responseType: Exactmac_V1_Macro.self,
                            code: .invalidArgument,
                            label: "malformed macro name",
                        )
                    },
                ),
                .init(
                    label: "malformed operation name",
                    call: {
                        await expectPublicRPCError(
                            client: client,
                            request: Google_Longrunning_GetOperationRequest.with { $0.name = "operations//alias" },
                            descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
                            responseType: Google_Longrunning_Operation.self,
                            code: .invalidArgument,
                            label: "malformed operation name",
                        )
                    },
                ),
            ]
            for probe in malformedResources {
                _ = probe.label
                await probe.call()
            }

            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_DeleteSessionRequest.with {
                    $0.name = "sessions/missing"
                    $0.force = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.DeleteSession.descriptor,
                responseType: Google_Protobuf_Empty.self,
                code: .unimplemented,
                label: "DeleteSession.force",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_DeleteMacroRequest.with {
                    $0.name = "macros/missing"
                    $0.force = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.DeleteMacro.descriptor,
                responseType: Google_Protobuf_Empty.self,
                code: .unimplemented,
                label: "DeleteMacro.force",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_CloseWindowRequest.with {
                    $0.name = "applications/111/windows/1"
                    $0.force = true
                },
                descriptor: Exactmac_V1_ExactMac.Method.CloseWindow.descriptor,
                responseType: Exactmac_V1_CloseWindowResponse.self,
                code: .unimplemented,
                label: "CloseWindow.force",
            )
            await expectPublicRPCError(
                client: client,
                request: Exactmac_V1_BeginTransactionRequest.with {
                    $0.session = "sessions/missing"
                    $0.timeout = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.BeginTransaction.descriptor,
                responseType: Exactmac_V1_BeginTransactionResponse.self,
                code: .unimplemented,
                label: "BeginTransaction.timeout",
            )
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_ListOperationsRequest.with {
                    $0.returnPartialSuccess = true
                },
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
                responseType: Google_Longrunning_ListOperationsResponse.self,
                code: .unimplemented,
                label: "ListOperations.return_partial_success",
            )
        }

        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        #expect(await composition.automationCoordinator.activeMutationCount() == 0)
        #expect(system.setAXAttributeCalls.isEmpty)
        #expect(system.performAXActionCalls.isEmpty)
    }

    @Test
    func `output only request fields reject before resource insertion or producer admission`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let suffix = UUID().uuidString
        let sessionName = "sessions/output-only-\(suffix)"
        let macroName = "macros/output-only-\(suffix)"
        let observationName = "applications/111/observations/output-only-\(suffix)"

        try await withPublicContractClient(composition) { client in
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateSessionRequest.with {
                    $0.sessionID = "output-only-\(suffix)"
                    $0.session.displayName = "must reject"
                    $0.session.state = .active
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateSession.descriptor,
                responseType: Exactmac_V1_Session.self,
                code: .invalidArgument,
                reason: "OUTPUT_ONLY_FIELD",
                field: "session.state",
                label: "CreateSession output-only state",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateMacroRequest.with {
                    $0.macroID = "output-only-\(suffix)"
                    $0.macro.displayName = "must reject"
                    $0.macro.actions = [assignmentAction()]
                    $0.macro.createTime.seconds = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                responseType: Exactmac_V1_Macro.self,
                code: .invalidArgument,
                reason: "OUTPUT_ONLY_FIELD",
                field: "macro.create_time",
                label: "CreateMacro output-only timestamp",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = "output-only-\(suffix)"
                    $0.input.state = .completed
                    $0.input.target.desktop = true
                    $0.input.action.mouseMove.position.x = 1
                    $0.input.action.mouseMove.position.y = 1
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
                responseType: Exactmac_V1_Input.self,
                code: .invalidArgument,
                reason: "OUTPUT_ONLY_FIELD",
                field: "input.state",
                label: "CreateInput output-only state",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateObservationRequest.with {
                    $0.parent = "applications/111"
                    $0.observationID = "output-only-\(suffix)"
                    $0.observation.type = .windowChanges
                    $0.observation.state = .completed
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateObservation.descriptor,
                responseType: Google_Longrunning_Operation.self,
                code: .invalidArgument,
                reason: "OUTPUT_ONLY_FIELD",
                field: "observation.state",
                label: "CreateObservation output-only state",
            )
        }

        #expect(await composition.sessionManager.getSession(name: sessionName) == nil)
        #expect(await composition.macroRegistry.getMacro(name: macroName) == nil)
        #expect(await composition.exactMacService.stateStore.getInput(name: "applications/-/inputs/output-only-\(suffix)") == nil)
        #expect(await composition.observationManager.getObservation(name: observationName) == nil)
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        _ = await composition.sessionManager.deleteSession(name: sessionName)
        _ = await composition.macroRegistry.deleteMacro(name: macroName)
        _ = await composition.observationManager.cancelObservation(name: observationName)
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `create identifiers and supplied resource names reject before insertion or producers`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )
        let suffix = UUID().uuidString
        let invalidID = "bad/\(suffix)"
        let sessionID = "session-name-\(suffix)"
        let macroID = "macro-name-\(suffix)"
        let observationID = "observation-name-\(suffix)"

        try await withPublicContractClient(composition) { client in
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateSessionRequest.with {
                    $0.sessionID = invalidID
                    $0.session.displayName = "invalid ID"
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateSession.descriptor,
                responseType: Exactmac_V1_Session.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "session_id",
                label: "CreateSession invalid session_id",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateSessionRequest.with {
                    $0.sessionID = sessionID
                    $0.session.name = "sessions/client-selected"
                    $0.session.displayName = "supplied name"
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateSession.descriptor,
                responseType: Exactmac_V1_Session.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "session.name",
                label: "CreateSession supplied session.name",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateMacroRequest.with {
                    $0.macroID = invalidID
                    $0.macro.displayName = "invalid ID"
                    $0.macro.actions = [assignmentAction()]
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                responseType: Exactmac_V1_Macro.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "macro_id",
                label: "CreateMacro invalid macro_id",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateMacroRequest.with {
                    $0.macroID = macroID
                    $0.macro.name = "macros/client-selected"
                    $0.macro.displayName = "supplied name"
                    $0.macro.actions = [assignmentAction()]
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateMacro.descriptor,
                responseType: Exactmac_V1_Macro.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "macro.name",
                label: "CreateMacro supplied macro.name",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateObservationRequest.with {
                    $0.parent = "applications/111"
                    $0.observationID = invalidID
                    $0.observation.type = .windowChanges
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateObservation.descriptor,
                responseType: Google_Longrunning_Operation.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "observation_id",
                label: "CreateObservation invalid observation_id",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_CreateObservationRequest.with {
                    $0.parent = "applications/111"
                    $0.observationID = observationID
                    $0.observation.name = "applications/111/observations/client-selected"
                    $0.observation.type = .windowChanges
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateObservation.descriptor,
                responseType: Google_Longrunning_Operation.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "observation.name",
                label: "CreateObservation supplied observation.name",
            )
        }

        let sessions = try await composition.sessionManager.listSessions(
            pageSize: 1000,
            pageToken: nil,
        ).sessions
        #expect(sessions.isEmpty)
        #expect(await composition.macroRegistry.getMacro(name: "macros/\(invalidID)") == nil)
        #expect(await composition.macroRegistry.getMacro(name: "macros/\(macroID)") == nil)
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.observationManager.getActiveObservationCount() == 0)
        #expect(await composition.observationManager.monitorTaskCount() == 0)
        _ = await composition.sessionManager.deleteSession(name: "sessions/\(invalidID)")
        _ = await composition.sessionManager.deleteSession(name: "sessions/\(sessionID)")
        _ = await composition.macroRegistry.deleteMacro(name: "macros/\(invalidID)")
        _ = await composition.macroRegistry.deleteMacro(name: "macros/\(macroID)")
        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `window query and Operations filter grammar fail closed with stable total ordering`() async throws {
        let pid: pid_t = 321
        let system = MockSystemOperations(cgWindowList: [
            publicWindowDictionary(windowID: 3, pid: pid, title: "Same", layer: 7),
            publicWindowDictionary(windowID: 1, pid: pid, title: "Same", layer: 7),
            publicWindowDictionary(windowID: 2, pid: pid, title: "Same", layer: 7),
        ])
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
        )

        try await withPublicContractClient(composition) { client in
            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = "applications/\(pid)"
                    $0.filter = "minimized=true"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                responseType: Exactmac_V1_ListWindowsResponse.self,
                code: .invalidArgument,
                reason: "INVALID_FILTER",
                field: "filter",
                label: "unsupported minimized filter",
            )
            await expectStructuredPublicRPCError(
                client: client,
                request: Google_Longrunning_ListOperationsRequest.with {
                    $0.filter = "d o n e = t r u e"
                },
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
                responseType: Google_Longrunning_ListOperationsResponse.self,
                code: .invalidArgument,
                reason: "INVALID_FILTER",
                field: "filter",
                label: "Operations intra-token whitespace",
            )

            let baseline: Exactmac_V1_ListWindowsResponse = try await publicUnary(
                client: client,
                request: Exactmac_V1_ListWindowsRequest.with {
                    $0.parent = "applications/\(pid)"
                    $0.pageSize = 100
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
            )
            let ascendingNames = baseline.windows.map(\.name)
            let layerDescendingNames = baseline.windows.sorted {
                if $0.layer == $1.layer {
                    return $0.name < $1.name
                }
                return $0.layer > $1.layer
            }.map(\.name)
            #expect(ascendingNames.count == 3)
            #expect(Set(ascendingNames).count == ascendingNames.count)

            for (ordering, expectedNames) in [
                ("title", ascendingNames),
                ("layer desc", layerDescendingNames),
            ] {
                var pageToken = ""
                var actualNames: [String] = []
                repeat {
                    let response: Exactmac_V1_ListWindowsResponse = try await publicUnary(
                        client: client,
                        request: Exactmac_V1_ListWindowsRequest.with {
                            $0.parent = "applications/\(pid)"
                            $0.pageSize = 1
                            $0.pageToken = pageToken
                            $0.orderBy = ordering
                        },
                        descriptor: Exactmac_V1_ExactMac.Method.ListWindows.descriptor,
                    )
                    #expect(response.windows.count == 1)
                    if let name = response.windows.first?.name {
                        actualNames.append(name)
                    }
                    pageToken = response.nextPageToken
                } while !pageToken.isEmpty
                #expect(actualNames == Array(expectedNames), Comment(rawValue: ordering))
                #expect(Set(actualNames).count == actualNames.count, Comment(rawValue: ordering))
            }
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `desktop Input resources round trip through create get and list with exact grammar`() async throws {
        let system = MockSystemOperations(cgWindowList: [])
        let coordinator = AutomationCoordinator(
            activationSystem: system,
            inputPostAccessChecker: { true },
            inputActionExecutor: { action, route, _ in
                committedInputExecutionReceipt(for: action, route: route)
            },
        )
        let composition = ExactMacServiceComposition(
            system: system,
            legacyPIDResourceNamesForTests: true,
            automationCoordinator: coordinator,
        )
        let inputID = "desktop-\(UUID().uuidString)"
        let inputName = "applications/-/inputs/\(inputID)"
        let malformedName = "\(inputName)/extra"
        await composition.exactMacService.stateStore.seedInputForTesting(
            Exactmac_V1_Input.with {
                $0.name = malformedName
                $0.action.mouseMove.position = Exactmac_Type_Point.with {
                    $0.x = 10
                    $0.y = 20
                }
                $0.state = .completed
            },
        )

        try await withPublicContractClient(composition) { client in
            let created: Exactmac_V1_Input = try await publicUnary(
                client: client,
                request: Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/-"
                    $0.inputID = inputID
                    $0.input.target.desktop = true
                    $0.input.action.mouseMove.position = Exactmac_Type_Point.with {
                        $0.x = 10
                        $0.y = 20
                    }
                },
                descriptor: Exactmac_V1_ExactMac.Method.CreateInput.descriptor,
            )
            #expect(created.name == inputName)
            #expect(created.state == .completed)

            let fetched: Exactmac_V1_Input = try await publicUnary(
                client: client,
                request: Exactmac_V1_GetInputRequest.with { $0.name = inputName },
                descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
            )
            #expect(fetched == created)

            let listed: Exactmac_V1_ListInputsResponse = try await publicUnary(
                client: client,
                request: Exactmac_V1_ListInputsRequest.with {
                    $0.parent = "applications/-"
                },
                descriptor: Exactmac_V1_ExactMac.Method.ListInputs.descriptor,
            )
            #expect(listed.inputs.contains { $0.name == inputName })

            await expectStructuredPublicRPCError(
                client: client,
                request: Exactmac_V1_GetInputRequest.with { $0.name = malformedName },
                descriptor: Exactmac_V1_ExactMac.Method.GetInput.descriptor,
                responseType: Exactmac_V1_Input.self,
                code: .invalidArgument,
                reason: "INVALID_RESOURCE_NAME",
                field: "name",
                label: "malformed desktop Input name before lookup",
            )
        }

        await composition.serviceLifetime.shutdown()
    }

    @Test
    func `all five Operations methods enforce grammar missing resources and producer ownership through grpc`() async throws {
        let composition = ExactMacServiceComposition(system: MockSystemOperations())
        let deleteProbe = PublicBoundaryOperationProbe()
        let cancelProbe = PublicBoundaryOperationProbe()
        let deletedName = "operations/delete-\(UUID().uuidString)"
        let cancelledName = "operations/cancel-\(UUID().uuidString)"
        let pendingName = "operations/pending-\(UUID().uuidString)"
        _ = try await composition.operationStore.createOperation(
            name: deletedName,
            execution: { await deleteProbe.run() },
        )
        _ = try await composition.operationStore.createOperation(
            name: cancelledName,
            execution: { await cancelProbe.run() },
        )
        _ = await composition.operationStore.createOperation(name: pendingName)
        await deleteProbe.waitUntilEntered()
        await cancelProbe.waitUntilEntered()

        try await withPublicContractClient(composition) { client in
            let listed: Google_Longrunning_ListOperationsResponse = try await publicUnary(
                client: client,
                request: Google_Longrunning_ListOperationsRequest.with {
                    $0.filter = "done=false"
                },
                descriptor: Google_Longrunning_Operations.Method.ListOperations.descriptor,
            )
            #expect(Set(listed.operations.map(\.name)).isSuperset(of: [deletedName, cancelledName, pendingName]))

            let fetched: Google_Longrunning_Operation = try await publicUnary(
                client: client,
                request: Google_Longrunning_GetOperationRequest.with { $0.name = pendingName },
                descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
            )
            #expect(fetched.name == pendingName)
            #expect(!fetched.done)

            let waited: Google_Longrunning_Operation = try await publicUnary(
                client: client,
                request: Google_Longrunning_WaitOperationRequest.with {
                    $0.name = pendingName
                    $0.timeout = Google_Protobuf_Duration()
                },
                descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
            )
            #expect(waited.name == pendingName)
            #expect(!waited.done)

            let _: Google_Protobuf_Empty = try await publicUnary(
                client: client,
                request: Google_Longrunning_DeleteOperationRequest.with { $0.name = deletedName },
                descriptor: Google_Longrunning_Operations.Method.DeleteOperation.descriptor,
            )
            #expect(await composition.operationStore.getOperation(name: deletedName) == nil)
            #expect(await composition.operationStore.executionTaskCount() == 2)
            #expect(await !(deleteProbe.cancellationObserved()))

            let _: Google_Protobuf_Empty = try await publicUnary(
                client: client,
                request: Google_Longrunning_CancelOperationRequest.with { $0.name = cancelledName },
                descriptor: Google_Longrunning_Operations.Method.CancelOperation.descriptor,
            )
            await cancelProbe.waitUntilCancellationObserved()
            let cancellationRequested: Google_Longrunning_Operation = try await publicUnary(
                client: client,
                request: Google_Longrunning_GetOperationRequest.with { $0.name = cancelledName },
                descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
            )
            #expect(!cancellationRequested.done)
            #expect(cancellationRequested.result == nil)

            await cancelProbe.release()
            let cancelled: Google_Longrunning_Operation = try await publicUnary(
                client: client,
                request: Google_Longrunning_WaitOperationRequest.with {
                    $0.name = cancelledName
                    $0.timeout = Google_Protobuf_Duration.with { $0.seconds = 1 }
                },
                descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
            )
            #expect(cancelled.done)
            #expect(cancelled.error.code == Int32(RPCError.Code.cancelled.rawValue))

            for missingCall in PublicOperationsMissingCall.allCases {
                await missingCall.expectNotFound(client: client)
            }
        }

        await deleteProbe.release()
        await deleteProbe.waitUntilFinished()
        _ = await composition.operationStore.drainAllOperations()
        #expect(await composition.operationStore.executionTaskCount() == 0)
        #expect(await composition.operationStore.waiterCount() == 0)
        #expect(await !(deleteProbe.cancellationObserved()))
        #expect(await cancelProbe.cancellationObserved())
    }
}

private struct PublicUnaryErrorProbe: Sendable {
    let label: String
    let call: @Sendable () async -> Void
}

private enum PublicOperationsMissingCall: CaseIterable {
    case get
    case delete
    case cancel
    case wait

    func expectNotFound(client: GRPCClient<InProcessTransport.Client>) async {
        let name = "operations/missing"
        switch self {
        case .get:
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_GetOperationRequest.with { $0.name = name },
                descriptor: Google_Longrunning_Operations.Method.GetOperation.descriptor,
                responseType: Google_Longrunning_Operation.self,
                code: .notFound,
                label: "GetOperation missing",
            )
        case .delete:
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_DeleteOperationRequest.with { $0.name = name },
                descriptor: Google_Longrunning_Operations.Method.DeleteOperation.descriptor,
                responseType: Google_Protobuf_Empty.self,
                code: .notFound,
                label: "DeleteOperation missing",
            )
        case .cancel:
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_CancelOperationRequest.with { $0.name = name },
                descriptor: Google_Longrunning_Operations.Method.CancelOperation.descriptor,
                responseType: Google_Protobuf_Empty.self,
                code: .notFound,
                label: "CancelOperation missing",
            )
        case .wait:
            await expectPublicRPCError(
                client: client,
                request: Google_Longrunning_WaitOperationRequest.with {
                    $0.name = name
                    $0.timeout = Google_Protobuf_Duration()
                },
                descriptor: Google_Longrunning_Operations.Method.WaitOperation.descriptor,
                responseType: Google_Longrunning_Operation.self,
                code: .notFound,
                label: "WaitOperation missing",
            )
        }
    }
}

private actor PublicBoundaryOperationProbe {
    private var entered = false
    private var finished = false
    private var observedCancellation = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuations: [CheckedContinuation<Void, Never>] = []

    func run() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        recordFinished()
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func cancellationObserved() -> Bool {
        observedCancellation
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            finishContinuations.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !observedCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func recordCancellation() {
        observedCancellation = true
        let continuations = cancellationContinuations
        cancellationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func recordFinished() {
        finished = true
        let continuations = finishContinuations
        finishContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func assignmentAction() -> Exactmac_V1_MacroAction {
    Exactmac_V1_MacroAction.with {
        $0.assignment.variable = "value"
        $0.assignment.literal = "must reject"
    }
}

private func publicWindowDictionary(
    windowID: CGWindowID,
    pid: pid_t,
    title: String,
    layer: Int32,
) -> [String: Any] {
    [
        kCGWindowNumber as String: windowID,
        kCGWindowOwnerPID as String: pid,
        kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 100],
        kCGWindowName as String: title,
        kCGWindowLayer as String: layer,
        kCGWindowIsOnscreen as String: true,
    ]
}

private func withPublicContractClient(
    _ composition: ExactMacServiceComposition,
    operation: @escaping @Sendable (GRPCClient<InProcessTransport.Client>) async throws -> Void,
) async throws {
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
        try await operation(client)
    }
}

private func publicUnary<
    Request: SwiftProtobuf.Message & Sendable,
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: Request,
    descriptor: MethodDescriptor,
    options: CallOptions = .defaults,
) async throws -> Response {
    try await client.unary(
        request: ClientRequest(message: request),
        descriptor: descriptor,
        serializer: ProtobufSerializer<Request>(),
        deserializer: ProtobufDeserializer<Response>(),
        options: options,
    ) { response in
        try response.message
    }
}

private func assertPublicPageSizeContinuation<
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    descriptor: MethodDescriptor,
    queryBinding: String,
    responseType _: Response.Type,
    label: String,
    request: (Int32, String) -> some SwiftProtobuf.Message & Sendable,
) async throws {
    let token = ParsingHelpers.encodePageToken(offset: 0, queryBinding: queryBinding)
    do {
        let _: Response = try await publicUnary(
            client: client,
            request: request(1, token),
            descriptor: descriptor,
        )
    } catch {
        Issue.record("\(label) rejected its canonical page_size=1 continuation: \(error)")
    }

    do {
        let _: Response = try await publicUnary(
            client: client,
            request: request(2, token),
            descriptor: descriptor,
        )
    } catch {
        Issue.record("\(label) rejected a changed page_size=2 continuation: \(error)")
    }
}

private func expectPublicRPCError<
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: some SwiftProtobuf.Message & Sendable,
    descriptor: MethodDescriptor,
    responseType _: Response.Type,
    code: RPCError.Code,
    label: String,
) async {
    do {
        let _: Response = try await publicUnary(
            client: client,
            request: request,
            descriptor: descriptor,
        )
        Issue.record("\(label) unexpectedly succeeded")
    } catch let error as RPCError {
        #expect(error.code == code, Comment(rawValue: "\(label): \(error)"))
    } catch {
        Issue.record("\(label) returned non-RPC error: \(error)")
    }
}

private func expectStructuredPublicRPCError<
    Response: SwiftProtobuf.Message & Sendable,
>(
    client: GRPCClient<InProcessTransport.Client>,
    request: some SwiftProtobuf.Message & Sendable,
    descriptor: MethodDescriptor,
    responseType _: Response.Type,
    code: RPCError.Code,
    reason: String,
    field: String,
    label: String,
) async {
    do {
        let _: Response = try await publicUnary(
            client: client,
            request: request,
            descriptor: descriptor,
        )
        Issue.record("\(label) unexpectedly succeeded")
    } catch let error as RPCError {
        #expect(error.code == code, Comment(rawValue: "\(label): \(error)"))
        do {
            let info = try publicContractErrorInfo(error)
            #expect(info.reason == reason, Comment(rawValue: label))
            #expect(info.metadata["field"] == field, Comment(rawValue: label))
        } catch {
            Issue.record("\(label) omitted structured error details: \(error)")
        }
    } catch {
        Issue.record("\(label) returned non-RPC error: \(error)")
    }
}

private func publicContractErrorInfo(_ error: RPCError) throws -> Google_Rpc_ErrorInfo {
    var statusBytes: [UInt8]?
    for bytes in error.metadata[binaryValues: "grpc-status-details-bin"] {
        statusBytes = bytes
        break
    }
    guard let statusBytes else {
        throw PublicContractBoundaryTestError.missingErrorDetails
    }
    let status = try Google_Rpc_Status(serializedBytes: statusBytes)
    guard let detail = status.details.first(where: { $0.isA(Google_Rpc_ErrorInfo.self) }) else {
        throw PublicContractBoundaryTestError.missingErrorDetails
    }
    return try Google_Rpc_ErrorInfo(serializedBytes: detail.value)
}

private enum PublicContractBoundaryTestError: Error {
    case missingErrorDetails
}
