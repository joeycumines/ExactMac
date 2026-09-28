import AppKit
@testable import ExactMacConsole
import Foundation
import ServiceManagement
import Testing

/// The fail-closed posture, in the form it takes now.
///
/// ## Why this suite exists and what it replaced
///
/// There was a test asserting that killing a *separate console process* made a mutator fail
/// closed. That reasoning is RETRACTED: there is no separate console process, so "the
/// console is not running" is not a condition the system can be in. The condition that
/// replaces it is "the app is not running, or the app is running and cannot put a window in
/// front of the operator" — and the second half is the one worth asserting, because the app
/// being alive is exactly what makes it easy to get wrong. A process that is running, looks
/// healthy in the menu bar, and cannot ask anybody is the dangerous one: a consent request
/// would sit until it expired and be denied while a green dot said otherwise.
///
/// ## What is asserted, and what is not
///
/// STATES AND BANDS, NEVER STRINGS. A test that matches prose is a test of a spelling, and
/// the operator-facing wording here is a copy decision that will be revised. The properties
/// worth holding are: the process refuses to report a state that claims consent is
/// obtainable, it reports the band that says the safe direction, and it does not clear that
/// band. Those are falsifiable, and they survive the copy changing.
@Suite("Fail-closed posture")
@MainActor
struct FailClosedPostureTests {
    /// A model whose state comes from its own reasoning, driven without a server.
    ///
    /// IT TAKES A START-AT-LIN ITEM DOUBLE rather than reaching the real one, because the
    /// real `SMAppService` reports `.notFound` for a test binary that is not a bundle and a
    /// suite that consulted it would be measuring the harness rather than the posture.
    private func model(presentation: OperatorInterface) -> ConsoleModel {
        ConsoleModel(
            startAtLogin: StartAtLogin(item: AlwaysRegisteredLoginItem()),
            presentation: presentation,
        )
    }

    @Test
    func `A process that cannot present a window never reports that it is running`() {
        let subject = model(presentation: .headless)

        subject.apply(.running)

        // The state difference, not the words: `Running` is the claim that ExactMac will
        // ask the operator when something needs approving.
        #expect(subject.serviceState != .running)
        #expect(subject.serviceState != .pending)
        // And the band is present, so the operator is not left with a healthy-looking
        // menu bar and no explanation.
        #expect(subject.failClosed != nil)
    }

    @Test
    func `A process that can present a window does report running`() {
        // The counterpart, and the reason the veto is a rule about the process rather than a
        // blanket downgrade: the veto must not cost the app its own healthy state.
        let subject = model(presentation: .application)

        subject.apply(.running)

        #expect(subject.serviceState == .running)
        #expect(subject.failClosed == nil)
    }

    @Test
    func `The start-at-login toggle is not a way to change the service state`() {
        // IT USED TO BE, AND THAT WAS THE BUG THIS SUITE EXISTS TO CATCH. The toggle drove
        // launchctl, and turning the "service" on wrote `.running` and cleared the
        // fail-closed band directly — so an operator pressing it on a process that could not
        // ask anybody watched the band disappear. The toggle is now start-at-login, which
        // has no business touching whether the server is serving, and this pins that.
        let subject = model(presentation: .application)
        let before = subject.serviceState

        subject.setServiceEnabled(false)

        #expect(subject.serviceState == before, "start-at-login is not the service, and must not report as one")
        // And the reverse, on a process that cannot ask: the band stays whatever it was.
        let headless = model(presentation: .headless)
        headless.apply(.running)
        headless.setServiceEnabled(true)
        #expect(headless.serviceState != .running, "the veto still holds when the toggle is pressed")
        #expect(headless.failClosed != nil)
    }

    @Test
    func `The veto is narrow, so a state that already denies passes through`() {
        // `.stopped` and the other three already mean "consent is not available", so the
        // veto must not replace them: an operator who stopped ExactMac deserves to be told
        // it is stopped rather than given a vaguer reason they cannot act on.
        let subject = model(presentation: .headless)

        for state in [ServiceState.stopped, .degraded, .reduced, .unreachable] {
            subject.apply(state)
            #expect(subject.serviceState == state, "\(state) was rewritten to \(subject.serviceState)")
            #expect(subject.failClosed != nil, "\(state) must say why")
        }
    }

    @Test
    func `A hosted server that started is reported as running`() {
        // THE OTHER HALF OF THE SAME FIX. The app used to learn it was running by failing
        // to reach a peer process, so it could not say so at all: the only reporter was a
        // socket loop that found nothing and reported `unreachable` — which put the
        // fail-closed band in front of an operator while the app was asking them things.
        // The server this process owns is now reported by this process.
        let subject = model(presentation: .application)

        subject.reportServerStarted()

        #expect(subject.serviceState == .running)
        #expect(subject.failClosed == nil)
    }

    @Test
    func `A server that could not start is reported as not serving, not as unable to ask`() {
        // THE FAULT HAS ITS OWN STATE, and conflating the two sent an operator after the
        // wrong fix. "Nothing can put the question in front of you" and "the server is not
        // running" are different facts with different remedies, and the start-failure path
        // used to report the first while meaning the second. The notice carries the reason;
        // the state says only what is true of the server.
        let subject = model(presentation: .application)

        subject.reportServerStartFailure(reason: "the socket pathname is held by another server")

        #expect(subject.serviceState == .stopped, "a server that is not running is not serving")
        // And it is DISTINCT from the state that means this process cannot prompt, which is
        // the whole point: conflating them is what the assertion is guarding.
        #expect(subject.serviceState != .unreachable)
        #expect(subject.failClosed != nil)
        #expect(subject.pendingNotice?.contains("held by another server") == true)
    }

    @Test
    func `The not-serving band does not blame a toggle the operator may not have touched`() throws {
        // IT USED TO READ "You turned ExactMac off", and this state is reached when the
        // app's own server failed to start — so an operator who had touched nothing was told
        // they had. The band names the state; the reason is the notice and the log.
        let subject = model(presentation: .application)
        subject.reportServerStartFailure(reason: "boom")

        let band = try #require(subject.failClosed)
        #expect(band.title != "The service is off")
        #expect(!band.body.contains("You turned"), "got \(band.body)")
    }

    @Test
    func `Constructing the model reports no failure that did not happen`() {
        // A DEFAULT-VALUE PROPERTY, SO IT IS ASSERTED AS ONE. The app used to start a loop
        // that polled a socket for a console in another process; there is no such process,
        // so the loop could only report that nothing was reachable — and it did so every two
        // seconds, which is how a working app came to display its fail-closed band.
        let subject = model(presentation: .application)

        #expect(subject.serviceState != .unreachable, "a freshly built model must not claim a fault")
        #expect(subject.failClosed == nil)
    }

    @Test
    func `The refused state still renders as a caution rather than a healthy dot`() {
        // INVARIANT 17 in a form a test can hold: the operator must be able to tell from the
        // menu bar that something is not normal. `Running` and `Cannot ask` are both drawn,
        // so the assertion is on the two states disagreeing rather than on a colour, which
        // is a design decision and not the property.
        let headless = model(presentation: .headless)
        headless.apply(.running)
        let application = model(presentation: .application)
        application.apply(.running)

        #expect(headless.serviceState.pillLabel != application.serviceState.pillLabel)
        #expect(headless.serviceState.dot != application.serviceState.dot)
    }
}

// MARK: - Doubles

/// A login item that is already registered and accepts whatever it is told, so the
/// registration is not what a posture test is measuring.
private final class AlwaysRegisteredLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SMAppService.Status = .enabled

    var status: SMAppService.Status {
        lock.withLock { stored }
    }

    func register() throws {
        lock.withLock { stored = .enabled }
    }

    func unregister() throws {
        lock.withLock { stored = .notRegistered }
    }
}
