import ExactMacProto
import Foundation
import SwiftProtobuf

/// The authoritative map from every RPC to what it costs and what it touches.
///
/// DRIFT IS MADE STRUCTURALLY IMPOSSIBLE rather than merely checked. The method list
/// comes from the same descriptor set the wire validator already loads, and
/// `AuthorizationMapDriftTests` fails if any method has no entry or any entry names a
/// method that no longer exists. Adding an RPC to the proto therefore fails the build
/// until it is classified, which is the only way a 68-row table stays true.
///
/// SCOPE AND PAYLOAD ARE DERIVED FROM THE REQUEST BYTES by `RequestFacts`, not declared
/// per method and not accepted from anywhere. That is the control which answers the
/// prompt-versus-enforcement TOCTOU: the console is told what the engine computed, and
/// the engine never reads anything the console said.
enum RPCAuthorizationMap {
    /// Where a request's target application is named, if anywhere. `.none` is a real
    /// answer and not a placeholder: a request that names no application genuinely spans
    /// every application, and the blast-radius model charges for that breadth rather than
    /// the map pretending it is narrower.
    enum ScopeSource: Sendable {
        /// The `name` field, e.g. `applications/4211/windows/12`.
        case resourceName
        /// The `parent` field, e.g. `applications/4211/elements`.
        case parentField
        /// The `application` field, e.g. `applications/4211`.
        case applicationField
        /// No application is named, so the request is global over applications.
        case global
    }

    /// A stream cannot be re-prompted per element, so it is authorized once at subscribe
    /// and the grant is held for the stream's life. Treating a stream as a series of
    /// unary calls would mean either prompting continuously or holding a decision the
    /// operator made for one element across all of them.
    enum StreamBehaviour: Sendable {
        case unary
        case authorizeOnceAndHold
    }

    /// What the prompt must be able to show. The prompt's entire value depends on this
    /// being accurate and complete, and "accurate" means the literal text, never a
    /// summary of a summary.
    enum ArgumentSummary: Sendable {
        case none
        /// The literal command, its arguments and its working directory.
        case shellInvocation
        /// The literal script and its declared type, for a call that EXECUTES it.
        case scriptText
        /// The literal script and its declared type, for a call that only PARSES it.
        case parseOnlyScript
        /// The literal text destined for the clipboard.
        case clipboardText
        /// Clearing the clipboard, which destroys what is on it.
        case destructiveClipboardClear
        /// Keys, or a coordinate in Global Display Coordinates (top-left origin).
        case synthesizedInput
        /// The target element and the selector that found it.
        case elementTarget
        /// The region, the display and the encoding.
        case captureRegion
        /// The macro's declared steps, which is what it will actually do.
        case macroDefinition
        /// The transaction's declared operation count.
        case transactionScope
        case fileDialog
        case observationFilter
        /// The resource name alone, which is all a metadata read discloses.
        case resourceName
    }

    struct Entry: Sendable {
        let capability: Capability
        let scopeSource: ScopeSource
        let streamBehaviour: StreamBehaviour
        let summary: ArgumentSummary

        init(
            _ capability: Capability,
            _ scopeSource: ScopeSource = .resourceName,
            stream: StreamBehaviour = .unary,
            _ summary: ArgumentSummary = .resourceName,
        ) {
            self.capability = capability
            self.scopeSource = scopeSource
            self.streamBehaviour = stream
            self.summary = summary
        }
    }

    static let serviceName = "exactmac.v1.ExactMac"

    /// Every method, keyed by fully-qualified name.
    ///
    /// The three groupings that are not obvious, each decided by reading the
    /// implementation rather than the method name:
    ///
    ///   `localEcho` is for reads that touch nothing on the desktop and return only what
    ///   the caller itself submitted — GetInput and ListInputs read the server's own input
    ///   registry. It is still mapped and still passes through the interceptor, so the set
    ///   of unmapped methods stays empty; it simply needs no consent.
    ///
    ///   `ValidateScript` is in the same group and the judgement is recorded rather than
    ///   assumed: it builds an `NSAppleScript` and COMPILES caller-supplied source in
    ///   process, and for a shell it only checks for emptiness. Compiling is a parser
    ///   surface, not an execution surface, and prompting on every syntax check is exactly
    ///   the uniform prompt the design rejects. The script text is still carried in the
    ///   summary so the audit records what was parsed.
    ///
    ///   `ListDisplays` and `GetDisplay` are `display.read` and NOT `localEcho`. Monitor
    ///   layout is a real disclosure — it reveals how many screens the operator has, their
    ///   arrangement and their scale — and leaving it unmapped or unmetered would be an
    ///   omission dressed as a decision. It is a cheap capability on purpose: a
    ///   single-app grant covers it, and the radius model charges for breadth.
    static let table: [String: Entry] = {
        var entries: [String: Entry] = [:]
        func add(
            _ capability: Capability,
            _ methods: [(String, ScopeSource, StreamBehaviour, ArgumentSummary)],
        ) {
            for (method, source, stream, summary) in methods {
                entries["\(serviceName)/\(method)"] = Entry(
                    capability, source, stream: stream, summary,
                )
            }
        }
        func simple(
            _ capability: Capability,
            _ source: ScopeSource,
            _ methods: [String],
            summary: ArgumentSummary = .resourceName,
        ) {
            add(capability, methods.map { ($0, source, .unary, summary) })
        }

        // Application lifecycle and inventory.
        simple(.applicationControl, .resourceName, [
            "OpenApplication", "ActivateApplication", "CloseApplication",
        ])
        simple(.windowObserve, .resourceName, [
            "GetApplication", "GetApplicationBundle", "GetScriptingDictionaryCatalog",
        ], summary: .none)
        // Two listings that genuinely span every application, so a global scope is the
        // honest answer rather than a fallback: there is no application to narrow to.
        simple(.windowObserve, .global, [
            "ListApplications", "ListApplicationBundles",
        ], summary: .none)

        // Input synthesis, and the two reads that only echo it back.
        simple(.inputSynthesize, .parentField, ["CreateInput"], summary: .synthesizedInput)
        simple(.localEcho, .parentField, ["ListInputs"], summary: .none)
        // GetInput names the input itself; the application is in the same resource name.
        simple(.localEcho, .resourceName, ["GetInput"], summary: .none)

        // Accessibility traversal and observation.
        simple(.accessibilityTraverse, .resourceName, [
            "TraverseAccessibility", "GetElement", "GetElementActions",
        ], summary: .elementTarget)
        simple(.accessibilityTraverse, .parentField, [
            "WaitElement", "WaitElementState",
        ], summary: .elementTarget)
        simple(.accessibilityTraverse, .parentField, [
            "FindElements", "FindRegionElements", "ListElements",
        ], summary: .elementTarget)
        simple(.inputSynthesize, .parentField, [
            "ClickElement", "WriteElementValue", "PerformElementAction",
        ], summary: .elementTarget)
        add(.observationStream, [
            ("WatchAccessibility", .resourceName, .authorizeOnceAndHold, .observationFilter),
            ("StreamObservations", .resourceName, .authorizeOnceAndHold, .observationFilter),
        ])
        simple(.observationStream, .resourceName, [
            "GetObservation", "CancelObservation",
        ], summary: .observationFilter)
        simple(.observationStream, .parentField, ["CreateObservation"], summary: .observationFilter)
        simple(.observationStream, .parentField, ["ListObservations"], summary: .observationFilter)

        // Windows: read one, or manage one.
        simple(.windowObserve, .resourceName, [
            "GetWindow", "GetWindowState",
        ], summary: .resourceName)
        // ListWindows names its application in `parent`, not `name`. It was mapped to the
        // resource-name source, so the lookup found nothing and the scope degraded to
        // global — fail-safe, but wrong: the request names ONE application, and a global
        // scope charges global breadth and cannot be covered by a window-scoped grant.
        simple(.windowObserve, .parentField, ["ListWindows"], summary: .resourceName)
        simple(.windowManage, .resourceName, [
            "FocusWindow", "MoveWindow", "ResizeWindow", "MinimizeWindow", "RestoreWindow",
            "CloseWindow",
        ], summary: .resourceName)

        // Sessions and the three transaction methods, which are a consent-bypass primitive
        // if treated as ordinary calls: a transaction batches actions so that ONE decision
        // covers many, so its scope carries a declared operation count and exceeding it is
        // denied rather than amortised.
        simple(.sessionManage, .global, [
            "CreateSession", "ListSessions", "GetSession", "GetSessionSnapshot",
            "DeleteSession",
        ], summary: .none)
        add(.transactionManage, [
            ("BeginTransaction", .global, .unary, .transactionScope),
            ("CommitTransaction", .resourceName, .unary, .transactionScope),
            ("RollbackTransaction", .resourceName, .unary, .transactionScope),
        ])

        // Capture. A display or window reference does NOT narrow the application axis —
        // a screenshot of a display spans whatever is on it — so these are global over
        // applications and the radius model charges for that.
        simple(.screenObserve, .global, [
            "CaptureScreenshot", "CaptureRegionScreenshot", "CaptureWindowScreenshot",
            "CaptureCursorPosition",
        ], summary: .captureRegion)
        simple(.screenObserve, .parentField, ["CaptureElementScreenshot"], summary: .captureRegion)

        // Display layout: a real, cheap disclosure. See the note on `table`.
        simple(.displayRead, .global, ["ListDisplays", "GetDisplay"], summary: .resourceName)

        // Clipboard, sessions and displays are SINGLETON RESOURCES: their `name` fields
        // name `clipboard`, `sessions/s1` and `displays/1`, never an application. They are
        // global because there is nothing to narrow to, and reading their `name` would find
        // a reference that does not parse as one and fall back to global anyway.
        simple(.clipboardRead, .global, ["GetClipboard", "GetClipboardHistory"], summary: .none)
        add(.clipboardWrite, [
            ("WriteClipboard", .global, .unary, .clipboardText),
            ("ClearClipboard", .global, .unary, .destructiveClipboardClear),
        ])

        // File dialogs, driven against one application.
        simple(.fileDialogAutomate, .applicationField, [
            "AutomateOpenFileDialog", "AutomateSaveFileDialog",
        ], summary: .fileDialog)

        // Macros: a macro is a recorded sequence, so it is bounded input plus a
        // transaction, and the summary is the steps it will actually perform.
        simple(.macroExecute, .applicationField, ["ExecuteMacro"], summary: .macroDefinition)
        simple(.macroExecute, .global, [
            "CreateMacro", "ListMacros",
        ], summary: .macroDefinition)
        simple(.macroExecute, .resourceName, ["GetMacro", "DeleteMacro"],
               summary: .macroDefinition)
        // UpdateMacro names a MACRO, not an application, so there is nothing to narrow to.
        simple(.macroExecute, .global, ["UpdateMacro"], summary: .macroDefinition)

        // Script execution, and the parse-only sibling.
        simple(.scriptExecute, .global, [
            "ExecuteShellCommand",
        ], summary: .shellInvocation)
        simple(.scriptExecute, .global, [
            "ExecuteAppleScript", "ExecuteJavaScript",
        ], summary: .scriptText)
        add(.localEcho, [("ValidateScript", .global, .unary, .parseOnlyScript)])

        return entries
    }()

    static func authorization(forMethod fullyQualifiedName: String) -> Entry? {
        table[fullyQualifiedName]
    }

    /// Every method the descriptor set declares, read at runtime so this cannot drift from
    /// the proto without the tests noticing.
    static func declaredMethods(
        using policy: PublicRequestDescriptorPolicy,
    ) -> Set<String> {
        Set(policy.methodInputs.keys.filter { $0.hasPrefix("\(serviceName)/") })
    }

    /// The two comparison directions, as functions rather than as assertions buried in a
    /// test, because a completeness check has to be runnable against a hypothetical
    /// descriptor set — that is how its sensitivity gets proven instead of assumed.
    static func unmappedMethods(declared: Set<String>) -> Set<String> {
        declared.subtracting(Set(table.keys))
    }

    static func staleMappings(declared: Set<String>) -> Set<String> {
        Set(table.keys).subtracting(declared)
    }
}

/// What the server knows about the process behind an application resource name.
struct ResolvedApplicationTarget: Sendable, Equatable {
    var processIdentifier: Int32
    var bundleIdentifier: String?
}

/// Resolves an application RESOURCE NAME to the process behind it.
///
/// The name, not a pid, because that is what a request carries: production emits
/// `applications/<sha256 of pid + start time>`. Resolving it is a lookup in the server's
/// own application catalog, which is also how a recycled pid is told apart from the
/// process that used to hold the name.
///
/// The scope a request derives has to name an APPLICATION as well as a process instance,
/// because an operator who says "allow this for TextEdit" names a bundle and a grant
/// scoped that way has to cover a request that arrived naming the opaque form. Without
/// this resolution every application-scoped grant would be unusable and every request
/// would fall back to a global grant, which is the opposite of what the granularity is for.
protocol ApplicationTargetResolving: Sendable {
    func applicationTarget(forResourceName: String) async -> ResolvedApplicationTarget?
}

/// A resolver that knows nothing. The derivation then produces an OPAQUE scope rather than
/// a global one: the request named a specific process instance and a scope that said "some
/// unknown application" would be a lie, while the opaque scope is narrow and cannot be
/// covered by anything the operator did not aim at it.
struct UnresolvableApplicationTarget: ApplicationTargetResolving {
    func applicationTarget(forResourceName _: String) async -> ResolvedApplicationTarget? { nil }
}

/// The request's own contents, read once, from the WIRE FORMAT and the SAME descriptor
/// table the wire validator already loads.
///
/// NOT JSON, and not sixty-eight hand-written accessors. `SwiftProtobuf.JSONEncoder` is
/// internal in the version this package pins, and a hand-written accessor per field is a
/// table that rots the moment a proto field is renamed — and a renamed field would leave
/// the scope global, which is fail-safe for security but wrong. Reading the wire against
/// `PublicRequestDescriptorPolicy` means the field names and numbers come from the
/// descriptor set itself, so this cannot drift from the proto, and it introduces no second
/// source of truth about the schema.
struct RequestFacts: Sendable {
    enum Value: Sendable {
        case text(String)
        case unsigned(UInt64)
        case double(Double)
        case boolean(Bool)
        case nested(RequestFacts)
        case list([Value])
        case opaque(String)

        /// Appends in place rather than rebuilding the array, so a long repeated field costs
        /// linear rather than quadratic time. The accumulator used to rebuild the whole
        /// list per element, which made a 96KB request take nineteen seconds on the path
        /// that runs before any consent decision.
        fileprivate mutating func listAppend(_ value: Value) {
            switch self {
            case .list(var existing):
                existing.append(value)
                self = .list(existing)
            case .text, .unsigned, .double, .boolean, .nested, .opaque:
                self = .list([self, value])
            }
        }
    }

    private var fields: [String: Value] = [:]

    init() {}

    init(message: any SwiftProtobuf.Message, policy: PublicRequestDescriptorPolicy) {
        guard let bytes = try? message.serializedData() else { return }
        var accumulator = Accumulator()
        Self.read(
            bytes: bytes,
            messageName: type(of: message).protoMessageName,
            policy: policy,
            into: &accumulator,
        )
        fields = accumulator.fields
    }

    /// Repeated fields need somewhere to accumulate, which a dictionary subscript cannot do.
    private struct Accumulator {
        var fields: [String: Value] = [:]

        /// In place, and the difference is not cosmetic. Rebuilding the array on every
        /// append made a 96KB request — well under gRPC's 4 MiB default — take nineteen
        /// seconds, quadratically, on the path that runs before any consent decision.
        mutating func append(_ name: String, _ value: Value) {
            fields[name, default: .list([])].listAppend(value)
        }
    }

    private static func read(
        bytes: Data,
        messageName: String,
        policy: PublicRequestDescriptorPolicy,
        into accumulator: inout Accumulator,
    ) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let tag = readVarint(bytes, &index) else { return }
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            let descriptor = policy.field(messageName: messageName, number: number)
            // NORMALISED TO THE SWIFT SPELLING, once, here. The wire and the descriptor
            // both use the proto name (`working_directory`, `mouse_click`,
            // `ocr_enabled`); every accessor above reads the generated Swift name
            // (`workingDirectory`). Keying by the proto name silently produced an EMPTY
            // summary and a GLOBAL scope for four separate tests, because a lookup that
            // finds nothing is indistinguishable from a field that is genuinely absent.
            let name = descriptor.map { camelCased($0.name) } ?? "field\(number)"
            switch wire {
            case 0:
                guard let raw = readVarint(bytes, &index) else { return }
                if descriptor?.isRepeated == true {
                    accumulator.append(name, .unsigned(raw))
                } else {
                    accumulator.fields[name] = .unsigned(raw)
                }
            case 1:
                guard let raw = readFixed64(bytes, &index) else { return }
                accumulator.fields[name] = descriptor?.wireKind == .fixed64
                    ? .double(Double(bitPattern: raw))
                    : .opaque("8 bytes")
            case 5:
                guard let raw = readFixed32(bytes, &index) else { return }
                accumulator.fields[name] = .opaque("\(raw) (32-bit)")
            case 2:
                guard let length = readVarint(bytes, &index) else { return }
                let end = index + Int(length)
                guard end <= bytes.endIndex else { return }
                let payload = Data(bytes[index..<end])
                index = end
                if let nestedName = descriptor?.messageName,
                   policy.message(nestedName) != nil
                {
                    var nested = Accumulator()
                    read(bytes: payload, messageName: nestedName, policy: policy, into: &nested)
                    let value = Value.nested(RequestFacts(fields: nested.fields))
                    if descriptor?.isRepeated == true {
                        accumulator.append(name, value)
                    } else {
                        accumulator.fields[name] = value
                    }
                } else if descriptor?.isRepeated == true {
                    accumulator.append(name, .text(String(decoding: payload, as: UTF8.self)))
                } else {
                    accumulator.fields[name] = .text(String(decoding: payload, as: UTF8.self))
                }
            default:
                // Groups are not used by this API, and an unknown wire type means the bytes
                // are not what we think they are, so the walk stops rather than guessing.
                return
            }
        }
    }

    private init(fields: [String: Value]) {
        self.fields = fields
    }


    /// `working_directory` becomes `workingDirectory`, matching the generated Swift, so the
    /// accessors read the way the API reads. A name that is already camelCase is unchanged.
    private static func camelCased(_ name: String) -> String {
        var result = ""
        var upperNext = false
        for character in name {
            if character == "_" {
                upperNext = true
                continue
            }
            result.append(upperNext ? Character(character.uppercased()) : character)
            upperNext = false
        }
        return result
    }

    private static func readVarint(_ bytes: Data, _ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func readFixed64(_ bytes: Data, _ index: inout Data.Index) -> UInt64? {
        let end = index + 8
        guard end <= bytes.endIndex else { return nil }
        var value: UInt64 = 0
        for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
        index = end
        return value
    }

    private static func readFixed32(_ bytes: Data, _ index: inout Data.Index) -> UInt64? {
        let end = index + 4
        guard end <= bytes.endIndex else { return nil }
        var value: UInt64 = 0
        for offset in 0..<4 { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
        index = end
        return value
    }

    // MARK: Accessors

    func has(_ key: String) -> Bool { fields[key] != nil }

    func text(_ key: String) -> String? {
        switch fields[key] {
        case .text(let value): value
        case .unsigned(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        case .double(let value): String(value)
        case nil, .nested, .list, .opaque: nil
        }
    }

    func boolean(_ key: String) -> Bool? {
        switch fields[key] {
        case .boolean(let value): value
        case .unsigned(let value): value != 0
        case nil, .text, .double, .nested, .list, .opaque: nil
        }
    }

    func number(_ key: String) -> Double? {
        switch fields[key] {
        case .unsigned(let value): Double(value)
        case .double(let value): value
        case .boolean(let value): value ? 1 : 0
        case nil, .text, .nested, .list, .opaque: nil
        }
    }

    func texts(_ key: String) -> [String] {
        switch fields[key] {
        case .list(let values): values.compactMap { value in
            if case .text(let text) = value { return text } else { return nil }
        }
        case .text(let value): [value]
        case nil, .unsigned, .double, .boolean, .nested, .opaque: []
        }
    }

    /// A map field, or a repeated message field, rendered as `key: value` lines.
    ///
    /// A protobuf map arrives on the wire as a LIST of nested messages, each with a `key`
    /// and a `value` field — which is why `texts()` returned nothing for the shell's
    /// environment variables and the macro's parameter values, and why the summaries
    /// silently dropped the payloads an operator most needs to see.
    func entries(_ key: String) -> [String] {
        switch fields[key] {
        case .list(let values):
            return values.compactMap { value in
                guard case .nested(let entry) = value else { return nil }
                let name = entry.text("key") ?? ""
                switch entry.text("value") {
                case .some(let text) where !text.isEmpty: return "\(name): \(text)"
                case .some: return name
                case nil: return entry.describe()
                }
            }
        case .nested(let entry):
            return [entry.describe()]
        case .text(let value):
            return [value]
        case nil, .unsigned, .double, .boolean, .opaque:
            return []
        }
    }

    /// A one-line description of a nested message, for the cases where a map's value is
    /// itself a message.
    func describe() -> String {
        var parts: [String] = []
        for key in fields.keys.sorted() {
            guard let value = text(key), !value.isEmpty else { continue }
            // The keys are already normalised on the way in.
            parts.append("\(key): \(value)")
        }
        return parts.joined(separator: " ")
    }

    func nested(_ key: String) -> RequestFacts? {
        guard case .nested(let value) = fields[key] else { return nil }
        return value
    }

    /// The first non-empty string among `keys`, which is how a resource reference is found
    /// without knowing which of the three conventional fields this request uses.
    func firstText(among keys: [String]) -> (key: String, value: String)? {
        for key in keys {
            if let value = text(key), !value.isEmpty { return (key, value) }
        }
        return nil
    }
}

/// Parses the application resource names the API uses, and nothing else.
///
/// THE PRODUCTION FORM IS THE OPAQUE ONE. `AppStateStore.applicationResourceName(for:)`
/// returns `applications/<sha256 of pid + start time>`, and `ParsingHelpers` requires 64
/// hex characters. A parser that expected a pid found nothing in a 64-character digest
/// and returned nil, so `scope(for:)` fell through to a global scope for every request —
/// which is why the scope column appeared to do nothing. The digest is also strictly better
/// than the pid it replaced, because a recycled pid cannot inherit a grant aimed at the
/// process that used to hold the name.
///
/// The legacy `applications/<pid>` form is still accepted, because
/// `ExactMacService.legacyPIDResourceNamesForTests` still emits it and rejecting it would
/// break the test surface rather than improve it.
enum ResourceReference: Sendable, Equatable {
    case opaqueApplication(resourceName: String, window: String?)
    case legacyProcess(processIdentifier: Int32, window: String?)

    static func parse(_ name: String) -> ResourceReference? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "applications", !parts[1].isEmpty else { return nil }
        var window: String?
        if parts.count >= 4, parts[2] == "windows" {
            // An EMPTY window segment is not a window. Treating "" as a window identifier
            // would produce a scope naming window "", which a grant could then cover.
            window = parts[3].isEmpty ? nil : parts[3]
        }
        if parts[1].count == 64, parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return .opaqueApplication(resourceName: name, window: window)
        }
        guard let pid = Int32(parts[1]), pid > 0 else { return nil }
        return .legacyProcess(processIdentifier: pid, window: window)
    }
}

/// Derives the authorization request from the method and the request bytes.
///
/// This is the ONLY place capability and scope come into being, and it takes no verdict
/// from anywhere: not from the console, not from a prompt, not from the caller.
enum AuthorizationRequestDeriver {
    static func derive(
        method: String,
        message: any SwiftProtobuf.Message,
        policy: PublicRequestDescriptorPolicy,
        requestID: AuthorizationRequestID,
        agentReason: String?,
        origin: RequestOrigin,
        /// The transaction's declared operation count, which the API does not carry in the
        /// request: it lives in the server's own transaction state, so the interceptor
        /// supplies it. Without it a transaction is authorized UNBOUNDED, which is the
        /// consent-bypass the blueprint names.
        operationLimit: Int? = nil,
        resolver: any ApplicationTargetResolving = UnresolvableApplicationTarget(),
    ) async -> AuthorizationRequest? {
        guard let entry = RPCAuthorizationMap.authorization(forMethod: method) else {
            // An unmapped method is not a request. Returning nil here is what makes an
            // unmapped RPC a DENIAL at the interceptor rather than a silent allow.
            return nil
        }
        let facts = RequestFacts(message: message, policy: policy)
        let scope = await scope(
            for: entry.scopeSource, facts: facts, resolver: resolver, operationLimit: operationLimit,
        )
        return AuthorizationRequest(
            id: requestID,
            rpcName: method,
            capability: entry.capability,
            scope: scope,
            argumentSummary: summary(
                for: entry.summary, facts: facts, method: method, operationLimit: operationLimit,
            ),
            agentReason: agentReason,
            origin: origin,
        )
    }

    static func scope(
        for source: RPCAuthorizationMap.ScopeSource,
        facts: RequestFacts,
        resolver: any ApplicationTargetResolving,
        operationLimit: Int? = nil,
    ) async -> AuthorizationScope {
        guard source != .global else { return AuthorizationScope() }
        let keys: [String] = switch source {
        case .resourceName: ["name"]
        case .parentField: ["parent"]
        case .applicationField: ["application"]
        case .global: []
        }
        guard let reference = facts.firstText(among: keys) else {
            // The request named nothing this derivation can read. The scope stays global,
            // which is the safe direction: a global scope cannot be covered by a narrow
            // grant, so nothing is under-restricted by failing to parse.
            return AuthorizationScope(operationLimit: operationLimit)
        }
        let parsed = ResourceReference.parse(reference.value)
        if case .none = parsed {
            return AuthorizationScope(operationLimit: operationLimit)
        }
        let window: TargetWindow = switch parsed {
        case .opaqueApplication(_, let window), .legacyProcess(_, let window):
            window.map(TargetWindow.identifier) ?? .any
        case nil:
            .any
        }
        let application: TargetApplication
        switch parsed {
        case .opaqueApplication(let resourceName, _):
            // Resolved, the operator's application-scoped grant can cover this request;
            // unresolved, the scope names the PROCESS INSTANCE, which is narrow and cannot
            // be covered by anything aimed at a different application.
            if let resolved = await resolver.applicationTarget(forResourceName: resourceName) {
                application = resolved.bundleIdentifier.map { TargetApplication.bundleIdentifier($0) }
                    ?? .processIdentifier(resolved.processIdentifier)
            } else {
                application = .opaqueApplication(resourceName: resourceName, resolvedBundleIdentifier: nil)
            }
        case .legacyProcess(let processIdentifier, _):
            application = .processIdentifier(processIdentifier)
        case nil:
            application = .any
        }

        return AuthorizationScope(
            application: application,
            window: window,
            operationLimit: operationLimit,
        )
    }

    /// The literal request, for the prompt. Never a summary of a summary, and never an
    /// elision: a command that hides its last argument hides the surprise at the end.
    static func summary(
        for kind: RPCAuthorizationMap.ArgumentSummary,
        facts: RequestFacts,
        method: String,
        operationLimit: Int? = nil,
    ) -> String {
        if facts.text("__absent__") != nil {
            return "the request could not be read for display; it is shown uninspected"
        }
        switch kind {
        case .none:
            // NOT "reads metadata only", which is what this used to say about
            // GetClipboardHistory — a record of everything the operator has ever copied,
            // each entry with its content and its source application — and about
            // GetSessionSnapshot, which returns the session's operation records. Telling an
            // operator a content read is a metadata read is worse than saying nothing.
            return "no arguments"
        case .resourceName:
            return describeReference(facts)
        case .shellInvocation:
            var parts: [String] = []
            if let command = facts.text("command") { parts.append(command) }
            let arguments = facts.texts("args")
            if !arguments.isEmpty { parts.append(arguments.joined(separator: " ")) }
            if let directory = facts.text("workingDirectory"), !directory.isEmpty {
                parts.append("(in \(directory))")
            }
            if let shell = facts.text("shell"), !shell.isEmpty { parts.append("via \(shell)") }
            // The environment is carried LITERALLY. `LD_PRELOAD=/tmp/evil.dylib` and
            // `AWS_SECRET_ACCESS_KEY=...` are the payloads an operator most needs to see
            // before approving a shell, and this used to drop the map entirely because a
            // map field arrives as a list of nested messages rather than a string.
            let environment = facts.entries("environmentVariables")
            if !environment.isEmpty {
                parts.append("(with \(environment.joined(separator: ", ")))")
            }
            // And the standard input is shown, not counted. A here-doc body is an
            // argument, and the invariant names arguments.
            if let standardInput = facts.text("stdin"), !standardInput.isEmpty {
                parts.append("(with stdin: \(standardInput))")
            }
            return parts.isEmpty ? "an empty shell invocation" : parts.joined(separator: " ")
        case .scriptText:
            let type = enumName(facts.number("type"), scriptTypeNames) ?? "unspecified"
            return "\(type): \(facts.text("script") ?? "")"
        case .parseOnlyScript:
            // Parse-only is a property of the METHOD, not of a request field a caller can
            // leave unset, and the summary says so every time rather than only when the
            // caller remembered the flag.
            let type = enumName(facts.number("type"), scriptTypeNames) ?? "unspecified"
            return "parse only, no execution (\(type)): \(facts.text("script") ?? "")"
        case .clipboardText:
            return describeClipboardWrite(facts)
        case .destructiveClipboardClear:
            // A destructive clear is not a write, and describing it as "an empty clipboard
            // write" told the operator they were being asked to do nothing.
            return "clear the clipboard, destroying its contents"
        case .synthesizedInput:
            return describeInput(facts)
        case .elementTarget:
            var parts: [String] = []
            if let parent = facts.text("parent") { parts.append("in \(parent)") }
            if let name = facts.text("name") { parts.append(name) }
            if let element = facts.text("elementId"), !element.isEmpty { parts.append(element) }
            // The SELECTOR, which is how most of these methods name their target: the
            // request either carries an element id or a selector, and reading only the
            // first meant the operator saw "in applications/4211" and nothing about WHAT
            // was about to be clicked — which is the whole question.
            if let selector = describeSelector(facts.nested("selector")) {
                parts.append(selector)
            }
            if let action = facts.text("action"), !action.isEmpty {
                parts.append("performing \(action)")
            }
            if let value = facts.text("value"), !value.isEmpty { parts.append("value \(value)") }
            // A right-click and a double-click on the same element are different requests,
            // so the click type is named rather than left in the request.
            if let click = enumName(facts.number("clickType"), elementClickTypeNames) {
                parts.append(click)
            }
            return parts.isEmpty ? "an element with no described target" : parts.joined(separator: " ")
        case .captureRegion:
            var parts: [String] = []
            if let display = facts.text("display"), !display.isEmpty { parts.append(display) }
            if let window = facts.text("window"), !window.isEmpty { parts.append(window) }
            if let parent = facts.text("parent"), !parent.isEmpty { parts.append(parent) }
            if let region = facts.nested("region"),
               let x = region.number("x"), let y = region.number("y"),
               let width = region.number("width"), let height = region.number("height")
            {
                parts.append(
                    "region x \(Int(x)) y \(Int(y)) \(Int(width))x\(Int(height)) in Global Display Coordinates",
                )
            }
            if let format = enumName(facts.number("format"), imageFormatNames) { parts.append(format) }
            if let padding = facts.number("padding"), padding > 0 {
                parts.append("with \(formatted(padding))pt padding")
            }
            if facts.boolean("shadowEnabled") == true { parts.append("including window shadows") }
            if facts.boolean("ocrEnabled") == true { parts.append("with OCR") }
            if let quality = facts.number("quality") { parts.append("quality \(formatted(quality))") }
            return parts.isEmpty ? "the whole screen" : parts.joined(separator: ", ")
        case .macroDefinition:
            // The proto spells it `actions`, not `steps`, has no `step_count` at all, and
            // ExecuteMacro's `macro` is a STRING while CreateMacro's is a message. The
            // previous reader looked for fields that do not exist, so every macro
            // summarized to the constant "a macro" and a three-action macro displayed as
            // zero steps — while the operator was asked to approve inputSynthesize and
            // transactionManage on the strength of it.
            var parts: [String] = []
            if let name = facts.text("name"), !name.isEmpty { parts.append(name) }
            if let reference = facts.text("macro"), !reference.isEmpty { parts.append(reference) }
            if let macro = facts.nested("macro") {
                let declared = macro.texts("actions").count
                parts.append("\(declared) recorded actions")
                for (index, action) in macro.entries("actions").enumerated() {
                    parts.append("action \(index + 1): \(action)")
                }
            }
            // The parameter values are the macro's arguments, and they are what it will
            // actually type or open.
            let parameters = facts.entries("parameterValues")
            if !parameters.isEmpty { parts.append("(\(parameters.joined(separator: ", ")))") }
            return parts.isEmpty ? "a macro with nothing recorded" : parts.joined(separator: ", ")
        case .transactionScope:
            // The count is NOT in the request — no request message in the API has such a
            // field — it lives in the server's own transaction state, so the interceptor
            // supplies it. The placeholder string this used to return unconditionally was
            // the ONLY reachable output, and a test asserting that the summary "mentions
            // the operation count" passed on it while the behaviour was absent.
            guard let declared = operationLimit else {
                return "a transaction of UNBOUNDED length: the server holds no declared count"
            }
            let target = facts.firstText(among: ["name", "session"])?.value ?? "this transaction"
            return "up to \(declared) operations, batched under \(target)"
        case .fileDialog:
            var parts: [String] = []
            if let application = facts.text("application") { parts.append(application) }
            if let title = facts.text("title"), !title.isEmpty { parts.append("title \(title)") }
            // The destination. A save dialog aimed at ~/.ssh/authorized_keys and one aimed
            // at the Desktop are different requests, and the invariant names paths first.
            if let path = facts.text("filePath"), !path.isEmpty { parts.append("writing \(path)") }
            if let directory = facts.text("defaultDirectory"), !directory.isEmpty {
                parts.append("starting in \(directory)")
            }
            if let filename = facts.text("defaultFilename"), !filename.isEmpty {
                parts.append("naming it \(filename)")
            }
            return parts.isEmpty ? "a file dialog" : parts.joined(separator: ", ")
        case .observationFilter:
            var parts: [String] = []
            if let name = facts.text("name") { parts.append(name) }
            if let parent = facts.text("parent") { parts.append(parent) }
            // CreateObservation nests the observation, and the filter inside it. Reading a
            // top-level `filter` found nothing, so the roles an observation would watch
            // and whether it is focus-only were both invisible.
            let filter = facts.nested("filter")
                ?? facts.nested("observation")?.nested("filter")
            if let filter {
                for role in filter.texts("roles") where !role.isEmpty { parts.append("watching \(role)") }
                for attribute in filter.texts("attributes") { parts.append("attribute \(attribute)") }
                if filter.boolean("focusOnly") == true { parts.append("focused elements only") }
                if let kind = filter.text("kind"), !kind.isEmpty { parts.append(kind) }
            }
            if let observation = facts.nested("observation") {
                if let name = observation.text("name"), !name.isEmpty { parts.append(name) }
            }
            return parts.isEmpty ? "every accessibility change" : parts.joined(separator: ", ")
        }
    }


    /// An `ElementSelector` in words. This is how most element methods name their target,
    /// and reading only the parent left the operator looking at "in applications/4211"
    /// with no idea what was about to be clicked.
    private static func describeSelector(_ selector: RequestFacts?) -> String? {
        guard let selector else { return nil }
        var parts: [String] = []
        if let role = selector.text("role"), !role.isEmpty { parts.append("role \(role)") }
        if let subrole = selector.text("subrole"), !subrole.isEmpty { parts.append("subrole \(subrole)") }
        if let title = selector.text("title"), !title.isEmpty { parts.append("titled \"\(title)\"") }
        if let value = selector.text("value"), !value.isEmpty { parts.append("with value \"\(value)\"") }
        if let text = selector.text("text"), !text.isEmpty { parts.append("with text \"\(text)\"") }
        if let description = selector.text("description"), !description.isEmpty {
            parts.append("described \"\(description)\"")
        }
        if let identifier = selector.text("identifier"), !identifier.isEmpty {
            parts.append("with identifier \(identifier)")
        }
        for attribute in selector.texts("attributes") {
            parts.append("attribute \(attribute)")
        }
        if selector.boolean("focusOnly") == true { parts.append("focused elements only") }
        return parts.isEmpty ? nil : "selecting " + parts.joined(separator: ", ")
    }

    /// The one arm of `InputAction` that is set, described in words.
    ///
    /// `InputAction` is a ONE-OF with eight arms, so the earlier reading of `action.x` and
    /// `action.text` was reading fields that do not exist on it. Coordinates live under
    /// `mouse_click` and `mouse_move`, text under `text_input`, keys under `key_press`.

    /// A clipboard write carries a `ClipboardContent` whose payload is a oneof, so the
    /// summary names WHICH kind it is and shows the text literally when there is text. The
    /// arm is named because "the clipboard" and "a file path" and "a URL" are different
    /// requests with different consequences, and an operator shown only a string could not
    /// tell them apart.
    private static func describeClipboardWrite(_ facts: RequestFacts) -> String {
        guard let content = facts.nested("content") else {
            return "an empty clipboard write"
        }
        if let text = content.text("text") {
            return text.isEmpty ? "an empty string" : text
        }
        for arm in ["rtf", "html"] {
            if content.has(arm) {
                return "rich text (\(arm))"
            }
        }
        if content.has("image") { return "an image" }
        if content.has("files") {
            let files = content.entries("files")
            return files.isEmpty
                ? "a set of file paths"
                : "the file paths \(files.joined(separator: ", "))"
        }
        if let url = content.text("url"), !url.isEmpty { return "the URL \(url)" }
        return "an empty clipboard write"
    }

    private static func describeInput(_ facts: RequestFacts) -> String {
        var parts: [String] = []
        if let identifier = facts.text("inputId"), !identifier.isEmpty {
            parts.append("input \(identifier)")
        }
        // CreateInput carries an Input, and the action is inside it.
        guard let action = facts.nested("action") ?? facts.nested("input")?.nested("action") else {
            return parts.isEmpty ? "an input with no action" : parts.joined(separator: ", ")
        }
        // Coordinates are named as Global Display Coordinates (top-left origin), because
        // that is the space these numbers live in and an operator reading "x 420" cannot
        // place it on their desk without being told.
        func position(_ point: RequestFacts?, _ label: String) {
            guard let point, let x = point.number("x"), let y = point.number("y") else { return }
            parts.append(
                "\(label) x \(formatted(x)), y \(formatted(y)) in Global Display Coordinates",
            )
        }
        if let click = action.nested("mouseClick") {
            position(click.nested("position"), "click at")
            if let type = enumName(click.number("clickType"), clickTypeNames) {
                parts.append(type)
            }
            if let count = click.number("clickCount"), count > 1 { parts.append("x\(Int(count))") }
        }
        if let move = action.nested("mouseMove") { position(move.nested("position"), "move to") }
        if let drag = action.nested("mouseDrag") {
            position(drag.nested("startPosition"), "drag from")
            position(drag.nested("endPosition"), "to")
        }
        if let scroll = action.nested("scrollAction") {
            position(scroll.nested("position"), "scroll at")
            if let horizontal = scroll.number("horizontal") {
                parts.append("horizontal \(formatted(horizontal))")
            }
            if let vertical = scroll.number("vertical") {
                parts.append("vertical \(formatted(vertical))")
            }
        }
        if let typing = action.nested("textInput") {
            if let text = typing.text("text"), !text.isEmpty {
                parts.append("type \(text.count) characters: \(text)")
            } else {
                parts.append("type an empty string")
            }
        }
        if let press = action.nested("keyPress") {
            let keys = press.texts("key")
            if keys.isEmpty {
                parts.append("press a key")
            } else {
                parts.append("press \(keys.joined(separator: " + "))")
            }
            let pressModifiers = press.texts("modifiers")
            if !pressModifiers.isEmpty {
                parts.append("with \(pressModifiers.joined(separator: "+").lowercased())")
            }
        }
        if let hover = action.nested("hoverAction") {
            // The seventh arm. It was unhandled, so a hover summarized to "an input with no
            // described action" — which reads as a malformed request rather than a move of
            // the pointer.
            position(hover.nested("position"), "hover at")
        }
        if let click = action.nested("mouseClick") {
            let clickModifiers = click.texts("modifiers")
            if !clickModifiers.isEmpty {
                parts.append("with \(clickModifiers.joined(separator: "+").lowercased())")
            }
        }
        if let drag = action.nested("mouseDrag") {
            if let button = enumName(drag.number("button"), clickTypeNames) { parts.append(button) }
            let waypoints = drag.entries("waypoints")
            if !waypoints.isEmpty {
                parts.append("through \(waypoints.count) waypoints")
            }
        }
        return parts.isEmpty ? "an input with no described action" : parts.joined(separator: ", ")
    }

    /// A double that is finite but beyond `Int.max` used to go through `Int(_:)`, which
    /// TRAPS — and the only numeric gate on these fields accepts anything finite, so
    /// `region.x = 1e30` killed the server on the path that gates every other request. A
    /// crash is not the fail-closed deny the invariant requires, and a caller with socket
    /// access should not be able to take the process down with a number.
    private static func formatted(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        let rounded = value.rounded()
        if rounded.magnitude < 9.0e15, rounded == rounded.rounded() {
            return String(Int64(rounded))
        }
        return String(value)
    }

    /// Enum names are read from the GENERATED Swift types rather than a hand-written
    /// table, so a new value cannot be missing from the prompt and a renamed one cannot
    /// drift. A summary that printed `2` where the operator needs to see `png` would be
    /// worse than no summary.
    private static func enumName(_ raw: Double?, _ names: [UInt64: String]) -> String? {
        guard let raw, raw >= 0, let name = names[UInt64(raw)] else { return nil }
        return name
    }

    /// Enum name tables built from the GENERATED types, keyed by raw value, so a value
    /// added to the proto appears in the prompt and a value renamed cannot drift. A
    /// summary that printed `2` where the operator needs to see `png` is worse than no
    /// summary, and a hand-written table of enum values is exactly the kind of table that
    /// rots.
    private static func names<Enum: SwiftProtobuf.Enum & CaseIterable & RawRepresentable>(
        _ type: Enum.Type,
    ) -> [UInt64: String] where Enum.RawValue == Int {
        var table: [UInt64: String] = [:]
        for value in Enum.allCases {
            let raw = value.rawValue
            // `allCases` includes UNRECOGNIZED(-1), and clamping it to zero would let it
            // overwrite the real name of the unspecified value.
            guard raw >= 0 else { continue }
            table[UInt64(raw)] = String(describing: value)
        }
        return table
    }

    private static let clickTypeNames = names(Exactmac_V1_MouseClick.ClickType.self)
    private static let elementClickTypeNames = names(Exactmac_V1_ClickElementRequest.ClickType.self)
    private static let imageFormatNames = names(Exactmac_V1_ImageFormat.self)
    private static let scriptTypeNames = names(Exactmac_V1_ScriptType.self)

    private static func describeReference(_ facts: RequestFacts) -> String {
        for key in ["name", "parent", "application", "display", "window", "session", "macro"] {
            if let value = facts.text(key), !value.isEmpty { return value }
        }
        return "no resource named"
    }
}
