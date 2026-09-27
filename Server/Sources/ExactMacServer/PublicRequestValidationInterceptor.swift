import ExactMacProto
import Foundation
import GRPCCore
import SwiftProtobuf

enum PublicRequestValidationPolicy {
    static let validatedServices: Set<String> = [
        "google.longrunning.Operations",
        "exactmac.v1.ExactMac",
    ]
    static let descriptorPolicy: Result<PublicRequestDescriptorPolicy, RPCError> = Result {
        try PublicRequestDescriptorPolicy.load()
    }.mapError { error in
        RPCError(
            code: .internalError,
            message: "failed to load the public request descriptor policy",
            cause: error,
        )
    }
}

/// Rejects preserved protobuf intent before any public ExactMac or Operations
/// handler can validate a known subset, allocate state, or start work.
struct PublicRequestValidationInterceptor: ServerInterceptor {
    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (
            _ request: StreamingServerRequest<Input>,
            _ context: ServerContext,
        ) async throws -> StreamingServerResponse<Output>,
    ) async throws -> StreamingServerResponse<Output> {
        guard PublicRequestValidationPolicy.validatedServices.contains(
            context.descriptor.service.fullyQualifiedService,
        ) else {
            return try await next(request, context)
        }
        let descriptorPolicy = try PublicRequestValidationPolicy.descriptorPolicy.get()

        let validatedMessages = request.messages.map { message in
            guard let protobufMessage = message as? any SwiftProtobuf.Message else {
                throw RPCError(
                    code: .internalError,
                    message: "public protobuf service received a non-protobuf request",
                )
            }
            var visitor = UnknownFieldRejectingVisitor(
                descriptorPolicy: descriptorPolicy,
                messageName: type(of: protobufMessage).protoMessageName,
            )
            try protobufMessage.traverse(visitor: &visitor)
            try visitor.finish()
            return message
        }
        let validatedRequest = StreamingServerRequest(
            metadata: request.metadata,
            messages: RPCAsyncSequence(wrapping: validatedMessages),
        )
        return try await next(validatedRequest, context)
    }
}

/// The server's interceptor chain, in the order the security properties require.
///
/// ORDER IS A PROPERTY, not a convention. `PublicRequestValidationInterceptor` runs FIRST
/// so a malformed request cannot probe the authorization layer, and authorization runs
/// BEFORE every handler so none can allocate state, start work or touch the physical
/// desktop without a decision.
///
/// `authorization` is REQUIRED and has no default, so no server can be built without
/// stating which enforcement it has. A test that exercises handlers rather than
/// enforcement passes `handlerContractTestInterceptors()` below, which is the single
/// visible way to build a server that does not authorize — a decision at the call site
/// rather than a default nobody chose.
func productionServerInterceptors(
    _ authorization: any ServerInterceptor,
) -> [any ServerInterceptor] {
    [PublicRequestValidationInterceptor(), authorization]
}

/// The ONLY way to build a server that does not authorize.
///
/// Named for what it is: these suites test handler behaviour, and a server that denied
/// every call would test nothing. Anything security-relevant must use
/// `productionServerInterceptors` instead, and `AuthorizationInterceptorTests` is where
/// the enforcement itself is proven.
func handlerContractTestInterceptors() -> [any ServerInterceptor] {
    [PublicRequestValidationInterceptor()]
}

struct PublicRequestDescriptorPolicy: Sendable {
    enum WireKind: Sendable {
        case varint
        case fixed64
        case lengthDelimited
        case fixed32
        case group
    }

    struct Field: Sendable {
        let name: String
        let isOutputOnly: Bool
        let isRequired: Bool
        let oneofIndex: Int?
        let wireKind: WireKind
        let messageName: String?
        let isRepeated: Bool
        let isPackable: Bool
    }

    struct Message: Sendable {
        let fields: [Int: Field]
        let realOneofs: [Int: String]
    }

    /// Oneofs that are contractually optional and therefore exempt from the
    /// required-oneof check. Every other real oneof in a request-reachable
    /// message must have exactly one arm set.
    ///
    /// The only optional oneof is `ElementSelector.criteria`: an empty
    /// selector means "matches ALL elements" (documented on the message and
    /// implemented by SelectorParser/ElementLocator), so a present-but-empty
    /// selector must not be rejected before the handler runs.
    static let optionalOneofs: Set<String> = [
        "exactmac.type.ElementSelector.criteria",
    ]

    let messages: [String: Message]
    let methodInputs: [String: String]

    func field(messageName: String, number: Int) -> Field? {
        messages[messageName]?.fields[number]
    }

    func message(_ messageName: String) -> Message? {
        messages[messageName]
    }

    func inputMessage(methodName: String) -> String? {
        methodInputs[methodName]
    }

    static func load() throws -> Self {
        let descriptorURLs = ResourceBundleHelper.bundle.urls(
            forResourcesWithExtension: "pb",
            subdirectory: "DescriptorSets",
        ) ?? []
        guard let descriptorURL = descriptorURLs.first(where: {
            $0.lastPathComponent == "exactmac_descriptors.pb"
        }) else {
            throw PublicRequestDescriptorPolicyError.descriptorSetMissing
        }
        let descriptorSet = try Google_Protobuf_FileDescriptorSet(
            serializedBytes: Data(contentsOf: descriptorURL),
            extensions: Google_Api_FieldBehavior_Extensions,
        )
        var messagesByName: [String: Message] = [:]

        func collect(
            messageDescriptors: [Google_Protobuf_DescriptorProto],
            prefix: String,
        ) {
            for message in messageDescriptors {
                let messageName = prefix.isEmpty ? message.name : "\(prefix).\(message.name)"
                let fields: [Int: Field] = Dictionary(
                    uniqueKeysWithValues: message.field.map { field in
                        let realOneofIndex = field.hasOneofIndex && !field.proto3Optional
                            ? Int(field.oneofIndex)
                            : nil
                        let nestedMessageName: String? = switch field.type {
                        case .message, .group:
                            field.typeName.hasPrefix(".")
                                ? String(field.typeName.dropFirst())
                                : field.typeName
                        default:
                            nil
                        }
                        return (
                            Int(field.number),
                            Field(
                                name: field.name,
                                isOutputOnly: field.options.Google_Api_fieldBehavior.contains(.outputOnly),
                                isRequired: field.options.Google_Api_fieldBehavior.contains(.required),
                                oneofIndex: realOneofIndex,
                                wireKind: Self.wireKind(field.type),
                                messageName: nestedMessageName,
                                isRepeated: field.label == .repeated,
                                isPackable: Self.isPackable(field.type),
                            ),
                        )
                    },
                )
                let realOneofIndexes: Set<Int> = Set(fields.values.compactMap(\.oneofIndex))
                let realOneofs: [Int: String] = Dictionary(
                    uniqueKeysWithValues: realOneofIndexes.map { index in
                        (index, message.oneofDecl[index].name)
                    },
                )
                messagesByName[messageName] = Message(
                    fields: fields,
                    realOneofs: realOneofs,
                )
                collect(messageDescriptors: message.nestedType, prefix: messageName)
            }
        }

        for file in descriptorSet.file {
            collect(messageDescriptors: file.messageType, prefix: file.package)
        }
        var methodInputs: [String: String] = [:]
        for file in descriptorSet.file {
            for service in file.service {
                let serviceName = file.package.isEmpty
                    ? service.name
                    : "\(file.package).\(service.name)"
                guard PublicRequestValidationPolicy.validatedServices.contains(serviceName) else {
                    continue
                }
                for method in service.method {
                    methodInputs["\(serviceName)/\(method.name)"] = method.inputType.hasPrefix(".")
                        ? String(method.inputType.dropFirst())
                        : method.inputType
                }
            }
        }
        return Self(messages: messagesByName, methodInputs: methodInputs)
    }

    private static func wireKind(
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    ) -> WireKind {
        switch type {
        case .double, .fixed64, .sfixed64:
            .fixed64
        case .float, .fixed32, .sfixed32:
            .fixed32
        case .string, .bytes, .message:
            .lengthDelimited
        case .group:
            .group
        case .int64, .uint64, .int32, .uint32, .sint32, .sint64, .bool, .enum:
            .varint
        }
    }

    private static func isPackable(
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
    ) -> Bool {
        switch type {
        case .string, .bytes, .message, .group:
            false
        default:
            true
        }
    }
}

private enum PublicRequestDescriptorPolicyError: Error {
    case descriptorSetMissing
}

private struct UnknownFieldRejectingVisitor: Visitor {
    let descriptorPolicy: PublicRequestDescriptorPolicy
    let messageName: String
    var path: [String] = []
    private var visitedFieldNumbers: Set<Int> = []

    init(
        descriptorPolicy: PublicRequestDescriptorPolicy,
        messageName: String,
        path: [String] = [],
    ) {
        self.descriptorPolicy = descriptorPolicy
        self.messageName = messageName
        self.path = path
    }

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
        try validateFinite(value)
    }

    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
        guard value >= 0 else {
            throw RPCErrorHelpers.validationError(
                message: "request contains a negative integer value",
                reason: "INVALID_NUMERIC_VALUE",
                field: "request",
                value: String(value),
            )
        }
    }

    mutating func visitSingularUInt64Field(value _: UInt64, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
    }

    mutating func visitSingularBoolField(value _: Bool, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
    }

    mutating func visitSingularStringField(value _: String, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
    }

    mutating func visitSingularBytesField(value _: Data, fieldNumber: Int) throws {
        _ = try validateField(number: fieldNumber)
    }

    mutating func visitSingularEnumField(
        value: some SwiftProtobuf.Enum,
        fieldNumber: Int,
    ) throws {
        _ = try validateField(number: fieldNumber)
        guard let caseIterableType = type(of: value) as? any CaseIterable.Type else {
            throw RPCError(
                code: .internalError,
                message: "public protobuf enum does not expose its recognized cases",
            )
        }
        let recognized = caseIterableType.allCases.contains { candidate in
            guard let enumCase = candidate as? any SwiftProtobuf.Enum else { return false }
            return enumCase.rawValue == value.rawValue
        }
        guard recognized else {
            throw RPCErrorHelpers.validationError(
                message: "request contains an unrecognized enum value",
                reason: "INVALID_ENUM_VALUE",
                field: "request",
                value: String(value.rawValue),
            )
        }
    }

    mutating func visitSingularMessageField(
        value: some SwiftProtobuf.Message,
        fieldNumber: Int,
    ) throws {
        let field = try validateField(number: fieldNumber)
        var nestedVisitor = Self(
            descriptorPolicy: descriptorPolicy,
            messageName: type(of: value).protoMessageName,
            path: path + [field.name],
        )
        try value.traverse(visitor: &nestedVisitor)
        try nestedVisitor.finish()
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType _: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int,
    ) throws {
        _ = try validateField(number: fieldNumber)
        for primitiveValue in value.values {
            if let doubleValue = primitiveValue as? Double {
                try validateFinite(doubleValue)
            } else if let floatValue = primitiveValue as? Float {
                try validateFinite(Double(floatValue))
            } else if let int64Value = primitiveValue as? Int64 {
                try visitSingularInt64Field(value: int64Value, fieldNumber: fieldNumber)
            } else if let int32Value = primitiveValue as? Int32 {
                try visitSingularInt64Field(value: Int64(int32Value), fieldNumber: fieldNumber)
            }
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType _: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int,
    ) throws where ValueType.RawValue == Int {
        _ = try validateField(number: fieldNumber)
        for enumValue in value.values {
            try visitSingularEnumField(value: enumValue, fieldNumber: fieldNumber)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType _: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int,
    ) throws {
        let field = try validateField(number: fieldNumber)
        for nestedMessage in value.values {
            var nestedVisitor = Self(
                descriptorPolicy: descriptorPolicy,
                messageName: type(of: nestedMessage).protoMessageName,
                path: path + [field.name],
            )
            try nestedMessage.traverse(visitor: &nestedVisitor)
            try nestedVisitor.finish()
        }
    }

    mutating func visitUnknown(bytes _: Data) throws {
        throw RPCErrorHelpers.validationError(
            message: "request contains unknown fields",
            reason: "UNKNOWN_FIELD",
            field: "request",
        )
    }

    private func validateFinite(_ value: Double) throws {
        guard value.isFinite else {
            let valueDescription = if value.isNaN {
                "nan"
            } else if value.sign == .minus {
                "-infinity"
            } else {
                "+infinity"
            }
            throw RPCErrorHelpers.validationError(
                message: "request contains a non-finite numeric value",
                reason: "INVALID_NUMERIC_VALUE",
                field: "request",
                value: valueDescription,
            )
        }
    }

    mutating func finish() throws {
        guard let message = descriptorPolicy.message(messageName) else {
            throw RPCError(
                code: .internalError,
                message: "public request descriptor policy is missing \(messageName)",
            )
        }
        for (number, field) in message.fields.sorted(by: { $0.key < $1.key })
            where field.isRequired && !visitedFieldNumbers.contains(number)
        {
            throw RPCErrorHelpers.validationError(
                message: "request omits a required field",
                reason: "REQUIRED_FIELD_MISSING",
                field: (path + [field.name]).joined(separator: "."),
            )
        }
        let requiredOneofs = message.realOneofs.filter { _, name in
            !PublicRequestDescriptorPolicy.optionalOneofs.contains("\(messageName).\(name)")
        }
        for (index, name) in requiredOneofs.sorted(by: { $0.key < $1.key })
            where !message.fields.contains(where: {
                $0.value.oneofIndex == index && visitedFieldNumbers.contains($0.key)
            })
        {
            throw RPCErrorHelpers.validationError(
                message: "request omits a required oneof",
                reason: "REQUIRED_ONEOF_MISSING",
                field: (path + [name]).joined(separator: "."),
            )
        }
    }

    private mutating func validateField(
        number: Int,
    ) throws -> PublicRequestDescriptorPolicy.Field {
        guard let field = descriptorPolicy.field(messageName: messageName, number: number) else {
            throw RPCError(
                code: .internalError,
                message: "public request descriptor policy is incomplete for \(messageName).\(number)",
            )
        }
        guard !field.isOutputOnly else {
            throw RPCErrorHelpers.validationError(
                message: "request sets an output-only field",
                reason: "OUTPUT_ONLY_FIELD",
                field: (path + [field.name]).joined(separator: "."),
            )
        }
        visitedFieldNumbers.insert(number)
        return field
    }
}
