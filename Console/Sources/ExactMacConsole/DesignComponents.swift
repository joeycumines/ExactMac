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

        /// Maps the SERVER's vocabulary, which is not this enum's.
        ///
        /// THE TWO DO NOT AGREE AND THE MISMATCH WAS INVISIBLE. The server's `SignatureState`
        /// raw values are `signedAndValid`, `signedUnnotarized`, `adHoc`, `unsigned`,
        /// `invalid`, `unresolved`; this enum's are `signed`, `unnotarized` and so on — so
        /// `init(rawValue:)` returned nil for precisely the two states an operator wants to
        /// find reassuring, and a `?? .unresolved` fallback reported a fully notarized binary
        /// as "could not find out". A `RawRepresentable` conformance claims two vocabularies
        /// are one vocabulary, and here they were not.
        ///
        /// WRITTEN OUT rather than derived, because a derivation is the same mistake in a
        /// different hat: a state added later must fail visibly rather than fall through.
        init(serverValue: String) {
            self = switch serverValue {
            case "signedAndValid": .signed
            case "signedUnnotarized": .unnotarized
            case "adHoc": .adHoc
            case "unsigned": .unsigned
            case "invalid": .invalid
            default: .unresolved
            }
        }

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
    /// The tallest this field may grow. nil grows to fit, which is right where the value is
    /// short by construction — an activity row's note, the operator's own words. The
    /// approval prompt's reason is NOT short by construction: it is caller-supplied text of
    /// any length, and an uncapped field grew the prompt's header without limit until the
    /// options, the biometric line and the Deny row were pushed past the bottom of the
    /// window with nothing to scroll them back into reach. A control the operator cannot
    /// see is a control they cannot deny with.
    var maximumHeight: CGFloat?

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.component) {
            // Flush to the leading edge: the padding that clears this rule is produced
            // entirely by the rule's own width plus the gap, not by a spacer.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Design.Rule.untrusted)
                .frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Design.Font.eyebrow(caption.text)
                valueField
            }
        }
        .padding(.top, Design.Space.chip)
        .padding(.trailing, Design.Space.component)
        .padding(.bottom, Design.Space.chip)
        .padding(.leading, 0)
        // FILLS the row. Sized to its content it becomes a box that shrinks to the shortest
        // reason, which reads as a different kind of thing from the full-width field above
        // and below it — and the design has every provenance field at the row's full width.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
        .overlay(alignment: .trailing) { rail }
    }

    /// The value itself. Uncapped it grows to fit; capped it hugs the text below the cap and
    /// scrolls inside it above, with the rail drawn in the field's own gutter so the reason
    /// stays fully readable while the prompt's height stays bounded.
    ///
    /// `maxHeight` AND NOT `height`, which was the first attempt: a fixed height made a
    /// one-line reason sit in a 160pt box, where the design draws 56pt. Measured both:
    /// `height` reports 160 for short text, `maxHeight` reports 14 for the same text and 160
    /// for text that overflows.
    @ViewBuilder
    private var valueField: some View {
        if let maximumHeight {
            ScrollView {
                Design.Font.value(value)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maximumHeight)
            .onScrollGeometryChange(for: ScrollRail.Measurement.self) { geometry in
                ScrollRail.Measurement(geometry: geometry)
            } action: { _, measurement in
                reasonGeometry = measurement
            }
        } else {
            Design.Font.value(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rail: some View {
        if maximumHeight != nil {
            ScrollRail(geometry: reasonGeometry)
        }
    }

    @State private var reasonGeometry: ScrollRail.Measurement?
}

/// The scroll affordance for a region that scrolls, which the app was missing entirely.
///
/// A cut with no affordance reads as content that is simply absent. The prompt's disclosure
/// is DELIBERATELY cut mid-block so the operator can see there is more, and macOS overlay
/// scrollbars are invisible at rest, so the region looked like a static card: the mechanism
/// worked and nothing said it did.
///
/// THE DESIGN DRAWS THIS RAIL in all five of its `body-scroll` frames — 4pt wide at x=412,
/// inset 12pt top and bottom, filled with the separator token, inside the 16pt gutter the
/// content padding leaves on the right. The implementation draws a PROPORTIONED thumb in
/// that rail rather than the solid 212pt block the design draws, because a rail that does
/// not move tells the operator a scrollbar exists without telling them where they are in
/// it. The design's 212pt is its own approximation and not a measurement of this content;
/// the thumb here is derived from the scroll geometry the framework reports, so it cannot
/// claim a position the content is not at.
struct ScrollRail: View {
    /// What the framework last reported about the region's geometry, or nil before it has.
    ///
    /// Nil draws nothing. A rail that claims a scroll position nobody can verify is worse
    /// than no rail, and an unverified indicator is the same failure as a claim with no
    /// render behind it.
    let geometry: ScrollRail.Measurement?

    /// One read of the region's geometry, so the three numbers cannot come from different
    /// frames and describe a scroll position that never existed.
    struct Measurement: Equatable {
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var offset: CGFloat = 0

        /// Written out rather than left to the memberwise synthesiser, because declaring
        /// the reading init below suppresses it — and a measurement that cannot be built
        /// outside the framework is a measurement that cannot be asserted.
        init(contentHeight: CGFloat = 0, viewportHeight: CGFloat = 0, offset: CGFloat = 0) {
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            self.offset = offset
        }

        init(geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            viewportHeight = geometry.visibleRect.height
            offset = geometry.contentOffset.y
        }
    }

    /// Where the thumb goes, or nil when the region does not overflow and there is nothing
    /// to indicate.
    ///
    /// A PURE FUNCTION of one measurement, so it can be asserted without a render, and so
    /// the view cannot draw a thumb the arithmetic does not support. Returning nil until
    /// the framework has reported geometry is deliberate: a rail that claims a position
    /// nobody can verify is worse than no rail.
    static func thumb(for geometry: Measurement?) -> (height: CGFloat, offset: CGFloat)? {
        guard let geometry, geometry.contentHeight > geometry.viewportHeight + 0.5 else {
            return nil
        }
        // The design's rail is 12pt inset top and bottom.
        let track = max(geometry.viewportHeight - inset * 2, 1)
        // Proportional to what is visible, with a floor so the thumb stays grabbable. The
        // floor is a choice, not a measurement: a 4pt-wide thumb a few points long cannot
        // be caught with a pointer, and an ungrabbable indicator is worse than none.
        let proportional = track * geometry.viewportHeight / geometry.contentHeight
        let height = min(max(proportional, minimumThumbLength), track)
        // The thumb TRAVELS (track - height) over the whole scroll range, not `track`. With
        // `track` the formula puts the thumb's top at the end of the track when scrolled to
        // the bottom, which hangs it outside the rail it is supposed to be inside. Caught by
        // asserting the bottom position against the top one.
        let travel = track - height
        let offset = travel * (geometry.offset / (geometry.contentHeight - geometry.viewportHeight))
        return (height, offset)
    }

    static let minimumThumbLength: CGFloat = 24

    /// The design's rail is 12pt inset top and bottom.
    private static let inset = Design.Space.three
    /// The design's rail is 4pt wide, 4pt from the trailing edge of a 420pt surface whose
    /// content column is 388pt.
    private static let width: CGFloat = 4
    private static let trailingInset: CGFloat = 4

    var body: some View {
        if let thumb = Self.thumb(for: geometry) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                // textSecondary AND NOT separator, which is what the design drew and what
                // this first drew. MEASURED: separator on surfaceSunken is 1.27:1 in light
                // and 1.62:1 in dark, and WCAG 1.4.11 asks 3:1 of a non-text affordance, so
                // the rail was effectively invisible — a scroll indicator nobody can see is
                // not an indicator. controlBorder was tried and is 2.89:1 / 2.77:1, still
                // short. textSecondary is 5.43:1 light and 7.77:1 dark, and reads as a
                // control rather than as a hairline. The design is updated to match; a test
                // asserts the ratio in both schemes so it cannot quietly go back.
                .fill(Design.Ink.textSecondary)
                .frame(width: Self.width, height: thumb.height)
                .offset(y: Self.inset + thumb.offset)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Self.trailingInset)
                .allowsHitTesting(false)
        }
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

        /// Maps the SERVER's vocabulary, which is not this enum's.
        ///
        /// THIS MISMATCH BROKE THE PRODUCT END TO END. The server's `OfferedDecision.Kind`
        /// raw values are `allowOnce`, `allowTargetApplication`, `allowSession`,
        /// `preAuthorizeEnvelope`, `allowGlobalPersistent` and `deny`; this enum's are `once`,
        /// `target`, `session`, `envelope`, `global` and `deny`. So `init(rawValue:)` matched
        /// only `deny`, `compactMap` threw the other five away, and every request arrived
        /// offering exactly one option, which was Deny. The same mismatch ran the other way:
        /// the console POSTED `once` and the server parsed it as nil, so every approval was
        /// enforced as a refusal.
        ///
        /// It was invisible because the fixture built the wire `offered` array from THIS
        /// enum's own raw values, so it could never contain a server-shaped name. The mapping
        /// is written out for the same reason as the signature one: a value that is not in
        /// this list must not silently become something else.
        init(serverValue: String) {
            self = switch serverValue {
            case "allowOnce": .once
            case "allowTargetApplication": .target
            case "allowSession": .session
            case "preAuthorizeEnvelope": .envelope
            case "allowGlobalPersistent": .global
            default: .deny
            }
        }

        /// The value the SERVER parses, which is what a decision must carry.
        ///
        /// NAMED SEPARATELY from the inbound mapping rather than assumed to be its inverse,
        /// because posting this enum's own `rawValue` is precisely what made every approval a
        /// denial.
        var serverValue: String {
            switch self {
            case .once: "allowOnce"
            case .target: "allowTargetApplication"
            case .session: "allowSession"
            case .envelope: "preAuthorizeEnvelope"
            case .global: "allowGlobalPersistent"
            case .deny: "deny"
            }
        }

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
