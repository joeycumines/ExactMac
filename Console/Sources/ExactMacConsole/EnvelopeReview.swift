import SwiftUI

/// How much a single capability in a batch is worth. It belongs BESIDE `Capability` rather
/// than inside it, because it is a property of a capability and not a kind of capability.
enum CapabilityRisk: String, Equatable, CaseIterable {
    case routine
    case elevated
    case high

    var label: String {
        switch self {
        case .routine: "Routine"
        case .elevated: "Elevated"
        case .high: "High"
        }
    }

    /// The dot carries it and the LABEL NEVER DOES — the same rule RiskChip states, and the
    /// reason a chip that coloured its text would be the only one in the product.
    var dot: Color {
        switch self {
        case .routine: Design.Ink.textSecondary
        case .elevated: Design.Ink.caution
        case .high: Design.Ink.danger
        }
    }
}

/// The pre-authorization review: a DIFFERENT SURFACE, not a variant of the prompt.
///
/// The design is explicit about this and it is the whole reason the sheet distinguishes
/// them — a pre-authorization of a CAPABILITY SET is a different decision from approving
/// one request, and an operator who cannot tell them apart at a glance has been shown a
/// control they did not mean to grant. So this opens with a full-bleed band, states the
/// count, lists every capability with its consequence, and states its own duration twice.
struct EnvelopeReview: View {
    struct Capability: Equatable, Identifiable {
        var id: String
        var consequence: String
        var breadth: String
        var risk: CapabilityRisk
    }

    let requester: String
    let reason: String
    let capabilities: [Capability]
    let duration: String
    let maximumDuration: String
    let biometricLine: String
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // The band. A pre-authorization is not a request, and the band is the first
            // thing that says so.
            HStack(spacing: 0) {
                Text("PRE-AUTHORIZATION ENVELOPE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.frame)
            // FULL BLEED. The band's whole job is to be a different surface from the prompt
            // beneath it, and a band that stops short of the panel edge reads as a selected
            // row rather than as the top of a different sheet.
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: Design.Radius.large,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: Design.Radius.large,
                    style: .continuous,
                )
                .fill(Design.Ink.surfaceRaised),
            )

            VStack(alignment: .leading, spacing: Design.Space.three) {
                VStack(alignment: .leading, spacing: Design.Space.one) {
                    Text("Pre-authorize a batch of capabilities")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Design.Ink.textPrimary)
                    Text("\(capabilities.count) capabilities  ·  requested by \(requester)")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textTertiary)
                }
                UntrustedField(caption: .agentReason, value: reason)
            }
            .padding(.top, 14)
            .padding(.horizontal, Design.Space.frame)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: Design.Space.chip) {
                ForEach(capabilities) { capability in
                    HStack(alignment: .center, spacing: Design.Space.chip) {
                        StatusPill(kind: .risk(capability.risk.label, capability.risk.dot))
                        VStack(alignment: .leading, spacing: Design.Space.hair) {
                            Text(capability.consequence)
                                .font(.system(size: 12))
                                .foregroundStyle(Design.Ink.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(capability.breadth)
                                .font(.system(size: 10))
                                .foregroundStyle(Design.Ink.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Design.Space.three)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Ink.surfaceSunken)

            VStack(alignment: .leading, spacing: Design.Space.component) {
                HStack(alignment: .center, spacing: Design.Space.chip) {
                    StatusDot(Design.Ink.success, diameter: 8)
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

                // The duration is stated HERE and on the button, because an envelope the
                // operator cannot bound is not a pre-authorization at all.
                HStack(alignment: .center, spacing: Design.Space.component) {
                    Text("Valid for")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.Ink.textSecondary)
                    Text(duration)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Design.Ink.textPrimary)
                    Spacer(minLength: 0)
                    Text("maximum \(maximumDuration)")
                        .font(.system(size: 10))
                        .foregroundStyle(Design.Ink.textTertiary)
                }
                .padding(.horizontal, Design.Space.three)
                .padding(.vertical, Design.Space.chip)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                        .fill(Design.Ink.surfaceSunken),
                )

                HStack {
                    Spacer(minLength: 0)
                    ConsoleButton(title: "Approve for \(duration)", kind: .primary, action: onApprove)
                        .frame(width: 158)
                }

                EnvelopeNoteField()

                Rectangle().fill(Design.Ink.separator).frame(height: 1)
                HStack {
                    ConsoleButton(title: "Deny", kind: .deny, action: onDeny)
                        .frame(width: 96)
                    Spacer(minLength: 0)
                }

                // The invariant the whole surface exists to state, in the product's own
                // words rather than in a code comment.
                Text("An envelope can never become global or outlive its duration.")
                    .font(.system(size: 10))
                    .foregroundStyle(Design.Ink.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Design.Space.three)
            .padding(.horizontal, Design.Space.frame)
            .padding(.bottom, Design.Space.frame)
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
}

private struct EnvelopeNoteField: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text("NOTE TO THE AGENT — SENT BACK WITH YOUR DECISION")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Design.Ink.textSecondary)
            TextField(
                "Why are you deciding this way? The agent sees this.",
                text: $text,
                axis: .vertical,
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Design.Ink.textTertiary)
        }
        .padding(Design.Space.three)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1),
        )
    }
}

/// The prompt with its options revealed.
///
/// THE PRIMARY BUTTON IS GONE and that is the point: in the collapsed state there is one
/// default affordance, and offering it beside six rows would be a second, weaker default.
/// The options ARE the decision. The header and the disclosure above are byte-for-byte the
/// same as the collapsed prompt — expanding does not perturb a pixel above the footer.
struct ExpandedApprovalPrompt<Content: View>: View {
    let header: AnyView
    let disclosure: AnyView
    let biometricLine: String
    let biometricDot: Color
    @Binding var selected: OptionRow.Kind
    @ViewBuilder let options: () -> Content

    init(
        header: AnyView,
        disclosure: AnyView,
        biometricLine: String,
        biometricDot: Color,
        selected: Binding<OptionRow.Kind>,
        @ViewBuilder options: @escaping () -> Content,
    ) {
        self.header = header
        self.disclosure = disclosure
        self.biometricLine = biometricLine
        self.biometricDot = biometricDot
        self._selected = selected
        self.options = options
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            disclosure
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

                VStack(spacing: Design.Space.leading) {
                    options()
                }

                EnvelopeNoteField()
            }
            .padding(.top, Design.Space.three)
            .padding(.horizontal, Design.Space.frame)
            .padding(.bottom, Design.Space.frame)
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
}
