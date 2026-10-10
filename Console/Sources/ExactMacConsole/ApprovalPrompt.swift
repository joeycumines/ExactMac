import ExactMacServer
import SwiftUI

/// One process in the caller's ancestry.
///
/// The design walks FOUR levels before reaching the requester — Terminal, zsh, opencode,
/// exactmac — and that traversal is the point: the operator is consenting to something an
/// agent asked, not to something a binary asked. The socket peer is the LAST row.
///
/// THREE SIGNALS mark the requester and nothing else does: an accent marker, a semibold
/// label, and accent ink on the role. The ink is already at maximum on the agent row, so the
/// promotion is weight and marker colour — deliberately, because more colour on the same row
/// would be the same information twice.
///
/// Indentation is 20pt per level, expressed as leading padding. The 1pt guide ticks are
/// optional at 1x on a Retina panel and the tree still reads without them, so they are
/// drawn but carry no information.
struct CallerTree: View {
    struct Row: Identifiable, Equatable {
        let id: Int32
        let name: String
        let role: String
        let depth: Int
        let signature: SignatureBadge.State
        let isRequester: Bool
    }

    let rows: [Row]

    /// The tree for a pending request: the caller first, then the chain above it.
    /// /// THE REQUESTER IS THE FIRST ROW AND NOT THE LAST, because the operator is consenting to
    /// something an AGENT asked for. The thing that wants the capability is the thing the
    /// prompt is about; its ancestors are context for judging it. A tree that started at the
    /// login window would bury the one row that matters.
    /// /// DEPTH IS CAPPED, and the cap is reported by the caller rather than hidden here,
    /// because a silently truncated ancestry reads as a complete one — the operator would
    /// conclude they had seen everything when they had not.
    static func rows(for request: PendingRequest, maximumDepth: Int = 6) -> [Row] {
        var rows = [Row(
            id: request.processIdentifier,
            name: request.executablePath,
            // NOT "wants \(request.capability)". It was, and the capability now appears on
            // the prompt's own scope line directly above, so the tree said it a third time —
            // in the one place with no room, which ellipsised it to "wants observatio….".
            // The row says who is asking; the line above says what for.
            role: "asking for this",
            depth: 0,
            signature: request.signature,
            isRequester: true,
        )]
        for (index, ancestor) in request.ancestors.enumerated() {
            guard index < maximumDepth else { break }
            rows.append(Row(
                id: ancestor.processIdentifier,
                name: ancestor.executablePath,
                role: ancestorRole(for: ancestor),
                depth: index + 1,
                signature: ancestor.signature,
                isRequester: false,
            ))
        }
        if request.ancestors.count > maximumDepth {
            let remaining = request.ancestors.count - maximumDepth
            rows.append(Row(
                id: -1,
                name: "+\(remaining) more ancestors",
                role: "ancestry capped",
                depth: maximumDepth + 1,
                signature: .unresolved,
                isRequester: false,
            ))
        }
        return rows
    }

    /// What an ancestor's row says about it: "unresolved" is a fact about the evidence and is
    /// said, because a row that read like every other row would claim more than is known.
    private static func ancestorRole(for ancestor: PendingRequest.Ancestor) -> String {
        ancestor.isFullyResolved ? "started it" : "unresolved · started it"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: Design.Space.leading) {
                    if row.depth > 0 {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Design.Ink.separator)
                            .frame(width: 1, height: 18)
                            .padding(.top, 2)
                    }
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(row.isRequester ? Design.Ink.accent : Design.Ink.separator)
                        .frame(width: 3, height: 16)
                        .padding(.top, 2)
                    // The name and the role are separated by the design's own delimiter.
                    Text(Design.joined([row.name, row.role]))
                        .font(.system(size: 12, weight: row.isRequester ? .semibold : .regular))
                        .foregroundStyle(Design.Ink.textPrimary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Design.Space.leading)
                    SignatureBadge(state: row.signature)
                        .padding(.top, 1)
                }
                .padding(.leading, CGFloat(row.depth) * Design.Space.treeIndent + Design.Space.chip)
                .padding(.trailing, Design.Space.chip)
                .padding(.vertical, Design.Space.hair)
                .frame(minHeight: 34)
            }
        }
        .padding(.vertical, Design.Space.hair)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surface),
        )
    }
}

/// The exact request, and nothing truncated.
///
/// The scroll region may cut inside this block, which is how the surface shows that there is
/// more. Where it cuts is NOT FIXED by shrinking the payload to fit: the block's caption and
/// its Copy control are above the cut in the arrangements measured so far, and what
/// determines the cut is where the block's own 8pt gaps put the safe window. There is no
/// test pinning that geometry — an autopsy found the ones that existed were self-referential
/// arithmetic and were removed — so it is established by looking at docs/render/.
struct PayloadBlock: View {
    let text: String
    /// NO DEFAULT: Copy is this block's only act, and a default no-op made it a
    /// button that could absorb the click and copy nothing.
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.leading) {
            VStack(alignment: .leading, spacing: Design.Space.two) {
                Text("EXACT REQUEST — NOTHING IS TRUNCATED")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Ink.textSecondary)
                HStack(alignment: .top, spacing: Design.Space.leading) {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        Button("Copy", action: onCopy)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Design.Ink.accentText)
                        // The copy lands on the SHARED clipboard, and saying so is part of
                        // offering it.
                        Text("lands on the shared clipboard")
                            .font(.system(size: 9))
                            .foregroundStyle(Design.Ink.textTertiary)
                    }
                }
            }
            // Menlo, because the .fig cannot render a monospace face and therefore cannot
            // carry the code/prose distinction in type. The real app can, so it does.
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Design.Ink.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Design.Space.two)
        .padding(.horizontal, Design.Space.three)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}

/// The approval prompt.
///
/// THREE REGIONS, and the arrangement is the design's central claim: a HUGGING header
/// carrying ONLY what the system derived, a FIXED scrolling disclosure, and a HUGGING footer
/// carrying the decision.
///
/// THE HEADER CARRIES NO CALLER-WRITTEN TEXT, and that is the whole point of the current
/// arrangement. It used to carry the reason, which meant the only prose readable without
/// scrolling was text the untrusted caller wrote, while the verified request bytes sat below
/// the cut — measured at 0pt of 134pt visible. The header now states the risk, the
/// consequence, the reach and what the grant silently includes, all of it derived here, and
/// the reason has moved into the disclosure where it is still fully readable, still marked,
/// and subordinate by position.
struct ApprovalPrompt: View {
    enum State: Equatable {
        case pending
        case expanded
        case noReason
        case denied
        case expired
        case consoleUnreachable
    }

    // MARK: Content

    // // Every string below is the design's copy, verbatim. A prompt that paraphrases its own
    // warnings is a prompt that says something weaker than the thing it is warning about.

    let state: State
    let title: String
    let capabilityLine: String
    let risk: String
    let riskDot: Color
    let clock: String?
    /// The request's actual consent timeout in seconds. The expired line states this
    /// value rather than a remembered constant: a prompt that says "45 seconds" while
    /// the server waits 90 is a prompt that lies about its own deadline.
    let consentTimeoutSeconds: Int
    let createdAt: Date
    let reason: String?
    let implication: String?
    let tree: [CallerTree.Row]
    let target: String?
    let payload: String
    let biometricLine: String
    let biometricDot: Color
    let moreChoicesLabel: String?
    let showOptionsLabel: String?
    /// The options the SERVER actually offered. The prompt renders only these — not all
    /// six Kind cases — because showing an option the server withdrew (e.g. session under
    /// strict posture) is a choice that leads nowhere.
    let offeredOptions: [PendingRequest.Offered]
    var onDecision: (OptionRow.Kind, String) -> Void
    var onCopyPayload: () -> Void
    /// Expands the collapsed affordances into the full option set. The model owns the
    /// transition because it owns the state machine, and a view that held its own expansion
    /// flag would be a second state machine.
    var onShowOptions: () -> Void
    /// How many requests are waiting behind this one. 0 when this is the only question.
    /// ZERO DEFAULTS HERE rather than at the handlers: the absent value is the honest
    /// one for every prompt that answers a single request, and the indicator renders on
    /// the count alone — only the Review link needs a handler.
    var queuedCount: Int = 0
    /// Opens the queue review. NIL when there is no review to open: the indicator's
    /// Review link only renders when a handler exists, so a prompt constructed without
    /// one cannot grow a link that absorbs the click and opens nothing.
    var onReviewQueue: (() -> Void)?

    @State var operatorNote: String

    init(
        state: State,
        title: String,
        capabilityLine: String,
        risk: String,
        riskDot: Color,
        clock: String? = nil,
        consentTimeoutSeconds: Int = ServerConfig.defaultConsentTimeoutSeconds,
        createdAt: Date = Date(),
        reason: String? = nil,
        implication: String? = nil,
        tree: [CallerTree.Row],
        target: String? = nil,
        payload: String,
        biometricLine: String,
        biometricDot: Color,
        moreChoicesLabel: String? = nil,
        showOptionsLabel: String? = nil,
        offeredOptions: [PendingRequest.Offered],
        operatorNote: String = "",
        queuedCount: Int = 0,
        onReviewQueue: (() -> Void)? = nil,
        // NO DEFAULTS on the three handlers: a prompt constructed without a decision
        // handler is a consent surface whose buttons absorb clicks and decide nothing.
        // Every construction site states what happens when the operator chooses.
        onDecision: @escaping (OptionRow.Kind, String) -> Void,
        onCopyPayload: @escaping () -> Void,
        onShowOptions: @escaping () -> Void,
    ) {
        self.state = state
        self.title = title
        self.capabilityLine = capabilityLine
        self.risk = risk
        self.riskDot = riskDot
        self.clock = clock
        self.consentTimeoutSeconds = consentTimeoutSeconds
        self.createdAt = createdAt
        self.reason = reason
        self.implication = implication
        self.tree = tree
        self.target = target
        self.payload = payload
        self.biometricLine = biometricLine
        self.biometricDot = biometricDot
        self.moreChoicesLabel = moreChoicesLabel
        self.showOptionsLabel = showOptionsLabel
        self.offeredOptions = offeredOptions
        self._operatorNote = SwiftUI.State(initialValue: operatorNote)
        self.queuedCount = queuedCount
        self.onReviewQueue = onReviewQueue
        self.onDecision = onDecision
        self.onCopyPayload = onCopyPayload
        self.onShowOptions = onShowOptions
    }

    /// The kind of the option the SERVER marked as default focus, falling back to the
    /// first offered when none is marked. The engine always marks exactly one and it is
    /// never Deny; the fallback exists only so a malformed offer cannot leave the prompt
    /// without a primary. This is what the collapsed primary button and the expanded
    /// "default" badge read — NOT the first array element, which is what the console used
    /// to read.
    var focusedKind: OptionRow.Kind {
        offeredOptions.first(where: \.isDefault)?.kind ?? offeredOptions.first?.kind ?? .deny
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            disclosure
            footer
        }
        .frame(width: Design.Layout.promptWidth)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }

    // MARK: Header — hugs, and carries only what the system derived

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Space.three) {
            HStack(alignment: .center, spacing: Design.Space.chip) {
                StatusPill(kind: .risk(risk, riskDot))
                Spacer(minLength: 0)
                if state == .pending || state == .expanded, consentTimeoutSeconds > 0 {
                    TimelineView(.periodic(from: createdAt, by: 1.0)) { context in
                        let elapsed = Int(context.date.timeIntervalSince(createdAt))
                        let remaining = max(0, consentTimeoutSeconds - elapsed)
                        Text("decides in \(PendingRequest.clockLabel(remaining))")
                            .font(.system(size: 11))
                            .foregroundStyle(Design.Ink.textTertiary)
                    }
                } else if let clock {
                    Text(clock)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: Design.Space.one) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text(capabilityLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textTertiary)
            }
            if let implication, state == .pending || state == .expanded {
                // Same geometry as the untrusted field, and separable from it ONLY by the
                // rule's colour: orange means someone else wrote this, grey means the
                // system's own finding. No border, so the pair reads as one tier.
                HStack(alignment: .center, spacing: Design.Space.component) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Design.Rule.unknown)
                        .frame(width: 3, height: 18)
                    Text(implication)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Design.Space.chip)
                .padding(.trailing, Design.Space.three)
                .padding(.bottom, Design.Space.chip)
                .padding(.leading, 0)
            }
        }
        .padding(.top, Design.Space.frame)
        .padding(.trailing, Design.Space.frame)
        .padding(.bottom, 14)
        .padding(.leading, Design.Space.frame)
    }

    /// Whether the agent gave no reason (nil or empty/whitespace).
    var showsMissingReasonBanner: Bool {
        guard let reason else { return true }
        return reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The agent's reason, or the state its absence puts the operator in.
    @ViewBuilder
    private var reasonBlock: some View {
        if !showsMissingReasonBanner, let reason {
            UntrustedField(
                caption: state == .noReason ? .caller : .agentReason,
                value: reason,
                maximumHeight: Self.maximumReasonHeight,
            )
        } else {
            reasonMissing
        }
    }

    /// The state an agent that gave NO reason puts the operator in. Not a shorter prompt: a
    /// different one, with a neutral rule rather than a warning-coloured one, and an
    /// instruction that steers toward the narrowest grant. It sits with the reason in the
    /// disclosure for the same reason the reason does: it is the agent's silence, which is a
    /// fact about the caller and not a system finding, so it does not belong in the header
    /// either.
    private var reasonMissing: some View {
        HStack(alignment: .center, spacing: Design.Space.component) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Design.Rule.unknown)
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text("THE AGENT GAVE NO REASON")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text("Decline, or allow only for this exact request.")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Design.Space.chip)
        .padding(.trailing, Design.Space.three)
        .padding(.bottom, Design.Space.chip)
        .padding(.leading, 0)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }

    // MARK: Disclosure — the evidence, and the one scroll region

    private var disclosure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.component) {
                CallerTree(rows: tree)
                if let target {
                    // The fill spans the whole content column, and the caption's 13pt
                    // leading inset is INSIDE it. Putting the background on the padded view
                    // insets the box itself, which the render showed as a white block
                    // narrower than the tree above it.
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                            .fill(Design.Ink.surface)
                        SystemField(caption: .target, value: target)
                    }
                    .frame(minHeight: 35)
                }
                // THE REASON, HERE AND NOT IN THE HEADER. It is caller-written and the design
                // marks it unverified with an orange rule and a NOT VERIFIED caption, so the
                // layout used to be the one place that rule did not hold: it promoted the
                // agent's own prose above the fold while the verified request bytes sat
                // entirely below the cut, measured at 0pt of 134pt visible. The header now
                // carries only what the system derived — the risk, the consequence, the
                // reach, what the grant silently includes — and this stays fully readable,
                // still marked, subordinate by position.
                reasonBlock
                PayloadBlock(text: payload, onCopy: onCopyPayload)
            }
            .padding(.top, Design.Space.three)
            .padding(.horizontal, Design.Space.four)
            .padding(.bottom, Design.Space.three)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Design.Layout.promptScrollHeight)
        .background(Design.Ink.surfaceSunken)
    }

    /// The tallest the agent's reason may grow before it scrolls in its own box.
    ///
    /// DERIVED BY MEASUREMENT, and the derivation is recorded because a bare constant is a
    /// number a later edit invalidates silently. The tall state is the prompt with every
    /// offered option out and a reason long enough to reach the cap, and with a cap of 160 it
    /// measured 1061pt against the window ceiling of 1008 — 53pt over, which would push the
    /// last option and the note field past the bottom of the window again. 96pt puts that
    /// state at 997pt. `the prompt's tallest state fits inside the window ceiling` is a test,
    /// so a footer that grows without this being re-derived fails loudly rather than quietly
    /// reintroducing the defect.
    ///
    /// The cap is on the FIELD and not on the reason, so the text is never shortened or
    /// elided: an operator can still read every character of what the agent said, which is
    /// what the field is for. The design's own single-line field is 56pt, so 96pt is still
    /// room for five lines before anything scrolls.
    static let maximumReasonHeight: CGFloat = 96

    // MARK: Footer — hugs, and carries the decision

    private var footer: some View {
        VStack(alignment: .leading, spacing: Design.Space.three) {
            // The queue indicator states a FACT the operator needs before deciding this
            // request: more questions are waiting behind it. It sits at the top of the
            // footer — above the biometric strip — because it changes what any decision
            // here means for the requests behind it, and a fact that changes a decision
            // belongs where the decision is made. It hides once the options are expanded
            // (the operator is mid-choice) and once the prompt settles (nothing waits
            // behind a settled prompt that still has a queue, because the queue advances).
            if showsQueueIndicator {
                queueIndicator
            }

            HStack(alignment: .center, spacing: Design.Space.chip) {
                StatusDot(biometricDot, diameter: 8)
                Text(biometricLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Design.Space.three)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(Design.Ink.surfaceSunken),
            )

            if state == .expanded {
                VStack(spacing: Design.Space.leading) {
                    ForEach(offeredOptions, id: \.kind) { option in
                        OptionRow(
                            kind: option.kind,
                            scopeLine: option.scopeLine,
                            isDefault: option.isDefault,
                            shortcut: option.isDefault ? .defaultAction : nil,
                        ) { onDecision(option.kind, operatorNote) }
                    }
                }

                NoteField(text: $operatorNote)

                HStack(alignment: .center, spacing: Design.Space.chip) {
                    ConsoleButton(
                        title: "Deny",
                        kind: .deny,
                        shortcut: .cancelAction,
                    ) {
                        onDecision(.deny, operatorNote)
                    }
                    .frame(width: 96)

                    Spacer(minLength: 0)
                }
            } else if isSettled {
                settledOutcome
            } else {
                NoteField(text: $operatorNote)

                if let moreChoicesLabel {
                    HStack(alignment: .center, spacing: Design.Space.chip) {
                        Text(moreChoicesLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(Design.Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: onShowOptions) {
                            Text(showOptionsLabel ?? "Show options")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Design.Ink.accentText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, Design.Space.leading)
                    .padding(.horizontal, Design.Space.three)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                            .fill(Design.Ink.surfaceSunken),
                    )
                }

                HStack(alignment: .center, spacing: Design.Space.chip) {
                    ConsoleButton(
                        title: "Deny",
                        kind: .deny,
                        shortcut: .cancelAction,
                    ) {
                        onDecision(.deny, operatorNote)
                    }
                    .frame(width: 96)

                    Spacer(minLength: 0)

                    ConsoleButton(
                        title: focusedKind.title,
                        kind: .primary,
                        shortcut: .defaultAction,
                    ) {
                        onDecision(focusedKind, operatorNote)
                    }
                    .frame(minWidth: 150)
                }
            }
        }
        .padding(.top, Design.Space.three)
        .padding(.trailing, Design.Space.frame)
        .padding(.bottom, Design.Space.frame)
        .padding(.leading, Design.Space.frame)
    }

    /// A settled prompt keeps the whole header — chip, title, capability and the implication,
    /// so the operator can still read WHAT was asked and HOW FAR it reaches, and drops the
    /// disclosure (which is where the reason and the request bytes live), the biometric
    /// strip, every button, the note field and the rest of the footer.
    /// THERE IS NO PATH FROM HERE BACK TO A DECISION, so an expired request cannot be
    /// approved after the fact.
    private var settledOutcome: some View {
        let headline: String
        let sub: String
        switch state {
        case .denied:
            // THE NOTE LINE IS GONE because it said the note "went back to the agent",
            // and it does not: the note travels with the decision into the decision
            // audit log (AuthorizationInterceptor records it as `operatorNote`), which
            // the operator can read in Activity. Stating a destination the operator
            // cannot check is exactly the copy defect this pass removes.
            headline = "Denied"
            sub = "The request was denied. Nothing was granted."
        case .expired:
            headline = "Expired unanswered"
            // THE REQUEST'S OWN TIMEOUT, in the same M:SS the countdown showed, so the
            // deadline the operator watched and the one this line recalls are visibly the
            // same number. It used to say "45 seconds" whatever the server was actually
            // waiting, which made the settled line lie about its own deadline.
            sub = "After \(PendingRequest.clockLabel(consentTimeoutSeconds)) with no decision "
                + "the request was denied. Nothing was granted."
        default:
            headline = "No way to ask"
            sub = "Nothing could put this question in front of you, so it was denied. "
                + "Nothing was granted."
        }
        return VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state == .denied ? Design.Ink.danger : Design.Ink.textSecondary)
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.three)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surfaceRaised),
        )
    }

    /// Whether the queue indicator shows: requests are waiting behind this one, and the
    /// prompt is neither expanded (the operator is mid-choice) nor settled (a settled
    /// prompt has no live decision the count could inform).
    var showsQueueIndicator: Bool {
        queuedCount > 0 && !isSettled && state != .expanded
    }

    /// The indicator, matching the design's queue-indicator band: a sunken row with an
    /// accent dot, the waiting count, and — only where a review handler is wired — a
    /// Review link. A count with no way to open the review would be a fact the operator
    /// cannot act on, so the link renders only where one exists.
    private var queueIndicator: some View {
        HStack(alignment: .center, spacing: Design.Space.chip) {
            StatusDot(Design.Ink.accent, diameter: 8)
            Text("\(queuedCount) more waiting")
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
            Spacer(minLength: 0)
            if let onReviewQueue {
                Button(action: onReviewQueue) {
                    Text("Review queue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Design.Ink.accentText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Design.Space.three)
        .padding(.vertical, Design.Space.chip)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
    }

    private var isSettled: Bool {
        state == .denied || state == .expired || state == .consoleUnreachable
    }
}

struct NoteField: View {
    @Binding var text: String

    static let caption = "NOTE FOR AUDIT LOG — RECORDED WITH DECISION"

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(Self.caption)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.Ink.textSecondary)
            TextField(
                "Explain your reasoning for the audit log.",
                text: $text,
                axis: .vertical,
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Design.Ink.textPrimary)
            .lineLimit(2 ... 4)
        }
        .padding(Design.Space.three)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }
}
