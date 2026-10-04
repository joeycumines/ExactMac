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
    var onCopy: () -> Void = {}

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
    let reason: String?
    let implication: String?
    let tree: [CallerTree.Row]
    let target: String?
    let payload: String
    let biometricLine: String
    let biometricDot: Color
    let moreChoicesLabel: String?
    let showOptionsLabel: String?
    let selectedOption: OptionRow.Kind?
    var onDecision: (OptionRow.Kind, String) -> Void
    var onCopyPayload: () -> Void
    /// Expands the collapsed affordances into the full option set. The model owns the
    /// transition because it owns the state machine, and a view that held its own expansion
    /// flag would be a second state machine.
    var onShowOptions: () -> Void

    @State var operatorNote: String

    init(
        state: State,
        title: String,
        capabilityLine: String,
        risk: String,
        riskDot: Color,
        clock: String? = nil,
        reason: String? = nil,
        implication: String? = nil,
        tree: [CallerTree.Row],
        target: String? = nil,
        payload: String,
        biometricLine: String,
        biometricDot: Color,
        moreChoicesLabel: String? = nil,
        showOptionsLabel: String? = nil,
        selectedOption: OptionRow.Kind? = nil,
        operatorNote: String = "",
        onDecision: @escaping (OptionRow.Kind, String) -> Void = { _, _ in },
        onCopyPayload: @escaping () -> Void = {},
        onShowOptions: @escaping () -> Void = {},
    ) {
        self.state = state
        self.title = title
        self.capabilityLine = capabilityLine
        self.risk = risk
        self.riskDot = riskDot
        self.clock = clock
        self.reason = reason
        self.implication = implication
        self.tree = tree
        self.target = target
        self.payload = payload
        self.biometricLine = biometricLine
        self.biometricDot = biometricDot
        self.moreChoicesLabel = moreChoicesLabel
        self.showOptionsLabel = showOptionsLabel
        self.selectedOption = selectedOption
        self._operatorNote = SwiftUI.State(initialValue: operatorNote)
        self.onDecision = onDecision
        self.onCopyPayload = onCopyPayload
        self.onShowOptions = onShowOptions
    }

    init(
        state: State,
        title: String,
        capabilityLine: String,
        risk: String,
        riskDot: Color,
        clock: String? = nil,
        reason: String? = nil,
        implication: String? = nil,
        tree: [CallerTree.Row],
        target: String? = nil,
        payload: String,
        biometricLine: String,
        biometricDot: Color,
        moreChoicesLabel: String? = nil,
        showOptionsLabel: String? = nil,
        selectedOption: OptionRow.Kind? = nil,
        operatorNote: String = "",
        onDecision: @escaping (OptionRow.Kind) -> Void,
        onCopyPayload: @escaping () -> Void = {},
        onShowOptions: @escaping () -> Void = {},
    ) {
        self.init(
            state: state,
            title: title,
            capabilityLine: capabilityLine,
            risk: risk,
            riskDot: riskDot,
            clock: clock,
            reason: reason,
            implication: implication,
            tree: tree,
            target: target,
            payload: payload,
            biometricLine: biometricLine,
            biometricDot: biometricDot,
            moreChoicesLabel: moreChoicesLabel,
            showOptionsLabel: showOptionsLabel,
            selectedOption: selectedOption,
            operatorNote: operatorNote,
            onDecision: { kind, _ in onDecision(kind) },
            onCopyPayload: onCopyPayload,
            onShowOptions: onShowOptions,
        )
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
                if let clock {
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
                    .frame(height: 35)
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
        // THE RAIL, because this region is CUT ON PURPOSE and the cut was silent. The design
        // draws a scrollbar here in every body-scroll it draws; without one the payload
        // block simply stops, under a caption that says nothing is truncated, and a reader
        // is right to conclude the rest of the request was withheld.
        .overlay(alignment: .trailing) {
            ScrollRail(geometry: disclosureGeometry)
        }
        .onScrollGeometryChange(for: ScrollRail.Measurement.self) { geometry in
            ScrollRail.Measurement(geometry: geometry)
        } action: { _, measurement in
            disclosureGeometry = measurement
        }
    }

    @State private var disclosureGeometry: ScrollRail.Measurement?

    /// The tallest the agent's reason may grow before it scrolls in its own box.
    ///
    /// DERIVED BY MEASUREMENT, and the derivation is recorded because a bare constant is a
    /// number a later edit invalidates silently. The tall state is the prompt with all six
    /// options out and a reason long enough to reach the cap, and with a cap of 160 it
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
                // The primary button is GONE. There is no default affordance, because the
                // options are the decision and one highlighted button beside six rows would
                // be a second, weaker default.
                VStack(spacing: Design.Space.leading) {
                    ForEach(OptionRow.Kind.allCases, id: \.self) { kind in
                        OptionRow(
                            kind: kind,
                            isDefault: kind == selectedOption,
                        ) { onDecision(kind, operatorNote) }
                    }
                }
            } else if isSettled {
                settledOutcome
            } else {
                // THE COLLAPSED PRIMARY ACTION IS THE NARROWEST OFFER, NOT A LABEL. It used
                // to be a `ConsoleButton` with no action at all, which is why the alert could
                // be opened, read, and never answered: every request in the running product
                // timed out and was denied while the screen said "Allow once".
                CollapsedActions(
                    primary: selectedOption ?? .once,
                    onDecision: { kind in onDecision(kind, operatorNote) },
                )
            }

            NoteField(
                text: $operatorNote,
                isDenied: selectedOption == .deny,
            )

            if !isSettled, state != .expanded {
                Rectangle()
                    .fill(Design.Ink.separator)
                    .frame(height: 1)
                DenyRow(
                    moreChoicesLabel: moreChoicesLabel,
                    showOptionsLabel: showOptionsLabel,
                    onDeny: { onDecision(.deny, operatorNote) },
                    onShowOptions: onShowOptions,
                )
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
            headline = "Denied"
            sub = "Your note went back to the agent: use the scoped option, not this one."
        case .expired:
            headline = "Expired unanswered"
            sub = "After 45 seconds with no decision the request was denied. "
                + "Nothing was granted."
        default:
            headline = "No way to ask"
            sub = "Nothing could put this question in front of you, so it was denied. "
                + "This is the safe direction."
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

    private var isSettled: Bool {
        state == .denied || state == .expired || state == .consoleUnreachable
    }
}

/// The collapsed affordances, deliberately far apart: a primary action at the top right and
/// a deny at the bottom left, separated by a hairline and the note field, so muscle memory
/// cannot reach the destructive row from the default one.
private struct CollapsedActions: View {
    let primary: OptionRow.Kind
    let onDecision: (OptionRow.Kind) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            // LABELLED WITH THE OPTION, not with a fixed "Allow once", because the option the
            // server put in focus is the one the operator is being offered, and a fixed label
            // next to a different default is a lie the operator acts on.
            ConsoleButton(title: primary.title, kind: .primary) {
                onDecision(primary)
            }
            .frame(width: 150)
        }
    }
}

private struct DenyRow: View {
    let moreChoicesLabel: String?
    let showOptionsLabel: String?
    let onDeny: () -> Void
    let onShowOptions: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.chip) {
            ConsoleButton(title: "Deny", kind: .deny, action: onDeny)
                .frame(width: 96)
            if let moreChoicesLabel {
                HStack(alignment: .center, spacing: Design.Space.chip) {
                    Text(moreChoicesLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // A BUTTON, because the whole point of the row is that the other
                    // options are one click away. It was a `Text`, so the options were not
                    // merely hidden but unreachable.
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
        }
    }
}

struct NoteField: View {
    @Binding var text: String
    var isDenied: Bool = false

    var caption: String {
        isDenied
            ? "NOTE TO THE AGENT — SENT BACK WITH YOUR DENIAL"
            : "NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(caption)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.Ink.textSecondary)
            TextField(
                "Why are you deciding this way? The agent sees this.",
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
