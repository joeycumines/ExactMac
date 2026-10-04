@testable import ExactMacConsole
@testable import ExactMacServer
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

    /// A request an operator can be asked about, built from the SERVER'S OWN TYPES.
    ///
    /// The `offered` parameter is the console's own `OptionRow.Kind` because the tests
    /// choose options by the label the operator sees, and it is mapped to the engine's
    /// `OfferedDecision.Kind` on the way in — so a test that picks `.session` is picking the
    /// option the engine actually offered, not a string that happens to look like one.
    private static func makeRequest(
        requiresBiometric: Bool = false,
        requestID: String = "req-1",
        offered: [OptionRow.Kind] = [.once, .session, .deny],
    ) -> PendingRequest {
        let (req, identity, decision) = ServerFixture.request(requestID: requestID)
        return PendingRequest(
            request: req,
            identity: identity,
            decision: AuthorizationDecision(
                outcome: .deny,
                basis: .promptRequired,
                effectiveCapabilities: decision.effectiveCapabilities,
                blastRadius: decision.blastRadius,
                riskClass: decision.riskClass,
                biometric: requiresBiometric
                    ? .required(reason: "a standing clipboard grant")
                    : .notRequired,
                offeredDecisions: decision.offeredDecisions.filter {
                    offered.map(\.serverValue).contains($0.kind.rawValue)
                },
                expiresAt: nil,
            ),
        )
    }

    final class ScriptedCeremony: CeremonyPerforming {
        var outcome: BiometricCeremony.Outcome
        private(set) var reasons: [String] = []
        private(set) var nonces: [String] = []

        init(_ outcome: BiometricCeremony.Outcome) {
            self.outcome = outcome
        }

        func perform(
            nonce: String,
            reason: String,
        ) async -> BiometricCeremony.Outcome {
            nonces.append(nonce)
            reasons.append(reason)
            return outcome
        }
    }

    private func makeModel(
        ceremony: (any CeremonyPerforming)? = nil,
    ) -> ConsoleModel {
        ConsoleModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
        )
    }

    // MARK: The answer that is produced

    @Test
    func `an approved option produces an answer for the request the operator was shown`() async {
        // IT USED TO ASSERT WHAT WAS POSTED, because the answer travelled over a socket. The
        // operator interface is in this process, so the answer is RETURNED — and the binding
        // it asserts is the same one, on a value the server receives directly.
        let model = makeModel()
        let request = Self.makeRequest()

        let answer = await model.answerValue(.session, for: request)

        #expect(answer.requestID == request.requestID)
        #expect(answer.nonce == request.nonce)
        #expect(answer.requestDigest == request.requestDigest)
        #expect(answer.isApproved)
        #expect(answer.kind == .session)
    }

    @Test
    func `choosing deny produces a refusal and never an approval`() async {
        let model = makeModel()
        let request = Self.makeRequest()

        let answer = await model.answerValue(.deny, for: request)

        #expect(!answer.isApproved)
        #expect(answer.refusal == .operatorDeclined)
    }

    @Test
    func `answering one request does not clear another that arrived meanwhile`() async {
        let model = makeModel()
        let first = Self.makeRequest(requestID: "req-1")
        let second = Self.makeRequest(requestID: "req-2")
        model.deliverPending(first)

        // A second request arrives while the operator is deciding the first.
        model.deliverPending(second)
        _ = await model.answerValue(.once, for: first)

        // The answer belongs to the FIRST request, because that is the one the operator was
        // shown and the one the answer is bound to.
        #expect(model.pendingPrompt?.requestID == "req-2", "the second is still the operator's to answer")
    }

    @Test
    func `cancelling the answer wait dismisses the approval window and clears pending state`() async {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(presentation: .application, windows: windows)
        let (req, identity, decision) = ServerFixture.request(requestID: "req-cancel-1")

        let answerTask = Task {
            await model.answer(
                request: req,
                identity: identity,
                decision: decision,
            )
        }

        for _ in 0 ..< 50 {
            if model.pendingPrompt != nil {
                break
            }
            await Task.yield()
        }

        #expect(model.pendingPrompt?.requestID == "req-cancel-1")
        #expect(model.pendingNotice != nil)
        #expect(windows.isPresented(.approval))
        #expect(model.serviceState == .pending)

        answerTask.cancel()
        let answer = await answerTask.value

        #expect(answer == nil)
        #expect(model.pendingPrompt == nil)
        #expect(model.pendingNotice == nil)
        #expect(!windows.isPresented(.approval))
        #expect(model.serviceState == .running)
    }

    // MARK: The ceremony

    @Test
    func `a performed ceremony is reported to the server as performed`() async {
        let ceremony = ScriptedCeremony(.performed)
        let model = makeModel(ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)
        model.deliverPending(request)

        // THE ANSWER, NOT THE POST. It used to be read off `channel.posted`, because the
        // answer travelled to a socket. The operator interface is hosted in this process, so
        // the answer is RETURNED to the server that asked, and there is no frame to inspect.
        let answer = await model.answerValue(.session, for: request)

        #expect(answer.biometricObtained)
        #expect(answer.isApproved)
        #expect(ceremony.nonces == [request.nonce], "the ceremony must be bound to this nonce")
    }

    @Test
    func `a ceremony that did not happen denies and does not fall back to a weaker check`() async {
        let ceremony = ScriptedCeremony(.unavailable(.cancelled))
        let model = makeModel(ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)
        model.deliverPending(request)

        let answer = await model.answerValue(.global, for: request)

        #expect(!answer.biometricObtained, "no ceremony means no claim of one")
        #expect(
            !answer.isApproved,
            "a request that needed a ceremony must not be approved without one",
        )
        #expect(
            answer.kind == .deny,
            "the only thing a failed ceremony can produce is a refusal",
        )
    }

    @Test
    func `a ceremony that is not required is not performed`() async {
        let ceremony = ScriptedCeremony(.performed)
        let model = makeModel(ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: false)
        model.deliverPending(request)

        let answer = await model.answerValue(.once, for: request)

        #expect(ceremony.reasons.isEmpty, "no ceremony was required, so none may be performed")
        #expect(!answer.biometricObtained)
        #expect(answer.isApproved)
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
        let (req, _, decision) = ServerFixture.request(requestID: "r")
        let request = PendingRequest(
            request: req,
            identity: ServerFixture.identity(
                isAncestryTruncated: true,
                ancestors: (1 ... 20).map {
                    ResolvedProcess(
                        processIdentifier: Int32(100 + $0),
                        parentProcessIdentifier: nil,
                        code: CodeIdentity(
                            executablePath: "/usr/bin/ancestor\($0)",
                            bundleIdentifier: nil,
                            designatedRequirement: nil,
                            signature: .signedAndValid,
                        ),
                        isFullyResolved: true,
                    )
                },
            ),
            decision: decision,
        )
        let rows = CallerTree.rows(for: request, maximumDepth: 4)
        #expect(rows.count == 5, "the requester plus four ancestors, and no more")
        // The truncation is REPORTED, not hidden: the server said it truncated, and the rows
        // stop where it stopped.
        #expect(request.isAncestryTruncated)
    }

    // MARK: The answer as a value, which is what a direct caller receives

    /// THE DIMENSION THAT IS NEW NOW, and the one the server that ASKS will consume.
    ///
    /// Everything above asserts the decision that was POSTED, which is what a transport
    /// receives. The operator interface is now hosted in this process, so the thing a caller
    /// receives is a returned value instead — and a returned value has properties a posted
    /// one does not. It must be answerable without a channel, and it must be able to say
    /// WHICH refusal it is, because "the operator said no" and "the operator could not be
    /// asked" are different events that a caller logs differently and recovers from
    /// differently.
    @Test
    func `an answer is produced without posting anything`() async {
        let model = makeModel()
        let request = Self.makeRequest()

        let answer = await model.answerValue(.session, for: request)

        #expect(answer.isApproved)
        #expect(answer.kind == .session)
    }

    @Test
    func `an answer carries the request it answers`() async {
        let model = makeModel()
        let request = Self.makeRequest(requestID: "req-bound")

        let answer = await model.answerValue(.once, for: request)

        // Binding, asserted on the value rather than on the post: a returned answer is only
        // an answer to something, and a server applying it to a different request is the
        // confused deputy in its narrowest form.
        #expect(answer.requestID == request.requestID)
        #expect(answer.nonce == request.nonce)
        #expect(answer.requestDigest == request.requestDigest)
    }

    @Test
    func `a declined answer and an unobtainable one are distinguishable`() async {
        let model = makeModel()

        let declined = await model.answerValue(.deny, for: Self.makeRequest(requestID: "a"))
        #expect(!declined.isApproved)
        #expect(declined.refusal == .operatorDeclined)

        // A request that REQUIRED a ceremony, answered with no ceremony installed. The
        // operator chose to allow, so this is not their refusal, and saying otherwise would
        // tell a caller the wrong thing about why nothing was granted.
        let blocked = await model.answerValue(
            .session,
            for: Self.makeRequest(requiresBiometric: true, requestID: "b"),
        )
        #expect(!blocked.isApproved)
        #expect(blocked.refusal == .ceremonyRefused)
    }

    @Test
    func `a ceremony that did not happen refuses rather than approving`() async {
        let ceremony = ScriptedCeremony(.unavailable(.lockedOut))
        let model = makeModel(ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)

        // The operator chose to ALLOW, and the answer is a refusal. That is the whole
        // invariant: a failed ceremony is not a weaker approval, it is a denial.
        let answer = await model.answerValue(.session, for: request)

        #expect(!answer.isApproved)
        #expect(answer.kind == .deny)
        #expect(answer.refusal == .ceremonyRefused)
        #expect(!answer.biometricObtained)
    }

    @Test
    func `a required ceremony that cannot be performed denies rather than approving`() async {
        // THE SILENT DOWNGRADE, CLOSED. A request that asks for a biometric, answered with
        // no ceremony installed, used to return the operator's chosen ALLOW carrying
        // `biometricObtained: false` — an approval for a check that never happened, on
        // precisely the requests that demanded one. In the old world it was invisible
        // because the posted decision carried the same flag as an honest non-biometric
        // approval. A returned answer makes the difference legible, which is the point of
        // having one.
        let model = makeModel(ceremony: nil)
        let request = Self.makeRequest(requiresBiometric: true)

        let answer = await model.answerValue(.session, for: request)

        #expect(!answer.isApproved, "an approval for a check that did not happen is a downgrade")
        #expect(answer.kind == .deny)
        #expect(answer.refusal == .ceremonyRefused)
        #expect(!answer.biometricObtained)
    }

    @Test
    func `a performed ceremony is reported on the returned answer`() async {
        let ceremony = ScriptedCeremony(.performed)
        let model = makeModel(ceremony: ceremony)
        let request = Self.makeRequest(requiresBiometric: true)

        let answer = await model.answerValue(.session, for: request)

        #expect(answer.biometricObtained)
        #expect(answer.isApproved)
        #expect(ceremony.nonces == [request.nonce])
    }

    @Test
    func `approval is derived from the option, so the two cannot disagree`() async {
        let model = makeModel()

        // A deny option must never yield an approved answer, whatever else is set. The value
        // derives one from the other rather than storing both, because a stored pair is a
        // pair that can contradict itself.
        let allowing: [OptionRow.Kind] = [.once, .target, .session, .envelope, .global]
        for kind in allowing {
            let answer = await model.answerValue(kind, for: Self.makeRequest(requestID: kind.serverValue))
            #expect(answer.isApproved, "\(kind.serverValue) should be an approval")
            #expect(answer.refusal == nil)
        }
        let denied = await model.answerValue(.deny, for: Self.makeRequest())
        #expect(!denied.isApproved)
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
        let (req, identity, _) = ServerFixture.request(requestID: "r")
        let request = PendingRequest(
            request: req,
            identity: identity,
            decision: ServerFixture.decision(
                offered: [.allowSession, .deny],
            ),
        )
        #expect(request.offeredKinds == [.session, .deny], "all six were previously collapsed to deny")
        #expect(request.offeredKinds.first == .session, "not the refusal, which is what it was")
    }

    // MARK: - Concurrency and Queueing (E32)

    @Test
    @MainActor
    func `two concurrent consent requests are queued and both resolved sequentially`() async throws {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(presentation: .application, windows: windows)
        let (req1, id1, dec1) = ServerFixture.request(requestID: "req-queue-1")
        let (req2, id2, dec2) = ServerFixture.request(requestID: "req-queue-2")

        let task1 = Task { @MainActor in
            await model.answer(request: req1, identity: id1, decision: dec1)
        }
        for _ in 0 ..< 50 {
            if model.pendingPrompt != nil {
                break
            }
            await Task.yield()
        }

        #expect(model.pendingPrompt?.requestID == "req-queue-1")
        #expect(model.queuedRequests.isEmpty)
        #expect(model.waitingCount == 1)

        let task2 = Task { @MainActor in
            await model.answer(request: req2, identity: id2, decision: dec2)
        }
        for _ in 0 ..< 50 {
            if !model.queuedRequests.isEmpty {
                break
            }
            await Task.yield()
        }

        #expect(model.pendingPrompt?.requestID == "req-queue-1")
        #expect(model.queuedRequests.count == 1)
        #expect(model.queuedRequests.first?.requestID == "req-queue-2")
        #expect(model.waitingCount == 2)
        #expect(model.blockedBy["req-queue-2"] != nil)

        // Answer Request 1
        try await model.answer(.once, for: #require(model.pendingPrompt))
        let answer1 = await task1.value

        #expect(answer1?.isApproved == true)
        #expect(answer1?.requestID == "req-queue-1")

        // Request 2 is promoted to active prompt
        #expect(model.pendingPrompt?.requestID == "req-queue-2")
        #expect(model.queuedRequests.isEmpty)
        #expect(model.waitingCount == 1)
        #expect(windows.isPresented(.approval) == true)

        // Answer Request 2
        try await model.answer(.session, for: #require(model.pendingPrompt))
        let answer2 = await task2.value

        #expect(answer2?.isApproved == true)
        #expect(answer2?.requestID == "req-queue-2")
        #expect(model.pendingPrompt == nil)
        #expect(model.waitingCount == 0)
        #expect(windows.isPresented(.approval) == false)
        #expect(model.serviceState == .running)
    }

    @Test
    @MainActor
    func `queued request cancelled while waiting leaves active prompt intact`() async throws {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(presentation: .application, windows: windows)
        let (req1, id1, dec1) = ServerFixture.request(requestID: "req-cancel-q-1")
        let (req2, id2, dec2) = ServerFixture.request(requestID: "req-cancel-q-2")

        let task1 = Task { @MainActor in
            await model.answer(request: req1, identity: id1, decision: dec1)
        }
        for _ in 0 ..< 50 {
            if model.pendingPrompt != nil {
                break
            }
            await Task.yield()
        }

        let task2 = Task { @MainActor in
            await model.answer(request: req2, identity: id2, decision: dec2)
        }
        for _ in 0 ..< 50 {
            if !model.queuedRequests.isEmpty {
                break
            }
            await Task.yield()
        }

        #expect(model.queuedRequests.count == 1)

        // Cancel Request 2 while in queue
        task2.cancel()
        let answer2 = await task2.value

        #expect(answer2 == nil)
        #expect(model.pendingPrompt?.requestID == "req-cancel-q-1")
        #expect(model.queuedRequests.isEmpty)
        #expect(model.waitingCount == 1)
        #expect(windows.isPresented(.approval) == true)

        // Request 1 can still be answered normally
        try await model.answer(.once, for: #require(model.pendingPrompt))
        let answer1 = await task1.value

        #expect(answer1?.isApproved == true)
        #expect(model.pendingPrompt == nil)
        #expect(windows.isPresented(.approval) == false)
    }

    @Test
    @MainActor
    func `active prompt cancelled promotes next queued request immediately`() async throws {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(presentation: .application, windows: windows)
        let (req1, id1, dec1) = ServerFixture.request(requestID: "req-cancel-act-1")
        let (req2, id2, dec2) = ServerFixture.request(requestID: "req-cancel-act-2")

        let task1 = Task { @MainActor in
            await model.answer(request: req1, identity: id1, decision: dec1)
        }
        for _ in 0 ..< 50 {
            if model.pendingPrompt != nil {
                break
            }
            await Task.yield()
        }

        let task2 = Task { @MainActor in
            await model.answer(request: req2, identity: id2, decision: dec2)
        }
        for _ in 0 ..< 50 {
            if !model.queuedRequests.isEmpty {
                break
            }
            await Task.yield()
        }

        // Cancel Request 1 (the active prompt)
        task1.cancel()
        let answer1 = await task1.value

        #expect(answer1 == nil)

        // Request 2 should immediately become active prompt
        #expect(model.pendingPrompt?.requestID == "req-cancel-act-2")
        #expect(model.queuedRequests.isEmpty)
        #expect(model.waitingCount == 1)
        #expect(windows.isPresented(.approval) == true)

        // Request 2 is answered
        try await model.answer(.once, for: #require(model.pendingPrompt))
        let answer2 = await task2.value

        #expect(answer2?.isApproved == true)
        #expect(model.pendingPrompt == nil)
        #expect(windows.isPresented(.approval) == false)
    }

    @Test
    @MainActor
    func `queued request timeout records notice naming what timed out and what blocked it`() async throws {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(presentation: .application, windows: windows)
        let (req1, id1, dec1) = ServerFixture.request(requestID: "req-blocker")
        let (req2, id2, dec2) = ServerFixture.request(requestID: "req-blocked")

        let task1 = Task { @MainActor in
            await model.answer(request: req1, identity: id1, decision: dec1)
        }
        for _ in 0 ..< 50 {
            if model.pendingPrompt != nil {
                break
            }
            await Task.yield()
        }

        let task2 = Task { @MainActor in
            await model.answer(request: req2, identity: id2, decision: dec2)
        }
        for _ in 0 ..< 50 {
            if !model.queuedRequests.isEmpty {
                break
            }
            await Task.yield()
        }

        #expect(model.queuedRequests.count == 1)
        let blockerTitle = model.pendingPrompt?.promptTitle ?? ""
        #expect(!blockerTitle.isEmpty)

        // Cancel/timeout Request 2 while in queue
        task2.cancel()
        let answer2 = await task2.value
        #expect(answer2 == nil)

        // Operator answers Request 1
        try await model.answer(.once, for: #require(model.pendingPrompt))
        _ = await task1.value

        // Prompt is gone, and the operator sees the notice explaining that a request timed out behind the blocker
        #expect(model.pendingPrompt == nil)
        #expect(model.pendingNotice != nil)
        #expect(model.pendingNotice?.contains("timed out while waiting behind") == true)
        #expect(model.pendingNotice?.contains(blockerTitle) == true)
    }
}
