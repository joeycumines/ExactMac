import ExactMacProto
import Foundation
@testable import ExactMacServer
import SwiftProtobuf
import XCTest

/// C2's acceptance suite: the map is complete, it cannot drift, and what it claims the
/// prompt will show is what the prompt will get.
///
/// The completeness checks read the SAME descriptor set the production wire validator
/// loads, from the same file on disk, so "all 68 methods are mapped" is a statement about
/// the API as it exists rather than about a list somebody typed.
final class AuthorizationMapDriftTests: XCTestCase {
    // MARK: - Fixtures

    private static func loadPolicy() throws -> PublicRequestDescriptorPolicy {
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
        var messages: [String: PublicRequestDescriptorPolicy.Message] = [:]
        var methodInputs: [String: String] = [:]

        func collect(_ descriptors: [Google_Protobuf_DescriptorProto], prefix: String) {
            for descriptor in descriptors {
                let messageName = prefix.isEmpty ? descriptor.name : "\(prefix).\(descriptor.name)"
                let fields: [Int: PublicRequestDescriptorPolicy.Field] = Dictionary(
                    uniqueKeysWithValues: descriptor.field.map { field in
                        let messageName: String? = switch field.type {
                        case .message, .group:
                            field.typeName.hasPrefix(".")
                                ? String(field.typeName.dropFirst())
                                : field.typeName
                        default: nil
                        }
                        return (
                            Int(field.number),
                            PublicRequestDescriptorPolicy.Field(
                                name: field.name,
                                isOutputOnly: field.options.Google_Api_fieldBehavior.contains(.outputOnly),
                                isRequired: field.options.Google_Api_fieldBehavior.contains(.required),
                                oneofIndex: field.hasOneofIndex && !field.proto3Optional
                                    ? Int(field.oneofIndex) : nil,
                                wireKind: Self.wireKind(field.type),
                                messageName: messageName,
                                isRepeated: field.label == .repeated,
                                isPackable: Self.isPackable(field.type),
                            ),
                        )
                    },
                )
                let realOneofs = Set(fields.values.compactMap(\.oneofIndex))
                messages[messageName] = PublicRequestDescriptorPolicy.Message(
                    fields: fields,
                    realOneofs: Dictionary(
                        uniqueKeysWithValues: realOneofs.map { ($0, descriptor.oneofDecl[$0].name) },
                    ),
                )
                collect(descriptor.nestedType, prefix: messageName)
            }
        }

        for file in descriptorSet.file {
            collect(file.messageType, prefix: file.package)
            for service in file.service {
                let serviceName = file.package.isEmpty
                    ? service.name : "\(file.package).\(service.name)"
                guard serviceName == RPCAuthorizationMap.serviceName else { continue }
                for method in service.method {
                    methodInputs["\(serviceName)/\(method.name)"] = method.inputType
                        .hasPrefix(".") ? String(method.inputType.dropFirst()) : method.inputType
                }
            }
        }
        return PublicRequestDescriptorPolicy(messages: messages, methodInputs: methodInputs)
    }

    private static func wireKind(
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    ) -> PublicRequestDescriptorPolicy.WireKind {
        switch type {
        case .double, .fixed64, .sfixed64: .fixed64
        case .float, .fixed32, .sfixed32: .fixed32
        case .string, .bytes, .message: .lengthDelimited
        case .group: .group
        case .int64, .uint64, .int32, .uint32, .sint32, .sint64, .bool, .enum: .varint
        }
    }

    private static func isPackable(
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    ) -> Bool {
        switch type {
        case .string, .bytes, .message, .group: false
        default: true
        }
    }

    private struct StubResolver: ApplicationTargetResolving {
        let bundles: [Int32: String]
        func bundleIdentifier(forProcessIdentifier pid: Int32) -> String? { bundles[pid] }
    }

    private func derive(
        _ method: String,
        _ message: any SwiftProtobuf.Message,
        policy: PublicRequestDescriptorPolicy,
        resolver: any ApplicationTargetResolving = UnresolvableApplicationTarget(),
    ) throws -> AuthorizationRequest? {
        try AuthorizationRequestDeriver.derive(
            method: "\(RPCAuthorizationMap.serviceName)/\(method)",
            message: message,
            policy: policy,
            requestID: AuthorizationRequestID(rawValue: "req-1"),
            agentReason: "because the test says so",
            origin: .directSocket,
            resolver: resolver,
        )
    }

    // MARK: - Completeness, and the proof that the check can fail

    func testEveryDeclaredMethodHasAMapping() throws {
        let policy = try Self.loadPolicy()
        let declared = RPCAuthorizationMap.declaredMethods(using: policy)
        XCTAssertEqual(
            declared.count, 68,
            "the API's method count moved; this map has to be re-derived, not patched",
        )
        let unmapped = RPCAuthorizationMap.unmappedMethods(declared: declared)
        XCTAssertEqual(
            unmapped, [],
            "these methods reach the interceptor with no capability: \(unmapped.sorted())",
        )
    }

    func testNoMappingNamesAMethodThatNoLongerExists() throws {
        let policy = try Self.loadPolicy()
        let declared = RPCAuthorizationMap.declaredMethods(using: policy)
        let stale = RPCAuthorizationMap.staleMappings(declared: declared)
        XCTAssertEqual(
            stale, [],
            "these mappings name methods the API no longer has: \(stale.sorted())",
        )
        XCTAssertEqual(
            RPCAuthorizationMap.table.count, declared.count,
            "a mapping and a method that is not one of these would both be invisible here",
        )
    }

    /// THE NEGATIVE CONTROL, and the reason this file exists rather than a checklist.
    ///
    /// A completeness check that has never been seen to fail is not a check. Rather than
    /// regenerate the protos to add a method, the same comparison functions are run
    /// against a declared set with one extra method in it — which is exactly what the
    /// proto would hand them — and the omission is required to be reported.
    func testTheDriftCheckReportsAnAddedMethodAndARemovedOne() throws {
        let policy = try Self.loadPolicy()
        let declared = RPCAuthorizationMap.declaredMethods(using: policy)

        let added = declared.union(["\(RPCAuthorizationMap.serviceName)/ExfiltrateEverything"])
        XCTAssertEqual(
            RPCAuthorizationMap.unmappedMethods(declared: added),
            ["\(RPCAuthorizationMap.serviceName)/ExfiltrateEverything"],
            "a method added to the proto without a mapping was not reported",
        )

        var removed = declared
        removed.remove("exactmac.v1.ExactMac/ExecuteShellCommand")
        XCTAssertEqual(
            RPCAuthorizationMap.staleMappings(declared: removed),
            ["exactmac.v1.ExactMac/ExecuteShellCommand"],
            "a mapping left behind by a removed method was not reported",
        )
        // And removing a REAL mapping is caught by the completeness direction, which is
        // the direction that matters at review time.
        XCTAssertEqual(
            RPCAuthorizationMap.unmappedMethods(declared: declared).count, 0,
        )
    }

    /// An unmapped method must yield NO request rather than a default one, because the
    /// interceptor turns a nil into a denial and a default would be an allow.
    func testAnUnmappedMethodYieldsNoRequestAtAll() throws {
        let policy = try Self.loadPolicy()
        XCTAssertNil(
            try derive(
                "ExfiltrateEverything",
                Exactmac_V1_ListWindowsRequest.with { $0.parent = "applications/4211/windows" },
                policy: policy,
            ),
        )
    }

    // MARK: - The classifications that are decisions rather than obvious

    /// Monitor layout is a real disclosure, so it is metered rather than waved through,
    /// and cheaply enough that metering it does not annoy anyone.
    func testDisplayMethodsAreMeteredAsADisclosure() throws {
        for method in ["ListDisplays", "GetDisplay"] {
            let entry = try XCTUnwrap(
                RPCAuthorizationMap.authorization(forMethod: "\(RPCAuthorizationMap.serviceName)/\(method)"),
            )
            XCTAssertEqual(entry.capability, .displayRead, method)
            XCTAssertTrue(entry.capability.requiresConsent, method)
            XCTAssertEqual(entry.scopeSource, .global, "a display is not owned by an application")
        }
    }

    /// The three transaction methods are a consent-bypass primitive if treated as ordinary
    /// calls, so each one's summary is the declared operation count rather than a name.
    func testTransactionMethodsCarryTheirOperationCount() throws {
        for method in ["BeginTransaction", "CommitTransaction", "RollbackTransaction"] {
            let entry = try XCTUnwrap(
                RPCAuthorizationMap.authorization(forMethod: "\(RPCAuthorizationMap.serviceName)/\(method)"),
            )
            XCTAssertEqual(entry.capability, .transactionManage, method)
            XCTAssertEqual(entry.summary, .transactionScope, method)
            let request = try XCTUnwrap(
                try derive(
                    method,
                    Exactmac_V1_CommitTransactionRequest.with {
                        $0.name = "sessions/s1/transactions/t1"
                        $0.transactionID = "t1"
                    },
                    policy: Self.loadPolicy(),
                ),
            )
            XCTAssertTrue(
                request.argumentSummary.contains("operation count"),
                "\(method) did not surface the count: \(request.argumentSummary)",
            )
        }
    }

    /// A stream cannot be re-prompted per element, so both streaming methods authorize
    /// once and hold the decision for the stream's life.
    func testBothStreamingMethodsAuthorizeOnceAndHold() throws {
        let streaming = ["WatchAccessibility", "StreamObservations"]
        for method in streaming {
            let entry = try XCTUnwrap(
                RPCAuthorizationMap.authorization(forMethod: "\(RPCAuthorizationMap.serviceName)/\(method)"),
            )
            XCTAssertEqual(entry.streamBehaviour, .authorizeOnceAndHold, method)
        }
        // And nothing else claims to stream, so the interceptor cannot hold a decision for
        // a unary call by accident.
        for (method, entry) in RPCAuthorizationMap.table
            where entry.streamBehaviour == .authorizeOnceAndHold
        {
            XCTAssertTrue(
                streaming.contains { method.hasSuffix("/\($0)") },
                "\(method) claims to be a stream and is not one",
            )
        }
        XCTAssertEqual(RPCAuthorizationMap.table.values.filter { $0.streamBehaviour == .authorizeOnceAndHold }.count, 2)
    }

    /// The parse-only sibling of script execution needs no consent, and the judgement is
    /// recorded in the map's documentation rather than left to the next reader.
    func testValidateScriptIsNotScriptExecution() throws {
        let entry = try XCTUnwrap(
            RPCAuthorizationMap.authorization(forMethod: "\(RPCAuthorizationMap.serviceName)/ValidateScript"),
        )
        XCTAssertEqual(entry.capability, .localEcho)
        XCTAssertFalse(entry.capability.requiresConsent)
        // But the script is still carried, so the audit records what was parsed.
        let request = try XCTUnwrap(
            try derive(
                "ValidateScript",
                Exactmac_V1_ValidateScriptRequest.with {
                    $0.script = "tell application \"TextEdit\" to get the clipboard"
                    $0.type = .applescript
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertTrue(
            request.argumentSummary.contains("parse only"),
            request.argumentSummary,
        )
        XCTAssertTrue(request.argumentSummary.contains("TextEdit"), request.argumentSummary)
    }

    // MARK: - Derivation from the request bytes

    /// The shell invocation is the one payload the operator must see literally and in
    /// full, including the working directory and any standard input.
    func testTheShellPayloadIsCarriedLiterally() throws {
        let request = try XCTUnwrap(
            try derive(
                "ExecuteShellCommand",
                Exactmac_V1_ExecuteShellCommandRequest.with {
                    $0.command = "/bin/zsh"
                    $0.args = ["-lc", "cat ~/secret/keys.txt | pbcopy"]
                    $0.workingDirectory = "/Users/joeyc/dev/secret-project"
                    $0.stdin = String(repeating: "x", count: 12)
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.capability, .scriptExecute)
        XCTAssertTrue(request.argumentSummary.contains("/bin/zsh"), request.argumentSummary)
        XCTAssertTrue(
            request.argumentSummary.contains("cat ~/secret/keys.txt | pbcopy"),
            request.argumentSummary,
        )
        XCTAssertTrue(
            request.argumentSummary.contains("/Users/joeyc/dev/secret-project"),
            request.argumentSummary,
        )
        XCTAssertTrue(request.argumentSummary.contains("12 bytes"), request.argumentSummary)
        // And the scope is global, because a shell is not owned by an application.
        XCTAssertEqual(request.scope.application, .any)
    }

    /// A request that names an application derives a scope for that application, and the
    /// pid is resolved to a bundle when the platform can say which application it is —
    /// because an operator who says "allow this for TextEdit" names a bundle, and a grant
    /// scoped that way has to be able to cover a request that arrived naming a pid.
    func testScopeIsDerivedFromTheResourceNameAndResolvedToAnApplication() throws {
        let policy = try Self.loadPolicy()
        let resolver = StubResolver(bundles: [4211: "com.apple.TextEdit"])

        let listed = try XCTUnwrap(
            try derive(
                "ListWindows",
                Exactmac_V1_ListWindowsRequest.with { $0.parent = "applications/4211/windows" },
                policy: policy,
                resolver: resolver,
            ),
        )
        XCTAssertEqual(listed.scope.application, .bundleIdentifier("com.apple.TextEdit"))
        XCTAssertEqual(listed.scope.window, .any)

        let single = try XCTUnwrap(
            try derive(
                "GetWindow",
                Exactmac_V1_GetWindowRequest.with { $0.name = "applications/4211/windows/77" },
                policy: policy,
                resolver: resolver,
            ),
        )
        XCTAssertEqual(single.scope.application, .bundleIdentifier("com.apple.TextEdit"))
        XCTAssertEqual(single.scope.window, .identifier("77"))

        // With no resolver, the scope degrades to the pid rather than to global, so a
        // narrow grant can still cover it and nothing silently widens.
        let unresolved = try XCTUnwrap(
            try derive(
                "GetWindow",
                Exactmac_V1_GetWindowRequest.with { $0.name = "applications/4211/windows/77" },
                policy: policy,
            ),
        )
        XCTAssertEqual(unresolved.scope.application, .processIdentifier(4211))
    }

    /// A name that is not an application reference leaves the scope GLOBAL, which is the
    /// safe direction: a global scope cannot be covered by a narrow grant.
    func testAnUnparseableReferenceWidensRatherThanNarrows() throws {
        let request = try XCTUnwrap(
            try derive(
                "GetWindow",
                Exactmac_V1_GetWindowRequest.with { $0.name = "windows/77" },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.scope.application, .any)
    }

    /// A synthesized click names its coordinates AND the coordinate system they live in,
    /// because "x 420" is not something an operator can place on their desk.
    func testASynthesizedClickNamesItsCoordinatesAndTheirCoordinateSystem() throws {
        let request = try XCTUnwrap(
            try derive(
                "CreateInput",
                Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/4211/inputs"
                    $0.input = Exactmac_V1_Input.with {
                        $0.action = Exactmac_V1_InputAction.with {
                            $0.mouseClick = Exactmac_V1_MouseClick.with {
                                $0.position = Exactmac_Type_Point.with { $0.x = 420; $0.y = 118 }
                                $0.clickType = .left
                            }
                        }
                    }
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.capability, .inputSynthesize)
        XCTAssertTrue(
            request.argumentSummary.contains("Global Display Coordinates"),
            request.argumentSummary,
        )
        XCTAssertTrue(request.argumentSummary.contains("420"), request.argumentSummary)
        XCTAssertTrue(
            request.argumentSummary.contains("left"),
            request.argumentSummary,
        )
    }

    /// Clicking an ELEMENT names the element and the click type, because a right-click and
    /// a double-click on the same element are different requests.
    func testAnElementClickNamesItsTargetAndClickType() throws {
        let request = try XCTUnwrap(
            try derive(
                "ClickElement",
                Exactmac_V1_ClickElementRequest.with {
                    $0.parent = "applications/4211/elements"
                    $0.elementID = "e-9"
                    $0.clickType = .double
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.capability, .inputSynthesize)
        XCTAssertTrue(request.argumentSummary.contains("applications/4211/elements"), request.argumentSummary)
        XCTAssertTrue(request.argumentSummary.contains("e-9"), request.argumentSummary)
        XCTAssertTrue(request.argumentSummary.contains("double"), request.argumentSummary)
    }

    /// Typed text is shown, not summarised: the operator is deciding whether an agent may
    /// type THIS, and "42 characters" does not tell them what.
    func testTypedTextIsCarriedNotSummarised() throws {
        let request = try XCTUnwrap(
            try derive(
                "CreateInput",
                Exactmac_V1_CreateInputRequest.with {
                    $0.parent = "applications/4211/inputs"
                    $0.input = Exactmac_V1_Input.with {
                        $0.action = Exactmac_V1_InputAction.with {
                            $0.textInput = Exactmac_V1_TextInput.with { $0.text = "rm -rf ~/Documents" }
                        }
                    }
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertTrue(
            request.argumentSummary.contains("rm -rf ~/Documents"),
            request.argumentSummary,
        )
    }

    /// A capture names its region, its format and whether OCR is on, because a screenshot
    /// of the whole screen and a screenshot of a password field are not the same request.
    func testACaptureNamesItsRegionFormatAndOcr() throws {
        let request = try XCTUnwrap(
            try derive(
                "CaptureRegionScreenshot",
                Exactmac_V1_CaptureRegionScreenshotRequest.with {
                    $0.region = Exactmac_Type_Region.with {
                        $0.x = 10; $0.y = 20; $0.width = 300; $0.height = 40
                    }
                    $0.format = .png
                    $0.ocrEnabled = true
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.capability, .screenObserve)
        XCTAssertTrue(request.argumentSummary.contains("300x40"), request.argumentSummary)
        XCTAssertTrue(
            request.argumentSummary.contains("Global Display Coordinates"),
            request.argumentSummary,
        )
        XCTAssertTrue(request.argumentSummary.contains("png"), request.argumentSummary)
        XCTAssertTrue(request.argumentSummary.contains("OCR"), request.argumentSummary)
    }

    /// The clipboard write is shown in full, because it is the request most likely to
    /// carry something the operator would not want typed.
    func testAClipboardWriteIsCarriedLiterally() throws {
        let request = try XCTUnwrap(
            try derive(
                "WriteClipboard",
                Exactmac_V1_WriteClipboardRequest.with {
                    $0.content = Exactmac_V1_ClipboardContent.with { $0.text = "sk-live-0123456789" }
                },
                policy: Self.loadPolicy(),
            ),
        )
        XCTAssertEqual(request.capability, .clipboardWrite)
        XCTAssertTrue(request.argumentSummary.contains("sk-live-0123456789"), request.argumentSummary)
    }

    /// Every mapped method must produce a request from SOME request of its own type, and
    /// the sample used here is the one the drift test cares about: that no method is
    /// mapped to a capability that needs no consent while the API says otherwise.
    func testNoConsentFreeCapabilityIsMappedToSomethingThatReachesTheDesktop() throws {
        let policy = try Self.loadPolicy()
        let consentFree = Set(
            RPCAuthorizationMap.table.filter { !$0.value.capability.requiresConsent }.keys,
        )
        // Everything consent-free is a read of the server's own state, a metadata listing
        // or the parse-only sibling. None of them may be a capability that reaches the
        // desktop, and this asserts the exact membership so a future reclassification has
        // to be deliberate.
        XCTAssertEqual(
            consentFree,
            [
                "exactmac.v1.ExactMac/GetInput",
                "exactmac.v1.ExactMac/ListInputs",
                "exactmac.v1.ExactMac/ValidateScript",
            ],
            "a method was reclassified as needing no consent, or one was given a capability that reaches the desktop",
        )
        XCTAssertFalse(declaredMethodsAreUnknown(policy), "the descriptor set could not be read")
    }

    /// Every non-global scope source must name a field the request ACTUALLY DECLARES.
    ///
    /// A source naming a field the request does not have is the silent-global bug:
    /// `ListWindows` was mapped to the resource-name source when its target lives in
    /// `parent`, the lookup found nothing, and the scope degraded to global — fail-safe,
    /// but wrong in a way nothing was watching, because a global scope is a legal answer.
    ///
    /// The rule stops there deliberately. Deriving the EXPECTED source from field names
    /// alone would demand `.resourceName` for `GetClipboardRequest`, whose `name` is
    /// `clipboard` and not an application at all; those methods are global on purpose and
    /// their names are listed above in the map.
    func testEveryNonGlobalScopeSourceNamesAFieldTheRequestDeclares() throws {
        let policy = try Self.loadPolicy()
        var wrong: [String] = []
        for (method, entry) in RPCAuthorizationMap.table where entry.scopeSource != .global {
            guard let input = policy.methodInputs[method] else {
                wrong.append("\(method): no input message in the descriptor set")
                continue
            }
            let names = Set(policy.message(input)?.fields.values.map(\.name) ?? [])
            let field: String = switch entry.scopeSource {
            case .resourceName: "name"
            case .parentField: "parent"
            case .applicationField: "application"
            case .global: ""
            }
            if !names.contains(field) {
                wrong.append("\(method): reads \(field), which \(input) does not declare")
            }
        }
        XCTAssertEqual(wrong, [], "scope sources naming a field the request does not have")
    }

    /// And the reverse, for the methods that must NOT be global because they name an
    /// application: the ones whose capability is about ONE application's content.
    func testApplicationScopedReadsAreNotGlobal() throws {
        let policy = try Self.loadPolicy()
        let mustNarrow = [
            "ListWindows", "ListElements", "ListObservations", "ListInputs",
            "TraverseAccessibility", "GetWindow", "ClickElement", "CreateInput",
            "CaptureElementScreenshot", "ExecuteMacro", "AutomateOpenFileDialog",
        ]
        var wrong: [String] = []
        for method in mustNarrow {
            guard let entry = RPCAuthorizationMap.authorization(
                forMethod: "\(RPCAuthorizationMap.serviceName)/\(method)",
            ) else {
                wrong.append("\(method) is not mapped")
                continue
            }
            if entry.scopeSource == .global {
                wrong.append("\(method) names an application and is mapped global")
            }
        }
        XCTAssertEqual(wrong, [])
    }

    private func declaredMethodsAreUnknown(_ policy: PublicRequestDescriptorPolicy) -> Bool {
        RPCAuthorizationMap.declaredMethods(using: policy).isEmpty
    }
}
