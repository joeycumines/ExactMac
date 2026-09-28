import SwiftUI

/// The consent console.
///
/// A MENU-BAR ACCESSORY with no Dock icon, because the operator's way in is the menu bar
/// and always has been — Hana's first word on the interaction was a directly controllable
/// system-tray item, and a Dock icon would be a second, weaker way in.
///
/// `MenuBarExtra` and not an `NSStatusItem` with a target-action pair, because
/// `NSControl.action` is a `Selector?` and a SwiftUI menu cannot own one without a bridging
/// object that exists only to be a target.
/// The SwiftUI scene. It is NOT `@main`: a file named `main.swift` IS the top-level entry
/// file, so the entry point is the `ExactMacConsoleMain` enum there and the App struct has
/// to be launched from it.
/// The one console state, shared by the SwiftUI scene and the server's consent closure.
///
/// A HOLDER RATHER THAN A CONSTRUCTOR PARAMETER, because `App.main()` is static and takes
/// none, so the scene cannot be given the instance the entry point built. Both halves reach
/// it here instead, which is the only arrangement in which they are guaranteed to be the
/// same object rather than two that happen to look alike.
@MainActor
enum ConsoleRuntime {
    static let model = ConsoleModel()
}

struct ExactMacConsoleApp: App {
    /// The one model, taken from `ConsoleRuntime` rather than constructed here.
    ///
    /// `App.main()` IS A STATIC PROTOCOL REQUIREMENT, so a model cannot be handed to the
    /// scene through it — the instance the App wraps is not an argument anyone controls. The
    /// shared holder is how the scene and the server's consent closure end up looking at the
    /// SAME state, which is the property that matters: two models would mean a request
    /// rendered into a window whose state nobody is reading.
    @State private var model = ConsoleRuntime.model

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(model: model)
        } label: {
            // The item is ICON-ONLY and 22pt, and the design says so: the only thing that
            // must survive at that size is the state. Three of the five states share an
            // amber dot, so the full five-way discrimination is delegated to the popover's
            // word — which is why the popover's pill must be intrinsic-width.
            MenuBarGlyph(state: model.serviceState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The 22pt status item: a 14pt ring with a 6pt dot inside it, and nothing else.
///
/// No glyph and no text, by design. The ring's colour never changes, so the dot is the only
/// signal and it survives greyscale and colour blindness by being one of three values.
struct MenuBarGlyph: View {
    let state: ServiceState

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Design.Ink.controlBorder, lineWidth: 1)
                .frame(width: 14, height: 14)
            StatusDot(state.dot, diameter: 6)
        }
        .frame(width: 22, height: 22)
        // The switch carries no text and therefore no accessibility label in the design, so
        // one has to be supplied or the item is unreadable to VoiceOver.
        .accessibilityLabel("ExactMac")
        .accessibilityValue(state.spokenLabel)
    }
}

/// The service's state, which is a property of the LISTENER and not a flag.
enum ServiceState: String, Equatable, CaseIterable, Sendable {
    case running
    case pending
    case degraded
    case reduced
    case stopped
    case unreachable

    var dot: Color {
        switch self {
        case .running, .pending: Design.Ink.success
        case .stopped: Design.Ink.textSecondary
        // Degraded, reduced and cannot-ask are DELIBERATELY the same amber. The menu bar is
        // not required to tell them apart, only to signal that something is not normal.
        case .degraded, .reduced, .unreachable: Design.Ink.caution
        }
    }

    /// The word, which is what the design delegates the five-way distinction to.
    ///
    /// `.unreachable` USED TO SAY "No console", which was true of the two-process deployment
    /// and is false now. The app IS the console: there is one process, and what is missing
    /// is a window to ask through. An operator reading "No console" while ExactMac is in
    /// their menu bar has no way to reconcile the two, and the honest word names the thing
    /// that is actually absent.
    var pillLabel: String {
        switch self {
        case .running: "Running"
        case .pending: "Running"
        case .degraded: "Degraded"
        case .reduced: "Reduced"
        case .stopped: "Stopped"
        case .unreachable: "Cannot ask"
        }
    }

    var headline: String {
        switch self {
        case .running: "Balanced — friction scales with what a grant would permit"
        case .pending: "Balanced — one request is waiting for you"
        case .unreachable: "Every request that needs consent is being denied"
        case .degraded: "Nothing can be requested while the service is down"
        case .reduced: "TCP listener: no approvals and no identity"
        case .stopped: "The service is off, so nothing is served"
        }
    }

    var spokenLabel: String {
        switch self {
        case .pending: "Running, with a request waiting for you"
        default: pillLabel
        }
    }

    /// The security footnote. The TCP card is the only one that abandons the
    /// `Unix socket · owner-only` shape, and that is the point: it is the one state
    /// where the system is exposed to a network.
    /// /// The strings are the design's, corrected in `docs/design.fig` first. They said
    /// "launchd-managed", which stopped being true when the server began binding its own
    /// socket and holding the pathname under a lock the kernel releases when it dies;
    /// launchd supervises the process and nothing else. `owner-only` is what the operator
    /// actually relies on, and it is still exactly true.
    var transport: String {
        switch self {
        case .running, .pending: "Unix socket · owner-only · no network listener"
        case .unreachable: "Unix socket · owner-only · no window to ask through"
        case .degraded: "Unix socket · owner-only · the service is not answering"
        case .reduced: "TCP listener · no owning user to authenticate"
        case .stopped: "Unix socket · owner-only · disabled"
        }
    }
}

/// The popover: 360pt, content-hugging, FLAT.
///
/// No shadow. `NSPopover` casts one by default and the design draws a 1pt hairline card, so
/// the shadow is turned off and the border does the separation. Fixed width, variable
/// height: the design has no single height, and the card's height is driven entirely by
/// whether the optional state band is present.
struct MenuBarPopover: View {
    @Bindable var model: ConsoleModel

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.component) {
            head
            if let notice = model.pendingNotice, model.pendingPrompt != nil {
                // A BUTTON, and that is the whole change. This row used to be a `VStack` of
                // `Text`: the console displayed that a request was waiting and there was
                // nothing to click, which is the state the operator reported as "it does
                // nothing". It is the request's only entry point, so it is presented as one.
                PendingNotice(text: notice) { model.openApproval() }
            } else if let notice = model.pendingNotice {
                PendingNotice(text: notice) {}
            } else if let band = model.failClosed {
                FailClosedBand(title: band.title, text: band.body)
            }
            ServiceToggle(isOn: model.isServiceEnabled) { model.toggleService() }
            Text("Start ExactMac when you log in. Turning this off does not revoke grants you already made.")
                .font(.system(size: 10))
                .foregroundStyle(Design.Ink.textTertiary)
            Rectangle().fill(Design.Ink.separator).frame(height: 1)
            menu
            Rectangle().fill(Design.Ink.separator).frame(height: 1)
            MenuRow(title: "Quit ExactMac", detail: nil, isDestructive: true) { model.quit() }
            Text(model.serviceState.transport)
                .font(.system(size: 10))
                .foregroundStyle(Design.Ink.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.frame)
        .frame(width: Design.Layout.popoverWidth)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                .strokeBorder(Design.Ink.separator, lineWidth: 1),
        )
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: Design.Space.one) {
            HStack(spacing: Design.Space.three) {
                Text("ExactMac")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Spacer(minLength: 0)
                StatusPill(kind: .risk(model.serviceState.pillLabel, model.serviceState.dot))
            }
            Text(model.serviceState.headline)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menu: some View {
        VStack(spacing: Design.Space.hair) {
            // ACTIONS, where there were none. `MenuRow` has always been a `Button`; every
            // call site passed the default no-op, so three rows that look like navigation
            // did nothing at all.
            MenuRow(
                title: "Grants",
                detail: model.activeGrantCount.map { "\($0) active" },
                action: { model.openGrants() },
            )
            MenuRow(
                title: "Activity",
                detail: model.activityCount.map { formatted($0) },
                action: { model.openActivity() },
            )
            MenuRow(title: "Settings", detail: nil, action: { model.openSettings() })
        }
    }

    private func formatted(_ count: Int) -> String {
        let digits = String(count)
        var grouped = ""
        for (index, character) in digits.enumerated().reversed() {
            if index > 0, index % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(character)
        }
        return String(grouped.reversed())
    }
}

/// A pending request is NOT a fault, so it gets an accent rule rather than amber, and it
/// states how many are waiting. A count the operator cannot see is a window they do not
/// know is open.
private struct PendingNotice: View {
    let text: String
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            pendingBody
        }
        .buttonStyle(.plain)
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text("1 request waiting for you")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Design.Ink.accentText)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Design.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Design.Space.three)
        .padding(.vertical, Design.Space.component)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.Ink.surface),
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .strokeBorder(Design.Ink.accent, lineWidth: 1),
        )
    }
}

/// Failing closed, and saying so.
///
/// The band is ENTIRELY NEUTRAL — grey fill, grey rule, no amber anywhere — even though the
/// component note says "amber, not red". The amber in the composition is on the status pill
/// directly above. Every body says what the system is DOING rather than the action it
/// refused, because a stopped service that reads as a fault teaches the wrong lesson, and
/// every one ends on the protective consequence.
private struct FailClosedBand: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.component) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Design.Rule.unknown)
                .frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
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
    }
}

/// The persistent service control.
///
/// The row states in PROSE that the state survives a restart, because a toggle an operator
/// believes is a preference will not be trusted to stop a service. The switch itself carries
/// no text, which is why the state has to be spelled out beside it.
private struct ServiceToggle: View {
    let isOn: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.three) {
            VStack(alignment: .leading, spacing: Design.Space.hair) {
                Text("ExactMac service")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.Ink.textPrimary)
                Text(isOn
                    ? "Running on a Unix socket. This survives a restart."
                    : "Stopped and disabled. It will not come back on its own.")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onToggle) {
                // A 38x22 track with an 18pt knob and 16pt of travel, inset 2pt at each
                // end. The inset belongs to the KNOB: putting it on the track squashes the
                // capsule and turns the knob into a half-moon.
                ZStack(alignment: isOn ? .trailing : .leading) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start ExactMac when you log in")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint("Turning this off does not revoke grants you already made.")
        }
        .padding(Design.Space.three)
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

private struct MenuRow: View {
    let title: String
    let detail: String?
    var isDestructive = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Design.Space.component) {
                Text(title)
                    .font(.system(size: 13, weight: isDestructive ? .semibold : .regular))
                    .foregroundStyle(isDestructive ? Design.Ink.danger : Design.Ink.textPrimary)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Ink.textTertiary)
                }
            }
            .padding(.horizontal, Design.Space.component)
            .padding(.vertical, Design.Space.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
