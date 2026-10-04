import AppKit
import ExactMacServer
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

    /// Whether the ExactMac automation service is actively running or pending a decision.
    var isServiceRunning: Bool {
        serviceState == .running || serviceState == .pending
    }

    /// Whether the service is enabled (synonymous with running/pending service state).
    var isServiceEnabled: Bool {
        isServiceRunning
    }

    /// Whether ExactMac is registered to start at login, read from the system via SMAppService.
    var isStartAtLoginEnabled: Bool {
        startAtLogin.status == .enabled
    }

    /// Number of requests currently waiting on operator consent.
    var waitingCount: Int {
        max(waiting.count, pendingPrompt != nil ? 1 : 0)
    }

    /// `.none` when there is nothing wrong, and the band when there is. An OPTIONAL SLOT at a
    /// fixed index, which is why the popover's height is driven by it and nothing else.
    private(set) var failClosed: (title: String, body: String)?
    private(set) var pendingNotice: String?
    /// Records the last timeout notice that occurred while another prompt was visible,
    /// so the operator is informed after the blocker resolves.
    private(set) var lastTimeoutNotice: String?
    var pendingPrompt: PendingRequest?
    /// Requests queued behind the active prompt, in arrival order.
    private(set) var queuedRequests: [PendingRequest] = []
    /// Records which prompt blocked another, for diagnostics and transparency.
    private(set) var blockedBy: [String: String] = [:]

    /// Start-at-login, the one on/off the app can still honour.
    ///
    /// IT REPLACED A LAUNCHCTL CONTROLLER, and the reason is structural rather than
    /// cosmetic. The app IS the service now: there is no daemon to start and stop, so
    /// "turn ExactMac off" could only ever mean "quit", which is a different act with
    /// different consequences and belongs on the menu's own Quit row. What remains that the
    /// operator can genuinely switch is whether ExactMac comes back at login, and that is
    /// registered by the platform through `SMAppService` rather than by a plist in a
    /// dot-directory. So the control stayed and its subject changed.
    private let startAtLogin: StartAtLogin
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

    // The activity rows, the integrity badge and the subtitle are GONE rather than left at
    // their initial values. They were read from a reply that arrived over the console socket,
    // and the socket is gone: the audit log is the server library's, behind an API this
    // module cannot call. Keeping three properties that nothing writes and a window that
    // renders them is the shape of a lie that compiles.

    init(
        startAtLogin: StartAtLogin = StartAtLogin(),
        presentation: OperatorInterface = ServerHosting.current(),
        windows: ConsoleWindowHost = ConsoleWindowHost(),
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
    ) {
        self.startAtLogin = startAtLogin
        self.presentation = presentation
        self.windows = windows
        self.ceremony = ceremony
    }

    // MARK: Answering a request the server asked

    /// The requests waiting on the operator, keyed by request id.
    ///
    /// A MAP RATHER THAN A SINGLE SLOT because the server can have several consent requests
    /// in flight at once, and the model already refused to answer one request with another
    /// request's decision. A second arrival gets its own entry, its own window content, and
    /// its own answer; collapsing them would make the second request's decision answer the
    /// first.
    private var waiting: [String: CheckedContinuation<PendingAnswer?, Never>] = [:]

    /// Puts a request in front of the operator and suspends until they answer it, or the
    /// surrounding task is cancelled.
    ///
    /// THE RETURN IS OPTIONAL and nil is the refusal, because the caller — the server's
    /// interceptor — is the thing that turns "nobody answered" into a denial, and a value it
    /// cannot construct for that case cannot be confused with an answer.
    func answer(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
    ) async -> PendingAnswer? {
        guard isServiceRunning else {
            logger.notice("Refusing request \(request.id.rawValue, privacy: .private): service is stopped")
            return nil
        }
        let pending = PendingRequest(
            request: request,
            identity: identity,
            decision: decision,
        )

        if pendingPrompt == nil {
            pendingPrompt = pending
            pendingNotice = pending.popoverNoticeBody
            apply(.pending)

            windows.present(.approval, title: "ExactMac needs your approval", width: Design.Layout.promptWidth) {
                approvalWindow(for: pending)
            }
        } else {
            // A request is already in front of the operator.
            // Queue this request behind it rather than overwriting the active prompt.
            queuedRequests.append(pending)
            if let active = pendingPrompt {
                blockedBy[pending.requestID] = active.promptTitle
            }
            apply(.pending)
            logger.notice(
                "Request \(pending.requestID, privacy: .private) queued behind active prompt \(self.pendingPrompt?.requestID ?? "", privacy: .private)",
            )
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // CANCELLED BEFORE SUSPENDING IS A LEAK, so the continuation is stored first
                // and a request already being answered is refused rather than overwriting
                // whoever is holding the slot.
                guard waiting[pending.requestID] == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                waiting[pending.requestID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.handleWaitCancellation(for: pending.requestID)
            }
        }
    }

    /// Hands the operator's answer back to whoever is waiting for it.
    private func finish(_ requestID: String, with answer: PendingAnswer?) {
        let continuation = waiting.removeValue(forKey: requestID)
        queuedRequests.removeAll { $0.requestID == requestID }
        let blockedReason = blockedBy.removeValue(forKey: requestID)

        if pendingPrompt?.requestID == requestID {
            optionsExpandedFor = nil
            if let next = queuedRequests.first {
                queuedRequests.removeFirst()
                pendingPrompt = next
                pendingNotice = next.popoverNoticeBody
                windows.present(
                    .approval,
                    title: "ExactMac needs your approval",
                    width: Design.Layout.promptWidth,
                    updateIfPresent: true,
                ) {
                    self.approvalWindow(for: next)
                }
                logger.info(
                    "Advanced approval prompt to next queued request \(next.requestID, privacy: .private)",
                )
            } else {
                pendingPrompt = nil
                if answer == nil, let blocked = blockedReason {
                    pendingNotice = "A request timed out while waiting behind \(blocked)"
                } else if let notice = lastTimeoutNotice {
                    pendingNotice = notice
                    lastTimeoutNotice = nil
                } else {
                    pendingNotice = nil
                }
                windows.close(.approval)
                if serviceState == .pending, waiting.isEmpty {
                    apply(.running)
                }
            }
        } else if answer == nil, let blocked = blockedReason {
            let notice = "A request timed out while waiting behind \(blocked)"
            logger.notice(
                "Queued request \(requestID, privacy: .private) was cancelled or timed out while waiting behind \(blocked, privacy: .public)",
            )
            if pendingPrompt == nil {
                pendingNotice = notice
            } else {
                lastTimeoutNotice = notice
            }
        }

        continuation?.resume(returning: answer)
    }

    private func handleWaitCancellation(for requestID: String) {
        finish(requestID, with: nil)
    }

    // MARK: The server this process hosts

    /// Reports that the server this process hosts is up and serving.
    ///
    /// THE APP'S STATE NOW COMES FROM THE SERVER IT OWNS RATHER THAN FROM A SOCKET. Before
    /// this, the only thing that could move the model out of its initialiser state was the
    /// console-channel loop, so "the server is running" was something the app inferred by
    /// failing to reach a peer process. It is now a fact this process establishes itself and
    /// states once.
    func reportServerStarted() {
        apply(.running)
    }

    /// Reports that the server this process hosts could not start, and says why.
    ///
    /// IT IS DISTINCT FROM "THE SERVICE IS OFF" because the operator turned nothing off.
    /// The likeliest cause is a socket pathname another server still holds, and the useful
    /// thing to say is that, rather than a state that invites the operator to toggle
    /// something that is not what is wrong.
    func reportServerStartFailure(reason: String) {
        logger.error("The hosted server did not start: \(reason, privacy: .public)")
        pendingNotice = "ExactMac could not start its server: \(reason)"
        // `.stopped` RATHER THAN `.unreachable`, and the two are not interchangeable. The
        // unreachable band says nothing can put a question in front of the operator, which
        // is a claim about this process's ability to present. A server that failed to start
        // is a different fault with a different fix, and sending an operator after the wrong
        // one is worse than saying nothing — its own comment said the distinction mattered,
        // and the state it chose did not make it.
        apply(.stopped)
    }

    // MARK: The service control

    /// Stops the ExactMac service: closes active approval prompts, refuses waiting requests, and sets state to stopped.
    func stopService() {
        logger.info("Stopping ExactMac service by operator request")
        queuedRequests.removeAll()
        blockedBy.removeAll()
        lastTimeoutNotice = nil
        let waitingKeys = Array(waiting.keys)
        for key in waitingKeys {
            finish(key, with: nil)
        }
        windows.close(.approval)
        apply(.stopped)
        failClosed = (
            "The service is off",
            "You turned ExactMac off. Nothing is served and nothing is exposed until you turn it back on.",
        )
    }

    /// Starts the ExactMac service, moving state to running unless vetoed by presentation.
    func startService() {
        logger.info("Starting ExactMac service by operator request")
        apply(.running)
    }

    /// Toggles the service between running and stopped.
    func toggleService() {
        if isServiceRunning {
            stopService()
        } else {
            startService()
        }
    }

    /// Enables or disables the service.
    func setServiceEnabled(_ enabling: Bool) {
        if enabling {
            startService()
        } else {
            stopService()
        }
    }

    // MARK: Login-item registration

    /// Registers or unregisters ExactMac for start at login via SMAppService.
    func setStartAtLoginEnabled(_ enabling: Bool) {
        let outcome = startAtLogin.setEnabled(enabling)
        switch outcome {
        case .none:
            break
        case .register:
            logger.info("ExactMac registered to start at login")
        case .unregister:
            logger.info("ExactMac removed from start at login")
        case .operatorApprovalRequired:
            break
        }
        pendingNotice = startAtLogin.lastRefusal
    }

    /// Flips start-at-login.
    func toggleStartAtLogin() {
        setStartAtLoginEnabled(!isStartAtLoginEnabled)
    }

    /// Re-reads the registration, because the operator can change it outside this app.
    func refreshServiceState() {
        startAtLogin.refresh()
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
        pendingNotice = request.popoverNoticeBody
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
            onDecision: { kind, note in
                Task { await self.answer(kind, for: request, note: note) }
            },
            onCopyPayload: { self.copyToPasteboard(request.argumentSummary) },
            onShowOptions: { self.expandOptions(for: request) },
        )
    }

    /// Answers a request, performing the ceremony FIRST when its option needs one.
    ///
    /// Exposed rather than private so a test can drive the whole decision — ceremony, nonce
    /// and answer — without a window server or a sensor. What is asserted is the answer, which
    /// is the thing that must not be wrong.
    func answer(_ kind: OptionRow.Kind, for request: PendingRequest, note: String = "") async {
        let answer = await answerValue(kind, for: request, note: note)
        await post(answer, for: request)
    }

    /// THE PRESENT-THEN-ANSWER FLOW, AS A VALUE.
    ///
    /// IT IS SEPARATED FROM POSTING so the same implementation serves both callers: the one
    /// that hands the answer to a transport, and the one that hands it back to the server
    /// that asked. The ceremony-ordering rule is the whole substance of this function and it
    /// must not be written twice — two copies of "perform the ceremony before the decision,
    /// and a failed ceremony is a denial" is two places for the ordering to be got wrong,
    /// and the ordering is the invariant.
    ///
    /// A CEREMONY THAT FAILED IS A DENIAL, returned as one rather than thrown, because a
    /// caller that cannot express "denied" would either offer a cheaper path or leave the
    /// operator believing the weaker one was accepted.
    func answerValue(
        _ kind: OptionRow.Kind,
        for request: PendingRequest,
        note: String = "",
    ) async -> PendingAnswer {
        var biometricObtained = false
        if request.requiresBiometric, kind != .deny {
            // ACTIVATION IS PAID HERE AND NOT EARLIER. The ceremony refuses unless the
            // console is frontmost, so the app has to come forward — but only once the
            // operator has committed to an option that needs a sensor, which is the moment
            // taking focus stops being an interruption and starts being the response to
            // something they did.
            windows.activateForCeremony()
            // A REQUIRED CEREMONY THAT CANNOT BE PERFORMED IS A DENIAL, and this branch
            // used to approve instead. With no ceremony installed, the old code fell through
            // and returned the operator's chosen option carrying `biometricObtained: false`
            // — an approval for a check that never happened, on exactly the requests that
            // asked for one. That is the silent downgrade invariant 3 forbids, and it was
            // invisible in the old world because the answer was posted with the same
            // `biometricObtained` flag a genuine non-biometric approval carried. The app
            // always installs a ceremony in production, so the branch is test-reachable
            // rather than operator-reachable — but "unreachable" is not a reason to leave a
            // downgrade in the path that grants things.
            guard let ceremony else {
                logger.error(
                    "A request required a biometric and no ceremony is installed; denying rather than approving without the check: \(request.requestID, privacy: .private)",
                )
                return answer(.deny, for: request, note: note, refusal: .ceremonyRefused)
            }
            let outcome = await ceremony.perform(
                nonce: request.nonce,
                reason: CeremonyReason.compose(request: request, option: kind),
            )
            switch outcome {
            case .performed:
                biometricObtained = true
            case let .unavailable(failure):
                pendingNotice = "The request was not approved: \(failure.explanation)"
                logger.error(
                    "A ceremony failed for \(request.requestID, privacy: .private): \(String(describing: failure), privacy: .public)",
                )
                return answer(.deny, for: request, note: note, refusal: .ceremonyRefused)
            }
        }
        return answer(
            kind,
            for: request,
            note: note,
            biometricObtained: biometricObtained,
            refusal: kind == .deny ? .operatorDeclined : nil,
        )
    }

    /// The value for one option, with the request's own nonce and digest attached.
    private func answer(
        _ kind: OptionRow.Kind,
        for request: PendingRequest,
        note: String = "",
        biometricObtained: Bool = false,
        refusal: AnswerRefusal? = nil,
    ) -> PendingAnswer {
        PendingAnswer(
            requestID: request.requestID,
            nonce: request.nonce,
            requestDigest: request.requestDigest,
            kind: kind,
            note: note,
            biometricObtained: biometricObtained,
            refusal: refusal,
        )
    }

    /// Hands a produced answer to whoever is waiting for it.
    ///
    /// NOT `post(...)`. There is no transport to post to: the server asked this process
    /// directly and is suspended on the continuation this resumes, so "delivering" the answer
    /// and "returning" it are the same act. The window is closed first so the prompt cannot
    /// still be on screen for a request that has already been answered.
    private func post(_ answer: PendingAnswer, for request: PendingRequest) async {
        finish(request.requestID, with: answer)
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens the Grants management window, reading live standing grants from the server.
    ///
    /// Never writes to `pendingNotice`: opening a window must not hijack the consent prompt slot.
    func openGrants() {
        refreshGrants()
    }

    /// Refreshes the Grants management window with current server state.
    func refreshGrants() {
        let grantsResult: Result<[DisplayGrant], Error> = Result {
            try ServerInspectionService.inspectGrants()
        }

        let view: GrantsManager
        switch grantsResult {
        case let .success(grants):
            let models = grants.map { GrantRow.Model(from: $0) }
            let subtitle = ServerInspectionService.grantsSubtitle(for: grants)
            view = GrantsManager(
                grants: models,
                subtitle: subtitle,
                onRevoke: { [weak self] id in
                    self?.revokeGrant(id: id)
                },
                onRevokeAll: { [weak self] in
                    self?.revokeAllGrants()
                },
            )
        case let .failure(error):
            logger.error("Failed to inspect grants: \(String(describing: error), privacy: .public)")
            view = GrantsManager(
                grants: [],
                errorMessage: "ExactMac cannot tell what is permitted, so it is denying every request that needs consent. Nothing is being granted on a guess.",
            )
        }

        windows.present(
            .grants,
            title: "Grants",
            activates: true,
            updateIfPresent: true,
        ) {
            view
        }
    }

    /// Revokes a specific standing grant and refreshes the Grants window.
    func revokeGrant(id: String) {
        do {
            try ServerInspectionService.revokeGrant(id: id)
        } catch {
            logger.error("Failed to revoke grant \(id, privacy: .private): \(String(describing: error), privacy: .public)")
        }
        refreshGrants()
    }

    /// Revokes all standing grants and envelopes, performing the biometric ceremony when installed.
    func revokeAllGrants() {
        Task { @MainActor in
            await performRevokeAllGrants()
        }
    }

    /// Performs revocation of all standing grants and envelopes with biometric ceremony verification.
    func performRevokeAllGrants() async {
        guard let ceremony else {
            logger.error("Cannot revoke all grants: no biometric ceremony is installed")
            return
        }
        windows.activateForCeremony()
        let outcome = await ceremony.perform(
            nonce: UUID().uuidString,
            reason: "ExactMac asks to revoke every grant at once",
        )
        guard case .performed = outcome else {
            logger.notice("Revoke-all ceremony was cancelled or declined")
            return
        }
        do {
            try ServerInspectionService.revokeAllGrants()
        } catch {
            logger.error("Failed to revoke all grants: \(String(describing: error), privacy: .public)")
        }
        refreshGrants()
    }

    /// Opens the Activity timeline window, reading and verifying the decision audit log from the server.
    ///
    /// Never writes to `pendingNotice`: opening a window must not hijack the consent prompt slot.
    func openActivity() {
        refreshActivity()
    }

    /// Refreshes the Activity timeline window with current server state and verified hash chain.
    func refreshActivity() {
        let activityResult: Result<DisplayActivityReport, Error> = Result {
            try ServerInspectionService.inspectActivity()
        }

        let view: ActivityTimeline
        switch activityResult {
        case let .success(report):
            if case let .unreadable(reason) = report.integrity {
                view = ActivityTimeline(
                    rows: [],
                    integrity: .unchecked,
                    subtitle: "Unavailable",
                    errorMessage: "The decision log did not open: \(reason). Decisions are still being enforced; this view is missing, not the protection.",
                    onRetry: { [weak self] in
                        self?.refreshActivity()
                    },
                )
            } else {
                let models = report.items.map { ActivityRow.Model(from: $0) }
                let badgeState = IntegrityBadge.State(from: report.integrity, itemCount: models.count)
                view = ActivityTimeline(
                    rows: models,
                    integrity: badgeState,
                    subtitle: report.subtitle,
                    onRetry: { [weak self] in
                        self?.refreshActivity()
                    },
                )
            }
        case let .failure(error):
            logger.error("Failed to inspect activity: \(String(describing: error), privacy: .public)")
            view = ActivityTimeline(
                rows: [],
                integrity: .unchecked,
                subtitle: "Unavailable",
                errorMessage: "The decision log did not open. Decisions are still being enforced; this view is missing, not the protection.",
                onRetry: { [weak self] in
                    self?.refreshActivity()
                },
            )
        }

        windows.present(
            .activity,
            title: "Activity",
            activates: true,
            updateIfPresent: true,
        ) {
            view
        }
    }

    func openSettings() {
        windows.present(.settings, title: "Settings") {
            SettingsWindow()
        }
    }

    // MARK: What this process reports about itself

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
            // IT DOES NOT SAY "YOU TURNED IT OFF". It used to, and the state is reached when
            // this process's own server failed to start — so an operator who had touched
            // nothing would have been told they had. Naming the state rather than the cause
            // is also the honest answer: the cause is the log line, and the operator's next
            // move is the same either way.
            failClosed = (
                "ExactMac is not serving",
                "Nothing is being served and nothing is exposed. Quitting and opening "
                    + "ExactMac again will not help on its own — the reason is in the log.",
            )
        case .running, .pending:
            failClosed = nil
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

    /// BUILDS THE DISCLOSURE FROM THE SERVER'S OWN TYPES, and reads them rather than
    /// re-deriving anything. The request, the identity and the decision were all produced by
    /// the server from the request bytes; the one thing that did not come across the wire as a
    /// field is the request's own id, which is here because the continuation is keyed by it.
    init(
        request: AuthorizationRequest,
        identity: CallerIdentity,
        decision: AuthorizationDecision,
    ) {
        // THE ID DOES THREE JOBS HERE, and it is worth being explicit about why that is not
        // a shortcut. The wire protocol had a separate per-decision nonce and a request
        // digest because a frame could be replayed: a second copy of the same decision had to
        // be refused. There is no frame any more — the server calls a closure in this
        // process, holding this very request value — so the binding is the VALUE, and the
        // continuation below is consumed exactly once, which is what the nonce was for. A
        // replay is not representable, so a separate nonce would be a value nothing checked.
        requestID = request.id.rawValue
        processIdentifier = identity.processIdentifier
        nonce = decision.ceremonyNonce ?? request.id.rawValue
        requestDigest = request.id.rawValue
        rpcName = request.rpcName
        capability = request.capability.rawValue
        consequence = request.capability.consequence
        scopeDescription = ScopeDescription.describe(request.scope)
        argumentSummary = request.argumentSummary
        agentReason = request.agentReason
        executablePath = identity.code.executablePath
        bundleIdentifier = identity.code.bundleIdentifier
        signature = SignatureBadge.State(serverValue: identity.code.signature.rawValue)
        isFullyResolved = identity.isFullyResolved
        ancestors = identity.ancestors.map {
            Ancestor(
                processIdentifier: $0.processIdentifier,
                executablePath: $0.code.executablePath,
                signature: SignatureBadge.State(serverValue: $0.code.signature.rawValue),
                isFullyResolved: $0.isFullyResolved,
            )
        }
        isAncestryTruncated = identity.isAncestryTruncated
        riskClass = CapabilityRisk(serverValue: decision.riskClass.rawValue)
        // SORTED, because the engine's implied set is a `Set` and `Set` iteration order is
        // not stable between launches. Composed straight from it, the same request produced
        // "Also permits taking a screenshot of the screen and reading the clipboard" on one
        // launch and the two clauses the other way round on the next — an operator-facing
        // sentence that reorders itself is one nobody learns to read quickly, and it makes
        // the prompt untestable. The order is the engine's own spelling, sorted, so it is
        // stable and still derived rather than invented.
        impliedCapabilities = decision.effectiveCapabilities
            .filter { $0 != request.capability }
            .map(\.rawValue)
            .sorted()
        requiresBiometric = decision.biometric.reason != nil
        biometricReason = decision.biometric.reason
        consentTimeoutSeconds = 0
        isRevokeAll = false
        offered = decision.offeredDecisions.map {
            Offered(
                kind: OptionRow.Kind(serverValue: $0.kind.rawValue),
                scope: ScopeDescription.describe($0.scope),
            )
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

    /// The line under the title, naming what the grant is bounded to.
    ///
    /// IT NAMED THE CAPABILITY TOKEN TOO, and that is a standing invariant broken: the title
    /// directly above already says what the capability IS in words -- "Read the accessibility
    /// tree of an app" -- so the token under it restates the same fact in a form the operator
    /// cannot act on. The design had it, with the reasoning that the token is what makes the
    /// scope mean something; the token is gone from the design for the same reason, and the
    /// scope stands on its own. The scope is the half that is new information here: the title
    /// says what, this says how wide.
    var promptScopeLine: String {
        scopeDescription
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

    /// The body text shown on the popover's pending notice card, matching Figma node 0:1326.
    ///
    /// Forms a human-readable sentence: "<caller> wants to <action> in <target>".
    var popoverNoticeBody: String {
        let caller = !executablePath.isEmpty
            ? URL(fileURLWithPath: executablePath).lastPathComponent
            : (bundleIdentifier ?? "An application")
        var action = consequence.prefix(1).lowercased() + consequence.dropFirst()
        if action.hasSuffix(" and its history") {
            action = String(action.dropLast(" and its history".count))
        }
        if scopeDescription.hasPrefix("in ") {
            return "\(caller) wants to \(action) \(scopeDescription)"
        } else if scopeDescription != "any application", !scopeDescription.isEmpty {
            return "\(caller) wants to \(action) in \(scopeDescription)"
        } else {
            return "\(caller) wants to \(action)"
        }
    }
}
