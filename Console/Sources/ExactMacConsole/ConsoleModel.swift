import AppKit
import ExactMacServer
import Foundation
import os
import SwiftUI

/// Coordinator model for the ExactMac console, orchestrating specialized view models and managers.
///
/// Decomposed into:
/// - `ConsentQueueManager`: request queue, continuations, starvation prevention, and diagnostics.
/// - `ApprovalViewModel`: active prompt disclosure, sheet transitions, and decision evaluation.
/// - `GrantsViewModel`: in-memory standing grants inspection and revocation.
/// - `ActivityViewModel`: audit log inspection and hash-chain verification.
/// - `SettingsViewModel`: posture, biometric gate, login-item, and service lifecycle.
@MainActor
@Observable
final class ConsoleModel {
    let queueManager: ConsentQueueManager
    let approvalViewModel: ApprovalViewModel
    let grantsViewModel: GrantsViewModel
    let activityViewModel: ActivityViewModel
    let settingsViewModel: SettingsViewModel

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "console",
    )

    // MARK: - Forwarded Properties

    var serviceState: ServiceState {
        settingsViewModel.serviceState
    }

    var isServiceRunning: Bool {
        settingsViewModel.isServiceRunning
    }

    var isServiceEnabled: Bool {
        settingsViewModel.isServiceEnabled
    }

    var isStartAtLoginEnabled: Bool {
        settingsViewModel.isStartAtLoginEnabled
    }

    var waitingCount: Int {
        max(queueManager.waitingCount, pendingPrompt != nil ? 1 : 0)
    }

    var failClosed: (title: String, body: String)? {
        settingsViewModel.failClosed
    }

    var pendingNotice: String? {
        settingsViewModel.pendingNotice
    }

    var lastTimeoutNotice: String? {
        queueManager.lastTimeoutNotice
    }

    var pendingPrompt: PendingRequest? {
        get { approvalViewModel.pendingPrompt }
        set { approvalViewModel.pendingPrompt = newValue }
    }

    var queuedRequests: [PendingRequest] {
        queueManager.queuedRequests
    }

    var blockedBy: [String: String] {
        queueManager.blockedBy
    }

    var postureHandle: HostedPostureHandle? {
        settingsViewModel.postureHandle
    }

    var displayedPosture: Posture {
        settingsViewModel.displayedPosture
    }

    var biometricGateHandle: HostedBiometricGateHandle? {
        settingsViewModel.biometricGateHandle
    }

    var displayedBiometricGate: Bool {
        settingsViewModel.displayedBiometricGate
    }

    var windows: ConsoleWindowHost {
        approvalViewModel.windows
    }

    // MARK: - Initialization

    init(
        startAtLogin: StartAtLogin = StartAtLogin(),
        presentation: OperatorInterface = ServerHosting.current(),
        windows: ConsoleWindowHost = ConsoleWindowHost(),
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
        stateEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    ) {
        self.queueManager = ConsentQueueManager()
        self.approvalViewModel = ApprovalViewModel(windows: windows, ceremony: ceremony)
        self.grantsViewModel = GrantsViewModel(windows: windows, ceremony: ceremony)
        self.activityViewModel = ActivityViewModel(windows: windows)
        self.settingsViewModel = SettingsViewModel(
            startAtLogin: startAtLogin,
            presentation: presentation,
            windows: windows,
            ceremony: ceremony,
            stateEnvironment: stateEnvironment,
        )
    }

    // MARK: - Request Answering Flow

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
            approvalViewModel.setActivePrompt(pending)
            settingsViewModel.setPendingNotice(pending.popoverNoticeBody)
            apply(.pending)

            windows.present(.approval, title: "ExactMac needs your approval", width: Design.Layout.promptWidth) {
                self.approvalWindow(for: pending)
            }
        } else {
            queueManager.enqueue(pending, blockedBy: pendingPrompt?.promptTitle)
            apply(.pending)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard queueManager.registerContinuation(continuation, for: pending.requestID) else {
                    continuation.resume(returning: nil)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.handleWaitCancellation(for: pending.requestID)
            }
        }
    }

    private func finish(_ requestID: String, with answer: PendingAnswer?) {
        let (continuation, blockedReason) = queueManager.removeWaiting(for: requestID)

        if pendingPrompt?.requestID == requestID {
            if let next = queueManager.promoteNext() {
                approvalViewModel.setActivePrompt(next)
                settingsViewModel.setPendingNotice(next.popoverNoticeBody)
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
                approvalViewModel.clearPrompt()
                if answer == nil, let blocked = blockedReason {
                    settingsViewModel.setPendingNotice("A request timed out while waiting behind \(blocked)")
                } else if let notice = queueManager.consumeLastTimeoutNotice() {
                    settingsViewModel.setPendingNotice(notice)
                } else {
                    settingsViewModel.setPendingNotice(nil)
                }
                if serviceState == .pending, queueManager.isWaitingEmpty {
                    apply(.running)
                }
            }
        } else if answer == nil, let blocked = blockedReason {
            let notice = "A request timed out while waiting behind \(blocked)"
            logger.notice(
                "Queued request \(requestID, privacy: .private) was cancelled or timed out while waiting behind \(blocked, privacy: .public)",
            )
            if let active = pendingPrompt {
                queueManager.setLastTimeoutNotice(notice)
                if queueManager.queuedRequests.isEmpty {
                    approvalViewModel.dismissSheet()
                }
                refreshApprovalWindow(for: active)
            } else {
                settingsViewModel.setPendingNotice(notice)
            }
        }

        continuation?.resume(returning: answer)
    }

    private func handleWaitCancellation(for requestID: String) {
        finish(requestID, with: nil)
    }

    // MARK: - Posture & Biometric Gate Forwarding

    func adoptPostureHandle(_ handle: HostedPostureHandle) {
        settingsViewModel.adoptPostureHandle(handle)
    }

    func setPosture(_ posture: Posture) {
        settingsViewModel.setPosture(posture)
    }

    func adoptBiometricGateHandle(_ handle: HostedBiometricGateHandle) {
        settingsViewModel.adoptBiometricGateHandle(handle)
    }

    func setBiometricGate(_ requiring: Bool) {
        settingsViewModel.setBiometricGate(requiring)
    }

    func performBiometricGateChange(_ requiring: Bool) async {
        await settingsViewModel.performBiometricGateChange(requiring)
    }

    func reportServerStarted() {
        settingsViewModel.reportServerStarted()
    }

    func reportServerStartFailure(reason: String) {
        settingsViewModel.reportServerStartFailure(reason: reason)
    }

    // MARK: - Service Lifecycle Forwarding

    func stopService() {
        let allWaiting = queueManager.cancelAllWaiting()
        for item in allWaiting {
            item.continuation.resume(returning: nil)
        }
        approvalViewModel.clearPrompt()
        settingsViewModel.stopService()
    }

    func startService() {
        settingsViewModel.startService()
    }

    func toggleService() {
        if isServiceRunning {
            stopService()
        } else {
            startService()
        }
    }

    func setServiceEnabled(_ enabling: Bool) {
        if enabling {
            startService()
        } else {
            stopService()
        }
    }

    func setStartAtLoginEnabled(_ enabling: Bool) {
        settingsViewModel.setStartAtLoginEnabled(enabling)
    }

    func toggleStartAtLogin() {
        settingsViewModel.toggleStartAtLogin()
    }

    func refreshServiceState() {
        settingsViewModel.refreshServiceState()
    }

    func quit() {
        windows.closeAll()
        NSApp.terminate(nil)
    }

    func apply(_ state: ServiceState) {
        settingsViewModel.apply(state)
    }

    // MARK: - Prompt Surfaces

    func deliverPending(_ request: PendingRequest) {
        approvalViewModel.setActivePrompt(request)
        settingsViewModel.setPendingNotice(request.popoverNoticeBody)
        apply(.pending)
        windows.present(
            .approval,
            title: "ExactMac needs your approval",
            width: Design.Layout.promptWidth,
        ) {
            self.approvalWindow(for: request)
        }
    }

    func openApproval() {
        guard let request = pendingPrompt else { return }
        windows.present(
            .approval,
            title: "ExactMac needs your approval",
            width: Design.Layout.promptWidth,
            activates: true,
        ) {
            self.approvalWindow(for: request)
        }
    }

    @ViewBuilder
    private func approvalWindow(for request: PendingRequest) -> some View {
        if approvalViewModel.envelopeReviewFor == request.requestID {
            envelopeReview(for: request)
        } else if approvalViewModel.queueReviewFor == request.requestID {
            queueReview()
        } else {
            ApprovalPrompt(
                state: approvalViewModel.optionsExpandedFor == request.requestID ? .expanded : .pending,
                title: request.promptTitle,
                capabilityLine: request.promptScopeLine,
                risk: request.riskClass.label,
                riskDot: request.riskClass.dot,
                clock: request.clockText,
                consentTimeoutSeconds: request.consentTimeoutSeconds,
                createdAt: request.createdAt,
                reason: request.agentReason,
                implication: request.implicationText,
                tree: CallerTree.rows(for: request),
                target: nil,
                payload: request.argumentSummary,
                biometricLine: request.biometricLine,
                biometricDot: request.requiresBiometric ? request.riskClass.dot : Design.Ink.success,
                moreChoicesLabel: request.moreChoicesText,
                showOptionsLabel: "Show options",
                offeredOptions: request.offered,
                queuedCount: queueManager.queuedRequests.count,
                onReviewQueue: queueManager.queuedRequests.isEmpty
                    ? nil
                    : { self.presentQueueReview(for: request) },
                onDecision: { kind, note in
                    if kind == .envelope {
                        self.presentEnvelopeReview(for: request)
                    } else {
                        Task { await self.answer(kind, for: request, note: note) }
                    }
                },
                onCopyPayload: { self.approvalViewModel.copyToPasteboard(request.argumentSummary) },
                onShowOptions: { self.expandOptions(for: request) },
            )
        }
    }

    private func presentEnvelopeReview(for request: PendingRequest) {
        approvalViewModel.presentEnvelopeReview(for: request)
        refreshApprovalWindow(for: request)
    }

    private func envelopeReview(for request: PendingRequest) -> some View {
        EnvelopeReview(
            requester: request.envelopeRequester,
            reason: request.agentReason ?? "",
            capabilities: request.envelopeCapabilities,
            duration: request.envelopeDurationLabel,
            maximumDuration: request.envelopeDurationLabel,
            biometricLine: request.requiresBiometric(for: .envelope)
                ? "\(BiometricCeremony.biometricType) will confirm this pre-authorization"
                : "This request requires no fingerprint confirmation.",
            onApprove: { note in
                self.approvalViewModel.dismissSheet()
                Task { await self.answer(.envelope, for: request, note: note) }
            },
            onDeny: { note in
                self.approvalViewModel.dismissSheet()
                Task { await self.answer(.deny, for: request, note: note) }
            },
        )
    }

    private func presentQueueReview(for request: PendingRequest) {
        approvalViewModel.presentQueueReview(for: request)
        refreshApprovalWindow(for: request)
    }

    private func queueReview() -> some View {
        QueueReview(
            items: queueManager.queuedRequests.map {
                QueueReview.Item(
                    id: $0.requestID,
                    title: $0.promptTitle,
                    scopeLine: $0.serverDefaultScopeLine,
                )
            },
            onDecide: { requestID in
                self.decideQueuedRequest(requestID)
            },
            onDenyAll: { note in
                Task { await self.denyAllQueued(note: note) }
            },
            onBack: {
                self.approvalViewModel.dismissSheet()
                if let active = self.pendingPrompt {
                    self.refreshApprovalWindow(for: active)
                }
            },
        )
    }

    func decideQueuedRequest(_ requestID: String) {
        guard let active = pendingPrompt,
              let chosen = queueManager.promoteQueued(requestID: requestID, active: active)
        else { return }
        approvalViewModel.setActivePrompt(chosen)
        settingsViewModel.setPendingNotice(chosen.popoverNoticeBody)
        refreshApprovalWindow(for: chosen)
    }

    func answerQueueWithDefaults(note: String) async {
        approvalViewModel.dismissSheet()
        let queued = queueManager.queuedRequests
        for request in queued {
            await answer(request.serverDefaultKind ?? .deny, for: request, note: note)
        }
        if let active = pendingPrompt {
            refreshApprovalWindow(for: active)
        }
    }

    func denyAllQueued(note: String) async {
        approvalViewModel.dismissSheet()
        let queued = queueManager.queuedRequests
        for request in queued {
            await answer(.deny, for: request, note: note)
        }
        if let active = pendingPrompt {
            refreshApprovalWindow(for: active)
        }
    }

    func answer(_ kind: OptionRow.Kind, for request: PendingRequest, note: String = "") async {
        let answer = await answerValue(kind, for: request, note: note)
        finish(request.requestID, with: answer)
    }

    func answerValue(
        _ kind: OptionRow.Kind,
        for request: PendingRequest,
        note: String = "",
    ) async -> PendingAnswer {
        await approvalViewModel.answerValue(kind, for: request, note: note) { [weak self] notice in
            self?.settingsViewModel.setPendingNotice(notice)
        }
    }

    func expandOptions(for request: PendingRequest) {
        approvalViewModel.expandOptions(for: request)
        refreshApprovalWindow(for: request)
    }

    private func refreshApprovalWindow(for request: PendingRequest) {
        windows.setContent(.approval) { self.approvalWindow(for: request) }
    }

    // MARK: - Grants & Activity Windows

    func openGrants() async {
        guard await settingsViewModel.passBiometricGate(for: "Grants") else { return }
        refreshGrants()
    }

    func refreshGrants() {
        grantsViewModel.refresh()
    }

    func revokeGrant(id: String) {
        grantsViewModel.revokeGrant(id: id)
    }

    func revokeAllGrants() {
        grantsViewModel.revokeAllGrants()
    }

    func performRevokeAllGrants() async {
        await grantsViewModel.performRevokeAllGrants()
    }

    func resetEverything() {
        settingsViewModel.resetEverything { [weak self] in
            self?.grantsViewModel.refresh()
        }
    }

    func performResetEverything() async {
        await settingsViewModel.performResetEverything { [weak self] in
            self?.grantsViewModel.refresh()
        }
    }

    func openActivity() async {
        guard await settingsViewModel.passBiometricGate(for: "Activity") else { return }
        refreshActivity()
    }

    func refreshActivity() {
        activityViewModel.refresh()
    }

    func openSettings() {
        windows.present(.settings, title: "Settings") {
            SettingsWindow(model: self)
        }
    }
}
