import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

/// The two administrative RPCs that make the consent model usable by an AGENT rather than
/// only by a human.
///
/// Both exist for the same reason: an agent that cannot see what it already holds cannot
/// work inside a grant it was given, so it asks again and spends the operator's attention a
/// second time on something already answered. And an agent that knows it will need the
/// clipboard and the accessibility tree across a refactor should say so ONCE, at the start,
/// rather than interrupting its own work at every step.
enum AuthorizationMethods {
    static let logger = ExactMac.sdkLogger(category: "authorization")

    /// Lists the permissions currently held.
    ///
    /// A GRANT BOUND TO A BINARY IS REPORTED WITH ITS BINDING, because the agent holding it
    /// needs to know that the binding is its code identity and not a process: a restart must
    /// not lose the grant, and a different binary must not inherit it. An unsigned holder is
    /// reported as unsigned rather than quietly presented as equivalent.
    static func listGrants(
        store: GrantStore?,
        filter: String,
        now: MonotonicInstant,
        pageSize: Int,
        skip: Int,
    ) -> (response: Exactmac_V1_ListGrantsResponse, failure: RPCError?) {
        // A store that could not be opened is NOT an empty store. Reporting zero grants
        // would tell an agent it holds nothing when in fact the server cannot tell either,
        // and the agent would ask for everything.
        guard let store else {
            return (.init(), RPCError(
                code: .unavailable,
                message: "grants could not be read; the store is unavailable",
            ))
        }
        var wanted = Set<String>()
        if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for rawToken in filter.split(separator: ",", omittingEmptySubsequences: false) {
                let token = rawToken.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else {
                    return (.init(), RPCError(
                        code: .invalidArgument,
                        message: "filter contains empty capability identifier",
                    ))
                }
                guard Capability(rawValue: token) != nil else {
                    return (.init(), RPCError(
                        code: .invalidArgument,
                        message: "filter contains unknown capability identifier '\(token)'",
                    ))
                }
                wanted.insert(token)
            }
        }
        let matching = store.grantsForDisplay()
            .sorted { $0.id < $1.id }
            .filter { entry in
                wanted.isEmpty || wanted.contains(entry.capability)
            }
        let page = Array(matching.dropFirst(max(0, skip)).prefix(pageSize > 0 ? pageSize : 100))
        var response = Exactmac_V1_ListGrantsResponse()
        response.grants = page.map { entry in wireGrant(entry, now: now) }
        let consumed = max(0, skip) + page.count
        if consumed < matching.count {
            response.nextPageToken = String(consumed)
        }
        return (response, nil)
    }

    /// One grant by name, which the grants manager needs in order to name what it revokes.
    static func getGrant(
        name: String,
        store: GrantStore?,
        now: MonotonicInstant,
    ) throws -> Exactmac_V1_Grant {
        guard let store else {
            throw RPCError(
                code: .unavailable,
                message: "grants could not be read; the store is unavailable",
            )
        }
        guard let identifier = name.split(separator: "/").last.map(String.init),
              let entry = store.grantsForDisplay().first(where: { $0.id == identifier })
        else {
            throw RPCError(code: .notFound, message: "grant not found")
        }
        return wireGrant(entry, now: now)
    }

    private static func wireGrant(
        _ entry: StoredGrant,
        now: MonotonicInstant,
    ) -> Exactmac_V1_Grant {
        var grant = Exactmac_V1_Grant()
        grant.name = "grants/\(entry.id)"
        grant.capability = entry.capability
        // The design's universal metadata delimiter, two spaces each side, so an agent reads
        // a scope the same way the prompt renders one.
        grant.scope = entry.capability + "  ·  " + entry.scope.model().description
            + "  ·  " + entry.originRPCName
        grant.holder = entry.executablePath
        grant.holderDesignatedRequirement = entry.designatedRequirement ?? ""
        grant.holderIsSigned = entry.designatedRequirement != nil
        grant.basis = entry.originEnvelopeIdentifier.map { "envelope:\($0)" } ?? "prompt"
        grant.reason = entry.originArgumentSummary
        // FLOORED at zero, so a caller never sees a grant claim to have more life than it
        // does — which for an expired grant is the difference between "expires now" and
        // "expires in -4 seconds".
        let deadline = MonotonicInstant(nanoseconds: entry.expiresAtNanoseconds)
        let seconds = now.remaining(until: deadline).map { max(0, $0.components.seconds) } ?? 0
        grant.lifetime = SwiftProtobuf.Google_Protobuf_Duration(seconds: Int64(seconds))
        return grant
    }

    /// Validates a pre-authorization BEFORE anyone is interrupted, because an envelope that
    /// is stored and then refused is one the operator was told they had.
    static func validatePreauthorization(
        reason: String,
        capabilities: [String],
        requestedSeconds: Int,
        maximumSeconds: Int,
    ) -> RPCError? {
        // A REASON IS REQUIRED, and the refusal says why in the product's words rather than
        // naming a missing field, because this is the one request where an unexplained ask is
        // a standing permission nobody can account for.
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return RPCError(
                code: .invalidArgument,
                message: "reason is required: a pre-authorization is a standing permission, "
                    + "and the operator is entitled to know why it is being asked for",
            )
        }
        guard !capabilities.isEmpty else {
            return RPCError(
                code: .invalidArgument,
                message: "capabilities is required: an envelope must declare what it covers",
            )
        }
        // An UNKNOWN capability is refused rather than ignored. Accepting one and quietly
        // covering less than the agent asked for would leave the agent believing it holds
        // something it does not.
        for capability in capabilities where Capability(rawValue: capability) == nil {
            return RPCError(
                code: .invalidArgument,
                message: "unknown capability \(capability); an envelope cannot cover a "
                    + "capability this API does not have",
            )
        }
        guard requestedSeconds > 0 else {
            return RPCError(
                code: .invalidArgument,
                message: "requested_lifetime must be positive; an envelope that expires "
                    + "immediately is not pre-authorization",
            )
        }
        guard requestedSeconds <= maximumSeconds else {
            return RPCError(
                code: .invalidArgument,
                message: "requested_lifetime of \(requestedSeconds)s exceeds the maximum of "
                    + "\(maximumSeconds)s; an envelope may not outlive the session that "
                    + "justified it",
            )
        }
        return nil
    }

    /// The identity a pre-authorization is judged against.
    ///
    /// UNRESOLVED, deliberately. The batch arrives from the Go layer over the same socket
    /// as every other request, and the engine resolves the caller the same way it always
    /// does; until that evidence is available this says so rather than claiming an identity
    /// nobody has checked, and an unresolved caller is escalated rather than trusted.
    static let unresolvedIdentity = CallerIdentity(
        processIdentifier: 0,
        effectiveUserIdentifier: 0,
        parentProcessIdentifier: nil,
        code: CodeIdentity(
            executablePath: "<pre-authorization>",
            bundleIdentifier: nil,
            designatedRequirement: nil,
            signature: .unresolved,
        ),
        isFullyResolved: false,
    )

    /// The decision the engine produces for a batch, which the operator then answers.
    ///
    /// THE ENGINE SCORES THE REQUEST, not a duration: the durations belong to the options
    /// the operator chooses, and each of those is scored with its own. The ceiling therefore
    /// has exactly one home — the boundary check above — and this is the same decision a
    /// single request would produce, so the two cannot drift apart.
    static func envelopeDecision(
        capabilities: [String],
    ) -> AuthorizationDecision {
        AuthorizationPolicy.evaluate(
            request: envelopeRequest(capabilities: capabilities),
            identity: unresolvedIdentity,
            grants: [],
            envelopes: [],
            posture: .balanced,
            context: .unixSocket(),
            now: MonotonicInstant(nanoseconds: 0),
        )
    }

    /// The request the engine sees for a batch.
    ///
    /// A REAL request rather than a special case, so the envelope's options are the same
    /// options a single request would be offered. A parallel path for envelopes is how the
    /// two drift apart, and the drift would be invisible until an operator approved a batch
    /// on terms no single request would get.
    static func envelopeRequest(capabilities: [String]) -> AuthorizationRequest {
        AuthorizationRequest(
            id: AuthorizationRequestID(rawValue: "envelope-\(UUID().uuidString)"),
            rpcName: "exactmac.v1.ExactMac/PreauthorizeEnvelope",
            // The FIRST declared capability, and the engine closes over implication from
            // there, so a batch is only as safe as the most powerful thing in it.
            capability: capabilities.compactMap(Capability.init(rawValue:)).first ?? .localEcho,
            // The broadest declared scope, because the prompt must show what the WHOLE batch
            // would permit before the operator narrows any of it.
            scope: AuthorizationScope(application: .any),
            argumentSummary: capabilities.joined(separator: "  ·  "),
            agentReason: nil,
            origin: .mcpProxy,
        )
    }
}

extension ExactMacService {
    /// The service methods, thin on purpose: every decision they make is in
    /// `AuthorizationMethods` above and every decision THAT makes is in the engine, so the
    /// RPC layer has no policy of its own to drift.
    func listGrants(
        request: ServerRequest<Exactmac_V1_ListGrantsRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_ListGrantsResponse> {
        Self.logger.info("listGrants called")
        let req = request.message
        let (response, failure) = try AuthorizationMethods.listGrants(
            store: self.grantStore,
            filter: req.filter,
            now: SystemMonotonicClock().now(),
            pageSize: RequestNumericValidation.pageSize(req.pageSize, default: 100),
            skip: RequestNumericValidation.skip(req.skip),
        )
        if let failure {
            throw failure
        }
        return ServerResponse(message: response)
    }

    func getGrant(
        request: ServerRequest<Exactmac_V1_GetGrantRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_Grant> {
        Self.logger.info("getGrant called")
        let grant = try AuthorizationMethods.getGrant(
            name: request.message.name,
            store: self.grantStore,
            now: SystemMonotonicClock().now(),
        )
        return ServerResponse(message: grant)
    }

    func preauthorizeEnvelope(
        request: ServerRequest<Exactmac_V1_PreauthorizeEnvelopeRequest>, context _: ServerContext,
    ) async throws -> ServerResponse<Exactmac_V1_PreauthorizeEnvelopeResponse> {
        Self.logger.info("preauthorizeEnvelope called")
        let req = request.message
        let asked = Int(req.requestedLifetime.seconds)
        // VALIDATED BEFORE ANYONE IS INTERRUPTED. An envelope that is stored and then
        // refused is one the operator was told they had.
        if let failure = AuthorizationMethods.validatePreauthorization(
            reason: req.reason,
            capabilities: req.capabilities,
            requestedSeconds: asked,
            maximumSeconds: self.maximumEnvelopeSeconds,
        ) {
            throw failure
        }
        // And then the engine decides, because the engine is where the policy lives.
        //
        // With no operator to ask the handler returns nil, which is a refusal: a prompt
        // nobody answered has not been consented to, and a refusal is the correct outcome
        // rather than an envelope nobody approved.
        guard let consent = self.consent else {
            throw RPCError(
                code: .failedPrecondition,
                message: "no operator interface is present, so no envelope can be "
                    + "granted; nothing has been authorized",
            )
        }
        let decision = AuthorizationMethods.envelopeDecision(capabilities: req.capabilities)
        let granted = await consent(
            AuthorizationMethods.envelopeRequest(capabilities: req.capabilities),
            AuthorizationMethods.unresolvedIdentity,
            decision,
        )
        guard let granted, granted.isApproved else {
            throw RPCError(
                code: .permissionDenied,
                message: "the pre-authorization was not granted; nothing has been authorized",
            )
        }
        // What the agent is told is the life GRANTED — the server's ceiling applied — and
        // the fact that the envelope is not global, which is a property of the type and not
        // a promise.
        let capped = min(max(1, asked), self.maximumEnvelopeSeconds)
        var envelope = Exactmac_V1_PreauthorizeEnvelopeResponse()
        envelope.id = granted.requestID.rawValue
        envelope.capabilities = req.capabilities
        envelope.scopes = req.scopes
        envelope.lifetime = SwiftProtobuf.Google_Protobuf_Duration(seconds: Int64(capped))
        envelope.expiryTime = SwiftProtobuf.Google_Protobuf_Timestamp(
            date: Date().addingTimeInterval(TimeInterval(capped)),
        )
        envelope.globalPersistent = false
        envelope.reason = req.reason
        return ServerResponse(message: envelope)
    }
}
