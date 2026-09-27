import SwiftUI

// MARK: - The dot and the word

//
// Six component families in the design — RiskChip, ServiceStatus, CountdownChip,
// IntegrityBadge, TargetChip and MenuBarItem — are BYTE-IDENTICAL chrome across their
// variants and differ only in a 5–8pt dot and a label. The audit found no coloured pill,
// chip or bordered badge anywhere in the library.
//
// So they are one view here too. A coloured dot and a coloured border would put semantic
// colour on chrome, which is the one thing the design's rule forbids; a coloured LABEL is
// the deliberate exception for the two verdicts an operator must not skim past.

/// The dot alone. Every status in the product is a 5, 6 or 8pt circle and nothing else.
struct StatusDot: View {
    let diameter: CGFloat
    let color: Color

    init(_ color: Color, diameter: CGFloat = 6) {
        self.color = color
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

/// A signature state: a dot and a word, on no chrome at all.
///
/// A signature state is an ANNOTATION, not a chip. It has no fill, no stroke and no radius,
/// and the label is always `text-secondary` — only the dot carries the meaning. The design
/// chose that deliberately and it is fragile, because the dot is 6pt, so the word is doing
/// most of the work and must not be styled down.
struct SignatureBadge: View {
    enum State: String, Sendable, Equatable, CaseIterable {
        case signed
        case unnotarized
        case adHoc
        case unsigned
        case invalid
        case unresolved

        var label: String {
            switch self {
            case .signed: "Signed"
            case .unnotarized: "Unnotarized"
            case .adHoc: "Ad-hoc signed"
            case .unsigned: "Unsigned"
            case .invalid: "Invalid signature"
            case .unresolved: "Unresolved"
            }
        }

        /// `unresolved` is text-secondary and not a grey: not knowing is a DIFFERENT fact
        /// from knowing it is bad, and the operator has to be able to tell them apart.
        var dot: Color {
            switch self {
            case .signed: Design.Ink.success
            case .unnotarized, .adHoc: Design.Ink.caution
            case .unsigned, .invalid: Design.Ink.danger
            case .unresolved: Design.Ink.textSecondary
            }
        }
    }

    let state: State

    var body: some View {
        HStack(spacing: Design.Space.leading) {
            StatusDot(state.dot)
            Text(state.label)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
        }
        .padding(.vertical, Design.Space.tight)
    }
}

/// The severity of what is being asked for, or the integrity of the log.
///
/// `RiskChip`'s three variants are identical chrome and differ only in the dot, and its
/// LABEL is never coloured — "the label is never coloured" is the rule stated as a
/// constraint. `IntegrityBadge/broken` is the one exception in the whole library, because a
/// broken hash chain is a verdict the operator must not be able to skim past.
struct StatusPill: View {
    enum Kind {
        case risk(String, Color)
        /// The window-level integrity assertion.
        case integrity(text: String, dot: Color, labelInk: Color)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: Design.Space.leading) {
            switch kind {
            case let .risk(label, dot):
                StatusDot(dot)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
            case let .integrity(text, dot, labelInk):
                StatusDot(dot)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(labelInk)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Design.Space.tight)
        .background(
            Capsule().fill(Design.Ink.surfaceRaised),
        )
        .overlay(
            Capsule().strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }
}

/// Remaining life, with urgency carried by the DOT and never by the text.
///
/// Three identical chrome treatments; the chip border is the same in all three. An expiry is
/// a normal outcome rather than a fault, so `expired` gets a neutral dot and the word, not
/// an alarm.
struct CountdownChip: View {
    enum State: Equatable {
        case live
        case soon
        case expired

        var dot: Color {
            switch self {
            case .live: Design.Ink.textSecondary
            case .soon: Design.Ink.caution
            case .expired: Design.Ink.textTertiary
            }
        }
    }

    let label: String
    let state: State

    var body: some View {
        HStack(spacing: Design.Space.leading) {
            StatusDot(state.dot, diameter: 5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Design.Ink.textPrimary)
        }
        .padding(.horizontal, Design.Space.chip)
        .frame(height: 16)
        .background(
            Capsule().fill(Design.Ink.surface),
        )
        .overlay(
            Capsule().strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }
}

// MARK: - Provenance fields

//
// Same typography, three independent differences: fill, left rule, and caption ink. That
// is the security property. Untrusted content is boxed and labelled; the operator's own
// words are neither.

/// Text the CALLER supplied, visually distinct from system-derived fact.
///
/// The orange rule is the whole mechanism and it means exactly one thing: someone else
/// wrote this. It is never used for a system error.
struct UntrustedField: View {
    enum Caption {
        case caller
        case agentReason

        var text: String {
            switch self {
            case .caller: "FROM THE CALLER — NOT VERIFIED"
            case .agentReason: "REASON GIVEN BY THE AGENT — NOT VERIFIED"
            }
        }
    }

    let caption: Caption
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.component) {
            // Flush to the leading edge: the padding that clears this rule is produced
            // entirely by the rule's own width plus the gap, not by a spacer.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Design.Rule.untrusted)
                .frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Design.Font.eyebrow(caption.text)
                Design.Font.value(value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Design.Space.chip)
        .padding(.trailing, Design.Space.component)
        .padding(.bottom, Design.Space.chip)
        .padding(.leading, 0)
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

/// A fact the SYSTEM derived, with no chrome: no fill, no border, no rule.
struct SystemField: View {
    enum Caption {
        case target
        case operatorNote
        case payload

        var text: String {
            switch self {
            case .target: "TARGET — RESOLVED BY THE SYSTEM"
            case .operatorNote: "YOUR NOTE WENT BACK TO THE AGENT"
            case .payload: "EXACT REQUEST — NOTHING IS TRUNCATED"
            }
        }
    }

    let caption: Caption
    let value: String
    var isMachineText = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(caption.text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.Ink.textTertiary)
            if isMachineText {
                Design.Font.code(value)
            } else {
                Design.Font.value(value)
            }
        }
        .padding(.top, Design.Space.one)
        .padding(.trailing, Design.Space.component)
        .padding(.bottom, Design.Space.one)
        // 13 clears where the untrusted field's rule would sit, so the two read as the same
        // slot in different states rather than as different indentation.
        .padding(.leading, Design.Space.clearingRule)
    }
}

// MARK: - Controls

struct ConsoleButton: View {
    enum Kind {
        case primary
        case secondary
        case caution
        case deny
        case quiet

        var height: CGFloat {
            self == .quiet ? 28 : 34
        }
    }

    let title: String
    let kind: Kind
    var action: () -> Void = {}

    private var fill: Color {
        switch kind {
        case .primary: Design.Ink.accent
        case .secondary, .caution: Design.Ink.surfaceRaised
        case .deny, .quiet: Design.Ink.surface
        }
    }

    private var stroke: Color? {
        switch kind {
        case .primary, .quiet: nil
        case .secondary, .caution, .deny: Design.Ink.controlBorder
        }
    }

    private var ink: Color {
        switch kind {
        case .primary: Design.Ink.onAccent
        // Destructive actions are marked by red INK and never by an outline or a filled red.
        case .deny: Design.Ink.danger
        case .quiet: Design.Ink.textSecondary
        case .secondary, .caution: Design.Ink.textPrimary
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .secondary || kind == .quiet ? .regular : .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: kind.height)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                        .fill(fill),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                        .strokeBorder(stroke ?? .clear, lineWidth: 1),
                )
        }
        .buttonStyle(.plain)
    }
}

/// One grant option. The two unbounded choices are marked by red TITLE INK over identical
/// neutral chrome; nothing else distinguishes them.
struct OptionRow: View {
    enum Kind: String, Equatable, CaseIterable {
        case once
        case target
        case session
        case envelope
        case global
        case deny

        var title: String {
            switch self {
            case .once: "Allow once"
            case .target: "Allow for TextEdit"
            case .session: "Allow for this session"
            case .envelope: "Pre-authorize a batch"
            case .global: "Always allow"
            case .deny: "Deny"
            }
        }

        var scope: String {
            switch self {
            case .once: "this exact request  ·  expires when it completes"
            case .target: "one application  ·  until you revoke it"
            case .session: "every app this agent touches  ·  until ExactMac quits"
            case .envelope: "a declared capability set  ·  you choose, up to 8 hours"
            case .global: "every app, every time  ·  until you revoke it"
            case .deny: "—  ·  no grant is created"
            }
        }

        var isDestructive: Bool {
            self == .global || self == .deny
        }
    }

    let kind: Kind
    let isDefault: Bool
    var onSelect: () -> Void = {}

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: Design.Space.chip) {
                VStack(alignment: .leading, spacing: Design.Space.hair) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind.isDestructive ? Design.Ink.danger : Design.Ink.textPrimary)
                    Text(kind.scope)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textSecondary)
                }
                Spacer(minLength: 0)
                if isDefault {
                    Text("default")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.Ink.accentText)
                }
            }
            .padding(.horizontal, Design.Space.three)
            .padding(.vertical, Design.Space.chip)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                    .fill(isDefault ? Design.Ink.surfaceRaised : Design.Ink.surface),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                    .strokeBorder(
                        isDefault ? Design.Ink.accent : Design.Ink.separator,
                        lineWidth: 1,
                    ),
            )
        }
        .buttonStyle(.plain)
    }
}
