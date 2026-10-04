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
        /// What the caller currently holds: capability, scope and remaining life. It says
        /// nothing about the desktop, and the summary must not imply that it does.
        case heldGrants
        /// A pre-authorization DECLARATION, shown before the operator answers it, because
        /// an envelope is judged on what it says it covers.
        case envelopeRequest
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
    ///   `localEcho` is for a call that touches nothing on the desktop, needs no consent,
    ///   and returns only what the CALLER ITSELF put in. `ValidateScript` is the only one,
    ///   and its judgement is recorded below.
    ///
    ///   `GetInput` and `ListInputs` WERE here, on the reasoning that they read the
    ///   server's own input registry rather than the desktop. An adversarial review read
    ///   the handlers and falsified it: `getInput` returns the whole stored
    ///   `Exactmac_V1_Input`, which retains the submitted `action` — the literal
    ///   `TextInput.text`, the `KeyPress.key`, the `MouseClick.position` — and the
    ///   `target` naming the exact application and window. `ListInputs` with
    ///   `parent: "applications/-"` enumerates that registry across every application.
    ///   Neither handler checks who created the record; the only check is that the name's
    ///   application segment parses. So these are a CONTENT READ of another caller's
    ///   payload, metered at no cost and summarised as nothing, which is a fail-open on
    ///   the same class the clipboard is metered for. They are `inputSynthesize` now: the
    ///   content IS a synthesized input, so an `inputSynthesize` grant covers reading back
    ///   what was synthesized, and a caller that may not synthesize may not read what
    ///   someone else typed. `localEcho` therefore has ONE member.
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
        // Reading back a recorded input discloses the literal text and the coordinates, so
        // it carries the same capability as writing one. The summary names the RECORD being
        // read rather than describing a create, because what the operator is approving is
        // the disclosure of that record, and the capability is what names the consequence.
        simple(.inputSynthesize, .parentField, ["ListInputs"], summary: .resourceName)
        // GetInput names the input itself; the application is in the same resource name.
        simple(.inputSynthesize, .resourceName, ["GetInput"], summary: .resourceName)

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
        // The administrative RPCs. They are `authorization.manage` and NOT `localEcho`,
        // which is the classification the review took away from GetInput for exactly this
        // reason: the grants a caller may read are the OPERATOR's, not the caller's own
        // submissions, so "returns only what the caller sent" is false of them. Reading and
        // asking are one capability because the risk is the same and the lattice should not
        // carry two names for it.
        simple(.authorizationManage, .resourceName, [
            "GetGrant",
        ], summary: .heldGrants)
        // GLOBAL, and the drift test is what says so: a top-level list declares no `name`
        // field, so reading `name` here would find nothing and quietly produce the same
        // global scope by accident rather than by decision.
        simple(.authorizationManage, .global, [
            "ListGrants",
        ], summary: .heldGrants)
        simple(.authorizationManage, .global, [
            "PreauthorizeEnvelope",
        ], summary: .envelopeRequest)

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

        // google.longrunning.Operations: the asynchronous continuation of calls THIS API
        // starts. The service used to be registered on the server but ABSENT from this
        // map, and the interceptor's service gate sent anything not named here straight to
        // its handler — so five RPCs reached real work with no decision, no record, and
        // (through ListOperations, which takes no filter) a full read of every caller's
        // operation results. An operation's result is desktop-derived content: an element
        // state a wait observed, an observation's record, a macro's output. That is what
        // `operationsManage` names, and it requires consent, because reading another
        // caller's result is a real disclosure even though the resource names carry
        // unguessable UUIDs — unguessable is not a permission model.
        //
        // The reads name `operations/<uuid>` in `name`, which no application grant can
        // narrow to, so they scope global through the same parse-or-global fallback every
        // other opaque reference takes.
        for (method, source, summary) in [
            ("ListOperations", ScopeSource.global, ArgumentSummary.none),
            ("GetOperation", ScopeSource.resourceName, ArgumentSummary.none),
            ("WaitOperation", ScopeSource.resourceName, ArgumentSummary.none),
            ("CancelOperation", ScopeSource.resourceName, ArgumentSummary.none),
            ("DeleteOperation", ScopeSource.resourceName, ArgumentSummary.none),
        ] {
            entries["\(operationsServiceName)/\(method)"] = Entry(
                .operationsManage, source, stream: .unary, summary,
            )
        }

        return entries
    }()

    /// The service that carries the asynchronous operations, and the set of services the
    /// interceptor authorizes. TWO, not one: the map above covers both, and a service the
    /// gate does not name is a service the map cannot protect.
    static let operationsServiceName = "google.longrunning.Operations"
    static let authorizedServiceNames: Set<String> = [serviceName, operationsServiceName]

    static func authorization(forMethod fullyQualifiedName: String) -> Entry? {
        table[fullyQualifiedName]
    }

    /// Every method the descriptor set declares, read at runtime so this cannot drift from
    /// the proto without the tests noticing.
    static func declaredMethods(
        using policy: PublicRequestDescriptorPolicy,
    ) -> Set<String> {
        Set(
            policy.methodInputs.keys.filter { name in
                Self.authorizedServiceNames.contains { name.hasPrefix("\($0)/") }
            },
        )
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
    func applicationTarget(forResourceName _: String) async -> ResolvedApplicationTarget? {
        nil
    }
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

        /// The value as a number, for a repeated ENUM field: those arrive on the wire as
        /// varints and can only be read by the operator through the generated name.
        var number: Double? {
            switch self {
            case let .unsigned(raw): Double(raw)
            case let .double(raw): raw
            case let .boolean(raw): raw ? 1 : 0
            case .text, .nested, .list, .opaque: nil
            }
        }
    }

    /// Repeated ENUM fields, keyed by field name. `modifiers` is the only one in a
    /// request-reachable message in this API, and it is the difference between a summary
    /// that says the operator is being asked to hold command and one that says `[1]`.
    private static let repeatedEnumNames: [String: [UInt64: String]] = [
        "modifiers": enumNames(Exactmac_V1_KeyPress.Modifier.self),
    ]

    private var fields: [String: Value] = [:]

    /// False when the request could NOT be read in full, which is a different fact from
    /// "read, and it has no such field".
    ///
    /// The guard that used to stand here asked for a field named `__absent__`, which no
    /// proto declares and which the normaliser could never produce: keys are
    /// `camelCased(protoName)` or `field<n>`, so the lookup always missed and the
    /// protection was never in force. A summary for an unreadable request therefore
    /// produced affirmative falsehoods — "an empty shell invocation", "the whole screen",
    /// "a macro with nothing recorded" — each of which reads to the operator as a fact
    /// about what they are approving. The flag is set where the walk actually gives up.
    private(set) var isFullyRead: Bool

    init() {
        isFullyRead = true
    }

    init(message: any SwiftProtobuf.Message, policy: PublicRequestDescriptorPolicy) {
        guard let bytes = try? message.serializedData() else {
            isFullyRead = false
            return
        }
        var accumulator = Accumulator()
        let completed = Self.read(
            bytes: bytes,
            messageName: type(of: message).protoMessageName,
            policy: policy,
            into: &accumulator,
        )
        fields = accumulator.finish()
        isFullyRead = completed
    }

    /// Deeper than any message in this API nests, and comfortably inside what `describe()`
    /// will render, so the bound costs nothing real and closes unbounded recursion.
    private static let maximumReadDepth = 32

    /// Repeated fields need somewhere to accumulate, which a dictionary subscript cannot do.
    ///
    /// THE LISTS ARE HELD OUTSIDE `fields`, and that is the whole trick. An array inside an
    /// enum cannot be appended to in place: `case .list(var existing)` copies the buffer,
    /// the append copy-on-writes it back, and every element pays for the whole list. That
    /// made a 96KB request — well under gRPC's 4 MiB default — take nineteen seconds,
    /// quadratically, on the path that runs before any consent decision. The stdlib's
    /// `dictionary[key, default: []].append` is amortised O(1) because the array there has
    /// exactly one owner.
    private struct Accumulator {
        var fields: [String: Value] = [:]
        var lists: [String: [Value]] = [:]
        var didFailToRead = false

        mutating func append(_ name: String, _ value: Value) {
            lists[name, default: []].append(value)
        }

        /// A protobuf field is either repeated or singular, never both, so folding the lists
        /// back in cannot collide with a singular value.
        func finish() -> [String: Value] {
            var merged = fields
            for (name, values) in lists {
                merged[name] = .list(values)
            }
            return merged
        }
    }

    /// - Returns: True when every field in `bytes` was understood. False means the walk
    ///   hit bytes it could not read, and the summary must then SAY SO rather than
    ///   describe a request nobody read.
    ///
    /// The depth is bounded for the same reason `describe()` bounds its own: this runs on
    /// the consent path over a message type the caller chose, and a self-referential one
    /// would otherwise be unbounded recursion chosen by whoever is asking for
    /// authorization. `protoc` rejects recursive message types today, so the reachable
    /// depth is the schema's own, and the cap is the defence rather than the control.
    private static func read(
        bytes: Data,
        messageName: String,
        policy: PublicRequestDescriptorPolicy,
        into accumulator: inout Accumulator,
        depth: Int = 0,
    ) -> Bool {
        guard depth < maximumReadDepth else {
            accumulator.didFailToRead = true
            return false
        }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let tag = readVarint(bytes, &index) else {
                accumulator.didFailToRead = true
                return false
            }
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
                guard let raw = readVarint(bytes, &index) else {
                    accumulator.didFailToRead = true
                    return false
                }
                if descriptor?.isRepeated == true {
                    accumulator.append(name, .unsigned(raw))
                } else {
                    accumulator.fields[name] = .unsigned(raw)
                }
            case 1:
                guard let raw = readFixed64(bytes, &index) else {
                    accumulator.didFailToRead = true
                    return false
                }
                accumulator.fields[name] = descriptor?.wireKind == .fixed64
                    ? .double(Double(bitPattern: raw))
                    : .opaque("8 bytes")
            case 5:
                guard let raw = readFixed32(bytes, &index) else {
                    accumulator.didFailToRead = true
                    return false
                }
                accumulator.fields[name] = .opaque("\(raw) (32-bit)")
            case 2:
                guard let raw = readVarint(bytes, &index) else {
                    accumulator.didFailToRead = true
                    return false
                }
                // A declared length beyond Int.max TRAPS at `Int(raw)`, and the bytes are
                // caller-chosen, so the check is a bound rather than a conversion. This is
                // the same class the numeric summary already fixed: a crash is not the
                // fail-closed deny the invariant requires.
                guard raw <= UInt64(Int.max) else {
                    accumulator.didFailToRead = true
                    return false
                }
                let end = index + Int(raw)
                guard end <= bytes.endIndex else {
                    accumulator.didFailToRead = true
                    return false
                }
                let payload = Data(bytes[index ..< end])
                index = end
                // A PACKED repeated scalar arrives as ONE length-delimited field holding
                // every value, not as one field per value, and protobuf3 does this by
                // default for repeated numeric and enum fields. A reader with only the
                // unpacked path saw the whole list as a single blob of bytes, so the
                // modifiers on a command-click decoded to the single value 0 and the
                // prompt read "with unspecified" — which looks like a malformed request
                // rather than the command-click it is.
                if descriptor?.isRepeated == true, descriptor?.isPackable == true {
                    for value in unpack(payload, wireKind: descriptor?.wireKind ?? .varint) {
                        accumulator.append(name, value)
                    }
                } else if let nestedName = descriptor?.messageName,
                          policy.message(nestedName) != nil
                {
                    var nested = Accumulator()
                    let nestedCompleted = read(
                        bytes: payload,
                        messageName: nestedName,
                        policy: policy,
                        into: &nested,
                        depth: depth + 1,
                    )
                    accumulator.didFailToRead = accumulator.didFailToRead || !nestedCompleted
                    // `finish()`, not `.fields`: a nested message's OWN repeated fields
                    // live in the separate lists dictionary, so reading `.fields` here
                    // silently dropped every repeated field below the top level. That is
                    // an observation's roles, a macro's actions, a click's modifiers and a
                    // compound selector's children — each one a thing the operator is
                    // approving on the strength of.
                    let value = Value.nested(RequestFacts(fields: nested.finish()))
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
                // are not what we think they are, so the walk stops rather than guessing —
                // and says it stopped, so the summary cannot describe a request nobody
                // read as if it were whole.
                accumulator.didFailToRead = true
                return false
            }
        }
        // Nothing was given up on, so the walk read the whole message.
        return !accumulator.didFailToRead
    }

    /// A submessage the parent's walk already read. Its own completeness is not tracked
    /// here: a failure inside it is folded into the TOP-LEVEL accumulator, which is the
    /// only place a summary consults.
    private init(fields: [String: Value]) {
        self.fields = fields
        isFullyRead = true
    }

    /// The values inside one packed repeated field. A truncated tail stops the walk rather
    /// than being read as a value, because a varint cut short by the end of the buffer is
    /// not a number the caller sent.
    private static func unpack(
        _ payload: Data,
        wireKind: PublicRequestDescriptorPolicy.WireKind,
    ) -> [Value] {
        var index = payload.startIndex
        var values: [Value] = []
        switch wireKind {
        case .varint:
            while index < payload.endIndex {
                guard let raw = readVarint(payload, &index) else { break }
                values.append(.unsigned(raw))
            }
        case .fixed64:
            while index < payload.endIndex {
                guard let raw = readFixed64(payload, &index) else { break }
                values.append(.double(Double(bitPattern: raw)))
            }
        case .fixed32:
            while index < payload.endIndex {
                guard let raw = readFixed32(payload, &index) else { break }
                values.append(.opaque("\(raw) (32-bit)"))
            }
        case .lengthDelimited, .group:
            values.append(.opaque("\(payload.count) bytes"))
        }
        return values
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
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }
        return nil
    }

    private static func readFixed64(_ bytes: Data, _ index: inout Data.Index) -> UInt64? {
        let end = index + 8
        guard end <= bytes.endIndex else { return nil }
        var value: UInt64 = 0
        for offset in 0 ..< 8 {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index = end
        return value
    }

    private static func readFixed32(_ bytes: Data, _ index: inout Data.Index) -> UInt64? {
        let end = index + 4
        guard end <= bytes.endIndex else { return nil }
        var value: UInt64 = 0
        for offset in 0 ..< 4 {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index = end
        return value
    }

    // MARK: Accessors

    func has(_ key: String) -> Bool {
        fields[key] != nil
    }

    func text(_ key: String) -> String? {
        switch fields[key] {
        case let .text(value): value
        case let .unsigned(value): String(value)
        case let .boolean(value): value ? "true" : "false"
        case let .double(value): String(value)
        case nil, .nested, .list, .opaque: nil
        }
    }

    func boolean(_ key: String) -> Bool? {
        switch fields[key] {
        case let .boolean(value): value
        case let .unsigned(value): value != 0
        case nil, .text, .double, .nested, .list, .opaque: nil
        }
    }

    func number(_ key: String) -> Double? {
        switch fields[key] {
        case let .unsigned(value): Double(value)
        case let .double(value): value
        case let .boolean(value): value ? 1 : 0
        case nil, .text, .nested, .list, .opaque: nil
        }
    }

    func texts(_ key: String) -> [String] {
        switch fields[key] {
        case let .list(values): values.compactMap { value in
                if case let .text(text) = value {
                    text
                } else {
                    nil
                }
            }
        case let .text(value): [value]
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
        case let .list(values):
            values.compactMap { value in
                guard case let .nested(entry) = value else { return nil }
                let name = entry.text("key") ?? ""
                switch entry.text("value") {
                case let .some(text) where !text.isEmpty: return "\(name): \(text)"
                case .some: return name
                case nil: return entry.describe()
                }
            }
        case let .nested(entry):
            [entry.describe()]
        case let .text(value):
            [value]
        case nil, .unsigned, .double, .boolean, .opaque:
            []
        }
    }

    /// A one-line description of a nested message, for the cases where a map's value is
    /// itself a message.
    ///
    /// IT RECURSES, because a macro action is a oneof of NESTED messages and nothing about
    /// it is scalar: `MacroAction.methodCall` is a `MethodCall` whose own `method` is the
    /// only thing that action will do. A reader that stopped at the first level described
    /// every such action as the empty string, so the prompt showed "action 1:" followed by
    /// nothing while the operator was asked to approve input synthesis on the strength of it.
    ///
    /// The depth is bounded because this walk runs on the consent path over a message type
    /// the CALLER chose, and a self-referential message would otherwise be unbounded work
    /// chosen by whoever is asking for authorization.
    func describe(depth: Int = 0) -> String {
        guard depth < Self.maximumDescriptionDepth else { return "…" }
        var parts: [String] = []
        for key in fields.keys.sorted() {
            switch fields[key] {
            case let .nested(entry):
                let rendered = entry.describe(depth: depth + 1)
                if !rendered.isEmpty {
                    parts.append("\(key): \(rendered)")
                }
            case let .list(values):
                // EVERY element, not only the nested ones. A repeated SCALAR — a held
                // modifier, a set of file paths — is `compactMap`ped to nothing by a
                // nested-only reader, so a macro action summarized as
                // "input: keyPress: key: q" with the command not held, and a clipboard
                // write of two files summarized as "the file paths " followed by nothing.
                // The two payloads the operator most needs to see before approving were the
                // two the reader dropped, and the `files` case dropped the paths
                // altogether: `FilePaths` holds nothing but `repeated string paths`, so the
                // whole message rendered empty.
                let rendered = values.compactMap { value -> String? in
                    switch value {
                    case let .nested(entry):
                        let nested = entry.describe(depth: depth + 1)
                        return nested.isEmpty ? nil : nested
                    case .list, .opaque:
                        return nil
                    default:
                        return Self.repeatedEnumNames[key].flatMap { table in
                            value.number.flatMap { AuthorizationRequestDeriver.enumName($0, table) }
                        } ?? text(key: value)
                    }
                }
                if !rendered.isEmpty {
                    parts.append("\(key): [\(rendered.joined(separator: ", "))]")
                }
            default:
                guard let value = text(key), !value.isEmpty else { continue }
                // The keys are already normalised on the way in.
                parts.append("\(key): \(value)")
            }
        }
        return parts.joined(separator: " ")
    }

    /// One element of a repeated field, as text. Enums and numbers are rendered by the
    /// caller's table where it has one, and as their own text where it does not, so a
    /// repeated enum in a summary the caller has not special-cased still reaches the
    /// operator rather than being dropped.
    private func text(key value: Value) -> String? {
        switch value {
        case let .text(raw): raw.isEmpty ? nil : raw
        case let .unsigned(raw): String(raw)
        case let .double(raw): formatted(raw)
        case let .boolean(raw): raw ? "true" : "false"
        case .nested, .list, .opaque: nil
        }
    }

    private static let maximumDescriptionDepth = 6

    func nested(_ key: String) -> RequestFacts? {
        guard case let .nested(value) = fields[key] else { return nil }
        return value
    }

    /// A repeated message field. A `oneof` with a nested arm and a `repeated` field of
    /// messages look identical on the wire, and a compound selector's children arrive as a
    /// list — which is why reading them as a single nested message found nothing.
    func nestedList(_ key: String) -> [RequestFacts] {
        switch fields[key] {
        case let .list(values): values.compactMap { value in
                guard case let .nested(entry) = value else { return nil }
                return entry
            }
        case let .nested(entry): [entry]
        case nil, .text, .unsigned, .double, .boolean, .opaque: []
        }
    }

    /// A repeated enum field, which arrives as a list of varints rather than strings.
    ///
    /// `texts()` returns nothing for one, so a command-click described itself as
    /// "click at x 420, y 118 … , with " — the operator could not tell a bare click from a
    /// command-click, which are different requests with different consequences.
    func numbers(_ key: String) -> [Double] {
        switch fields[key] {
        case let .list(values):
            values.map { (value: Value) -> Double in
                switch value {
                case let .unsigned(raw): Double(raw)
                case let .double(raw): raw
                case let .boolean(raw): raw ? 1 : 0
                case .text, .nested, .list, .opaque: 0
                }
            }
        case let .unsigned(raw): [Double(raw)]
        case let .double(raw): [raw]
        case nil, .text, .boolean, .nested, .opaque: []
        }
    }

    /// The first non-empty string among `keys`, which is how a resource reference is found
    /// without knowing which of the three conventional fields this request uses.
    func firstText(among keys: [String]) -> (key: String, value: String)? {
        for key in keys {
            if let value = text(key), !value.isEmpty {
                return (key, value)
            }
        }
        return nil
    }
}

/// Every case name of a generated enum, keyed by its raw value.
///
/// A hand-written table of enum values is exactly the kind of table that rots: a value
/// added to the proto would be missing from the prompt and a value renamed would drift.
/// Reading the GENERATED type means neither can happen. `allCases` includes
/// `UNRECOGNIZED(-1)`, and clamping that to zero would let it overwrite the real name of
/// the unspecified value, so it is dropped.
/// A number as the operator should read it.
///
/// A double that is finite but beyond `Int.max` used to go through `Int(_:)`, which
/// TRAPS — and the only numeric gate on these fields accepts anything finite, so
/// `region.x = 1e30` killed the server on the path that gates every other request. A
/// crash is not the fail-closed deny the invariant requires, and a caller with socket
/// access should not be able to take the process down with a number.
func formatted(_ value: Double) -> String {
    guard value.isFinite else { return String(value) }
    let rounded = value.rounded()
    if rounded.magnitude < 9.0e15, rounded == rounded.rounded() {
        return String(Int64(rounded))
    }
    return String(value)
}

func enumNames<Enum: SwiftProtobuf.Enum & CaseIterable & RawRepresentable>(
    _: Enum.Type,
) -> [UInt64: String] where Enum.RawValue == Int {
    var table: [UInt64: String] = [:]
    for value in Enum.allCases {
        let raw = value.rawValue
        guard raw >= 0 else { continue }
        table[UInt64(raw)] = String(describing: value)
    }
    return table
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
            // The APPLICATION name, not the reference that named it. `applications/<sha256>`
            // is what the resolver looks up and what a grant on one process instance is
            // written against; carrying the trailing `/windows/77` made the lookup miss
            // (the catalog is keyed by application), so every resolved request silently
            // degraded to the unresolvable form even when the server knew the answer.
            return .opaqueApplication(resourceName: "\(parts[0])/\(parts[1])", window: window)
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
        // The transaction's declared operation count, which the API does not carry in the
        // request: it lives in the server's own transaction state, so the interceptor
        // supplies it. Without it a transaction is authorized UNBOUNDED, which is the
        // consent-bypass the blueprint names.
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
        // The operation limit is NOT dropped on the global path, which is where
        // `BeginTransaction` lives. A transaction is authorized as a scope with a declared
        // operation count, and returning a scope with no count here authorized an UNBOUNDED
        // transaction while the summary beside it told the operator "up to 12 operations".
        guard source != .global else { return AuthorizationScope(operationLimit: operationLimit) }
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
        case let .opaqueApplication(_, window), let .legacyProcess(_, window):
            window.map(TargetWindow.identifier) ?? .any
        case nil:
            .any
        }
        let application: TargetApplication = switch parsed {
        case let .opaqueApplication(resourceName, _):
            // Resolved, the operator's application-scoped grant can cover this request;
            // unresolved, the scope names the PROCESS INSTANCE, which is narrow and cannot
            // be covered by anything aimed at a different application.
            if let resolved = await resolver.applicationTarget(forResourceName: resourceName) {
                resolved.bundleIdentifier.map { TargetApplication.bundleIdentifier($0) }
                    ?? .processIdentifier(resolved.processIdentifier)
            } else {
                .opaqueApplication(resourceName: resourceName, resolvedBundleIdentifier: nil)
            }
        case let .legacyProcess(processIdentifier, _):
            .processIdentifier(processIdentifier)
        case nil:
            .any
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
        method _: String,
        operationLimit: Int? = nil,
    ) -> String {
        // A request the parser could not read in full must never be described as though it
        // were read. The old guard asked for a field named `__absent__`, which no proto
        // declares and which the normaliser could never produce, so it could never fire
        // and every unreadable request produced an affirmative falsehood instead.
        guard facts.isFullyRead else {
            return "this request could not be read in full; it is shown uninspected"
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
            if let command = facts.text("command") {
                parts.append(command)
            }
            let arguments = facts.texts("args")
            if !arguments.isEmpty {
                parts.append(arguments.joined(separator: " "))
            }
            if let directory = facts.text("workingDirectory"), !directory.isEmpty {
                parts.append("(in \(directory))")
            }
            if let shell = facts.text("shell"), !shell.isEmpty {
                parts.append("via \(shell)")
            }
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
            if let parent = facts.text("parent") {
                parts.append("in \(parent)")
            }
            if let name = facts.text("name") {
                parts.append(name)
            }
            if let element = facts.text("elementId"), !element.isEmpty {
                parts.append(element)
            }
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
            if let value = facts.text("value"), !value.isEmpty {
                parts.append("value \(value)")
            }
            // A right-click and a double-click on the same element are different requests,
            // so the click type is named rather than left in the request.
            if let click = enumName(facts.number("clickType"), elementClickTypeNames) {
                parts.append(click)
            }
            return parts.isEmpty ? "an element with no described target" : parts.joined(separator: " ")
        case .captureRegion:
            var parts: [String] = []
            if let display = facts.text("display"), !display.isEmpty {
                parts.append(display)
            }
            if let window = facts.text("window"), !window.isEmpty {
                parts.append(window)
            }
            if let parent = facts.text("parent"), !parent.isEmpty {
                parts.append(parent)
            }
            if let region = facts.nested("region"),
               let x = region.number("x"), let y = region.number("y"),
               let width = region.number("width"), let height = region.number("height")
            {
                parts.append(
                    "region x \(formatted(x)) y \(formatted(y)) "
                        + "\(formatted(width))x\(formatted(height)) in Global Display Coordinates",
                )
            }
            if let format = enumName(facts.number("format"), imageFormatNames) {
                parts.append(format)
            }
            if let padding = facts.number("padding"), padding > 0 {
                parts.append("with \(formatted(padding))pt padding")
            }
            if facts.boolean("shadowEnabled") == true {
                parts.append("including window shadows")
            }
            if facts.boolean("ocrEnabled") == true {
                parts.append("with OCR")
            }
            if let quality = facts.number("quality") {
                parts.append("quality \(formatted(quality))")
            }
            return parts.isEmpty ? "the whole screen" : parts.joined(separator: ", ")
        case .macroDefinition:
            // The proto spells it `actions`, not `steps`, has no `step_count` at all, and
            // ExecuteMacro's `macro` is a STRING while CreateMacro's is a message. The
            // previous reader looked for fields that do not exist, so every macro
            // summarized to the constant "a macro" and a three-action macro displayed as
            // zero steps — while the operator was asked to approve inputSynthesize and
            // transactionManage on the strength of it.
            var parts: [String] = []
            if let name = facts.text("name"), !name.isEmpty {
                parts.append(name)
            }
            if let reference = facts.text("macro"), !reference.isEmpty {
                parts.append(reference)
            }
            if let macro = facts.nested("macro") {
                let actions = macro.nestedList("actions")
                parts.append("\(actions.count) recorded actions")
                for (index, action) in actions.enumerated() {
                    parts.append("action \(index + 1): \(action.describe())")
                }
            }
            // The parameter values are the macro's arguments, and they are what it will
            // actually type or open.
            let parameters = facts.entries("parameterValues")
            if !parameters.isEmpty {
                parts.append("(\(parameters.joined(separator: ", ")))")
            }
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
        case .heldGrants:
            // The resource alone. The name carries the grant's identity and the caller
            // fetches the rest by it, so repeating the scope here would be a second
            // rendering of the same fact that could disagree with the one the server holds.
            return describeReference(facts)
        case .envelopeRequest:
            // What was ASKED FOR, not what was granted: the prompt shows the ceiling beside
            // it, and an operator comparing the two is the whole point of stating the
            // duration twice.
            let declared = facts.texts("capabilities")
            let lifetime = facts.nested("requestedLifetime")
                .map { "\($0.text("seconds") ?? "?")s" } ?? "unspecified"
            var parts = [
                "a batch of " + (declared.isEmpty ? "unspecified" : declared.joined(separator: ", ")),
                "asked for " + lifetime,
            ]
            if let reason = facts.text("reason"), !reason.isEmpty {
                parts.append("because " + reason)
            }
            return parts.joined(separator: "  ·  ")
        case .fileDialog:
            var parts: [String] = []
            if let application = facts.text("application") {
                parts.append(application)
            }
            if let title = facts.text("title"), !title.isEmpty {
                parts.append("title \(title)")
            }
            // The destination. A save dialog aimed at ~/.ssh/authorized_keys and one aimed
            // at the Desktop are different requests, and the invariant names paths first.
            if let path = facts.text("filePath"), !path.isEmpty {
                parts.append("writing \(path)")
            }
            if let directory = facts.text("defaultDirectory"), !directory.isEmpty {
                parts.append("starting in \(directory)")
            }
            if let filename = facts.text("defaultFilename"), !filename.isEmpty {
                parts.append("naming it \(filename)")
            }
            return parts.isEmpty ? "a file dialog" : parts.joined(separator: ", ")
        case .observationFilter:
            var parts: [String] = []
            if let name = facts.text("name") {
                parts.append(name)
            }
            if let parent = facts.text("parent") {
                parts.append(parent)
            }
            // CreateObservation nests the observation, and the filter inside it. Reading a
            // top-level `filter` found nothing, so the roles an observation would watch
            // and whether it is focus-only were both invisible.
            let filter = facts.nested("filter")
                ?? facts.nested("observation")?.nested("filter")
            if let filter {
                for role in filter.texts("roles") where !role.isEmpty {
                    parts.append("watching \(role)")
                }
                for attribute in filter.texts("attributes") {
                    parts.append("attribute \(attribute)")
                }
                if filter.boolean("focusOnly") == true {
                    parts.append("focused elements only")
                }
                if let kind = filter.text("kind"), !kind.isEmpty {
                    parts.append(kind)
                }
            }
            if let observation = facts.nested("observation") {
                if let name = observation.text("name"), !name.isEmpty {
                    parts.append(name)
                }
            }
            return parts.isEmpty ? "every accessibility change" : parts.joined(separator: ", ")
        }
    }

    /// An `ElementSelector` in words. This is how most element methods name their target,
    /// and reading only the parent left the operator looking at "in applications/4211"
    /// with no idea what was about to be clicked.
    ///
    /// `ElementSelector` is a ONE-OF over `role`, `text`, `text_substring`, `text_regex`,
    /// `position`, `attributes` and `compound`, so a caller naming two criteria uses
    /// `compound` — and the six criteria that were read here and do not exist on the message
    /// (`subrole`, `title`, `value`, `description`, `identifier`, `focusOnly`) returned
    /// nothing at all, which is how a compound selector summarized to a bare parent and
    /// three of the seven arms described nothing.
    private static func describeSelector(_ selector: RequestFacts?) -> String? {
        guard let selector else { return nil }
        var parts: [String] = []
        if let role = selector.text("role"), !role.isEmpty {
            parts.append("role \(role)")
        }
        if let text = selector.text("text"), !text.isEmpty {
            parts.append("with text \"\(text)\"")
        }
        if let substring = selector.text("textSubstring"), !substring.isEmpty {
            parts.append("with text containing \"\(substring)\"")
        }
        if let regex = selector.text("textRegex"), !regex.isEmpty {
            parts.append("with text matching /\(regex)/")
        }
        if let position = selector.nested("position") {
            let x = position.number("x").map(formatted) ?? "unset"
            let y = position.number("y").map(formatted) ?? "unset"
            let tolerance = position.number("tolerance").map(formatted) ?? "0"
            parts.append("at x \(x), y \(y) in Global Display Coordinates within \(tolerance)pt")
        }
        let attributes = selector.entries("attributes")
        if !attributes.isEmpty {
            parts.append("with attributes \(attributes.joined(separator: ", "))")
        }
        if let compound = selector.nested("compound") {
            // A compound selector is the ONLY way to name two criteria, so it is the common
            // case rather than an exotic one, and it nests arbitrarily.
            let raw = compound.number("logicalOperator")
            let rendered = compound.nestedList("selectors").compactMap(describeSelector)
            if !rendered.isEmpty {
                parts.append(
                    "matching \(compoundOperator(raw)) of: \(rendered.joined(separator: " and "))",
                )
            }
        }
        return parts.isEmpty ? nil : "selecting " + parts.joined(separator: ", ")
    }

    /// `OPERATOR_AND` / `OPERATOR_OR` / `OPERATOR_NOT` in words, because the raw number
    /// tells the operator nothing and the generated name is shouty.
    private static func compoundOperator(_ raw: Double?) -> String {
        switch raw {
        case .some(1): "all"
        case .some(2): "any"
        case .some(3): "none"
        default: "an unstated combination"
        }
    }

    // The one arm of `InputAction` that is set, described in words.
    //
    // `InputAction` is a ONE-OF with eight arms, so the earlier reading of `action.x` and
    // `action.text` was reading fields that do not exist on it. Coordinates live under
    // `mouse_click` and `mouse_move`, text under `text_input`, keys under `key_press`.

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
        if content.has("image") {
            return "an image"
        }
        if content.has("files") {
            let files = content.entries("files")
            return files.isEmpty
                ? "a set of file paths"
                : "the file paths \(files.joined(separator: ", "))"
        }
        if let url = content.text("url"), !url.isEmpty {
            return "the URL \(url)"
        }
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
        //
        // A MISSING COMPONENT IS ZERO, not an absent point. `exactmac.type.Point` declares
        // `double x = 1` with implicit presence, so a caller clicking at x 1e30, y 0 puts
        // nothing on the wire for y — and requiring both meant the whole position was
        // dropped, which is how a click summarized to "an input with no described action"
        // and read as a malformed request rather than a click at the top edge.
        func position(_ point: RequestFacts?, _ label: String) {
            guard let point, point.number("x") != nil || point.number("y") != nil else { return }
            let x = point.number("x").map(formatted) ?? "0"
            let y = point.number("y").map(formatted) ?? "0"
            parts.append("\(label) x \(x), y \(y) in Global Display Coordinates")
        }

        // A repeated modifier, named. Read through the GENERATED enum so a new value
        // cannot be missing from the prompt. The generated case for the zero value spells
        // its name `unspecified`, which is a real value here rather than a parse failure.
        func modifiers(_ facts: RequestFacts) {
            let held = facts.numbers("modifiers")
                .compactMap { enumName($0, modifierNames) }
                .filter { $0 != "unspecified" }
            if !held.isEmpty {
                parts.append("with \(held.joined(separator: "+").lowercased())")
            }
        }
        if let click = action.nested("mouseClick") {
            position(click.nested("position"), "click at")
            if let type = enumName(click.number("clickType"), clickTypeNames) {
                parts.append(type)
            }
            if let count = click.number("clickCount"), count > 1 {
                parts.append("x\(formatted(count))")
            }
        }
        if let move = action.nested("mouseMove") {
            position(move.nested("position"), "move to")
        }
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
            modifiers(press)
        }
        if let hover = action.nested("hoverAction") {
            // The seventh arm. It was unhandled, so a hover summarized to "an input with no
            // described action" — which reads as a malformed request rather than a move of
            // the pointer.
            position(hover.nested("position"), "hover at")
        }
        if let click = action.nested("mouseClick") {
            modifiers(click)
        }
        if let drag = action.nested("mouseDrag") {
            if let button = enumName(drag.number("button"), clickTypeNames) {
                parts.append(button)
            }
            let waypoints = drag.entries("waypoints")
            if !waypoints.isEmpty {
                parts.append("through \(waypoints.count) waypoints")
            }
        }
        return parts.isEmpty ? "an input with no described action" : parts.joined(separator: ", ")
    }

    // A double that is finite but beyond `Int.max` used to go through `Int(_:)`, which
    // TRAPS — and the only numeric gate on these fields accepts anything finite, so
    // `region.x = 1e30` killed the server on the path that gates every other request. A
    // crash is not the fail-closed deny the invariant requires, and a caller with socket
    // access should not be able to take the process down with a number.

    /// Enum names are read from the GENERATED Swift types rather than a hand-written
    /// table, so a new value cannot be missing from the prompt and a renamed one cannot
    /// drift. A summary that printed `2` where the operator needs to see `png` would be
    /// worse than no summary.
    static func enumName(_ raw: Double?, _ names: [UInt64: String]) -> String? {
        guard let raw, raw >= 0, let name = names[UInt64(raw)] else { return nil }
        return name
    }

    /// Enum name tables built from the GENERATED types, keyed by raw value, so a value
    /// added to the proto appears in the prompt and a value renamed cannot drift. A
    /// summary that printed `2` where the operator needs to see `png` is worse than no
    /// summary, and a hand-written table of enum values is exactly the kind of table that
    /// rots.
    private static func names<Enum: SwiftProtobuf.Enum & CaseIterable & RawRepresentable>(
        _: Enum.Type,
    ) -> [UInt64: String] where Enum.RawValue == Int {
        enumNames(Enum.self)
    }

    private static let clickTypeNames = names(Exactmac_V1_MouseClick.ClickType.self)
    private static let elementClickTypeNames = names(Exactmac_V1_ClickElementRequest.ClickType.self)
    private static let imageFormatNames = names(Exactmac_V1_ImageFormat.self)
    private static let scriptTypeNames = names(Exactmac_V1_ScriptType.self)
    /// `MouseClick.modifiers` and `KeyPress.modifiers` are the same enum, so a held
    /// command reads the same however it was held.
    private static let modifierNames = names(Exactmac_V1_KeyPress.Modifier.self)

    private static func describeReference(_ facts: RequestFacts) -> String {
        for key in ["name", "parent", "application", "display", "window", "session", "macro"] {
            if let value = facts.text(key), !value.isEmpty {
                return value
            }
        }
        return "no resource named"
    }
}
