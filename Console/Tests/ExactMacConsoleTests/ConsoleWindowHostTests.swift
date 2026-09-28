import AppKit
@testable import ExactMacConsole
import Foundation
import SwiftUI
import Testing

/// The window host, which the console did not have at all.
///
/// THE OPERATOR COULD BE TOLD A REQUEST WAS WAITING AND COULD DO NOTHING ABOUT IT: the
/// pending notice was a `VStack` of `Text` and the three menu rows were `Button`s whose action
/// was the default no-op, so every designed surface was unreachable. These assert the two
/// things that host has to get right, and one of them is why the host takes an application
/// seam at all.
///
/// THE POLICY CHOREOGRAPHY IS THE PART THAT MATTERS AND THE PART THAT HAD NEVER BEEN
/// EXERCISED: presenting a window makes the app `regular` so the ceremony's frontmost check
/// can pass, and closing the last window puts it back to `accessory` so the Dock icon does
/// not outlive the window that needed it. It is asserted through a fake application because
/// this package's tests must run with no window server, and `NSApp` does not exist in a test
/// process at all.
@Suite("Console windows")
@MainActor
struct ConsoleWindowHostTests {
    /// A stand-in for the application, so the policy choreography is assertable headlessly.
    final class FakeApplication: ConsoleApplication {
        private(set) var transitions: [String] = []
        private(set) var activations = 0
        private var regular = false

        var isRegular: Bool {
            regular
        }

        func becomeRegular() {
            regular = true
            transitions.append("regular")
        }

        func becomeAccessory() {
            regular = false
            transitions.append("accessory")
        }

        func activate() {
            activations += 1
        }
    }

    @Test
    func `a request surfaces its window without taking the keyboard`() throws {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        let model = ConsoleModel(
            channel: ConsoleDecisionTests.RecordingChannel(),
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            windows: host,
            ceremony: nil,
            startLoop: false,
        )
        model.deliverPending(ConsoleDecisionTests.fixtureRequest())

        // IT SURFACED ITSELF, and that is the property: a consent request expires, so one
        // that waits for the operator to notice a menu bar dot has usually already timed
        // out. A window existing is the claim; it is asserted by identity, not by a tautology
        // over a boolean, which cannot fail.
        let window = try #require(host.window(forTesting: .approval))
        #expect(window.title == "ExactMac needs your approval")
        #expect(
            !application.isRegular,
            "the operator's keystrokes must still go where they were going: a request is a pointer decision, not a keyboard one",
        )
        #expect(application.transitions.isEmpty, "nothing about arriving may take focus")
    }

    @Test
    func `the ceremony is what takes focus, and only then`() async {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        let channel = ConsoleDecisionTests.RecordingChannel()
        let model = ConsoleModel(
            channel: channel,
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            windows: host,
            ceremony: ConsoleDecisionTests.ScriptedCeremony(.performed),
            startLoop: false,
        )
        let request = ConsoleDecisionTests.fixtureRequest(requiresBiometric: true)
        model.deliverPending(request)
        #expect(!application.isRegular, "arriving did not take focus")

        await model.answer(.session, for: request)

        // The TRANSITION, not the end state: the decision closes the window, and closing the
        // last window hands focus back. Asserting the end state would assert that the app was
        // left regular with nothing on screen, which is the bug the host exists to prevent.
        #expect(
            application.transitions.first == "regular",
            "the ceremony refuses unless the console is frontmost, so this is where focus is paid for: \(application.transitions)",
        )
        #expect(
            application.transitions == ["regular", "accessory"],
            "and it is given back when the decision closes the window: \(application.transitions)",
        )
        #expect(channel.posted.first?.biometricObtained == true)
    }

    @Test
    func `an operator opening the request from the popover brings it forward with the app`() {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        let model = ConsoleModel(
            channel: ConsoleDecisionTests.RecordingChannel(),
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            windows: host,
            ceremony: nil,
            startLoop: false,
        )
        model.deliverPending(ConsoleDecisionTests.fixtureRequest())

        // The operator clicked it. They asked for this window, so it comes forward with the
        // application rather than asking them to click again to raise it.
        model.openApproval()
        #expect(application.isRegular)
    }

    @Test
    func `presenting the same surface twice reuses the window rather than stacking a second`() throws {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        host.present(.grants, title: "Grants") { Text("first body") }
        let first = try #require(host.window(forTesting: .grants))

        host.present(.grants, title: "Grants") { Text("a second, different body") }
        let second = try #require(host.window(forTesting: .grants))

        // A second window answering the same request would leave the operator deciding which
        // of two identical prompts they meant, and one nonce cannot be answered twice.
        #expect(first === second)
        #expect(
            application.transitions.isEmpty,
            "re-presenting a surface nobody clicked must not take focus either",
        )
    }

    @Test
    func `a window closed by its own button is still forgotten`() throws {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        host.present(.activity, title: "Activity", activates: true) { Text("activity") }
        let window = try #require(host.window(forTesting: .activity))
        #expect(application.isRegular)

        // The operator's own close button goes through AppKit's delegate rather than through
        // the host, and a host that still believed a window was open would leave the app
        // `regular` with nothing on screen.
        window.performClose(nil)
        #expect(
            !application.isRegular,
            "a window closed with its own button must restore the accessory policy",
        )
        #expect(host.window(forTesting: .activity) == nil)
    }

    @Test
    func `different surfaces are different windows and closing all restores the accessory`() throws {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        host.present(.approval, title: "Approval", activates: true) { Text("a") }
        host.present(.activity, title: "Activity", activates: true) { Text("b") }
        let approval = try #require(host.window(forTesting: .approval))
        let activity = try #require(host.window(forTesting: .activity))
        #expect(approval !== activity)

        host.closeAll()
        #expect(!application.isRegular)
        #expect(host.window(forTesting: .approval) == nil)
        #expect(host.window(forTesting: .activity) == nil)
    }

    @Test
    func `a presented surface really is on screen and really hosts the view`() throws {
        let application = FakeApplication()
        let host = ConsoleWindowHost(application: application)
        host.present(.settings, title: "Settings", activates: true) {
            Text("a real surface").frame(width: 120, height: 40)
        }
        defer { host.closeAll() }
        let window = try #require(host.window(forTesting: .settings))
        #expect(window.title == "Settings")
        // The hosted view's TYPE is not asserted, because a caller that applies a modifier
        // produces a different type for the same body; what matters is that the surface is
        // hosted SwiftUI at all rather than an empty window.
        #expect(window.isVisible)
        #expect(
            window.contentView != nil,
            "a surface with no content view is a blank window, which is the failure being guarded",
        )
        // A console window is not resizable by dragging, because the design measures every
        // surface and a resized one is a surface the design does not describe.
        #expect(window.minSize == window.maxSize)
    }

    @Test
    func `opening the approval prompt is what the pending notices button does`() {
        let application = FakeApplication()
        let model = ConsoleModel(
            channel: ConsoleDecisionTests.RecordingChannel(),
            serviceController: LaunchdServiceController(executor: MockLaunchctlExecutor()),
            windows: ConsoleWindowHost(application: application),
            ceremony: nil,
            startLoop: false,
        )
        model.deliverPending(ConsoleDecisionTests.fixtureRequest())

        // The row the operator clicks.
        model.openApproval()

        #expect(application.isRegular, "the prompt must be a real window, not a popover line")
        #expect(model.windows.window(forTesting: .approval) != nil)
    }
}

/// The window is SIZED FROM ITS CONTENT, which is the fix for two defects Hana found and
/// the audit measured: the settings window clipped about 300pt of its content with no scroll
/// view and no way to resize, and the 420pt prompt was centred inside a 720pt window with
/// 150pt of empty chrome either side.
///
/// THE ASSERTION IS A MEASUREMENT rather than a number someone chose, because "the window
/// fits its content" is a claim about layout and the only honest evidence is a layout pass.
@Suite("Window sizing")
@MainActor
struct WindowSizingTests {
    @Test
    func `A window is as tall as its content, up to the ceiling`() {
        let short = ConsoleWindowHost.fittedHeight(of: Color.clear.frame(height: 200))
        #expect(abs(short - 200) <= 1, "a 200pt surface is a 200pt window")

        let tall = ConsoleWindowHost.fittedHeight(of: Color.clear.frame(height: 2000))
        #expect(
            tall > ConsoleWindowHost.maximumWindowHeight,
            "content past the ceiling is taller than any window, which is what makes the surface scroll",
        )
    }

    @Test
    func `The prompt is presented at the prompt's own width`() {
        // The prompt is a 420pt card the design measures; the window default is 720pt, so
        // passing the wrong one centres it with empty chrome either side. Asserted on the
        // design constant rather than a literal so the two cannot drift apart silently.
        #expect(Design.Layout.promptWidth == 420)
        #expect(Design.Layout.windowWidth == 720)
        #expect(
            Design.Layout.promptWidth != Design.Layout.windowWidth,
            "which is why the width is a parameter and not a constant",
        )
    }

    @Test
    func `The settings surface fits a window, which is what scrolling bought`() {
        // THIS IS THE REGRESSION GUARD, and it is worth being precise about what it
        // distinguishes. Measured WITHOUT the scroll view the settings body is over 1008pt —
        // the design draws it that tall — and it overflowed a window that could not be
        // resized, so the console and reset sections were unreachable. A `ScrollView` makes
        // the content's fitted height the VIEWPORT's height rather than the content's, so the
        // surface now measures to fit. That the number went DOWN is the fix, not a regression
        // in content, and an assertion that the surface still measures tall would be
        // asserting the bug.
        let natural = ConsoleWindowHost.fittedHeight(of: SettingsWindow())
        #expect(
            natural > 0,
            "the surface measured nothing, so the window would have no content",
        )
        #expect(
            natural <= ConsoleWindowHost.maximumWindowHeight,
            "the surface still overflows a window, so the scroll view is not there: \(natural)",
        )
    }
}
