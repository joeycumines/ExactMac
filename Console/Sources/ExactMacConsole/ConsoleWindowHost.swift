import AppKit
import SwiftUI

/// The two things the host asks of AppKit about the APPLICATION rather than of a window.
///
/// A SEAM, and the reason is the test suite's own constraint: this package must run its
/// tests with no window server and no human, and `NSApp` does not exist in a test process at
/// all — reaching for it is an implicit unwrap that crashes the whole runner. The policy
/// choreography is also the part that was never exercised, because there was no host, so it
/// is exactly the part worth asserting without a window server. Window creation itself is
/// verified in the running product, where a window server exists.
@MainActor
protocol ConsoleApplication: AnyObject {
    var isRegular: Bool { get }
    /// Whether the console is the frontmost (active) application. The honest signal
    /// for "is the operator already looking at us", which decides whether a new request
    /// needs to ask for attention at all.
    var isActive: Bool { get }
    func activate()
    /// Asks the system to draw the operator's attention to the console.
    func requestUserAttention()
}

/// The live application. Permanent accessory activation policy with zero Dock icon flicker.
@MainActor
final class LiveConsoleApplication: ConsoleApplication {
    private let application: NSApplication

    /// `NSApplication.shared` rather than the global `NSApp`, because the global is an
    /// implicitly-unwrapped value that does not exist before the app has launched.
    init(application: NSApplication = .shared) {
        self.application = application
    }

    var isRegular: Bool {
        application.activationPolicy() == .regular
    }

    func activate() {
        application.activate(ignoringOtherApps: true)
    }

    var isActive: Bool {
        application.isActive
    }

    func requestUserAttention() {
        application.requestUserAttention(.informationalRequest)
    }
}

/// Floating utility panel for the approval prompt that stays permanently accessory.
final class ConsoleFloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

/// The console's windows. Permanent accessory activation policy without Dock thrashing.
@MainActor
final class ConsoleWindowHost {
    /// The surfaces, named rather than identified by view type, so presenting the same one
    /// twice brings the existing window forward instead of stacking a second copy — which
    /// would let an operator answer one prompt in one window while a stale duplicate of the
    /// same request sits behind it.
    enum Surface: Hashable {
        case approval
        case grants
        case activity
        case settings
    }

    private var windows: [Surface: NSWindow] = [:]
    private let windowDelegate = SurfaceWindowDelegate()
    private let application: any ConsoleApplication

    init(application: any ConsoleApplication = LiveConsoleApplication()) {
        self.application = application
        windowDelegate.onClose = { [weak self] closingWindow in
            self?.windowClosed(closingWindow)
        }
    }

    /// - Parameter activates: whether to bring the APPLICATION to the front as well as the
    /// window.
    /// /// DEMANDING ATTENTION IS NOT THE SAME AS STEALING FOCUS, and the distinction is the
    /// whole reason this is a parameter. A consent request expires, and a request that
    /// expires unseen is a denial the operator never knew about — so a prompt that needs
    /// deciding must surface on its own, with its window on screen, while the operator is
    /// doing something else. Taking the keyboard away from them while they type is a
    /// different and much worse thing, and nothing about the request requires it: a request
    /// that needs no ceremony is decided with the pointer.
    /// /// The ceremony is what forces activation, and only at the moment the operator commits
    /// to an option that needs one: `BiometricCeremony` refuses unless the console is
    /// frontmost, because a biometric shown against a hidden window proves nothing. So the
    /// app becomes `regular` when a sensor is about to be used and not one moment earlier.
    /// The widest a window may be, and the tallest.
    ///
    /// A CEILING AND NOT A SIZE. The two surfaces are different shapes — the prompt is a
    /// 420pt card the design measures to 710, and the settings and activity windows are 720pt
    /// lists the design draws at their natural height — so one fixed content rect letterboxed
    /// the prompt with 150pt of empty window either side, and clipped roughly 300pt off the
    /// bottom of the settings window with no scroll view and no way to resize. The window now
    /// takes the width its surface declares and the height its content needs, up to this
    /// ceiling, and anything past the ceiling scrolls inside the surface rather than off the
    /// bottom of the screen.
    static let maximumWindowHeight: CGFloat = 1008
    /// The minimum height for the settings window, keeping the primary action (Posture control) visible.
    static let minimumSettingsWindowHeight: CGFloat = 480

    func present(
        _ surface: Surface,
        title: String,
        width: CGFloat = Design.Layout.windowWidth,
        activates: Bool = false,
        updateIfPresent: Bool = false,
        @ViewBuilder content: () -> some View,
    ) {
        // EVERY NEW REQUEST asks for the operator's attention when the console is not
        // already frontmost — including one that QUEUES behind an active prompt, because
        // the operator may have looked away between arrivals and the queue is invisible
        // until this request becomes the active one. The two paths that are NOT new
        // requests do not ask: `activates` is the operator's own click (they are already
        // here), and `updateIfPresent` alone is a content refresh of the request the
        // operator is already looking at (re-opening from the popover, expanding options,
        // or the queue advance onto a window that never closed).
        if surface == .approval, !activates, !updateIfPresent {
            requestAttentionIfNeeded()
        }
        if activates {
            application.activate()
        }

        if windows[surface] != nil {
            // Re-presenting the SAME request must not build a second window answering the
            // same nonce, so the content is only built when there is nothing to reuse.
            if updateIfPresent {
                setContent(surface, content: content)
            }
            bringToFront(surface, activates: activates)
            return
        }

        let hosting = NSHostingView(rootView: content())
        // The content is asked how tall it wants to be, rather than the window being told,
        // because a window that guesses is a window that clips.
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        let height = min(
            max(fitted.height, 1),
            Self.maximumWindowHeight,
        )

        let window: NSWindow
        if surface == .approval {
            let panel = ConsoleFloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            )
            panel.title = title
            panel.contentView = hosting
            panel.minSize = panel.frame.size
            panel.maxSize = panel.frame.size
            panel.delegate = windowDelegate
            panel.center()
            window = panel
        } else {
            let isSettings = (surface == .settings)
            var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if isSettings {
                styleMask.insert(.resizable)
            }
            let standardWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: styleMask,
                backing: .buffered,
                defer: false,
            )
            standardWindow.title = title
            standardWindow.contentView = hosting
            if isSettings {
                // The settings window can be resized by dragging its corner, within limits that
                // keep it usable — a minimum that shows the primary action and a maximum bounded
                // by the display it is on rather than by the content's natural height.
                let screenHeight = standardWindow.screen?.visibleFrame.height
                    ?? NSScreen.main?.visibleFrame.height
                    ?? Self.maximumWindowHeight
                let maxHeight = max(screenHeight, height)
                standardWindow.minSize = NSSize(width: width, height: Self.minimumSettingsWindowHeight)
                standardWindow.maxSize = NSSize(width: width, height: maxHeight)
            } else {
                standardWindow.minSize = standardWindow.frame.size
                standardWindow.maxSize = standardWindow.frame.size
            }
            standardWindow.isReleasedWhenClosed = false
            standardWindow.delegate = windowDelegate
            standardWindow.center()
            window = standardWindow
        }
        windows[surface] = window
        bringToFront(surface, activates: activates)
    }

    /// The window for a surface, for the tests that assert the host did its job.
    /// /// NAMED AS TESTING rather than exposed, so nothing in the app can start poking at the
    /// host's bookkeeping and a test cannot quietly become a second way to open a window.
    func window(forTesting surface: Surface) -> NSWindow? {
        windows[surface]
    }

    /// Whether a surface's window is currently presented.
    func isPresented(_ surface: Surface) -> Bool {
        windows[surface] != nil
    }

    /// Replaces a presented surface's content, which is how an already-open window comes to
    /// show something new.
    /// /// IT REPLACES THE CONTENT VIEW rather than closing and reopening, because closing the
    /// window would take the operator's attention with it, and because the window is
    /// positioned for a surface the operator may have moved.
    func setContent(
        _ surface: Surface,
        @ViewBuilder content: () -> some View,
    ) {
        guard let window = windows[surface] else { return }
        window.contentView = NSHostingView(rootView: content())
        // Replacing the content ALSO brings the window forward: a surface showing
        // something new must not sit behind the app the operator was using, or the new
        // content is invisible and the request it carries goes unanswered. This is the
        // half that keeps a queued request visible when the active one is answered and
        // the window is reused rather than reopened.
        bringToFront(surface, activates: false)
    }

    /// The height a surface's content asks for, which is what the window is sized from.
    ///
    /// EXPOSED FOR THE TEST THAT PINS IT, because "the settings window fits its content" is a
    /// claim about measurement and the only honest evidence is a measurement.
    static func fittedHeight(of content: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    func close(_ surface: Surface) {
        guard let window = windows[surface] else { return }
        window.close()
        // The delegate does the bookkeeping, so this is only a fallback for a window that
        // was never on screen; a second close is a no-op rather than a double removal.
        windowClosed(window)
    }

    /// Closes every window, for the operator quitting with one open.
    func closeAll() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
    }

    /// - Parameter activates: whether the APPLICATION comes forward with the window. When it
    /// does not, the window still orders front and is visible, which is the whole point —
    /// the request is on screen and the operator's keystrokes still go where they were going.
    private func bringToFront(_ surface: Surface, activates: Bool) {
        guard let window = windows[surface] else { return }
        if activates {
            window.makeKeyAndOrderFront(nil)
            application.activate()
        } else {
            // `orderFront` rather than `makeKeyAndOrderFront`: keying a window takes the
            // keyboard from whatever the operator is typing into, and the request does not
            // need the keyboard to be decided.
            window.orderFront(nil)
        }
    }

    /// Brings the application forward for a ceremony, and is a no-op when it is already.
    func activateForCeremony() {
        application.activate()
    }

    /// Asks for the operator's attention, but only when the console is not already the
    /// frontmost app. A no-op when it is: the operator is already looking, and asking for
    /// attention from an app that already has it is noise, not attention.
    private func requestAttentionIfNeeded() {
        guard !application.isActive else { return }
        application.requestUserAttention()
    }

    private func windowClosed(_ closingWindow: NSWindow) {
        guard let surface = windows.first(where: { $0.value === closingWindow })?.key else { return }
        windows.removeValue(forKey: surface)
    }
}

/// One delegate for every console window, telling the host which surface just closed.
///
/// A SINGLE DELEGATE rather than one per window, because AppKit holds the delegate weakly
/// and a per-window delegate would have to be retained somewhere for the window's whole
/// life. The closing window is identified by matching against tracked windows.
private final class SurfaceWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: ((NSWindow) -> Void)?

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose?(window)
    }
}
