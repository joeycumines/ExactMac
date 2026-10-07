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

/// The menu bar status item: stenciled vector emblem derived directly from the ExactMac emblem.
///
/// Rendered via `Image(nsImage:)` with `isTemplate = true` so AppKit automatically handles
/// wallpaper tinting, light/dark appearance, and selection highlight states.
struct MenuBarGlyph: View {
    let state: ServiceState

    var body: some View {
        Image(nsImage: state.statusImage)
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

    var dotNSColor: NSColor {
        switch self {
        case .running, .pending: Design.NSInk.success
        case .stopped: Design.NSInk.textSecondary
        case .degraded, .reduced, .unreachable: Design.NSInk.caution
        }
    }

    /// Rasterised status item image for the menu bar.
    var statusImage: NSImage {
        switch self {
        case .running, .pending:
            MenuBarImages.running
        case .stopped:
            MenuBarImages.stopped
        case .degraded, .reduced, .unreachable:
            MenuBarImages.caution
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

private enum MenuBarImages {
    private static let glyphSvgString = """
    <svg version="1.0" xmlns="http://www.w3.org/2000/svg" width="18pt" height="18pt" viewBox="-64 -64 1152 1152" preserveAspectRatio="xMidYMid meet">
    <g transform="translate(0.000000,1024.000000) scale(0.100000,-0.100000)" fill="black" stroke="none">
    <path d="M2555 10230 c-44 -4 -98 -10 -120 -14 -22 -3 -69 -10 -105 -16 -100 -15 -249 -46 -315 -66 -33 -10 -62 -18 -65 -19 -11 -2 -61 -19 -170 -57 -152 -54 -409 -180 -540 -265 -325 -213 -671 -564 -846 -859 -63 -106 -198 -381 -224 -457 -33 -97 -89 -276 -94 -300 -2 -12 -11 -53 -19 -92 -35 -161 -36 -164 -49 -520 -8 -217 -8 -935 -1 -2605 6 -1268 13 -2325 17 -2350 3 -25 10 -79 15 -120 22 -169 29 -204 71 -370 60 -237 114 -381 232 -615 141 -280 277 -473 473 -670 216 -217 432 -374 700 -507 220 -110 537 -226 695 -255 14 -2 57 -10 95 -18 117 -23 192 -32 355 -43 138 -10 4940 -9 4980 1 14 3 54 9 90 12 74 6 107 11 205 30 39 8 81 16 95 18 158 29 475 145 695 255 268 133 484 290 700 507 196 197 332 390 473 670 118 234 172 378 232 615 42 166 49 201 71 370 5 41 12 95 15 120 4 25 11 1082 17 2350 7 1670 7 2388 -1 2605 -13 356 -14 359 -49 520 -8 39 -17 80 -19 92 -5 24 -61 203 -94 300 -26 76 -161 351 -224 457 -175 295 -521 646 -846 859 -131 85 -388 211 -540 265 -109 38 -159 55 -170 57 -3 1 -32 9 -65 19 -67 20 -215 51 -315 66 -36 6 -81 13 -100 16 -19 3 -80 9 -135 14 -119 11 -5002 11 -5120 0z m5230 -637 c22 -6 74 -17 115 -24 41 -7 95 -18 120 -26 25 -7 70 -21 100 -30 107 -31 173 -57 303 -117 42 -20 81 -36 86 -36 5 0 11 -4 13 -8 2 -5 48 -35 103 -67 55 -33 127 -79 160 -104 134 -101 315 -276 399 -386 25 -33 49 -64 53 -70 99 -126 222 -370 282 -555 39 -121 46 -151 71 -272 30 -151 33 -299 37 -2199 3 -1582 2 -1938 -9 -1946 -7 -6 -51 -25 -98 -43 -47 -18 -98 -39 -115 -45 -16 -7 -102 -40 -190 -75 -88 -34 -178 -70 -200 -80 -22 -10 -51 -21 -65 -25 -14 -4 -29 -11 -35 -15 -5 -4 -64 -28 -130 -53 -117 -45 -219 -85 -280 -112 -16 -7 -124 -50 -240 -95 -115 -44 -223 -87 -240 -94 -16 -8 -95 -39 -175 -71 -80 -31 -163 -65 -185 -75 -22 -9 -56 -23 -75 -29 -19 -7 -44 -17 -55 -21 -32 -13 -189 -75 -316 -124 -64 -25 -129 -51 -143 -58 -28 -12 -28 -12 -23 -1085 l5 -1073 -368 0 -368 0 -7 32 c-3 18 -17 80 -30 138 -13 58 -27 123 -31 145 -4 22 -8 42 -9 45 0 3 -8 37 -17 75 -9 39 -28 122 -43 185 -24 107 -34 151 -41 175 -1 6 -12 55 -23 110 -27 127 -40 183 -53 217 -14 38 -6 55 62 128 33 36 60 68 60 72 0 3 11 19 24 35 68 80 169 303 197 433 48 225 50 383 8 590 -26 126 -94 305 -152 394 -219 344 -578 584 -958 641 -515 77 -1038 -174 -1336 -641 -58 -89 -126 -268 -152 -394 -42 -207 -40 -365 8 -590 28 -130 129 -353 197 -433 13 -16 24 -32 24 -35 0 -4 27 -36 60 -72 68 -73 76 -90 62 -128 -13 -34 -26 -90 -53 -217 -11 -55 -22 -104 -23 -110 -7 -24 -17 -68 -41 -175 -15 -63 -34 -146 -43 -185 -9 -38 -17 -72 -17 -75 -1 -3 -5 -23 -9 -45 -4 -22 -18 -87 -31 -145 -13 -58 -27 -120 -30 -138 l-7 -32 -368 0 -368 0 5 1073 c5 1073 5 1073 -23 1085 -14 7 -79 33 -143 58 -127 49 -284 111 -316 124 -11 4 -36 14 -55 21 -19 6 -53 20 -75 29 -22 10 -105 44 -185 75 -80 32 -158 63 -175 71 -16 7 -124 50 -240 94 -115 45 -223 88 -240 95 -61 27 -163 67 -280 112 -66 25 -124 49 -130 53 -5 4 -21 11 -35 15 -14 4 -43 15 -65 25 -22 10 -112 46 -200 80 -88 35 -173 68 -190 75 -16 6 -68 27 -115 45 -47 18 -91 37 -98 43 -11 8 -12 364 -9 1946 4 1900 7 2048 37 2199 25 121 32 151 71 272 60 185 183 429 282 555 4 6 28 37 53 70 84 110 265 285 399 386 33 25 105 71 160 104 55 32 102 62 103 67 2 4 8 8 13 8 5 0 44 16 86 36 132 61 197 86 308 119 33 9 71 21 85 26 47 16 283 57 360 63 25 1 1199 2 2610 1 1880 0 2576 -4 2605 -12z m-2529 -6204 c206 -37 392 -162 500 -334 24 -40 44 -75 44 -79 0 -7 5 -20 40 -101 22 -50 25 -271 5 -360 -27 -122 -91 -229 -202 -336 -62 -60 -176 -139 -201 -139 -24 0 -35 -30 -24 -68 16 -54 74 -293 78 -317 1 -11 7 -40 14 -65 17 -68 31 -132 50 -225 5 -27 17 -81 26 -120 9 -38 20 -89 25 -113 5 -24 11 -47 14 -52 6 -10 43 -181 56 -255 4 -27 11 -61 14 -75 3 -14 10 -45 15 -70 6 -25 13 -57 16 -72 6 -28 6 -28 -606 -28 -612 0 -612 0 -606 27 3 16 10 48 16 73 5 25 12 56 15 70 3 14 10 48 14 75 13 74 50 245 56 255 3 5 9 28 14 52 5 24 16 75 25 113 9 39 21 93 26 120 19 93 33 157 50 225 7 25 13 54 14 65 4 24 62 263 78 317 11 38 0 68 -24 68 -25 0 -139 79 -201 139 -111 107 -175 214 -202 336 -20 89 -17 310 5 360 35 81 40 94 40 101 0 21 95 156 142 201 152 149 322 220 529 222 47 1 112 -4 145 -10z"/>
    <path d="M2700 9049 c-188 -15 -251 -27 -435 -86 -283 -91 -512 -248 -716 -493 -112 -134 -206 -303 -263 -473 -20 -59 -53 -187 -63 -242 -3 -22 -8 -838 -10 -1813 l-3 -1772 32 -15 c18 -8 83 -33 143 -56 61 -22 124 -47 140 -54 17 -7 62 -25 100 -40 39 -15 108 -42 155 -60 47 -18 112 -43 145 -55 33 -11 89 -34 125 -50 56 -24 306 -119 580 -220 41 -15 104 -39 140 -53 36 -14 94 -36 130 -50 36 -14 130 -50 210 -81 80 -31 153 -56 162 -56 10 0 28 21 46 53 42 77 87 149 169 272 159 239 254 358 418 520 62 61 117 120 123 132 8 13 11 105 11 266 0 136 2 251 5 256 11 17 -32 57 -85 78 -71 28 -281 103 -444 158 -71 24 -182 63 -245 85 -211 76 -484 171 -545 190 -33 10 -112 37 -175 60 -63 23 -129 46 -147 51 -66 20 -63 -20 -60 629 2 379 6 593 13 600 6 6 21 7 39 1 36 -11 294 -102 455 -161 119 -43 274 -99 540 -193 166 -59 314 -112 475 -172 55 -20 116 -41 135 -47 19 -6 53 -18 75 -28 22 -9 96 -36 165 -60 69 -23 148 -50 175 -60 28 -11 79 -29 115 -42 36 -13 74 -29 85 -35 20 -11 20 -24 23 -659 2 -357 7 -653 12 -659 11 -13 926 -13 940 1 5 5 10 279 12 657 3 636 3 649 23 660 11 6 49 22 85 35 36 13 88 31 115 42 28 10 106 37 175 60 69 24 143 51 165 60 22 10 56 22 75 28 19 6 80 27 135 47 161 60 309 113 475 172 266 94 421 150 540 193 161 59 419 150 455 161 18 6 33 5 39 -1 7 -7 11 -221 13 -600 3 -649 6 -609 -60 -629 -18 -5 -84 -28 -147 -51 -63 -23 -142 -50 -175 -60 -61 -19 -334 -114 -545 -190 -63 -22 -173 -61 -245 -85 -163 -55 -373 -130 -444 -158 -53 -21 -96 -61 -85 -78 3 -5 5 -120 5 -256 0 -161 3 -253 11 -266 6 -12 61 -71 123 -132 164 -162 259 -281 418 -520 82 -123 127 -195 169 -272 18 -32 36 -53 46 -53 9 0 82 25 162 56 335 130 383 148 480 184 274 101 524 196 580 220 36 16 92 39 125 50 33 12 98 37 145 55 47 18 117 45 155 60 39 15 84 33 100 40 17 7 80 32 140 54 61 23 125 48 143 56 l32 15 -3 1772 c-2 975 -7 1791 -10 1813 -47 265 -164 522 -326 715 -103 124 -241 250 -352 322 -128 84 -322 166 -518 218 -54 14 -155 28 -296 39 -124 10 -4694 10 -4825 0z"/>
    </g>
    </svg>
    """

    private static func makeBaseGlyph() -> NSImage {
        guard let data = glyphSvgString.data(using: .utf8),
              let image = NSImage(data: data)
        else {
            let img = NSImage(size: NSSize(width: 18, height: 18))
            img.isTemplate = true
            return img
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    /// Clean monochrome template emblem for normal service running / pending.
    static let running: NSImage = makeBaseGlyph()

    /// Dimmed template emblem for stopped / inactive service state.
    static let stopped: NSImage = {
        let base = running
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.38)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Caution status: emblem with amber badge dot.
    static let caution: NSImage = {
        let base = running
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw emblem
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

            // Knockout cutout to cleanly separate badge from emblem squircle rim
            let cutoutRect = NSRect(x: 11.25, y: 0.25, width: 6.5, height: 6.5)
            let cutoutPath = NSBezierPath(ovalIn: cutoutRect)
            NSGraphicsContext.current?.compositingOperation = .clear
            cutoutPath.fill()

            // Draw caution badge: 5pt amber circle at bottom-right
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let badgeRect = NSRect(x: 12, y: 1, width: 5, height: 5)
            let badgePath = NSBezierPath(ovalIn: badgeRect)
            Design.NSInk.caution.setFill()
            badgePath.fill()

            return true
        }
        image.isTemplate = false
        return image
    }()
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
            if let pending = model.pendingPrompt {
                // A BUTTON, and that is the whole change. This row used to be a `VStack` of
                // `Text`: the console displayed that a request was waiting and there was
                // nothing to click, which is the state the operator reported as "it does
                // nothing". It is the request's only entry point, so it is presented as one.
                PendingNotice(
                    count: model.waitingCount,
                    text: pending.popoverNoticeBody,
                ) {
                    model.openApproval()
                }
            } else if let band = model.failClosed {
                FailClosedBand(title: band.title, text: band.body)
            }
            ServiceToggle(isOn: model.isServiceRunning) { model.toggleService() }
            Text("Turning it back on does not restore grants you revoked.")
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
            // NO COUNTS, AND SAYING WHY. Both rows used to show a number that arrived over
            // the console socket; the socket is gone and this process cannot ask the server
            // it hosts for either figure yet, so `nil` is the honest detail. A number
            // computed here from something other than the store would be a guess about how
            // much of the operator's own history is exposed.
            MenuRow(
                title: "Grants",
                detail: nil,
                action: { Task { await model.openGrants() } },
            )
            MenuRow(
                title: "Activity",
                detail: nil,
                action: { Task { await model.openActivity() } },
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
    var count: Int = 1
    let text: String
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            pendingBody
        }
        .buttonStyle(.plain)
    }

    private var titleText: String {
        count > 1 ? "\(count) requests waiting for you" : "1 request waiting for you"
    }

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(titleText)
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
            .accessibilityLabel("ExactMac service")
            .accessibilityValue(isOn ? "Running" : "Stopped")
            .accessibilityHint("Turning this off stops the ExactMac service.")
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
