import ExactMacServer
import SwiftUI

/// The 688pt content column every window row is.
///
/// The window is 720pt and the padding is 16 either side, so this is 688 and it NEVER
/// changes — including the header, the rows and the footer. A row that sizes itself to its
/// content is a row whose columns stop lining up.
private enum Window {
    static let width: CGFloat = 720
    static let content: CGFloat = 688
}

/// The chrome both windows share.
///
/// There is no table. The design has no column headers, no column rules and no sortable
/// affordance; a grant row's internal split is the only columnar structure and it is a
/// fixed 528 + 12 + 124. The ONE structural difference between the two windows is that
/// Activity's header carries a trailing integrity badge and Grants' does not.
struct ConsoleWindow<Content: View>: View {
    let title: String
    let subtitle: String
    var badge: AnyView?
    var footer: AnyView?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        badge: (some View)? = AnyView?.none,
        footer: (some View)? = AnyView?.none,
        @ViewBuilder content: @escaping () -> Content,
    ) {
        self.title = title
        self.subtitle = subtitle
        if let badge {
            self.badge = AnyView(badge)
        } else {
            self.badge = nil
        }
        if let footer {
            self.footer = AnyView(footer)
        } else {
            self.footer = nil
        }
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.three) {
            HStack(alignment: .center, spacing: Design.Space.three) {
                VStack(alignment: .leading, spacing: Design.Space.hair) {
                    Design.Font.heading(title)
                    Design.Font.caption(subtitle)
                }
                Spacer(minLength: 0)
                badge
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content()
            if let footer {
                Rectangle().fill(Design.Ink.separator).frame(height: 1)
                footer
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, Design.Space.frame)
        .padding(.trailing, Design.Space.frame)
        .padding(.bottom, Design.Space.frame)
        .padding(.leading, Design.Space.frame)
        .frame(width: Window.width)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}

// MARK: - Grants

/// One grant, stating the consequence, the full scope, who holds it, which request created
/// it and how much life is left — because a grant the operator cannot see is a grant they
/// cannot revoke.
struct GrantRow: View {
    struct Model: Equatable, Identifiable {
        var id: String
        var consequence: String
        var capability: String
        var scope: String
        var holder: String
        var signature: SignatureBadge.State
        var origin: String
        var remaining: String
        var countdown: CountdownChip.State

        init(
            id: String,
            consequence: String,
            capability: String,
            scope: String,
            holder: String,
            signature: SignatureBadge.State,
            origin: String,
            remaining: String,
            countdown: CountdownChip.State,
        ) {
            self.id = id
            self.consequence = consequence
            self.capability = capability
            self.scope = scope
            self.holder = holder
            self.signature = signature
            self.origin = origin
            self.remaining = remaining
            self.countdown = countdown
        }

        init(from displayGrant: DisplayGrant) {
            self.id = displayGrant.id
            self.consequence = displayGrant.consequence
            self.capability = displayGrant.capability
            self.scope = displayGrant.scope
            self.holder = displayGrant.holder
            self.signature = SignatureBadge.State(serverValue: displayGrant.signature)
            self.origin = displayGrant.origin
            self.remaining = displayGrant.remaining
            self.countdown = switch displayGrant.countdownState {
            case .live: .live
            case .soon: .soon
            case .expired: .expired
            }
        }
    }

    let grant: Model
    var onRevoke: (String) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.three) {
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Design.Font.emphasized(grant.consequence)
                Text(grant.scope)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                HStack(alignment: .center, spacing: Design.Space.chip) {
                    // The holder's own name is INK and not metadata: it is the fact the
                    // operator is looking for.
                    Text(grant.holder)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textPrimary)
                    Spacer(minLength: 0)
                    SignatureBadge(state: grant.signature)
                }
                // The origin is the quietest text in the product and it is the audit trail.
                Design.Font.microNote(grant.origin)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Design.Space.chip) {
                CountdownChip(label: grant.remaining, state: grant.countdown)
                Button("Revoke") {
                    onRevoke(grant.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Design.Ink.textSecondary)
                .frame(width: 110, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                        .fill(Design.Ink.surface),
                )
            }
        }
        .padding(Design.Space.three)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surfaceRaised),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}

struct GrantsManager: View {
    let grants: [GrantRow.Model]
    var subtitle: String?
    var errorMessage: String?
    var onRevoke: (String) -> Void = { _ in }
    var onRevokeAll: () -> Void = {}

    var body: some View {
        if let errorMessage {
            ConsoleWindow(
                title: "Grants",
                subtitle: "Unavailable",
                footer: AnyView?.none,
            ) {
                ErrorState(
                    title: "Grants could not be read",
                    message: errorMessage,
                )
            }
        } else if grants.isEmpty {
            ConsoleWindow(
                title: "Grants",
                subtitle: "None active",
                footer: AnyView?.none,
            ) {
                EmptyState(
                    title: "No grants",
                    message: "Nothing is permitted without asking. Every request that needs consent will prompt you, and every decision you make here is shown in Activity.",
                )
            }
        } else {
            ConsoleWindow(
                title: "Grants",
                subtitle: subtitle ?? "\(grants.count) listed",
                footer: VStack(alignment: .leading, spacing: Design.Space.chip) {
                    HStack(alignment: .center, spacing: Design.Space.chip) {
                        StatusDot(Design.Ink.success, diameter: 8)
                        Text("Touch ID will confirm: revoke every grant at once")
                            .font(.system(size: 11))
                            .foregroundStyle(Design.Ink.textSecondary)
                    }
                    .padding(Design.Space.three)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                            .fill(Design.Ink.surfaceSunken),
                    )
                    ConsoleButton(title: "Revoke every grant", kind: .caution, action: onRevokeAll)
                        .frame(width: 190)
                    Design.Font.microNote(
                        "Revocation is immediate and survives a restart. An envelope is revoked as a "
                            + "unit, never partially.",
                    )
                },
            ) {
                ScrollView {
                    VStack(spacing: Design.Space.chip) {
                        ForEach(grants) { grant in
                            GrantRow(grant: grant, onRevoke: onRevoke)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Activity

/// One decision, and the evidence for it.
///
/// `basis` is at 13/600 in full ink and that is load-bearing: a row that says "allowed"
/// without saying on what basis cannot answer the question the operator has.
struct ActivityRow: View {
    struct Model: Equatable, Identifiable {
        var id: String
        var isAllowed: Bool
        var time: String
        var consequence: String
        var capability: String
        var basis: String
        var identity: String
        var signature: SignatureBadge.State
        var agentReason: String
        var operatorNote: String?

        init(
            id: String,
            isAllowed: Bool,
            time: String,
            consequence: String,
            capability: String,
            basis: String,
            identity: String,
            signature: SignatureBadge.State,
            agentReason: String,
            operatorNote: String? = nil,
        ) {
            self.id = id
            self.isAllowed = isAllowed
            self.time = time
            self.consequence = consequence
            self.capability = capability
            self.basis = basis
            self.identity = identity
            self.signature = signature
            self.agentReason = agentReason
            self.operatorNote = operatorNote
        }

        init(from displayItem: DisplayActivityItem) {
            self.id = displayItem.id
            self.isAllowed = displayItem.isAllowed
            self.time = displayItem.time
            self.consequence = displayItem.consequence
            self.capability = displayItem.capability
            self.basis = displayItem.basis
            self.identity = displayItem.identity
            self.signature = SignatureBadge.State(serverValue: displayItem.signature)
            self.agentReason = displayItem.agentReason
            self.operatorNote = displayItem.operatorNote
        }
    }

    let row: Model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.one) {
            HStack(alignment: .center, spacing: Design.Space.three) {
                HStack(alignment: .center, spacing: Design.Space.leading) {
                    StatusDot(verdictColour, diameter: 8)
                    // ONE of only two places in the whole product where a LABEL takes
                    // semantic colour: a verdict the operator must not skim past.
                    Text(row.isAllowed ? "Allowed" : "Denied")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(verdictColour)
                }
                Spacer(minLength: 0)
                Text(row.time)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textTertiary)
            }
            Design.Font.emphasized(row.consequence)
            Text(row.capability)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
            Text(row.basis)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: Design.Space.chip) {
                Text(row.identity)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Design.Ink.textSecondary)
                Spacer(minLength: 0)
                SignatureBadge(state: row.signature)
            }
            UntrustedField(caption: .agentReason, value: row.agentReason)
            if let note = row.operatorNote {
                // The operator's own words get NO chrome — no fill, no border, no rule — and a
                // TERTIARY caption. Untrusted content is boxed and labelled; theirs is
                // neither, because it is not a claim about the system.
                SystemField(caption: .operatorNote, value: note)
            }
        }
        .padding(.horizontal, Design.Space.three)
        .padding(.vertical, Design.Space.component)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }

    private var verdictColour: Color {
        row.isAllowed ? Design.Ink.success : Design.Ink.danger
    }
}

/// The hash-chain integrity assertion, which is a WINDOW-LEVEL statement and not a
/// per-row one: one badge describing the whole log.
///
/// At rest it is deliberately quiet — a neutral pill with a 6pt green dot and no banner.
/// The alarm channel is the LABEL, and it is the second and last place in the product
/// where text takes semantic colour.
struct IntegrityBadge: View {
    enum State: Equatable {
        case verified(entries: Int)
        case broken(at: Int)
        case unchecked
        case nothingToVerify

        var dot: Color {
            switch self {
            case .verified: Design.Ink.success
            case .broken: Design.Ink.danger
            case .unchecked, .nothingToVerify: Design.Ink.textSecondary
            }
        }

        var label: String {
            switch self {
            case let .verified(entries): "Chain verified · \(grouped(entries)) entries"
            case let .broken(at): "Chain broken at entry \(grouped(at))"
            case .unchecked: "Not verified"
            case .nothingToVerify: "Nothing to verify"
            }
        }

        var labelInk: Color {
            // The one exception: the words are the warning.
            switch self {
            case .broken: Design.Ink.danger
            case .verified, .unchecked, .nothingToVerify: Design.Ink.textPrimary
            }
        }

        init(from displayState: DisplayIntegrityState, itemCount: Int) {
            switch displayState {
            case let .verified(count):
                if count == 0, itemCount == 0 {
                    self = .nothingToVerify
                } else {
                    self = .verified(entries: count)
                }
            case let .broken(at):
                self = .broken(at: at)
            case .unreadable:
                self = .unchecked
            }
        }

        private func grouped(_ value: Int) -> String {
            let digits = String(value)
            var out = ""
            for (index, character) in digits.enumerated().reversed() {
                if index > 0, index % 3 == 0 {
                    out.append(",")
                }
                out.append(character)
            }
            return String(out.reversed())
        }
    }

    let state: State

    var body: some View {
        StatusPill(kind: .integrity(
            text: state.label,
            dot: state.dot,
            labelInk: state.labelInk,
        ))
    }
}

struct ActivityTimeline: View {
    let rows: [ActivityRow.Model]
    let integrity: IntegrityBadge.State
    let subtitle: String
    var errorMessage: String?
    var onRetry: (() -> Void)?

    var body: some View {
        if let errorMessage {
            ConsoleWindow(
                title: "Activity",
                subtitle: "Unavailable",
                badge: IntegrityBadge(state: .unchecked),
                footer: AnyView?.none,
            ) {
                ErrorState(
                    title: "Activity could not be loaded",
                    message: errorMessage,
                    retryTitle: onRetry != nil ? "Try again" : nil,
                    onRetry: onRetry,
                )
            }
        } else if rows.isEmpty, integrity == .nothingToVerify || integrity == .verified(entries: 0) {
            ConsoleWindow(
                title: "Activity",
                subtitle: "Nothing recorded yet",
                badge: IntegrityBadge(state: .nothingToVerify),
                footer: AnyView?.none,
            ) {
                EmptyState(
                    title: "No activity yet",
                    message: "Every decision will appear here: what was asked, by whom, and whether a grant, your prompt or an envelope allowed it.",
                )
            }
        } else if case let .broken(at) = integrity, rows.isEmpty {
            ConsoleWindow(
                title: "Activity",
                subtitle: "Unavailable",
                badge: IntegrityBadge(state: integrity),
                footer: AnyView?.none,
            ) {
                ErrorState(
                    title: "The log has been altered",
                    message: "An entry does not match the hash recorded for it, so everything after entry \(at) cannot be trusted. Grants are still enforced — but this log is not evidence of what happened.",
                    retryTitle: onRetry != nil ? "Try again" : nil,
                    onRetry: onRetry,
                )
            }
        } else if rows.isEmpty {
            ConsoleWindow(
                title: "Activity",
                subtitle: "Unavailable",
                badge: IntegrityBadge(state: .unchecked),
                footer: AnyView?.none,
            ) {
                ErrorState(
                    title: "Activity could not be loaded",
                    message: "The decision log did not open. Decisions are still being enforced; this view is missing, not the protection.",
                    retryTitle: onRetry != nil ? "Try again" : nil,
                    onRetry: onRetry,
                )
            }
        } else {
            ConsoleWindow(
                title: "Activity",
                subtitle: subtitle,
                badge: IntegrityBadge(state: integrity),
                footer: Design.Font.microNote(
                    "The log is append-only and hash-chained: removing or editing an entry breaks "
                        + "the chain and is shown here rather than hidden.",
                ),
            ) {
                // SCROLLS, for the same reason the settings surface does: the list's length is
                // whatever the decision log happens to hold, and a window that cannot be resized
                // would put the oldest entries permanently out of reach.
                ScrollView {
                    VStack(spacing: Design.Space.chip) {
                        ForEach(rows) { ActivityRow(row: $0) }
                        if case let .broken(at) = integrity {
                            // The rule is GREY, not orange: this is the system saying it cannot
                            // tell you something, which is the other of the two provenances.
                            HStack(alignment: .center, spacing: Design.Space.component) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Design.Rule.unknown)
                                    .frame(width: 3, height: 40)
                                VStack(alignment: .leading, spacing: Design.Space.tight) {
                                    Design.Font.emphasized("The log has been altered")
                                    Text(
                                        "An entry does not match the hash recorded for it, so "
                                            + "everything after entry \(at) cannot be trusted. Grants "
                                            + "are still enforced — but this log is not evidence of "
                                            + "what happened.",
                                    )
                                    .font(.system(size: 11))
                                    .foregroundStyle(Design.Ink.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, Design.Space.three)
                            .padding(.vertical, Design.Space.component)
                            .background(
                                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                                    .fill(Design.Ink.surfaceSunken),
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The states every list has

struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Design.Space.leading) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Design.Ink.textPrimary)
                .frame(maxWidth: .infinity)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Design.Ink.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.six)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}

/// A system failure, and the two provenances again: a GREY rule, because the system could
/// not obtain the fact. It is never orange, and there is never a filled red.
struct ErrorState: View {
    let title: String
    let message: String
    var retryTitle: String?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.component) {
            HStack(alignment: .top, spacing: Design.Space.component) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Design.Rule.unknown)
                    .frame(width: 3, height: 40)
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    Design.Font.emphasized(title)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .frame(width: 110, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                            .fill(Design.Ink.surface),
                    )
            }
        }
        .padding(.top, Design.Space.component)
        .padding(.trailing, Design.Space.component)
        .padding(.bottom, Design.Space.component)
        .padding(.leading, 0)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
    }
}

/// Pure geometry: three bars, no text. A loading state that says "loading" is a loading
/// state that can be misread as content.
struct LoadingSkeleton: View {
    let barWidths: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.component) {
            ForEach(Array(barWidths.enumerated()), id: \.offset) { _, width in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Design.Ink.separator)
                    .frame(width: width, height: 10)
            }
        }
        .padding(.top, Design.Space.frame)
        .padding(.trailing, Design.Space.three)
        .padding(.bottom, Design.Space.frame)
        .padding(.leading, Design.Space.three)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surfaceRaised),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}
