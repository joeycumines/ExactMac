import AppKit
import ExactMacServer
import Foundation
import os
import SwiftUI

/// Observable view model managing the active consent prompt, sheet transitions, and decision answering.
@MainActor
@Observable
final class ApprovalViewModel {
    var pendingPrompt: PendingRequest?
    private(set) var optionsExpandedFor: String?
    private(set) var envelopeReviewFor: String?
    private(set) var queueReviewFor: String?

    let windows: ConsoleWindowHost
    let ceremony: (any CeremonyPerforming)?

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "approval.vm",
    )

    init(
        windows: ConsoleWindowHost,
        ceremony: (any CeremonyPerforming)? = BiometricCeremony(),
    ) {
        self.windows = windows
        self.ceremony = ceremony
    }

    /// Sets the active prompt, resetting any open sheet states.
    func setActivePrompt(_ request: PendingRequest?) {
        optionsExpandedFor = nil
        envelopeReviewFor = nil
        queueReviewFor = nil
        pendingPrompt = request
    }

    /// Clears the active prompt and closes the approval window if no more prompts wait.
    func clearPrompt() {
        optionsExpandedFor = nil
        envelopeReviewFor = nil
        queueReviewFor = nil
        pendingPrompt = nil
        windows.close(.approval)
    }

    /// Expands the options list for the specified request.
    func expandOptions(for request: PendingRequest) {
        optionsExpandedFor = request.requestID
    }

    /// Presents the envelope review sheet for the specified request.
    func presentEnvelopeReview(for request: PendingRequest) {
        envelopeReviewFor = request.requestID
    }

    /// Presents the queue review sheet for the active prompt.
    func presentQueueReview(for request: PendingRequest) {
        queueReviewFor = request.requestID
    }

    /// Dismisses any active sheet for the active prompt.
    func dismissSheet() {
        envelopeReviewFor = nil
        queueReviewFor = nil
    }

    /// Brings the active approval prompt window frontmost.
    func openApproval(content: @escaping () -> some View) {
        guard pendingPrompt != nil else { return }
        windows.present(
            .approval,
            title: "ExactMac needs your approval",
            width: Design.Layout.promptWidth,
            activates: true,
            content: content,
        )
    }

    /// Computes the answer value for a request, executing the biometric ceremony first if required.
    func answerValue(
        _ kind: OptionRow.Kind,
        for request: PendingRequest,
        note: String = "",
        onNotice: ((String) -> Void)? = nil,
    ) async -> PendingAnswer {
        var biometricObtained = false
        if request.requiresBiometric(for: kind) {
            windows.activateForCeremony()
            guard let ceremony else {
                logger.error(
                    "A request required a biometric and no ceremony is installed; denying rather than approving without the check: \(request.requestID, privacy: .private)",
                )
                return makeAnswer(.deny, for: request, note: note, refusal: .ceremonyRefused)
            }
            let outcome = await ceremony.perform(
                nonce: request.nonce,
                reason: CeremonyReason.compose(request: request, option: kind),
            )
            switch outcome {
            case .performed:
                biometricObtained = true
            case let .unavailable(failure):
                onNotice?("The request was not approved: \(failure.explanation)")
                logger.error(
                    "A ceremony failed for \(request.requestID, privacy: .private): \(String(describing: failure), privacy: .public)",
                )
                return makeAnswer(.deny, for: request, note: note, refusal: .ceremonyRefused)
            }
        }
        return makeAnswer(
            kind,
            for: request,
            note: note,
            biometricObtained: biometricObtained,
            refusal: kind == .deny ? .operatorDeclined : nil,
        )
    }

    private func makeAnswer(
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

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
