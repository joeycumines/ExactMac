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
    /// A channel that never connects, so `apply` is driven without a server. The state
    /// under test is produced by the model's own reasoning, not by a socket.
    private func model(presentation: OperatorInterface) -> ConsoleModel {
        ConsoleModel(
            channel: RecordingChannel(),
            serviceController: NeverServiceController(),
            presentation: presentation,
            startLoop: false,
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
    func `Turning the service on does not grant a headless process a healthy state`() async {
        // THE SECOND ROUTE, and the one that would have survived a fix applied only to
        // `apply`. `setServiceEnabled` assigned `.running` itself and cleared the band, so
        // an operator pressing the toggle on a process that could not ask anybody would
        // have watched the fail-closed band disappear.
        let subject = model(presentation: .headless)

        try? await subject.setServiceEnabled(true)

        #expect(subject.serviceState != .running)
        #expect(subject.failClosed != nil)
    }

    @Test
    func `Turning the service off still reports stopped, not the vaguer safe state`() async {
        // The veto is deliberately narrow. `.stopped` already means "consent is not
        // available", and an operator who turned ExactMac off deserves to be told it is off
        // rather than being given a vaguer reason it cannot act on.
        let subject = model(presentation: .headless)

        try? await subject.setServiceEnabled(false)

        #expect(subject.serviceState == .stopped)
        #expect(subject.failClosed != nil)
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

/// A channel that claims a reachable server and never produces a frame, so the model's own
/// state reasoning is what is under test.
private final class RecordingChannel: ConsoleChannel, @unchecked Sendable {
    private(set) var posted: [ConsentDecision] = []

    var isConnected: Bool {
        true
    }

    func connect() async throws {}
    func disconnect() {}
    func nextFrame(timeout _: Duration) async throws -> ConsoleFrame? {
        nil
    }

    func post(_ decision: ConsentDecision) async throws {
        posted.append(decision)
    }

    func query(_: QueryKind) async throws {}
}

/// A service controller that accepts whatever it is told, so the launchctl layer is not what
/// a test is measuring. It is a double, not a stub of the product: the product's own
/// `LaunchdServiceController` is exercised by the launchctl suite.
private final class NeverServiceController: ServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    func isServiceEnabled() async throws -> Bool {
        lock.withLock { enabled }
    }

    func setServiceEnabled(_ value: Bool) async throws {
        lock.withLock { enabled = value }
    }
}
