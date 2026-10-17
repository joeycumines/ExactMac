import ExactMacServer
import SwiftUI

/// A 10/600 uppercase section label separating settings sections.
private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Design.Ink.textSecondary)
    }
}

/// The top bar under DEFAULT ACCESS summarizing overall posture and offering bulk actions.
struct AccessSummaryBar: View {
    let isAllowingAll: Bool
    let onAllowAll: () -> Void
    let onResetDefaults: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.three) {
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text(isAllowingAll ? "Allowing all local requests" : "Ask before new capabilities")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text(isAllowingAll
                    ? "All capabilities are set to Allow. Decisions are still logged."
                    : "Prompts when an agent has no matching grant or pre-authorized session.")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if isAllowingAll {
                ConsoleButton(
                    title: "Reset to Ask defaults",
                    kind: .secondary,
                    height: 28,
                    action: onResetDefaults,
                )
                .frame(width: 160)
            } else {
                HStack(spacing: Design.Space.two) {
                    ConsoleButton(
                        title: "Allow all",
                        kind: .secondary,
                        height: 28,
                        action: onAllowAll,
                    )
                    .frame(width: 84)

                    ConsoleButton(
                        title: "Reset defaults",
                        kind: .quiet,
                        height: 28,
                        action: onResetDefaults,
                    )
                    .frame(width: 112)
                }
            }
        }
        .padding(.horizontal, Design.Space.three)
        .padding(.vertical, Design.Space.component)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(Design.Ink.surfaceRaised),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }
}

/// One capability group row under DEFAULT ACCESS with an Ask | Allow segmented control.
struct CapabilityAccessRow: View {
    let group: CapabilityGroup
    let level: AccessLevel
    let onSelect: (AccessLevel) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.three) {
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text(group.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Picker("", selection: Binding(
                get: { level },
                set: { onSelect($0) }
            )) {
                Text("Ask").tag(AccessLevel.ask)
                Text("Allow").tag(AccessLevel.allow)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
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
}

/// Unanswered prompt timeout setting row with 60s | 90s | 3m picker.
struct TimeoutSettingRow: View {
    let seconds: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.three) {
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text("Unanswered prompts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text("Deny automatically when the timer expires or the screen locks. Active grants continue.")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Picker("", selection: Binding(
                get: { seconds },
                set: { onSelect($0) }
            )) {
                Text("60s").tag(60)
                Text("90s").tag(90)
                Text("3m").tag(180)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
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
}

/// A setting card row with either an operable native toggle or a destructive action button.
struct SettingRow: View {
    struct Model: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String
        var isOn: Bool = false
        var isLocked = false
        var lockedCaption = "Required — this cannot be turned off"
        var isDestructive = false
        var actionTitle: String? = nil
    }

    let setting: Model
    var onToggle: (() -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.hair) {
            HStack(alignment: .center, spacing: Design.Space.three) {
                Text(setting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(setting.isDestructive ? Design.Ink.danger : Design.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle = setting.actionTitle, let onAction {
                    ConsoleButton(title: actionTitle, kind: .deny, action: onAction)
                        .frame(width: 138)
                } else if onToggle != nil {
                    Track(isOn: setting.isOn, onToggle: onToggle)
                }
            }
            Text(setting.detail)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// Legacy/compatibility posture control retained for test fixtures and posture assertions.
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

    static let fixedStatements =
        "The server cannot be made more permissive than Balanced, and the short list of "
            + "requests that never prompt at all is fixed in the server, not set here."

    static var optionExplanations: String {
        Choice.allCases
            .map { "\($0.label) — \($0.explanation)" }
            .joined(separator: "\n")
            + "\n\n" + fixedStatements
    }

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

/// Settings, 720pt, redesigned to match docs/design.fig and DESIGN.md:
/// (1) DEFAULT ACCESS: AccessSummaryBar and 4 CapabilityAccessRow controls (Inspect, Clipboard, Apps/Input, Scripts).
/// (2) TOUCH ID: 4 operable SettingRow toggles (Scripts, Broad approvals, Unsigned callers, Console open).
/// (3) UNATTENDED & SYSTEM: TimeoutSettingRow (60s | 90s | 3m) and Start at login toggle.
/// (4) RESET: Reset to defaults destructive button.
struct SettingsWindow: View {
    @Bindable var model: ConsoleModel

    var isAllowingAll: Bool {
        model.defaultAccess.isAllowingAll
    }

    private var defaultAccessSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.two) {
            SectionLabel(text: "DEFAULT ACCESS")
                .padding(.top, 1)
            AccessSummaryBar(
                isAllowingAll: isAllowingAll,
                onAllowAll: { model.allowAll() },
                onResetDefaults: { model.resetDefaults() },
            )
            ForEach(CapabilityGroup.allCases, id: \.self) { group in
                CapabilityAccessRow(
                    group: group,
                    level: model.defaultAccess.accessLevel(for: group),
                    onSelect: { newLevel in
                        model.setDefaultAccess(level: newLevel, for: group)
                    },
                )
            }
        }
    }

    private var touchIDSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.two) {
            SectionLabel(text: "TOUCH ID")
            SettingRow(
                setting: SettingRow.Model(
                    id: "scripts",
                    title: "Run scripts or shell commands",
                    detail: "Require Touch ID before running shell, AppleScript, or JavaScript commands.",
                    isOn: model.touchIDRules.scriptsAndTerminal,
                ),
                onToggle: {
                    model.setTouchIDRule(
                        .scriptsAndTerminal,
                        enabled: !model.touchIDRules.scriptsAndTerminal,
                    )
                },
            )
            SettingRow(
                setting: SettingRow.Model(
                    id: "broad",
                    title: "All-application and multi-hour approvals",
                    detail: "Require Touch ID for grants across all apps, pre-authorized sessions, and Allow all.",
                    isOn: model.touchIDRules.broadApprovals,
                ),
                onToggle: {
                    model.setTouchIDRule(
                        .broadApprovals,
                        enabled: !model.touchIDRules.broadApprovals,
                    )
                },
            )
            SettingRow(
                setting: SettingRow.Model(
                    id: "unsigned",
                    title: "Unsigned or unverified callers",
                    detail: "Require Touch ID when the calling binary has no valid code signature.",
                    isOn: model.touchIDRules.unsignedCallers,
                ),
                onToggle: {
                    model.setTouchIDRule(
                        .unsignedCallers,
                        enabled: !model.touchIDRules.unsignedCallers,
                    )
                },
            )
            SettingRow(
                setting: SettingRow.Model(
                    id: "console",
                    title: "Open Grants and Activity",
                    detail: "Require Touch ID to inspect active grants or the decision log.",
                    isOn: model.touchIDRules.consoleOpen,
                ),
                onToggle: {
                    model.setTouchIDRule(
                        .consoleOpen,
                        enabled: !model.touchIDRules.consoleOpen,
                    )
                },
            )
        }
    }

    private var unattendedSystemSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.two) {
            SectionLabel(text: "UNATTENDED & SYSTEM")
            TimeoutSettingRow(
                seconds: model.consentTimeoutSeconds,
                onSelect: { newSeconds in
                    model.setConsentTimeoutSeconds(newSeconds)
                },
            )
            SettingRow(
                setting: SettingRow.Model(
                    id: "login",
                    title: "Start ExactMac at login",
                    detail: "Launch the menu-bar console and local Unix socket when you sign in.",
                    isOn: model.isStartAtLoginEnabled,
                ),
                onToggle: {
                    model.toggleStartAtLogin()
                },
            )
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.two) {
            SectionLabel(text: "RESET")
            SettingRow(
                setting: SettingRow.Model(
                    id: "reset",
                    title: "Reset to defaults",
                    detail: "Revoke all active grants and restore default access and Touch ID rules. The audit log is kept.",
                    isOn: false,
                    isDestructive: true,
                    actionTitle: "Reset ExactMac",
                ),
                onAction: {
                    model.resetEverything()
                },
            )
        }
    }

    var body: some View {
        ConsoleWindow(
            title: "Settings",
            subtitle: "Permissions and Touch ID rules for local agents",
        ) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Design.Space.four) {
                    defaultAccessSection
                    touchIDSection
                    unattendedSystemSection
                    resetSection
                }
            }
        }
    }
}
