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
    func becomeRegular()
    func becomeAccessory()
    func activate()
}

/// The live application.
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

    func becomeRegular() {
        application.setActivationPolicy(.regular)
    }

    func becomeAccessory() {
        application.setActivationPolicy(.accessory)
    }

    func activate() {
        application.activate(ignoringOtherApps: true)
    }
}

/// The console's windows, which the app did not have.
///
/// EVERY DESIGNED SURFACE WAS UNREACHABLE. `ApprovalPrompt`, `GrantsManager`,
/// `ActivityTimeline`, `SettingsWindow` and `EnvelopeReview` are all built, and nothing
/// ever put one on screen: the popover's menu rows are `Button`s whose action is the default
/// no-op, and the pending notice is a `VStack` of `Text`. So the console could receive a
/// consent request, display that one was waiting, and offer the operator no way to answer —
/// which is the whole function of the program.
///
/// ACTIVATION IS NOT COSMETIC HERE, and that is why this is not a plain `NSWindow`. The
/// ceremony in `BiometricCeremony` refuses unless the console is FRONTMOST — a biometric
/// performed against a hidden window proves nothing and is indistinguishable from one the
/// operator never intended — and an `LSUIElement` accessory is not frontmost when nothing
/// of it is on screen. So presenting a window makes the app `regular`, and closing the last
/// one puts it back to `accessory`: the Dock icon exists exactly while a window needs it and
/// the menu bar item is never replaced by it.
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
        windowDelegate.onClose = { [weak self] surface in
            self?.windowClosed(surface)
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
    func present(
        _ surface: Surface,
        title: String,
        activates: Bool = false,
        @ViewBuilder content: () -> some View,
    ) {
        if activates {
            becomeActiveApplication()
        }

        if windows[surface] != nil {
            // Re-presenting the SAME request must not build a second window answering the
            // same nonce, so the content is only built when there is nothing to reuse.
            bringToFront(surface, activates: activates)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Design.Layout.windowWidth,
                height: Design.Layout.minWindowHeight,
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        // A console window is not resizable by dragging, because the design measures every
        // surface and a resized one is a surface the design does not describe. Equal minimum
        // and maximum is the honest way to say fixed, and no frame autosave: autosaving a
        // size the design does not have is the same mistake one layer down.
        window.minSize = window.frame.size
        window.maxSize = window.frame.size
        window.isReleasedWhenClosed = false
        window.delegate = windowDelegate
        windowDelegate.surface = surface
        window.center()
        windows[surface] = window
        bringToFront(surface, activates: activates)
    }

    /// The window for a surface, for the tests that assert the host did its job.
    /// /// NAMED AS TESTING rather than exposed, so nothing in the app can start poking at the
    /// host's bookkeeping and a test cannot quietly become a second way to open a window.
    func window(forTesting surface: Surface) -> NSWindow? {
        windows[surface]
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
    }

    func close(_ surface: Surface) {
        guard let window = windows[surface] else { return }
        window.close()
        // The delegate does the bookkeeping, so this is only a fallback for a window that
        // was never on screen; a second close is a no-op rather than a double removal.
        windowClosed(surface)
    }

    /// Closes every window, for the operator quitting with one open.
    func closeAll() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        restoreRestingPolicy()
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
    /// /// Called at the moment the operator commits to an option that needs a sensor, not when
    /// the request arrives: activation is the price of the ceremony and is not paid until the
    /// ceremony is about to happen.
    func activateForCeremony() {
        becomeActiveApplication()
        application.activate()
    }

    private func windowClosed(_ surface: Surface) {
        guard windows.removeValue(forKey: surface) != nil else { return }
        if windows.isEmpty {
            restoreRestingPolicy()
        }
    }

    private func becomeActiveApplication() {
        guard !application.isRegular else { return }
        application.becomeRegular()
    }

    private func restoreRestingPolicy() {
        guard application.isRegular else { return }
        application.becomeAccessory()
    }
}

/// One delegate for every console window, telling the host which surface just closed.
///
/// A SINGLE DELEGATE rather than one per window, because AppKit holds the delegate weakly
/// and a per-window delegate would have to be retained somewhere for the window's whole
/// life. The surface is the delegate's current field rather than a per-instance value, which
/// is sound only because console windows are surfaced one at a time from the main actor and
/// a window cannot be closed from two surfaces.
private final class SurfaceWindowDelegate: NSObject, NSWindowDelegate {
    var surface: ConsoleWindowHost.Surface?
    var onClose: ((ConsoleWindowHost.Surface) -> Void)?

    func windowWillClose(_: Notification) {
        guard let surface else { return }
        onClose?(surface)
    }
}
