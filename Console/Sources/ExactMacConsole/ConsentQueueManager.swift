import ExactMacServer
import Foundation
import os

/// Manages the queue of pending authorization requests waiting on operator consent.
///
/// Ensures FIFO ordering, starvation prevention, cancellation handling, and diagnostic tracking
/// of which prompt blocked another.
@MainActor
@Observable
final class ConsentQueueManager {
    /// Requests queued behind the active prompt, in arrival order.
    private(set) var queuedRequests: [PendingRequest] = []

    /// Records which prompt blocked another, for diagnostics and transparency.
    private(set) var blockedBy: [String: String] = [:]

    /// Records the last timeout notice that occurred while another prompt was visible.
    private(set) var lastTimeoutNotice: String?

    /// Continuations for callers waiting on a decision, keyed by requestID.
    private var waiting: [String: CheckedContinuation<PendingAnswer?, Never>] = [:]

    private let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac.console",
        category: "consent.queue",
    )

    var waitingCount: Int {
        waiting.count
    }

    var isWaitingEmpty: Bool {
        waiting.isEmpty
    }

    /// Enqueues a request behind the active prompt, recording the active prompt's title as blocker.
    func enqueue(_ pending: PendingRequest, blockedBy activeTitle: String?) {
        queuedRequests.append(pending)
        if let activeTitle {
            blockedBy[pending.requestID] = activeTitle
        }
        logger.notice(
            "Request \(pending.requestID, privacy: .private) queued behind active prompt",
        )
    }

    /// Registers the continuation for a request. Returns false if a continuation is already registered.
    func registerContinuation(_ continuation: CheckedContinuation<PendingAnswer?, Never>, for requestID: String) -> Bool {
        guard waiting[requestID] == nil else {
            return false
        }
        waiting[requestID] = continuation
        return true
    }

    /// Removes and returns the continuation for a request along with any blocker reason.
    func removeWaiting(for requestID: String) -> (continuation: CheckedContinuation<PendingAnswer?, Never>?, blockedReason: String?) {
        let continuation = waiting.removeValue(forKey: requestID)
        queuedRequests.removeAll { $0.requestID == requestID }
        let blockedReason = blockedBy.removeValue(forKey: requestID)
        return (continuation, blockedReason)
    }

    /// Promotes the next queued request to active status, updating its presentation timestamp
    /// to prevent countdown starvation.
    func promoteNext() -> PendingRequest? {
        guard !queuedRequests.isEmpty else { return nil }
        let next = queuedRequests.removeFirst()
        return next.withActiveTimestamp()
    }

    /// Promotes a specific queued request to active prompt, inserting the currently active prompt
    /// at the head of the queue.
    func promoteQueued(requestID: String, active: PendingRequest) -> PendingRequest? {
        guard let index = queuedRequests.firstIndex(where: { $0.requestID == requestID }) else {
            return nil
        }
        let chosen = queuedRequests.remove(at: index).withActiveTimestamp()
        queuedRequests.insert(active, at: 0)
        blockedBy[active.requestID] = chosen.promptTitle
        blockedBy.removeValue(forKey: chosen.requestID)
        logger.info(
            "Promoted queued request \(chosen.requestID, privacy: .private) to active prompt",
        )
        return chosen
    }

    /// Clears and resumes all waiting continuations with nil (denial).
    func cancelAllWaiting() -> [(continuation: CheckedContinuation<PendingAnswer?, Never>, requestID: String)] {
        queuedRequests.removeAll()
        blockedBy.removeAll()
        lastTimeoutNotice = nil
        let allWaiting = waiting
        waiting.removeAll()
        return allWaiting.map { (continuation: $0.value, requestID: $0.key) }
    }

    /// Sets the last timeout notice.
    func setLastTimeoutNotice(_ notice: String?) {
        lastTimeoutNotice = notice
    }

    /// Consumes and clears the last timeout notice.
    func consumeLastTimeoutNotice() -> String? {
        let notice = lastTimeoutNotice
        lastTimeoutNotice = nil
        return notice
    }
}
