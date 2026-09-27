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
        var isDestructive = false
        var actionTitle: String?
    }

    let setting: Model

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
                    Track(isOn: setting.isOn, isLocked: setting.isLocked)
                }
            }
            Text(setting.detail)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if setting.isLocked {
                // 10/600 and NOT tertiary: a locked setting is a standing statement about the
                // operator's security, and it is the one note in this window that is
                // emphasised rather than whispered.
                Text("Required — this cannot be turned off")
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
    }

    @Binding var selection: Choice

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            ForEach(Choice.allCases, id: \.self) { choice in
                let isChosen = choice == selection
                Button {
                    selection = choice
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
struct SettingsWindow: View {
    @State private var posture: PostureControl.Choice = .balanced
    @State private var targets: [String] = ["1Password", "Keychain Access", "Xcode"]
    @State private var requireTouchIDToOpen = true

    var body: some View {
        ConsoleWindow(
            title: "Settings",
            subtitle: "Owner-private · stored under your own account",
            footer: Color.clear.frame(height: 0),
        ) {
            VStack(alignment: .leading, spacing: Design.Space.chip) {
                SectionLabel(text: "POSTURE")
                PostureControl(selection: $posture)
                Text(
                    "The default. Friction scales with what a grant would actually permit, so "
                        + "a narrow one asks nothing and a broad one asks for a biometric.",
                )
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                SectionLabel(text: "BIOMETRIC REQUIREMENTS")
                ForEach(Self.biometricRows) { SettingRow(setting: $0) }

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
                SettingRow(setting: SettingRow.Model(
                    id: "console",
                    title: "Require Touch ID to open the console",
                    detail: "Opening the console reveals what is permitted and what was asked. "
                        + "Without this, anyone at the keyboard can read both.",
                    isOn: requireTouchIDToOpen,
                ))

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

    /// The design's four locked rows, verbatim, and the fifth which is the opposite case:
    /// friction deliberately NOT spent on a narrow one-shot ask, which is the only setting
    /// here that is optional in the other direction.
    private static let biometricRows: [SettingRow.Model] = [
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
            detail: "The broadest grant there is. It is a standing permission, so it is worth "
                + "proving you are you.",
            isOn: true,
            isLocked: true,
        ),
        .init(
            id: "observe",
            title: "Observe any application continuously",
            detail: "Sustained reading of everything on screen, in any application, for the "
                + "life of the grant.",
            isOn: true,
            isLocked: true,
        ),
        .init(
            id: "revokeAll",
            title: "Revoke every grant at once",
            detail: "Wiping every standing permission is exactly the moment a stolen session "
                + "would want.",
            isOn: true,
            isLocked: true,
        ),
        .init(
            id: "allowOnce",
            title: "Allow once — this exact request",
            detail: "A narrow one-shot ask is where friction is deliberately not spent. "
                + "Turning this on makes every trivial request cost a fingerprint.",
            isOn: false,
        ),
    ]
}
