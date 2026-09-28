import AppKit
import Foundation
import os
import SwiftUI

/// What the popover reads, and the one place the console decides anything.
///
/// Every state here is a property of the LISTENER, not a flag the console sets: whether the
/// service is up, whether it is answering, and whether it is reachable at all. The console
/// reports those; it does not decide them.
@MainActor
@Observable
final class ConsoleModel {
    private(set) var serviceState: ServiceState = .running
    private(set) var isServiceEnabled = true
    private(set) var activeGrantCount: Int?
    private(set) var activityCount: Int?
    /// `.none` when there is nothing wrong, and the band when there is. An OPTIONAL SLOT at a
    /// fixed index, which is why the popover's height is driven by it and nothing else.
    private(set) var failClosed: (title: String, body: String)?
    private(set) var pendingNotice: String?
    var pendingPrompt: PendingRequest?

    private let channel: any ConsoleChannel
    private let serviceController: any ServiceControlling
    private let onServiceDisabled: (@Sendable () async throws -> Void)?
    /// Whether this process can put a consent prompt in front of the operator.
    ///
    /// IT IS A DEPENDENCY RATHER THAN A CONSTANT so the one behaviour that matters — that
    /// a process with nowhere to show a window never reports itself as running — is
    /// assertable. Classified once at launch from the real process, and never re-derived,
    /// because a window server session cannot appear under a running app and a bundle
    /// cannot be shed by one either.
    private let presentation: OperatorInterface
    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "console",
    )

    /// The window host and the ceremony are dependencies rather than constructions, so a
    /// test can drive a decision without a window server or a sensor — which is the only way
    /// either is testable unattended, and the console has to be testable unattended.
    /// /// THE HOST IS ALSO READABLE, because the test that proves the operator's button opens a
    /// window has to be able to see whether one opened; the accessor is the only way out, and
    /// it is read-only so nothing in the app can drive the host that way.
    let windows: ConsoleWindowHost

    /// The request whose options are expanded, or nil for the collapsed affordance.
    /// /// HELD HERE AND NOT IN THE VIEW because the view is rebuilt from the request, and a flag
    /// inside it would reset every time the window's content was refreshed. It is also the
    /// only place a second request can be distinguished from the first: a stale window that
    /// said "options expanded" for a request that is no longer pending is a decision offered
    /// on the wrong question.
    private var optionsExpandedFor: String?
    private let ceremony: (any CeremonyPerforming)?

    /// What the activity window shows. Both are read from the server's reply, and BOTH ARE
    /// STATE ON THE SERVER'S CLOCK rather than this process's, which is why the console does
    /// not compute them: the store and the audit own their instants and a display that
    /// invented its own would disagree with the record it claims to show.
    private var activityRows: [ActivityRow.Model] = []
    private var activityIntegrity: IntegrityBadge.State = .unchecked
    private var activitySubtitle = "No decisions recorded yet"

    /// The channel's loop, held so it has an owner to be cancelled by. The model is the
    /// only thing in this app whose lifetime is the process's, which is exactly the lifetime
    /// the channel has.
    /// /// A BOX rather than a `var`, because a `@MainActor` type's `deinit` is nonisolated and
    /// cannot read or write an isolated property — so a cancellable task held directly would
    /// either not compile or, if it did, could not be stopped.
    private let channelLoop = ChannelLoopBox()

    init(
        channel: any ConsoleChannel = ConsoleChannelClient.live(),
        serviceController: any ServiceControlling = LaunchdServiceController(),
        onServiceDisabled: (@Sendable () async throws -> Void)? = nil,
        presentation: OperatorInterface = ServerHosting.current(),
        windows: ConsoleWindowHost = ConsoleWindowHost(),
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
        startLoop: Bool = true,
    ) {
        self.channel = channel
        self.serviceController = serviceController
        self.onServiceDisabled = onServiceDisabled
        self.presentation = presentation
        self.windows = windows
        self.ceremony = ceremony
        if startLoop {
            // NOT `.task` ON THE POPOVER: a View task is cancelled when the view leaves the
            // hierarchy, and the popover leaves it every time the operator clicks away — so
            // the channel would connect only while nobody was looking.
            channelLoop.set(Task { [weak self] in
                await self?.run()
            })
        }
    }

    deinit {
        channelLoop.cancel()
    }

    /// Holds the channel loop so a nonisolated `deinit` can cancel it.
    private final class ChannelLoopBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>?) {
            lock.withLock { self.task = task }
        }

        func cancel() {
            lock.withLock { task }?.cancel()
        }
    }

    // MARK: The service control

    /// Changes the service enablement state in launchd, revoking standing grants on disable.
    func setServiceEnabled(_ enabling: Bool) async throws {
        let previousEnabled = isServiceEnabled
        let previousState = serviceState
        let previousFailClosed = failClosed
        let previousGrants = activeGrantCount

        isServiceEnabled = enabling
        // Through `vetoed` rather than assigned, so turning the service ON cannot make a
        // process that cannot present a window report itself as running. The optimistic
        // update is rolled back on failure either way; what changed is that the optimistic
        // state is now one the process is actually entitled to show.
        serviceState = vetoed(enabling ? .running : .stopped)
        if !enabling {
            activeGrantCount = 0
            failClosed = (
                "The service is off",
                "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
            )
        } else if serviceState == .running {
            failClosed = nil
        }
        logger.info("Service \(enabling ? "enabled" : "disabled", privacy: .public) by the operator")
        do {
            try await serviceController.setServiceEnabled(enabling)
            if !enabling, let onServiceDisabled {
                try await onServiceDisabled()
            }
        } catch {
            isServiceEnabled = previousEnabled
            serviceState = previousState
            failClosed = previousFailClosed
            activeGrantCount = previousGrants
            throw error
        }
    }

    /// Toggling drives launchd, the platform's own mechanism, and never a bespoke flag file.
    func toggleService() {
        let enabling = !isServiceEnabled
        Task { [weak self] in
            do {
                try await self?.setServiceEnabled(enabling)
            } catch {
                self?.handleServiceControlError(error, desiredState: enabling)
            }
        }
    }

    /// Synchronizes the in-memory state with launchd's persistent configuration.
    func refreshServiceState() async {
        do {
            let enabled = try await serviceController.isServiceEnabled()
            isServiceEnabled = enabled
            if !enabled {
                serviceState = .stopped
                failClosed = (
                    "The service is off",
                    "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
                )
            } else if serviceState == .stopped {
                // Through `vetoed` for the same reason `setServiceEnabled` is: a service that
                // is enabled is not a service that can ask the operator anything.
                serviceState = vetoed(.running)
                if serviceState == .running {
                    failClosed = nil
                }
            }
        } catch {
            logger.warning("Failed to refresh service state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A toggle that did not take is TOLD TO THE OPERATOR, and that is the whole point.
    /// /// `setServiceEnabled` already rolls its optimistic state back, so without this the
    /// operator sees the switch spring back and nothing else: no message, no error, and no
    /// way to tell a service that refused to stop from a button that was not pressed. A
    /// control the operator cannot read the result of is a control they will press again,
    /// and pressing it again is how a service gets left half-configured.
    private func handleServiceControlError(_ error: any Error, desiredState: Bool) {
        let wanted = desiredState ? "on" : "off"
        logger.error(
            "Failed to set service state to \(wanted, privacy: .public): \(error.localizedDescription, privacy: .public)",
        )
        pendingNotice = "Could not turn ExactMac \(wanted). \(error.localizedDescription)"
    }

    func quit() {
        windows.closeAll()
        NSApp.terminate(nil)
    }

    // MARK: The windows

    /// Opens the approval prompt for the request that is waiting.
    /// /// NOTHING ELSE CAN ANSWER IT, which is why this exists at all. The popover states that
    /// one request is waiting; before this, there was no way to see it, let alone answer
    /// it, and a request that cannot be answered becomes a timeout and then a denial.
    /// /// A NEW WINDOW EACH TIME is wrong and reusing is right: the same request has one nonce,
    /// and a second window answering the same nonce would leave the operator deciding which
    /// of two identical prompts they meant.
    /// Installs a request the operator can be asked about.
    /// /// THE SAME ENTRY THE CHANNEL USES, so a test that drives this drives the real path
    /// rather than a parallel one: a second route into `pendingPrompt` would let a test
    /// pass against state the console could never actually reach.
    func deliverPending(_ request: PendingRequest) {
        // A new request COLLAPSES the options, and the expansion was for the previous one.
        // Leaving it set would offer the new request the previous one's breadth at a glance.
        optionsExpandedFor = nil
        pendingPrompt = request
        pendingNotice = "\(request.executablePath) wants "
            + "\(request.capability)"
        apply(.pending)
        // IT SURFACES ITSELF, AND THAT IS NOT OPTIONAL. A consent request expires, and one
        // that expires unseen becomes a denial the operator never knew was asked for. Waiting
        // for the operator to notice the menu bar dot and click it means the request has
        // already timed out whenever they are not looking at the menu bar, which is almost
        // always. The window orders front WITHOUT activating: the decision is on screen and
        // the operator's keystrokes still go where they were going.
        windows.present(
            .approval,
            title: "ExactMac needs your approval",
            // The prompt's OWN width, not the window's default. It is a 420pt card, and
            // putting it in a 720pt window centred it with 150pt of empty chrome either
            // side, which is not a layout anyone chose.
            width: Design.Layout.promptWidth,
        ) {
            approvalWindow(for: request)
        }
    }

    /// The approval surface for one request.
    /// /// A SEPARATE FUNCTION from `openApproval` because two callers need the same view and
    /// they are not the same action: this one is the automatic surfacing when a request
    /// arrives, and `openApproval` is the operator bringing it forward from the popover. They
    /// must render identically, so they render the same view.
    private func approvalWindow(for request: PendingRequest) -> some View {
        ApprovalPrompt(
            state: optionsExpandedFor == request.requestID ? .expanded : .pending,
            title: request.promptTitle,
            capabilityLine: request.promptScopeLine,
            risk: request.riskClass.label,
            riskDot: request.riskClass.dot,
            clock: request.clockText,
            reason: request.agentReason,
            implication: request.implicationText,
            tree: CallerTree.rows(for: request),
            // THE TARGET FIELD IS OMITTED, and that is a decision rather than an omission.
            // The wire carries ONE scope string and the prompt had two places for it — the
            // scope line and this field — so "every application · until you revoke it"
            // appeared twice in four lines. The design's target field holds a resolved PATH
            // (/Users/…/notes.txt) which the server does not send; it held the scope instead.
            // Showing the scope once, on the line the design puts the breadth, beats showing
            // it twice. E7's design pass is where a real target gets designed.
            target: nil,
            payload: request.argumentSummary,
            biometricLine: request.biometricLine,
            biometricDot: request.requiresBiometric ? request.riskClass.dot : Design.Ink.success,
            moreChoicesLabel: request.moreChoicesText,
            showOptionsLabel: "Show options",
            selectedOption: request.offeredKinds.first,
            onDecision: { kind in
                Task { await self.answer(kind, for: request) }
            },
            onCopyPayload: { self.copyToPasteboard(request.argumentSummary) },
            onShowOptions: { self.expandOptions(for: request) },
        )
    }

    /// Answers a request, performing the ceremony first when its option needs one.
    /// /// Exposed rather than private so a test can drive the whole decision — ceremony, nonce
    /// and posted decision — without a window server or a sensor. What is asserted is the
    /// decision, which is the thing that must not be wrong.
    func answer(_ kind: OptionRow.Kind, for request: PendingRequest) async {
        await answerWithCeremony(kind, for: request)
    }

    /// Expands the collapsed affordances into the full option set for this request.
    func expandOptions(for request: PendingRequest) {
        optionsExpandedFor = request.requestID
        refreshApprovalWindow(for: request)
    }

    /// Rebuilds the window's content, which is the only way an already-open window can come
    /// to show something new.
    /// /// REPLACING THE CONTENT VIEW RATHER THAN ORDERING THE WINDOW AGAIN, because the early
    /// return that avoided a second window also avoided a refresh: a second request arriving
    /// while the first was open found a window that still showed the first request, and
    /// answering it would have posted a decision bound to the first request's nonce.
    private func refreshApprovalWindow(for request: PendingRequest) {
        windows.setContent(.approval) { self.approvalWindow(for: request) }
    }

    /// Brings the request the operator was already shown back to the front.
    func openApproval() {
        guard let request = pendingPrompt else { return }
        // The operator clicked it, so it comes forward WITH the application: they asked for
        // this window, and making them click again to raise it would be a worse answer than
        // the one they gave.
        windows.present(
            .approval,
            title: "ExactMac needs your approval",
            width: Design.Layout.promptWidth,
            activates: true,
        ) {
            approvalWindow(for: request)
        }
    }

    /// Answers a request, performing the ceremony FIRST when the option needs one.
    /// /// THE ORDER IS THE INVARIANT AND IT IS NOT NEGOTIABLE: a biometric success authorises
    /// exactly one decision, so a decision that was already posted cannot be "upgraded" by a
    /// ceremony performed afterwards. A failed or unavailable ceremony therefore denies, and
    /// never downgrades to a weaker check.
    private func answerWithCeremony(_ kind: OptionRow.Kind, for request: PendingRequest) async {
        var biometricObtained = false
        if request.requiresBiometric, kind != .deny {
            // ACTIVATION IS PAID HERE AND NOT EARLIER. The ceremony refuses unless the
            // console is frontmost, so the app has to come forward — but only once the
            // operator has committed to an option that needs a sensor, which is the moment
            // taking focus stops being an interruption and starts being the response to
            // something they did.
            windows.activateForCeremony()
            guard let ceremony else {
                await postDecision(kind, for: request, biometricObtained: false)
                return
            }
            let outcome = await ceremony.perform(
                requestID: AuthorizationRequestID(rawValue: request.requestID),
                nonce: request.nonce,
                reason: CeremonyReason.compose(request: request, option: kind),
            )
            switch outcome {
            case .performed:
                biometricObtained = true
            case let .unavailable(failure):
                // A CEREMONY THAT FAILED IS A DENIAL, and saying so is the whole point: the
                // operator is not offered a cheaper path and is not left believing the
                // weaker one was accepted.
                pendingNotice = "The request was not approved: \(failure.explanation)"
                logger.error(
                    "A ceremony failed for \(request.requestID, privacy: .private): \(String(describing: failure), privacy: .public)",
                )
                await postDecision(.deny, for: request, biometricObtained: false)
                return
            }
        }
        await postDecision(kind, for: request, biometricObtained: biometricObtained)
    }

    private func postDecision(
        _ kind: OptionRow.Kind,
        for request: PendingRequest,
        biometricObtained: Bool,
    ) async {
        windows.close(.approval)
        await decide(
            kind,
            note: "",
            for: request,
            biometricObtained: biometricObtained,
        )
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The grants list, which is NOT YET AVAILABLE and says so rather than showing a lie.
    /// /// The store persists each grant's expiry as nanoseconds on the SERVER's monotonic
    /// timeline, so the countdown the row shows cannot be computed in this process: those
    /// instants mean nothing here, and a chip counting down from a number it cannot
    /// interpret is worse than no list. The server has to send display-ready rows, and until
    /// it does the operator is told that instead of being shown a plausible wrong one.
    func openGrants() {
        Task { [weak self] in
            guard let self else { return }
            do { try await channel.query(.grants) } catch {
                logger.warning("The grants query failed: \(error.localizedDescription, privacy: .public)")
            }
            pendingNotice = "The grants list needs a display shape the server does not send yet."
        }
    }

    func openActivity() {
        Task { [weak self] in
            guard let self else { return }
            do { try await channel.query(.activity) } catch {
                logger.warning("The activity query failed: \(error.localizedDescription, privacy: .public)")
            }
            windows.present(.activity, title: "Activity") {
                ActivityTimeline(
                    rows: activityRows,
                    integrity: activityIntegrity,
                    subtitle: activitySubtitle,
                )
            }
        }
    }

    func openSettings() {
        windows.present(.settings, title: "Settings") {
            SettingsWindow()
        }
    }

    // MARK: The channel's whole lifecycle

    /// How long to wait before trying the server again, after a failed attempt.
    /// /// Long enough not to spin a menu-bar app against a server that is not there, short
    /// enough that starting the server afterwards is noticed while the operator is still
    /// looking at the menu bar.
    static let reconnectDelay = Duration.seconds(2)

    /// The last connect failure, so a repeat is silent and a CHANGE is not. This is what
    /// makes "the console has never connected" a diagnosable condition rather than a silence.
    private var lastConnectFailure: String?

    /// Connects, reads, and reconnects, for as long as the console is running.
    /// /// IT EXISTED NOWHERE, and that is not a detail. `ConsoleChannelClient.connect()` is
    /// written and tested, `poll()` is written and tested, and NOTHING CALLED EITHER: the
    /// console built a model whose `serviceState` was its initialiser default, drew a
    /// plausible popover from it, and never spoke to the server. Every symptom followed from
    /// that — the popover showed rows that were not true, the service toggle was the only
    /// live control, and the server refused every consent-requiring capability with
    /// `consoleUnreachable` forever because no console was ever authenticated.
    /// /// THE LOOP IS THE WHOLE DESIGN and it is deliberately dull: connect when not connected,
    /// read while connected, and treat a read failure as a disconnection so the next turn
    /// reconnects. There is no state to reconcile because every transition here is driven by
    /// something that either succeeded or did not.
    func run() async {
        logger.info("Console channel loop started")
        while !Task.isCancelled {
            if !channel.isConnected {
                do {
                    try await channel.connect()
                    lastConnectFailure = nil
                    apply(.running)
                } catch {
                    // THE REASON IS LOGGED WHEN IT CHANGES, AND NOT EVERY TICK. A menu-bar
                    // app with no server is a normal state for as long as the operator has
                    // not started one, so one line every two seconds would bury everything
                    // else — but an operator whose console never connects has to be able to
                    // find out WHY, and "nothing in the log" is not an answer. A changed
                    // reason is worth its own line: "no server" and "the server refused us"
                    // are different faults with different fixes.
                    let reason = String(describing: error)
                    if reason != lastConnectFailure {
                        lastConnectFailure = reason
                        logger.notice(
                            "Console could not reach the server: \(reason, privacy: .public)",
                        )
                    }
                    apply(.unreachable)
                    try? await Task.sleep(for: Self.reconnectDelay)
                    continue
                }
            }
            await poll()
        }
    }

    // MARK: Reading from the channel

    /// Pulls the next frame and folds it into the state the popover draws.
    /// /// A channel that is not connected is the `unreachable` state and the words say
    /// everything: the console is not running, so every consent-requiring capability is
    /// being denied, and that is the safe direction rather than a fault.
    func poll() async {
        guard channel.isConnected else {
            apply(.unreachable)
            return
        }
        do {
            while let frame = try await channel.nextFrame(timeout: .milliseconds(200)) {
                try handle(frame)
            }
        } catch {
            apply(.unreachable)
        }
    }

    /// The state this process is actually able to report.
    ///
    /// SEPARATE FROM `apply` so the two other places that set the state directly cannot
    /// bypass it. `setServiceEnabled` and `refreshServiceState` both wrote `.running`
    /// themselves, and both would have left a headless process reporting a healthy state
    /// with the fail-closed band cleared — which is the exact failure `apply` was changed to
    /// prevent, reached by a different route.
    private func vetoed(_ state: ServiceState) -> ServiceState {
        guard !presentation.canObtainConsent else { return state }
        switch state {
        case .running, .pending: return .unreachable
        case .degraded, .reduced, .stopped, .unreachable: return state
        }
    }

    /// Folds a reported state into what the popover draws, and decides the fail-closed band.
    ///
    /// INTERNAL RATHER THAN PRIVATE SO A TEST CAN DRIVE IT, which is the same reasoning
    /// `answer` uses: the posture decision is the whole function of this model and it has to
    /// be assertable without a server on the other end of a socket. A test that could only
    /// reach it by standing up a real server would be a test that runs once.
    func apply(_ state: ServiceState) {
        // THE POSTURE IS A PROPERTY OF THE PROCESS AND IT VETOES THE STATES THAT CLAIM
        // CONSENT IS OBTAINABLE.
        //
        // This used to be a straight assignment, which meant a menu bar app that could not
        // open a window still reported `Running` and drew a healthy dot. `Running` claims
        // something an operator will act on — that ExactMac is working and will ask them
        // when something needs approving — and a process with nowhere to show a prompt
        // cannot deliver on that claim. The request would sit until it expired and be
        // denied, while the operator looked at a green dot throughout.
        //
        // ONLY `.running` AND `.pending` ARE VETOED. The other four already mean "consent is
        // not available here", so rewriting them would replace a more specific and more
        // useful state with a vaguer one — an operator who turned ExactMac off should be
        // told it is off, not told it cannot ask them anything.
        let effective = vetoed(state)
        // A CHANGED STATE IS LOGGED, AND AN UNCHANGED ONE IS NOT. The console is the only
        // place an operator can see why nothing is being approved, so a silent state change
        // is a defect; a state that repeats every two seconds is noise that hides the one
        // line that matters.
        if effective != serviceState {
            logger.info(
                "Console state is now \(String(describing: effective), privacy: .public)",
            )
        }
        if effective != state {
            // Logged as a VETO rather than as a state change, because the underlying state
            // genuinely is running and the only thing wrong is this process's ability to
            // show a window. Silently rewriting it would make a launch-time misclassification
            // indistinguishable from a connectivity fault in the log forever after.
            logger.notice(
                "Refusing to report \(String(describing: state), privacy: .public): this process cannot present a consent prompt (\(self.presentation.summary, privacy: .public))",
            )
        }
        serviceState = effective
        switch effective {
        case .unreachable:
            failClosed = (
                "Denied until ExactMac can ask you",
                "Every request that needs consent is being denied, because nothing can put "
                    + "the question in front of you. Nothing ran and no grant was created. "
                    + "This is the safe direction.",
            )
        case .degraded:
            failClosed = (
                "The service is not answering",
                "No request can be made or answered. Nothing on this Mac is being "
                    + "automated while this is the case.",
            )
        case .reduced:
            failClosed = (
                "Running without approvals",
                "This server is listening on TCP, where there is no owning user to "
                    + "authenticate. Process verification and approvals are unavailable, so "
                    + "every consent-requiring capability is denied.",
            )
        case .stopped:
            failClosed = (
                "The service is off",
                "You turned ExactMac off. Nothing is served and nothing is exposed until "
                    + "you turn it back on.",
            )
        case .running, .pending:
            failClosed = nil
        }
    }

    private func handle(_ frame: ConsoleFrame) throws {
        switch frame {
        case let .pending(consent):
            deliverPending(PendingRequest(consent: consent))
            // THROUGH `apply`, like every other state change. It used to assign
            // `serviceState` directly, which meant a prompt arriving — the ONE transition
            // the operator most needs to see — produced no log line and no fail-closed
            // reconciliation, and there was no way to tell a console that had received a
            // prompt from one that had not.
            apply(.pending)
        case let .reply(reply):
            switch reply.kind {
            case "grants": activeGrantCount = reply.count
            case "activity": activityCount = reply.count
            default: break
            }
        case .decision, .query, .hello:
            // Server-to-console frames arriving inbound are refused rather than ignored,
            // because a peer sending them is not speaking this protocol.
            throw ConsoleChannelError.malformedFrame(reason: "a server-to-console frame arrived inbound")
        }
    }

    /// The operator's answer. A decision that cannot be delivered is NOT a decision, and
    /// treating it as one would let a console that lost its socket authorize something the
    /// operator agreed to a prompt nobody can see.
    func decide(_ kind: OptionRow.Kind, note: String) async {
        guard let prompt = pendingPrompt else { return }
        await decide(kind, note: note, for: prompt, biometricObtained: false)
    }

    /// Posts a decision for a SPECIFIC request.
    /// /// The request is a parameter rather than read from `pendingPrompt` because a decision is
    /// bound to one request's nonce and digest: a path that read whatever happened to be
    /// pending could answer a different request than the one the operator was shown, which is
    /// the confused deputy in its narrowest form.
    func decide(
        _ kind: OptionRow.Kind,
        note: String,
        for prompt: PendingRequest,
        biometricObtained: Bool,
    ) async {
        // Only the request being answered stops being pending, so a second request that
        // arrived while the operator was deciding is not silently discarded.
        if pendingPrompt?.requestID == prompt.requestID {
            pendingPrompt = nil
            pendingNotice = nil
            optionsExpandedFor = nil
        }
        apply(.running)
        let decision = ConsentDecision(
            requestID: prompt.requestID,
            nonce: prompt.nonce,
            requestDigest: prompt.requestDigest,
            isApproved: kind != .deny,
            selected: kind.serverValue,
            note: note,
            biometricObtained: biometricObtained,
        )
        do {
            try await channel.post(decision)
        } catch {
            // A decision that could not be delivered is NOT a decision, and the operator has
            // to be told so: the request is still waiting on the server, and pretending
            // otherwise would leave them believing they had answered it.
            pendingNotice = "The decision could not be delivered: \(error.localizedDescription)"
            logger.error(
                "The decision could not be delivered: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}

/// A request waiting on the operator, carrying the whole disclosure.
struct PendingRequest: Equatable {
    let requestID: String
    /// The pid the kernel named for the connection. Carried because the tree's first row IS
    /// this process and a tree that could not name it would be asking the operator to trust
    /// a row with no identity in it.
    let processIdentifier: Int32
    let nonce: String
    let requestDigest: String
    let rpcName: String
    let capability: String
    /// What the capability would take, in words. This is the prompt's title, because
    /// "observation.ax" is a token and what the operator has to picture is the consequence.
    let consequence: String
    let scopeDescription: String
    let argumentSummary: String
    let agentReason: String?
    let executablePath: String
    let bundleIdentifier: String?
    let signature: SignatureBadge.State
    let isFullyResolved: Bool
    let ancestors: [Ancestor]
    let isAncestryTruncated: Bool
    let basis: String
    /// The engine's own risk class, which is what the design's chip shows. `basis` says WHY a
    /// decision was reached and is not a risk level; the prompt was showing it as one, which
    /// put an enum rawValue in the operator's face.
    let riskClass: CapabilityRisk
    /// What the grant silently includes, beyond the capability being asked for. The design
    /// draws this as the implication, and it was being sent and then dropped.
    let impliedCapabilities: [String]
    let requiresBiometric: Bool
    let biometricReason: String?
    /// The options the server offered, each with ITS OWN SCOPE.
    ///
    /// It was `[OptionRow.Kind]`, which kept the kind and threw the scope away, and the
    /// prompt then named the options by `OptionRow.Kind.title` — a STATIC string that reads
    /// "Allow for TextEdit" whatever the target is. In the render it promised "Allow for
    /// TextEdit" directly under a scope line reading "every application". The scope is the
    /// whole of what distinguishes one option from another, so it is kept.
    let offered: [Offered]

    struct Offered: Equatable {
        let kind: OptionRow.Kind
        /// The server's own description of what this option would permit, e.g. "this exact
        /// request", "one application", "every app this agent touches".
        let scope: String
    }

    /// The options, as kinds, for the call sites that only need to choose one.
    var offeredKinds: [OptionRow.Kind] {
        offered.map(\.kind)
    }

    /// How long the operator has. The design draws a countdown, and the prompt was passing
    /// nil, so nothing on screen said the request would expire.
    let consentTimeoutSeconds: Int
    /// Whether this is the revoke-everything decision, which is the one request whose
    /// consequence is not a capability at all.
    let isRevokeAll: Bool

    struct Ancestor: Equatable {
        let processIdentifier: Int32
        let executablePath: String
        let signature: SignatureBadge.State
        let isFullyResolved: Bool
    }

    init(consent: PendingConsent) {
        requestID = consent.request.requestID
        processIdentifier = consent.identity.processIdentifier
        nonce = consent.nonce
        requestDigest = consent.requestDigest
        rpcName = consent.request.rpcName
        capability = consent.request.capability
        consequence = consent.request.capabilityConsequence
        scopeDescription = consent.request.scopeDescription
        argumentSummary = consent.request.argumentSummary
        agentReason = consent.request.agentReason
        executablePath = consent.identity.executablePath
        bundleIdentifier = consent.identity.bundleIdentifier
        signature = SignatureBadge.State(serverValue: consent.identity.signature)
        isFullyResolved = consent.identity.isFullyResolved
        ancestors = consent.identity.ancestors.map {
            Ancestor(
                processIdentifier: $0.processIdentifier,
                executablePath: $0.executablePath,
                signature: SignatureBadge.State(serverValue: $0.signature),
                isFullyResolved: $0.isFullyResolved,
            )
        }
        isAncestryTruncated = consent.identity.isAncestryTruncated
        basis = consent.decision.basis
        riskClass = CapabilityRisk(serverValue: consent.request.riskClass)
        // THE CAPABILITY BEING ASKED FOR IS NOT AN IMPLICATION OF ITSELF, so it is removed
        // here rather than in the composition: "this also permits clipboard.read" beside a
        // clipboard.read request is the exact duplication this work exists to remove.
        impliedCapabilities = consent.request.effectiveCapabilities
            .filter { $0 != consent.request.capability }
        requiresBiometric = consent.decision.requiresBiometric
        biometricReason = consent.decision.biometricReason
        consentTimeoutSeconds = consent.decision.consentTimeoutSeconds
        isRevokeAll = consent.request.isRevokeAll
        // MAPPED FROM THE SERVER'S NAMES, and an unrecognised one becomes Deny rather than
        // being dropped: dropping it would leave the operator with no primary option at all, and
        // a missing option is a worse failure than a wrong one the server will re-check.
        offered = consent.decision.offered.map {
            Offered(kind: OptionRow.Kind(serverValue: $0.kind), scope: $0.scopeDescription)
        }
    }

    /// The caller tree, in the order the design draws it: nearest ancestor first and the
    /// requester last, because the requester is the row that matters and the tree is read
    /// downward into it.
    var treeRows: [CallerTree.Row] {
        ancestors.enumerated().map { index, ancestor in
            CallerTree.Row(
                id: ancestor.processIdentifier,
                name: URL(fileURLWithPath: ancestor.executablePath).lastPathComponent,
                role: "ancestor",
                depth: index + 1,
                signature: ancestor.signature,
                isRequester: false,
            )
        } + [
            CallerTree.Row(
                id: 0,
                name: URL(fileURLWithPath: executablePath).lastPathComponent,
                role: "requesting",
                depth: ancestors.count + 1,
                signature: signature,
                isRequester: true,
            ),
        ]
    }

    /// The prompt's TITLE, and the single most important line on the surface.
    ///
    /// IT WAS `"\(capability) · \(rpcName)"` — two identifiers concatenated, so the heading
    /// read "observation.ax · AXUIElementCopyAttributeValue", which is the shape of a log line
    /// and not of something an operator can consent to. It is now the consequence the engine
    /// holds, because that is what the decision is actually about: the design's own example
    /// is "Read the clipboard in TextEdit".
    var promptTitle: String {
        isRevokeAll ? "Revoke every grant" : consequence
    }

    /// The line under the title, naming the capability TOKEN and the scope it is bounded to.
    ///
    /// IT WAS THE CAPABILITY AGAIN, verbatim, directly beneath a title that had just shown
    /// it — the same information twice in consecutive lines. The token belongs here, where
    /// the design puts it, and the scope is what makes the token mean something.
    var promptScopeLine: String {
        Design.joined([capability, scopeDescription])
    }

    /// What the grant would also permit, in the operator's words.
    ///
    /// NIL when the capability implies nothing beyond itself, which is the common case and is
    /// why the design's block is absent from most prompts rather than present and empty. The
    /// capability being asked for is removed from the list at the wire boundary, so this
    /// cannot read "this also permits clipboard.read" under a clipboard.read request.
    var implicationText: String? {
        guard !impliedCapabilities.isEmpty else { return nil }
        let named = impliedCapabilities.compactMap(CapabilityRisk.consequence(of:))
        guard !named.isEmpty else { return nil }
        return "Also permits " + Self.proseList(named)
    }

    /// An English list, NOT the design's `  ·  ` metadata delimiter.
    ///
    /// That delimiter is for SCOPE AND CAPABILITY LINES — it is a field separator, and the
    /// design uses it everywhere a row names its parts. The implication is a sentence, and
    /// the design's own example reads "Also permits screen capture and reading the focused
    /// window's text", joined with "and". One, two, then the Oxford form.
    private static func proseList(_ items: [String]) -> String {
        switch items.count {
        case 1:
            items[0]
        case 2:
            "\(items[0]) and \(items[1])"
        default:
            items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    /// How long the operator has, or nil when there is no timeout to count down. The design
    /// draws a countdown and the prompt was passing nil, so nothing on screen said the
    /// request would expire — and a request that expires silently is one the operator can
    /// walk away from without knowing it.
    var clockText: String? {
        guard consentTimeoutSeconds > 0 else { return nil }
        return "decides in \(consentTimeoutSeconds)s"
    }

    /// The biometric sentence, and what it says when no ceremony is required.
    ///
    /// THE FALLBACK WAS "No ceremony is required for this option", which is engine vocabulary
    /// and reads as a missing feature. An approval that needs no sensor is a fact about how
    /// little this one costs, and it is stated as the absence of a cost.
    var biometricLine: String {
        if let biometricReason, !biometricReason.isEmpty {
            return biometricReason
        }
        return requiresBiometric
            ? "Touch ID will confirm this decision."
            : "Nothing else is asked of you. This one needs no fingerprint."
    }

    /// The collapsed disclosure of the wider option set, and what it says rather than "More
    /// choices", which named no number and no breadth.
    ///
    /// The names are the options' own SCOPES — the thing an operator is choosing between —
    /// and the count is the real one from the server's offer, so a request that arrived
    /// offering only Deny says nothing here at all.
    var moreChoicesText: String? {
        let alternatives = offered.filter { $0.kind != .deny }
        guard alternatives.count > 1 else { return nil }
        // THE SCOPES THE SERVER SENT, NOT `OptionRow.Kind.title`. The static title reads
        // "Allow for TextEdit" for the target-scoped option, which is a LIE whenever the
        // target is not TextEdit — and in the render it was not: the scope line said "every
        // application" directly above a disclosure promising "Allow for TextEdit".
        return "\(alternatives.count) more choices — this exact request, or "
            + Self.proseList(alternatives.dropFirst().map(\.scope))
    }
}
