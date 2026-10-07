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

    /// The engine's name for this class, written out by hand rather than derived from the
    /// case, for the same reason `OptionRow.Kind(serverValue:)` and
    /// `SignatureBadge.State(serverValue:)` are: a derivation is the same mistake in a
    /// different hat, because a rename on the server would silently change what the operator
    /// is told. An unrecognised value becomes `.elevated` — the class that escalates rather
    /// than the one that reassures, and visible on screen as a change rather than a default.
    init(serverValue: String) {
        switch serverValue {
        case "routine": self = .routine
        case "high": self = .high
        default: self = .elevated
        }
    }

    /// What a capability token MEANS, for the prompt's implication line.
    ///
    /// The engine holds the same mapping in `Capability.consequence` and this is its mirror,
    /// written out by hand for the same reason as the decode above. The keys are the WIRE
    /// VALUES and not the case names — `clipboard.read`, not `clipboardRead` — which the
    /// console's own fixture caught: `Capability` declares `case clipboardRead = "clipboard.read"`,
    /// so a switch written against the case names matched nothing and every implication
    /// would have silently rendered empty.
    ///
    /// THE VALUES ARE GERUNDS, NOT THE ENGINE'S IMPERATIVES, and that is a grammar
    /// requirement rather than a style one. The engine's `Capability.consequence` reads
    /// "Read the clipboard and its history" because it stands alone as a title; this string
    /// follows "Also permits", and "Also permits read the clipboard and its history" is
    /// broken English on a security prompt. The design's own line is "Also permits screen
    /// capture and reading the focused window's text".
    ///
    /// It returns nil for a token it does not recognise, which is what lets the implication
    /// line drop a capability it cannot describe INSTEAD OF NAMING A TOKEN AT THE OPERATOR —
    /// the implication's whole purpose is to say what else is permitted, and a bare
    /// identifier in that sentence defeats it.
    static func consequence(of capability: String) -> String? {
        switch capability {
        case "script.execute": "running a shell command, AppleScript or JavaScript"
        case "macro.execute": "replaying a recorded macro"
        case "observation.ax": "reading the accessibility tree of an app"
        case "observation.window": "listing and reading your windows and applications"
        case "observation.screen": "taking a screenshot of the screen"
        case "observation.stream": "watching accessibility changes as they happen"
        case "display.read": "reading the display layout"
        case "clipboard.read": "reading the clipboard and its history"
        case "clipboard.write": "replacing what is on the clipboard"
        case "input.synthesize": "typing and clicking as you"
        case "window.manage": "moving, resizing, closing and focusing your windows"
        case "application.control": "opening, activating and quitting your applications"
        case "file.automate": "driving open and save panels"
        case "transaction.manage": "grouping actions into a transaction"
        case "session.manage": "creating and inspecting sessions"
        case "authorization.manage": "seeing what is permitted, and pre-authorizing a batch"
        case "local.echo": "reading back input this server was already given"
        default: nil
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

    @State private var capabilitiesGeometry: ScrollRail.Measurement?

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

            ScrollView {
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
            }
            .frame(maxHeight: 240)
            .background(Design.Ink.surfaceSunken)
            .overlay(alignment: .trailing) {
                ScrollRail(geometry: capabilitiesGeometry)
            }
            .onScrollGeometryChange(for: ScrollRail.Measurement.self) { geometry in
                ScrollRail.Measurement(geometry: geometry)
            } action: { _, measurement in
                capabilitiesGeometry = measurement
            }

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
