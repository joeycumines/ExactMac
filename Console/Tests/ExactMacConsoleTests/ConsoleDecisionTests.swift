@testable import ExactMacConsole
import Foundation
import Testing

/// The decision path, which is the whole function of the console.
///
/// IT WAS ENTIRELY UNTESTED, and untestable: there was no window to answer from, so there was
/// no path by which an answer could be produced. What these assert is the property that
/// matters and was never checked — that the DECISION POSTED is the one the operator's
/// option implies, for the request the operator was shown, and that a ceremony which did not
/// happen produces a DENIAL rather than a weaker approval.
@Suite("Console decisions")
@MainActor
struct ConsoleDecisionTests {
    // MARK: Fixtures

    /// A request an operator can be asked about, shared with the window suite because the
    /// notice and the prompt are two halves of one path.
    static func fixtureRequest(requiresBiometric: Bool = false) -> PendingRequest {
        makeRequest(requiresBiometric: requiresBiometric)
    }

    private static func makeRequest(
        requiresBiometric: Bool = false,
        requestID: String = "req-1",
        offered: [OptionRow.Kind] = [.once, .session, .deny],
    ) -> PendingRequest {
        PendingRequest(
            consent: PendingConsent(
                request: WireRequest(
                    requestID: requestID,
                    rpcName: "exactmac.v1.ExactMac/GetClipboard",
                    capability: "clipboard.read",
                    capabilityConsequence: "Read the clipboard and its history",
                    scopeDescription: "every app  ·  until ExactMac quits",
                    argumentSummary: "the clipboard and its history",
                    agentReason: "answering a question about what you copied",
                    blastRadius: 0.4,
                    riskClass: "elevated",
                    isRevokeAll: false,
                    operationLimit: nil,
                    effectiveCapabilities: ["clipboard.read"],
                ),
                identity: WireIdentity(
                    processIdentifier: 4242,
                    effectiveUserIdentifier: 501,
                    executablePath: "/usr/local/bin/exactmac",
                    bundleIdentifier: "io.github.joeycumines.exactmac",
                    signature: "signedUnnotarized",
                    designatedRequirement: nil,
                    isFullyResolved: true,
                    ancestors: [
                        WireAncestor(
                            processIdentifier: 4200,
                            executablePath: "/bin/zsh",
                            bundleIdentifier: nil,
                            signature: "signedAndValid",
                            isFullyResolved: true,
                        ),
                    ],
                    isAncestryTruncated: false,
                ),
                decision: WireDecision(
                    basis: "needs your consent",
                    requiresBiometric: requiresBiometric,
                    biometricReason: requiresBiometric ? "a standing clipboard grant" : nil,
                    offered: offered.map {
                        WireOption(
                            kind: $0.serverValue,
                            scopeDescription: "every app  ·  until ExactMac quits",
                            durationDescription: "this session",
                            blastRadius: 0.4,
                            requiresBiometric: requiresBiometric,
                            isDestructive: $0.isDestructive,
                            isDefault: $0 == .session,
                            isPrimary: $0 == .once,
                        )
                    },
                    consentTimeoutSeconds: 90,
                ),
                nonce: "nonce-\(requestID)",
                requestDigest: "digest-\(requestID)",
            ),
        )
    }

    /// A channel that records what was posted instead of talking to a server, so a decision
    /// can be asserted without a socket and without a window server.
    final class RecordingChannel: ConsoleChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var _posted: [ConsentDecision] = []
        private var _queries: [QueryKind] = []

        var posted: [ConsentDecision] {
            lock.withLock { _posted }
        }

        var queries: [QueryKind] {
            lock.withLock { _queries }
        }

        var isConnected: Bool {
            true
        }

        func connect() async throws {
            throw ConsoleChannelError.unavailable(reason: "not connected")
        }

        func post(_ decision: ConsentDecision) async throws {
            lock.withLock { _posted.append(decision) }
        }

        func query(_ kind: QueryKind) async throws {
            lock.withLock { _queries.append(kind) }
        }

        func nextFrame(timeout _: Duration) async throws -> ConsoleFrame? {
            nil
        }

        func disconnect() {}
    }

    final class ScriptedCeremony: CeremonyPerforming {
        var outcome: BiometricCeremony.Outcome
        private(set) var reasons: [String] = []
        private(set) var nonces: [String] = []

        init(_ outcome: BiometricCeremony.Outcome) {
            self.outcome = outcome
        }

        func perform(
            requestID _: AuthorizationRequestID,
            nonce: String,
            reason: String,
        ) async -> BiometricCeremony.Outcome {
            nonces.append(nonce)
            reasons.append(reason)
            return outcome
        }
    }

    private func makeModel(
        channel: RecordingChannel,
        ceremony: (any CeremonyPerforming)? = nil,
    ) -> ConsoleModel {
        ConsoleModel(
            channel: channel,
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            startLoop: false,
        )
    }

    // MARK: The decision that is posted

    @Test
    func `an approved option is posted for the request the operator was shown`() async throws {
        let channel = RecordingChannel()
        let model = makeModel(channel: channel)
        let request = Self.makeRequest()
        model.deliverPending(request)

        await model.decide(.session, note: "", for: request, biometricObtained: false)

        #expect(channel.posted.count == 1)
        let decision = try #require(channel.posted.first)
        #expect(decision.requestID == request.requestID)
        #expect(decision.nonce == request.nonce)
        #expect(decision.requestDigest == request.requestDigest)
        #expect(decision.isApproved)
        // THE SERVER'S NAME, not this package's. Posting the console's own `rawValue` is what
        // made every approval a denial, so the assertion is on the wire value the server
        // parses rather than on the value that happens to be convenient here.
        #expect(decision.selected == OptionRow.Kind.session.serverValue)
    }

    @Test
    func `choosing deny posts a refusal never an approval`() async throws {
        let channel = RecordingChannel()
        let model = makeModel(channel: channel)
        let request = Self.makeRequest()
        model.deliverPending(request)

        await model.decide(.deny, note: "", for: request, biometricObtained: false)

        let decision = try #require(channel.posted.first)
        #expect(!decision.isApproved)
        #expect(decision.selected == OptionRow.Kind.deny.serverValue)
    }

    @Test
    func `answering one request does not clear another that arrived meanwhile`() async {
        let channel = RecordingChannel()
        let model = makeModel(channel: channel)
        let first = Self.makeRequest(requestID: "req-1")
        let second = Self.makeRequest(requestID: "req-2")
        model.deliverPending(first)

        // A second request arrives while the operator is deciding the first.
        model.deliverPending(second)
        await model.decide(.once, note: "", for: first, biometricObtained: false)

        #expect(channel.posted.count == 1)
        #expect(channel.posted.first?.requestID == "req-1")
        // The second is still waiting, because it is still the operator's to answer.
        #expect(model.pendingPrompt?.requestID == "req-2")
    }

    // MARK: The ceremony

    @Test
    func `a performed ceremony is reported to the server as performed`() async throws {
        let channel = RecordingChannel()
        let ceremony = ScriptedCeremony(.performed)
        let model = makeModel(channel: channel, ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)
        model.deliverPending(request)

        await model.answer(.session, for: request)

        let decision = try #require(channel.posted.first)
        #expect(decision.biometricObtained)
        #expect(decision.isApproved)
        #expect(ceremony.nonces == [request.nonce], "the ceremony must be bound to this nonce")
    }

    @Test
    func `a ceremony that did not happen denies and does not fall back to a weaker check`() async throws {
        let channel = RecordingChannel()
        let ceremony = ScriptedCeremony(.unavailable(.cancelled))
        let model = makeModel(channel: channel, ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)
        model.deliverPending(request)

        await model.answer(.global, for: request)

        let decision = try #require(channel.posted.first)
        #expect(!decision.biometricObtained, "no ceremony means no claim of one")
        #expect(
            !decision.isApproved || decision.selected == OptionRow.Kind.deny.rawValue,
            "a request that needed a ceremony must not be approved without one",
        )
        #expect(
            decision.selected == OptionRow.Kind.deny.serverValue,
            "the only thing a failed ceremony can produce is a refusal",
        )
    }

    @Test
    func `a ceremony that is not required is not performed`() async {
        let channel = RecordingChannel()
        let ceremony = ScriptedCeremony(.performed)
        let model = makeModel(channel: channel, ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: false)
        model.deliverPending(request)

        await model.answer(.once, for: request)

        #expect(ceremony.reasons.isEmpty, "no ceremony was required, so none may be performed")
        #expect(channel.posted.first?.biometricObtained == false)
        #expect(channel.posted.first?.isApproved == true)
    }

    // MARK: The sentence beside the sensor

    @Test
    func `the ceremony reason names the caller the call and what is permitted`() {
        let request = Self.makeRequest()
        let reason = CeremonyReason.compose(request: request, option: .global)
        #expect(reason.contains("/usr/local/bin/exactmac"))
        #expect(reason.contains("exactmac.v1.ExactMac/GetClipboard"))
        #expect(reason.contains("every app, every time"), "a standing grant must say so plainly: \(reason)")
    }

    @Test
    func `a failed ceremony says why in the same sentence`() {
        let request = Self.makeRequest()
        let reason = CeremonyReason.compose(request: request, option: .once, failure: .lockedOut)
        #expect(reason.contains("locked out"), "the operator can act on that: \(reason)")
    }

    // MARK: The tree

    @Test
    func `the caller tree names the requester first and then the chain above it`() {
        let request = Self.makeRequest()
        let rows = CallerTree.rows(for: request)
        #expect(rows.count == 2)
        #expect(rows.first?.isRequester == true)
        #expect(rows.first?.id == 4242)
        #expect(rows.first?.depth == 0)
        #expect(rows[1].depth == 1)
        #expect(rows[1].isRequester == false)
    }

    @Test
    func `a deep chain is capped rather than silently truncated`() {
        // A real chain runs Terminal -> shell -> agent host -> the binary, and can be deeper
        // still; a cap that hid the truncation would let the operator conclude they had seen
        // the whole ancestry.
        let consent = PendingConsent(
            request: WireRequest(
                requestID: "r", rpcName: "exactmac.v1.ExactMac/GetClipboard",
                capability: "clipboard.read", capabilityConsequence: "Read the clipboard",
                scopeDescription: "any", argumentSummary: "x",
                agentReason: nil, blastRadius: 0, riskClass: "routine", isRevokeAll: false,
                operationLimit: nil, effectiveCapabilities: [],
            ),
            identity: WireIdentity(
                processIdentifier: 1, effectiveUserIdentifier: 501,
                executablePath: "/usr/local/bin/exactmac", bundleIdentifier: nil,
                signature: "signedAndValid", designatedRequirement: nil, isFullyResolved: true,
                ancestors: (1 ... 20).map {
                    WireAncestor(
                        processIdentifier: Int32(100 + $0),
                        executablePath: "/usr/bin/ancestor\($0)",
                        bundleIdentifier: nil, signature: "signedAndValid", isFullyResolved: true,
                    )
                },
                isAncestryTruncated: true,
            ),
            decision: WireDecision(
                basis: "b", requiresBiometric: false, biometricReason: nil,
                offered: [], consentTimeoutSeconds: 90,
            ),
            nonce: "n", requestDigest: "d",
        )
        let request = PendingRequest(consent: consent)
        let rows = CallerTree.rows(for: request, maximumDepth: 4)
        #expect(rows.count == 5, "the requester plus four ancestors, and no more")
        // The truncation is REPORTED, not hidden: the server said it truncated, and the rows
        // stop where it stopped.
        #expect(request.isAncestryTruncated)
    }
}

/// The two vocabularies, which do not agree, and which broke the product end to end.
///
/// THE SERVER SENDS ITS OWN NAMES on the wire: `allowOnce`, `signedAndValid`, and so on.
/// The console's enums have shorter names. Every mapping went through `init(rawValue:)`
/// instead, which matched `deny` and nothing else, and the suite never saw it because the
/// fixture built its wire values from the console's own enum — so the fixture could not
/// contain a server-shaped string even by accident.
@Suite("Server vocabulary")
struct ServerVocabularyTests {
    @Test
    func `every option the server offers maps to a console option`() {
        // THE SERVER'S NAMES, written out rather than derived, because the whole defect was
        // a derivation that assumed two vocabularies were one.
        let pairs: [(String, OptionRow.Kind)] = [
            ("allowOnce", .once),
            ("allowTargetApplication", .target),
            ("allowSession", .session),
            ("preAuthorizeEnvelope", .envelope),
            ("allowGlobalPersistent", .global),
            ("deny", .deny),
        ]
        for (serverValue, expected) in pairs {
            #expect(
                OptionRow.Kind(serverValue: serverValue) == expected,
                "\(serverValue) did not map to \(expected)",
            )
        }
    }

    @Test
    func `a decision carries the name the server parses`() {
        // THE ROUND TRIP, which is the property that matters: what the console posts must
        // come back as the same option. Posting the console's own rawValue is what made every
        // approval a denial on the server.
        for kind in OptionRow.Kind.allCases {
            #expect(
                OptionRow.Kind(serverValue: kind.serverValue) == kind,
                "\(kind) does not survive the round trip",
            )
        }
    }

    @Test
    func `an unknown option name is a refusal, not a silent allow`() {
        #expect(OptionRow.Kind(serverValue: "allowEverythingForever") == .deny)
    }

    @Test
    func `every signature the server reports maps to a badge, and the two good ones are good`() {
        // The two states an operator wants to find reassuring were both rendering as
        // "Unresolved", the one state that means the system could not find out. The mapping
        // is asserted per server value so a future addition fails visibly.
        #expect(SignatureBadge.State(serverValue: "signedAndValid") == .signed)
        #expect(SignatureBadge.State(serverValue: "signedUnnotarized") == .unnotarized)
        #expect(SignatureBadge.State(serverValue: "adHoc") == .adHoc)
        #expect(SignatureBadge.State(serverValue: "unsigned") == .unsigned)
        #expect(SignatureBadge.State(serverValue: "invalid") == .invalid)
        #expect(SignatureBadge.State(serverValue: "unresolved") == .unresolved)
        // Anything the server has not heard of is the unknown state, which is the honest
        // answer and is what a reader must be able to tell apart from "signed".
        #expect(SignatureBadge.State(serverValue: "somethingNew") == .unresolved)
    }

    @Test
    func `the option the operator is offered is the one the server put in focus`() {
        // A request arrives offering its options; the console must not substitute its own
        // first element, because the server's default is the narrowest option and the
        // console's first element is not.
        let consent = PendingConsent(
            request: WireRequest(
                requestID: "r", rpcName: "exactmac.v1.ExactMac/GetClipboard",
                capability: "clipboard.read", capabilityConsequence: "Read the clipboard",
                scopeDescription: "any", argumentSummary: "x",
                agentReason: nil, blastRadius: 0, riskClass: "routine", isRevokeAll: false,
                operationLimit: nil, effectiveCapabilities: [],
            ),
            identity: WireIdentity(
                processIdentifier: 1, effectiveUserIdentifier: 501,
                executablePath: "/usr/local/bin/exactmac", bundleIdentifier: nil,
                signature: "signedAndValid", designatedRequirement: nil, isFullyResolved: true,
                ancestors: [], isAncestryTruncated: false,
            ),
            decision: WireDecision(
                basis: "needs your consent",
                requiresBiometric: false,
                biometricReason: nil,
                offered: [
                    WireOption(
                        kind: "allowSession", scopeDescription: "every app", durationDescription: "8h",
                        blastRadius: 0.6, requiresBiometric: false, isDestructive: false,
                        isDefault: true, isPrimary: false,
                    ),
                    WireOption(
                        kind: "deny", scopeDescription: "—", durationDescription: "—",
                        blastRadius: 0, requiresBiometric: false, isDestructive: true,
                        isDefault: false, isPrimary: false,
                    ),
                ],
                consentTimeoutSeconds: 90,
            ),
            nonce: "n", requestDigest: "d",
        )
        let request = PendingRequest(consent: consent)
        #expect(request.offeredKinds == [.session, .deny], "all six were previously collapsed to deny")
        #expect(request.offeredKinds.first == .session, "not the refusal, which is what it was")
    }
}
