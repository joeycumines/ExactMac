import ExactMacServer
import SwiftUI

/// A 10/600 uppercase section label. Four in this window and it is the only thing that
/// separates one block of settings from the next, so it is doing all of the work the
/// window chrome does not.
private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Design.Ink.textSecondary)
    }
}

/// A setting, and the reason it exists.
///
/// The design states the REASON beside every setting rather than above it, because a list
/// of toggles with no reasons is a list of toggles the operator cannot reason about. Four
/// of the five biometric rows carry "Required — this cannot be turned off", which is a
/// switch that is ON and not operable — and drawing it as a live control would be a lie.
struct SettingRow: View {
    struct Model: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var isOn: Bool
        var isLocked = false
        /// What a LOCKED row says beneath itself. The default is the on-row's standing
        /// statement; an OFF locked row (the allow-once exemption) carries its own,
        /// because "required — this cannot be turned off" over a switch that reads OFF
        /// would be a contradiction on screen.
        var lockedCaption = "Required — this cannot be turned off"
        var isDestructive = false
        var actionTitle: String?
    }

    let setting: Model
    /// The row's own toggle, when the setting is genuinely operable. NIL means the row
    /// cannot be changed and its track is drawn locked-explained, never greyed: the
    /// design has no disabled state, and a live-looking switch that absorbs clicks
    /// silently is the exact defect E22 exists to end.
    var onToggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.one) {
            HStack(alignment: .center, spacing: Design.Space.three) {
                Text(setting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(setting.isDestructive ? Design.Ink.danger : Design.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle = setting.actionTitle {
                    ConsoleButton(title: actionTitle, kind: .deny)
                        .frame(width: 138)
                } else {
                    Track(isOn: setting.isOn, isLocked: setting.isLocked, onToggle: onToggle)
                }
            }
            Text(setting.detail)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if setting.isLocked {
                // 10/600 and NOT tertiary: a locked setting is a standing statement about the
                // operator's security, and it is the one note in this window that is
                // emphasised rather than whispered. The caption is the row's own: an ON
                // locked row says the requirement cannot be removed, and an OFF locked row
                // says the exemption is the server's policy rather than a switch here.
                Text(setting.lockedCaption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Design.Ink.textSecondary)
            }
        }
        .padding(.horizontal, Design.Space.three)
        .padding(.vertical, Design.Space.component)
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

/// The 38x22 switch track, shared with the popover's service control so the two cannot
/// drift apart.
///
/// A LOCKED track is drawn EXACTLY as an unlocked one, and that is not an oversight: the
/// design has no disabled state anywhere, and greying it would be inventing chrome it
/// explicitly rejected — the same class of mistake as painting an amber band it rejected.
/// The refusal is stated in WORDS beside the control ("Required — this cannot be turned
/// off") and enforced by the code refusing the change, and a switch that looks inert is
/// worse than one that looks live and is explained.
struct Track: View {
    let isOn: Bool
    var isLocked = false
    var onToggle: (() -> Void)?

    var body: some View {
        let shape = ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Design.Ink.accent : Design.Ink.surfaceSunken)
                .overlay(
                    Capsule().strokeBorder(
                        isOn ? .clear : Design.Ink.controlBorder,
                        lineWidth: 1,
                    ),
                )
            Circle()
                .fill(isOn ? Design.Ink.onAccent : Design.Ink.controlBorder)
                .frame(width: 18, height: 18)
                .padding(.horizontal, 2)
        }
        .frame(width: 38, height: 22)

        if let onToggle, !isLocked {
            Button(action: onToggle) { shape }.buttonStyle(.plain)
        } else {
            shape
        }
    }
}

/// The posture control, and the one thing in the product that is a three-way choice.
///
/// Selection is expressed in CHROME — a white fill and a control border on the chosen
/// option — and never in a variant name, because the design has no `selected` option: it
/// would be a fourth state somebody has to invent.
struct PostureControl: View {
    enum Choice: String, Equatable, CaseIterable {
        case strict
        case balanced
        case lockedDown

        var label: String {
            switch self {
            case .strict: "Ask every time"
            case .balanced: "Balanced"
            case .lockedDown: "Locked down"
            }
        }

        init(_ posture: Posture) {
            switch posture {
            case .strict: self = .strict
            case .balanced: self = .balanced
            case .lockedDown: self = .lockedDown
            }
        }

        var posture: Posture {
            switch self {
            case .strict: .strict
            case .balanced: .balanced
            case .lockedDown: .lockedDown
            }
        }

        /// What the option permits and what it refuses, in the operator's terms — the
        /// sentences the design carries beside the control, mirrored here so one edit
        /// cannot leave the other behind. Each clause is grounded in engine behaviour a
        /// server test pins: strict prompts even over a live grant and withdraws the
        /// durable options (AuthorizationPolicyTests' strict-posture pair), balanced
        /// answers from a standing grant before asking, locked down refuses without
        /// prompting. Invariant 17 holds because these are behaviours, not names.
        var explanation: String {
            switch self {
            case .strict:
                "Every request that needs approval prompts, even one a saved grant already "
                    + "covers. Grants are kept but never let a request skip a question. When "
                    + "you approve, the only options are this once or never — nothing is "
                    + "offered that would outlive the request."
            case .balanced:
                "If a saved grant covers the request it is answered without a prompt; "
                    + "otherwise you are asked, and what you are offered scales with breadth "
                    + "— a narrow one-shot approval for a narrow request, broader standing "
                    + "approvals for broader ones, and the broadest need your fingerprint."
            case .lockedDown:
                "Nothing asks you anything, because every request that would prompt is "
                    + "refused outright."
            }
        }
    }

    /// The two statements the control owes the operator no matter which option is chosen:
    /// why there is no permissive option to choose (the posture ladder deliberately stops
    /// at Balanced — widening what happens without asking is what this product exists to
    /// prevent), and that the never-prompt set is fixed in the server. Recording both HERE
    /// is the acceptance's own demand: an absence is not an answer.
    static let fixedStatements =
        "The server cannot be made more permissive than Balanced, and the short list of "
            + "requests that never prompt at all is fixed in the server, not set here."

    /// Every option's explanation, in the order the control shows them, followed by the
    /// fixed statements. ONE SOURCE for the block beside the control, so the design copy,
    /// the rendered window and the tests all read the same string.
    static var optionExplanations: String {
        Choice.allCases
            .map { "\($0.label) — \($0.explanation)" }
            .joined(separator: "\n")
            + "\n\n" + fixedStatements
    }

    /// The operator's choice, read from and written through the model: the getter is the
    /// posture the server is ACTUALLY enforcing (override, then stored, then strict), so
    /// the control's display can never be a hardcoded default, and the setter writes the
    /// same source the interceptor consults, so the next request is judged under the
    /// posture just chosen.
    private var selection: Choice {
        get { Choice(model.displayedPosture) }
        set { model.setPosture(newValue.posture) }
    }

    unowned let model: ConsoleModel

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            ForEach(Choice.allCases, id: \.self) { choice in
                let isChosen = choice == selection
                Button {
                    model.setPosture(choice.posture)
                } label: {
                    Text(choice.label)
                        .font(.system(size: 11, weight: isChosen ? .semibold : .regular))
                        .foregroundStyle(isChosen ? Design.Ink.textPrimary : Design.Ink.textSecondary)
                        .padding(.horizontal, Design.Space.chip)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                                .fill(isChosen ? Design.Ink.surface : Design.Ink.surfaceSunken),
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                                .strokeBorder(
                                    isChosen ? Design.Ink.controlBorder : .clear,
                                    lineWidth: 1,
                                ),
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.tight)
        .padding(.vertical, Design.Space.tight)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surfaceSunken),
        )
    }
}

/// One of the operator's own high-consequence applications.
///
/// Consequence is a fact about the operator's life, not a property of a taxonomy the
/// product could ship, so the list is theirs and the product escalates exactly where they
/// say. The placeholder is a different CHIP from a listed one — outlined and quiet, because
/// it is an invitation rather than a fact.
struct TargetChip: View {
    let title: String
    var isPlaceholder = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: isPlaceholder ? .regular : .semibold))
            .foregroundStyle(isPlaceholder ? Design.Ink.textTertiary : Design.Ink.textPrimary)
            .padding(.horizontal, Design.Space.three)
            .frame(height: 24)
            .background(
                Capsule().fill(isPlaceholder ? Design.Ink.surface : Design.Ink.surfaceRaised),
            )
            .overlay(
                Capsule().strokeBorder(
                    isPlaceholder ? Design.Ink.separator : Design.Ink.controlBorder,
                    lineWidth: 1,
                ),
            )
    }
}

/// Settings, 720pt, and the one window whose job is to let the operator change the
/// defaults everything else is measured against.
///
/// THE POSTURE CONTROL IS WIRED, and what it is wired to is the whole point: the model's
/// handle writes into the same source the interceptor consults per request, so selecting
/// a posture changes enforcement on the NEXT request in this process, with no restart.
/// The control displays `model.displayedPosture` — the posture actually in force, never
/// a hardcoded default — and when the environment override holds it says so, because an
/// operator changing a setting that is not taking effect deserves to be told why.
struct SettingsWindow: View {
    @Bindable var model: ConsoleModel
    @State private var targets: [String] = ["1Password", "Keychain Access", "Xcode"]

    var body: some View {
        ConsoleWindow(
            title: "Settings",
            subtitle: "Owner-private · stored under your own account",
            footer: Color.clear.frame(height: 0),
        ) {
            // SCROLLS, because this surface is taller than a screen-sized window and the
            // header and the rows below it were both off the bottom with nothing to reach
            // them. The operator's copy describes the last two sections — the switch that
            // "reveals what is permitted" and the reset — as security controls, and neither
            // was visible.
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.chip) {
                    SectionLabel(text: "POSTURE")
                        .padding(.top, 1)
                    PostureControl(model: model)
                    if model.postureHandle?.isOverriddenByEnvironment == true {
                        // STATED, NOT SILENT: the environment override wins over anything
                        // the operator stores, and a selection that is not taking effect
                        // without an explanation is a lie wearing a control.
                        Text("Controlled by the server's environment (EXACTMAC_POSTURE); your choice here is not taking effect.")
                            .font(.system(size: 11))
                            .foregroundStyle(Design.Ink.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(PostureControl.optionExplanations)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SectionLabel(text: "BIOMETRIC REQUIREMENTS")
                    ForEach(Self.biometricRows(model: model)) { SettingRow(setting: $0) }

                    SectionLabel(text: "HIGH-CONSEQUENCE TARGETS")
                    VStack(alignment: .leading, spacing: Design.Space.one) {
                        Text("Applications that always escalate")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Design.Ink.textPrimary)
                        Text(
                            "Requests against these require a biometric whatever their breadth, "
                                + "and are never covered by an existing grant. Consequence is a "
                                + "fact about your life, so you name it.",
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Design.Space.chip) {
                            ForEach(targets, id: \.self) { TargetChip(title: $0) }
                            TargetChip(title: "Add an application", isPlaceholder: true)
                        }
                    }
                    .padding(.horizontal, Design.Space.three)
                    .padding(.vertical, Design.Space.component)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                            .fill(Design.Ink.surface),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                            .strokeBorder(Design.Ink.separator, lineWidth: 1),
                    )

                    SectionLabel(text: "CONSOLE")
                    // THE ROW IS LIVE, and what it is live to is the model: it displays
                    // the server's actual gate and writes through the ceremony-gated
                    // toggle — the state is NOT held here, so it survives a relaunch and
                    // a second window cannot disagree with the first.
                    SettingRow(setting: SettingRow.Model(
                        id: "console",
                        title: "Require Touch ID to open the console",
                        detail: "Opening Grants or Activity reveals what is permitted and "
                            + "what was asked. Without this, anyone at the keyboard can "
                            + "read both. Turning it off — and back on — costs a "
                            + "fingerprint, and the attempt is recorded either way.",
                        isOn: model.displayedBiometricGate,
                    ), onToggle: {
                        model.setBiometricGate(!model.displayedBiometricGate)
                    })

                    SectionLabel(text: "RESET")
                    SettingRow(setting: SettingRow.Model(
                        id: "reset",
                        title: "Reset everything",
                        detail: "Revoke every grant, empty the high-consequence list and restore "
                            + "the default posture. The decision log is append-only and is not "
                            + "erased.",
                        isOn: false,
                        isDestructive: true,
                        actionTitle: "Reset ExactMac",
                    ))
                }
            }
        }
    }

    /// The design's four locked rows, verbatim, and the fifth which is the opposite case:
    /// friction deliberately NOT spent on a narrow one-shot ask. THE FIFTH IS LOCKED TOO,
    /// and the reason is E22's own finding: an unlocked row with no closure was a
    /// live-looking switch that absorbed clicks — the same pretend-control as the toggle
    /// in the CONSOLE section was. What it states is true of the server (a routine narrow
    /// one-shot costs no fingerprint; a script, an unsigned caller, a global standing
    /// grant or a high-consequence target always does — `AuthorizationPolicy
    /// .biometricRequirement` is the policy the captions paraphrase), and it is not the
    /// operator's to change from here, so the row says so instead of offering a switch.
    static func biometricRows(model _: ConsoleModel) -> [SettingRow.Model] {
        [
            .init(
                id: "script",
                title: "Run a shell, AppleScript or JavaScript",
                detail: "A shell can read the screen, the clipboard and the interface, so no "
                    + "script runs without a fingerprint.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "global",
                title: "Grant every application, indefinitely",
                detail: "The broadest grant ExactMac can issue. It stays in force until you "
                    + "revoke it, so approving it proves you are you.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "observe",
                title: "Observe any application continuously",
                detail: "Reads everything on screen, in every application, for as long as the "
                    + "grant lasts.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "revokeAll",
                title: "Revoke every grant at once",
                detail: "If someone else has your session, this is the first control they "
                    + "would use.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "allowOnce",
                title: "Allow once — this exact request",
                detail: "A narrow one-shot ask is where friction is deliberately not spent. "
                    + "The bar is set by what each request actually is — a routine read "
                    + "costs nothing, a script or an unsigned caller always costs a "
                    + "fingerprint.",
                isOn: false,
                isLocked: true,
                lockedCaption: "Fixed — the bar is set by what each request is, not by a "
                    + "switch here",
            ),
        ]
    }
}
