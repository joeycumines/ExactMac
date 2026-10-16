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
    /// The row's button action, when the setting is a destructive one-click act rather
    /// than a toggle. NIL means the row cannot be changed; a button that rendered
    /// without one absorbed clicks and did nothing, which is the defect this wiring
    /// exists to end.
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.one) {
            HStack(alignment: .center, spacing: Design.Space.three) {
                Text(setting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(setting.isDestructive ? Design.Ink.danger : Design.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle = setting.actionTitle, let onAction {
                    // A row that declares an action button but has no action is not drawn:
                    // rendering it would be a button that absorbs clicks and does nothing,
                    // which is the defect the explicit wiring exists to end.
                    ConsoleButton(title: actionTitle, kind: .deny, action: onAction)
                        .frame(width: 138)
                } else if setting.isLocked {
                    PolicyCallout(isOn: setting.isOn)
                } else {
                    Track(isOn: setting.isOn, onToggle: onToggle)
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

/// An informative status callout badge for locked server policy rows.
struct PolicyCallout: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: Design.Space.leading) {
            StatusDot(isOn ? Design.Ink.accent : Design.Ink.textSecondary, diameter: 6)
            Text(isOn ? "Enforced" : "Exempt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Design.Ink.textPrimary : Design.Ink.textSecondary)
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

/// Native macOS toggle switch for operable settings.
struct Track: View {
    let isOn: Bool
    var onToggle: (() -> Void)?

    var body: some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { _ in
                if let onToggle {
                    onToggle()
                }
            },
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(onToggle == nil)
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
                "Every request prompts for approval, even when covered by an existing grant. "
                    + "Grants are preserved but do not bypass prompts. "
                    + "Approvals apply only to the single request."
            case .balanced:
                "Requests covered by an active grant are approved automatically. "
                    + "Other requests prompt for approval. "
                    + "High-consequence requests require Touch ID."
            case .lockedDown:
                "All requests requiring approval are denied automatically without prompting."
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
        Picker("Posture", selection: Binding(
            get: { selection },
            set: { newChoice in
                model.setPosture(newChoice.posture)
            },
        )) {
            ForEach(Choice.allCases, id: \.self) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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

    var body: some View {
        ConsoleWindow(
            title: "Settings",
            subtitle: "Local Preferences",
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

                    SectionLabel(text: "CONSOLE")
                    // THE ROW IS LIVE, and what it is live to is the model: it displays
                    // the server's actual gate and writes through the ceremony-gated
                    // toggle — the state is NOT held here, so it survives a relaunch and
                    // a second window cannot disagree with the first.
                    SettingRow(setting: SettingRow.Model(
                        id: "console",
                        title: "Require Touch ID to open the console",
                        detail: "Require Touch ID to view active grants and activity history. "
                            + "Changing this setting requires biometric confirmation.",
                        isOn: model.displayedBiometricGate,
                    ), onToggle: {
                        model.setBiometricGate(!model.displayedBiometricGate)
                    })

                    SectionLabel(text: "RESET")
                    SettingRow(setting: SettingRow.Model(
                        id: "reset",
                        title: "Reset everything",
                        detail: "Revoke all active grants and restore default settings. "
                            + "The append-only audit log is preserved.",
                        isOn: false,
                        isDestructive: true,
                        actionTitle: "Reset ExactMac",
                    ), onAction: { model.resetEverything() })
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
                detail: "A shell can read the screen, the clipboard, and the interface, "
                    + "requiring biometric confirmation to execute.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "global",
                title: "Grant every application, until ExactMac quits (up to 8 hours)",
                detail: "The broadest grant ExactMac can issue. It exists only in memory and "
                    + "expires when ExactMac quits (or after 8 hours), requiring biometric confirmation.",
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
                detail: "Revokes all active grants across all sessions, requiring biometric confirmation.",
                isOn: true,
                isLocked: true,
            ),
            .init(
                id: "allowOnce",
                title: "Allow once — this exact request",
                detail: "Routine requests do not require biometric confirmation. "
                    + "High-consequence requests and unsigned callers always require Touch ID.",
                isOn: false,
                isLocked: true,
                lockedCaption: "Fixed — the bar is set by what each request is, not by a "
                    + "switch here",
            ),
        ]
    }
}
