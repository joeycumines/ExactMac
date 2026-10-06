import CoreGraphics
import Foundation

/// The Core Graphics route on which one owned input transaction is delivered.
public enum InputDeliveryRoute: Equatable, Sendable {
    /// Deliver directly to one exact process and observe its per-process tap.
    case process(pid_t)
    /// Deliver to the authenticated desktop session and observe the annotated
    /// session event stream.
    case session
}

/// Proof produced only after every input post has been observed on the selected
/// route and all release obligations have settled.
public struct InputExecutionReceipt: Equatable, Sendable {
    public let route: InputDeliveryRoute
    public let postedEventCount: Int
    public let routedDeliveryObserved: Bool

    public init(
        route: InputDeliveryRoute,
        postedEventCount: Int,
        routedDeliveryObserved: Bool,
    ) {
        self.route = route
        self.postedEventCount = postedEventCount
        self.routedDeliveryObserved = routedDeliveryObserved
    }
}

/// Preserves the original execution failure while carrying conservative
/// post-attempt evidence for public commitment classification.
public struct InputExecutionFailure: Error, @unchecked Sendable {
    public let underlying: any Error
    public let route: InputDeliveryRoute
    public let postedEventCount: Int
    public let routedDeliveryObserved: Bool
    public let physicalEffectOccurred: Bool

    public init(
        underlying: any Error,
        route: InputDeliveryRoute,
        postedEventCount: Int,
        routedDeliveryObserved: Bool,
        physicalEffectOccurred: Bool,
    ) {
        self.underlying = underlying
        self.route = route
        self.postedEventCount = postedEventCount
        self.routedDeliveryObserved = routedDeliveryObserved
        self.physicalEffectOccurred = physicalEffectOccurred
    }
}

struct InputEventSourceIdentity: Equatable, Sendable {
    let unixProcessID: Int64
    let userID: Int64
    let sourceStateID: Int64

    init(
        unixProcessID: Int64,
        userID: Int64,
        sourceStateID: Int64 = 1,
    ) {
        self.unixProcessID = unixProcessID
        self.userID = userID
        self.sourceStateID = sourceStateID
    }
}

enum InputDeliveryObligationKind: Equatable, Sendable {
    case ordinary
    case safetyRelease
}

enum InputCleanupObligationKind: Equatable, Sendable {
    case keyRelease
    case pointerRelease
    case cursorReassociation
}

struct InputCleanupObligation: Equatable, Sendable {
    let id: UUID
    let kind: InputCleanupObligationKind
}

protocol InputCleanupObligationTracking: Sendable {
    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation
    func settleCleanupObligation(_ obligation: InputCleanupObligation)
    func abandonCleanupObligation(_ obligation: InputCleanupObligation)
    var outstandingCleanupObligationCount: Int { get }
}

struct InputDeliveryAttempt: Equatable, Sendable {
    let token: UInt64
    let obligationID: UUID
    let obligationKind: InputDeliveryObligationKind
    let eventType: CGEventType
    let source: InputEventSourceIdentity
    let route: InputDeliveryRoute
    let generation: UInt64
    let postTimeNanoseconds: UInt64

    init(
        token: UInt64,
        obligationID: UUID,
        obligationKind: InputDeliveryObligationKind = .ordinary,
        eventType: CGEventType,
        source: InputEventSourceIdentity,
        route: InputDeliveryRoute,
        generation: UInt64 = 1,
        postTimeNanoseconds: UInt64,
    ) {
        self.token = token
        self.obligationID = obligationID
        self.obligationKind = obligationKind
        self.eventType = eventType
        self.source = source
        self.route = route
        self.generation = generation
        self.postTimeNanoseconds = postTimeNanoseconds
    }
}

enum InputCleanupAttemptAdmission: Equatable, Sendable {
    case admitted
    case alreadySettled(postTimeNanoseconds: UInt64)
}

struct ObservedInputDelivery: Equatable, Sendable {
    let token: UInt64
    let eventType: CGEventType
    let source: InputEventSourceIdentity
    let route: InputDeliveryRoute
    let generation: UInt64

    init(
        token: UInt64,
        eventType: CGEventType,
        source: InputEventSourceIdentity,
        route: InputDeliveryRoute,
        generation: UInt64 = 1,
    ) {
        self.token = token
        self.eventType = eventType
        self.source = source
        self.route = route
        self.generation = generation
    }
}

enum InputDeliveryLedgerError: Error, Equatable {
    case invalidToken
    case duplicateAttemptToken(UInt64)
    case eventTypeMismatch(token: UInt64)
    case sourceMismatch(token: UInt64)
    case routeMismatch(token: UInt64)
    case generationMismatch(token: UInt64)
    case duplicateObservation(token: UInt64)
    case outOfOrder(expected: UUID, observed: UUID)
    case missingAcknowledgements(count: Int)
    case invalidSafetyReleaseEventType(CGEventType)
    case cleanupObligationMismatch(UUID)
    case outstandingCleanupObligations(count: Int)
    case noAttempts
    case observerFailure(String)
}

extension InputDeliveryLedgerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "input delivery token must be nonzero"
        case let .duplicateAttemptToken(token):
            "input delivery token \(token) was reused"
        case let .eventTypeMismatch(token):
            "input delivery token \(token) arrived with the wrong event type"
        case let .sourceMismatch(token):
            "input delivery token \(token) arrived from the wrong event source"
        case let .routeMismatch(token):
            "input delivery token \(token) arrived on the wrong route"
        case let .generationMismatch(token):
            "input delivery token \(token) arrived from the wrong observer generation"
        case let .duplicateObservation(token):
            "input delivery token \(token) was observed more than once"
        case .outOfOrder:
            "input delivery events arrived out of semantic order"
        case let .missingAcknowledgements(count):
            "input delivery is missing \(count) acknowledgement(s)"
        case let .invalidSafetyReleaseEventType(eventType):
            "input safety-release attempt used non-release event type \(eventType.rawValue)"
        case let .cleanupObligationMismatch(id):
            "input cleanup obligation \(id.uuidString) changed without exact ownership"
        case let .outstandingCleanupObligations(count):
            "input transaction retained \(count) cleanup obligation(s)"
        case .noAttempts:
            "input transaction invoked no events"
        case let .observerFailure(message):
            message
        }
    }
}

struct InputDeliveryLedgerSnapshot: Equatable, Sendable {
    let attemptCount: Int
    let observedAttemptCount: Int
    let settledObligationCount: Int
    let outstandingAcknowledgementCount: Int
    let outstandingCleanupObligationCount: Int
    let hasObservedDelivery: Bool
    let failure: InputDeliveryLedgerError?
}

struct InputDeliveryLedgerSynchronizationHooks: Sendable {
    let cleanupAdmissionDidAcquireLock: (@Sendable () -> Void)?
    let observationDidAcquireLock: (@Sendable () -> Void)?

    init(
        cleanupAdmissionDidAcquireLock: (@Sendable () -> Void)? = nil,
        observationDidAcquireLock: (@Sendable () -> Void)? = nil,
    ) {
        self.cleanupAdmissionDidAcquireLock = cleanupAdmissionDidAcquireLock
        self.observationDidAcquireLock = observationDidAcquireLock
    }
}

final class InputDeliveryLedger: InputCleanupObligationTracking, @unchecked Sendable {
    let route: InputDeliveryRoute
    let generation: UInt64

    private enum CleanupState {
        case armed
        case settled
        case abandoned
    }

    private struct State {
        var attemptsByToken: [UInt64: InputDeliveryAttempt] = [:]
        var attemptOrder: [UInt64] = []
        var obligationOrder: [UUID] = []
        var observedTokens: Set<UInt64> = []
        var settledObligations: [UUID: (token: UInt64, postTime: UInt64)] = [:]
        var cleanupObligations: [UUID: (kind: InputCleanupObligationKind, state: CleanupState)] = [:]
        var failure: InputDeliveryLedgerError?
    }

    private let lock = NSLock()
    private let synchronizationHooks: InputDeliveryLedgerSynchronizationHooks
    private var state = State()

    init(
        route: InputDeliveryRoute,
        generation: UInt64 = 1,
        synchronizationHooks: InputDeliveryLedgerSynchronizationHooks = .init(),
    ) {
        self.route = route
        self.generation = generation
        self.synchronizationHooks = synchronizationHooks
    }

    func registerAttempt(_ attempt: InputDeliveryAttempt) throws {
        try lock.withLock {
            try registerAttemptLocked(attempt)
        }
    }

    func admitCleanupAttemptIfUnsettled(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission {
        try lock.withLock {
            synchronizationHooks.cleanupAdmissionDidAcquireLock?()
            try validateAttemptLocked(attempt)
            guard attempt.obligationKind == .safetyRelease else {
                throw InputDeliveryLedgerError.cleanupObligationMismatch(
                    attempt.obligationID,
                )
            }
            if let settled = try validateSettledCleanupAttemptLocked(attempt) {
                return settled
            }
            appendAttemptLocked(attempt)
            return .admitted
        }
    }

    func validateSettledCleanupAttempt(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        try lock.withLock {
            try validateAttemptLocked(attempt)
            guard attempt.obligationKind == .safetyRelease else {
                throw InputDeliveryLedgerError.cleanupObligationMismatch(
                    attempt.obligationID,
                )
            }
            return try validateSettledCleanupAttemptLocked(attempt)
        }
    }

    @discardableResult
    func recordObserved(_ observation: ObservedInputDelivery) -> Bool {
        lock.withLock {
            synchronizationHooks.observationDidAcquireLock?()
            guard let attempt = state.attemptsByToken[observation.token] else {
                // Unrelated physical input is expected on global taps.
                return false
            }
            guard !state.observedTokens.contains(observation.token) else {
                recordFailureLocked(
                    .duplicateObservation(token: observation.token),
                )
                return true
            }
            guard observation.route == attempt.route else {
                recordFailureLocked(.routeMismatch(token: observation.token))
                return true
            }
            guard observation.generation == attempt.generation else {
                recordFailureLocked(
                    .generationMismatch(token: observation.token),
                )
                return true
            }
            guard observation.eventType == attempt.eventType else {
                recordFailureLocked(
                    .eventTypeMismatch(token: observation.token),
                )
                return true
            }
            guard observation.source == attempt.source else {
                recordFailureLocked(.sourceMismatch(token: observation.token))
                return true
            }

            if state.settledObligations[attempt.obligationID] == nil,
               let expected = state.obligationOrder.first(where: {
                   state.settledObligations[$0] == nil
               }),
               expected != attempt.obligationID
            {
                recordFailureLocked(
                    .outOfOrder(
                        expected: expected,
                        observed: attempt.obligationID,
                    ),
                )
                guard attempt.obligationKind == .safetyRelease else {
                    return true
                }
            }

            state.observedTokens.insert(observation.token)
            if state.settledObligations[attempt.obligationID] == nil {
                state.settledObligations[attempt.obligationID] = (
                    observation.token,
                    attempt.postTimeNanoseconds,
                )
            }
            return true
        }
    }

    func recordObserverFailure(_ message: String) {
        lock.withLock {
            recordFailureLocked(.observerFailure(message))
        }
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        lock.withLock {
            var id = UUID()
            while state.cleanupObligations[id] != nil {
                id = UUID()
            }
            state.cleanupObligations[id] = (kind, .armed)
            return InputCleanupObligation(id: id, kind: kind)
        }
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        transitionCleanupObligation(obligation, to: .settled)
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        transitionCleanupObligation(obligation, to: .abandoned)
    }

    var outstandingCleanupObligationCount: Int {
        lock.withLock {
            state.cleanupObligations.values.count { $0.state == .armed }
        }
    }

    func validateNoFailure() throws {
        try lock.withLock {
            if let failure = state.failure {
                throw failure
            }
        }
    }

    func isAttemptObserved(_ token: UInt64) -> Bool {
        lock.withLock { state.observedTokens.contains(token) }
    }

    func isObligationSettled(_ obligationID: UUID) -> Bool {
        lock.withLock { state.settledObligations[obligationID] != nil }
    }

    func settledPostTime(for obligationID: UUID) -> UInt64? {
        lock.withLock { state.settledObligations[obligationID]?.postTime }
    }

    var snapshot: InputDeliveryLedgerSnapshot {
        lock.withLock {
            InputDeliveryLedgerSnapshot(
                attemptCount: state.attemptOrder.count,
                observedAttemptCount: state.observedTokens.count,
                settledObligationCount: state.settledObligations.count,
                outstandingAcknowledgementCount: state.attemptOrder.count
                    - state.observedTokens.count,
                outstandingCleanupObligationCount: state.cleanupObligations.values.count {
                    $0.state == .armed
                },
                hasObservedDelivery: !state.observedTokens.isEmpty,
                failure: state.failure,
            )
        }
    }

    func complete() throws -> InputExecutionReceipt {
        try lock.withLock {
            if let failure = state.failure {
                throw failure
            }
            let outstandingCleanupCount = state.cleanupObligations.values.count {
                $0.state == .armed
            }
            guard outstandingCleanupCount == 0 else {
                throw InputDeliveryLedgerError.outstandingCleanupObligations(
                    count: outstandingCleanupCount,
                )
            }
            guard !state.attemptOrder.isEmpty else {
                throw InputDeliveryLedgerError.noAttempts
            }
            let missing = state.attemptOrder.count - state.observedTokens.count
            guard missing == 0 else {
                throw InputDeliveryLedgerError.missingAcknowledgements(
                    count: missing,
                )
            }
            return InputExecutionReceipt(
                route: route,
                postedEventCount: state.attemptOrder.count,
                routedDeliveryObserved: true,
            )
        }
    }

    private func recordFailureLocked(_ failure: InputDeliveryLedgerError) {
        if state.failure == nil {
            state.failure = failure
        }
    }

    private func registerAttemptLocked(
        _ attempt: InputDeliveryAttempt,
    ) throws {
        try validateAttemptLocked(attempt)
        appendAttemptLocked(attempt)
    }

    private func validateAttemptLocked(
        _ attempt: InputDeliveryAttempt,
    ) throws {
        guard attempt.token != 0 else {
            throw InputDeliveryLedgerError.invalidToken
        }
        guard attempt.route == route else {
            throw InputDeliveryLedgerError.routeMismatch(token: attempt.token)
        }
        guard attempt.generation == generation else {
            throw InputDeliveryLedgerError.generationMismatch(
                token: attempt.token,
            )
        }
        guard state.attemptsByToken[attempt.token] == nil else {
            throw InputDeliveryLedgerError.duplicateAttemptToken(attempt.token)
        }
        if attempt.obligationKind == .safetyRelease,
           !Self.isSafetyReleaseEventType(attempt.eventType)
        {
            throw InputDeliveryLedgerError.invalidSafetyReleaseEventType(
                attempt.eventType,
            )
        }
    }

    private func appendAttemptLocked(_ attempt: InputDeliveryAttempt) {
        state.attemptsByToken[attempt.token] = attempt
        state.attemptOrder.append(attempt.token)
        if !state.obligationOrder.contains(attempt.obligationID) {
            state.obligationOrder.append(attempt.obligationID)
        }
    }

    private func validateSettledCleanupAttemptLocked(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        guard let settlement = state.settledObligations[attempt.obligationID] else {
            return nil
        }
        guard let settledAttempt = state.attemptsByToken[settlement.token],
              settledAttempt.obligationKind == .safetyRelease
        else {
            throw InputDeliveryLedgerError.cleanupObligationMismatch(
                attempt.obligationID,
            )
        }
        guard settledAttempt.eventType == attempt.eventType else {
            throw InputDeliveryLedgerError.eventTypeMismatch(
                token: attempt.token,
            )
        }
        guard settledAttempt.source == attempt.source else {
            throw InputDeliveryLedgerError.sourceMismatch(
                token: attempt.token,
            )
        }
        guard settledAttempt.route == attempt.route else {
            throw InputDeliveryLedgerError.routeMismatch(
                token: attempt.token,
            )
        }
        guard settledAttempt.generation == attempt.generation else {
            throw InputDeliveryLedgerError.generationMismatch(
                token: attempt.token,
            )
        }
        return .alreadySettled(
            postTimeNanoseconds: settlement.postTime,
        )
    }

    private func transitionCleanupObligation(
        _ obligation: InputCleanupObligation,
        to nextState: CleanupState,
    ) {
        lock.withLock {
            guard let current = state.cleanupObligations[obligation.id],
                  current.kind == obligation.kind,
                  current.state == .armed
            else {
                recordFailureLocked(
                    .cleanupObligationMismatch(obligation.id),
                )
                return
            }
            state.cleanupObligations[obligation.id] = (
                obligation.kind,
                nextState,
            )
        }
    }

    private static func isSafetyReleaseEventType(
        _ eventType: CGEventType,
    ) -> Bool {
        switch eventType {
        case .keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            true
        default:
            false
        }
    }
}

enum InputDeliveryChange: Equatable, Sendable {
    case changed
    case closed
}

final class InputDeliveryChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let waiterDidInstall: (@Sendable () -> Void)?
    private var currentRevision: UInt64 = 1
    private var closed = false
    private var waiters: [
        UUID: CheckedContinuation<InputDeliveryChange, any Error>
    ] = [:]

    init(waiterDidInstall: (@Sendable () -> Void)? = nil) {
        self.waiterDidInstall = waiterDidInstall
    }

    var revision: UInt64 {
        lock.withLock { currentRevision }
    }

    var activeWaiterCount: Int {
        lock.withLock { waiters.count }
    }

    func signalChange() {
        let continuations: [
            CheckedContinuation<InputDeliveryChange, any Error>
        ] = lock.withLock {
            guard !closed else {
                return []
            }
            currentRevision &+= 1
            let continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: true)
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: .changed)
        }
    }

    func close() {
        let continuations: [
            CheckedContinuation<InputDeliveryChange, any Error>
        ] = lock.withLock {
            guard !closed else {
                return []
            }
            closed = true
            currentRevision &+= 1
            let continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: .closed)
        }
    }

    func waitForChange(
        after observedRevision: UInt64,
    ) async throws -> InputDeliveryChange {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var didInstall = false
                let immediate: Result<InputDeliveryChange, any Error>? =
                    lock.withLock {
                        if Task<Never, Never>.isCancelled {
                            return .failure(CancellationError())
                        }
                        if closed {
                            return .success(.closed)
                        }
                        if currentRevision != observedRevision {
                            return .success(.changed)
                        }
                        waiters[id] = continuation
                        didInstall = true
                        return nil
                    }
                if didInstall {
                    waiterDidInstall?()
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

struct InputDeliveryWaitScheduler: Sendable {
    let nowNanoseconds: @Sendable () -> UInt64
    let sleepUntil: @Sendable (UInt64) async throws -> Void

    static let production = InputDeliveryWaitScheduler(
        nowNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        sleepUntil: { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return
            }
            try await Task.sleep(nanoseconds: deadline - now)
        },
    )
}

final class InputDeliveryWaitCoordinator: @unchecked Sendable {
    private enum WaitOutcome: Sendable {
        case change(InputDeliveryChange)
        case deadline
    }

    private let signal: InputDeliveryChangeSignal
    private let scheduler: InputDeliveryWaitScheduler
    private let cleanupRevisionLock = NSLock()
    private var lastCleanupRevision: UInt64

    init(
        signal: InputDeliveryChangeSignal = InputDeliveryChangeSignal(),
        scheduler: InputDeliveryWaitScheduler = .production,
    ) {
        self.signal = signal
        self.scheduler = scheduler
        lastCleanupRevision = signal.revision
    }

    var activeWaiterCount: Int {
        signal.activeWaiterCount
    }

    func signalChange() {
        signal.signalChange()
    }

    func close() {
        signal.close()
    }

    func waitUntil(
        timeoutNanoseconds: UInt64,
        isSettled: @escaping @Sendable () -> Bool,
        validateHealth: @escaping @Sendable () throws -> Void,
        timeoutError: @escaping @Sendable () -> any Error,
    ) async throws {
        let deadline = try makeDeadline(after: timeoutNanoseconds)
        while true {
            try Task.checkCancellation()
            let revision = signal.revision
            if isSettled() {
                return
            }
            try validateHealth()
            if scheduler.nowNanoseconds() >= deadline {
                if isSettled() {
                    return
                }
                try validateHealth()
                throw timeoutError()
            }
            switch try await waitForChangeOrDeadline(
                after: revision,
                deadline: deadline,
            ) {
            case .change(.changed):
                continue
            case .change(.closed):
                throw InputDeliveryLedgerError.observerFailure(
                    "input delivery observer stopped while work remained",
                )
            case .deadline:
                if isSettled() {
                    return
                }
                try validateHealth()
                throw timeoutError()
            }
        }
    }

    func waitWhileHealthy(
        nanoseconds: UInt64,
        validateHealth: @escaping @Sendable () throws -> Void,
    ) async throws {
        let deadline = try makeDeadline(after: nanoseconds)
        while true {
            try Task.checkCancellation()
            let revision = signal.revision
            try validateHealth()
            guard scheduler.nowNanoseconds() < deadline else {
                return
            }
            switch try await waitForChangeOrDeadline(
                after: revision,
                deadline: deadline,
            ) {
            case .change(.changed):
                continue
            case .change(.closed):
                throw InputDeliveryLedgerError.observerFailure(
                    "input delivery observer stopped during action timing",
                )
            case .deadline:
                try validateHealth()
                return
            }
        }
    }

    func waitForChangeOrDelay(nanoseconds: UInt64) async {
        let currentRevision = signal.revision
        let observedRevision = cleanupRevisionLock.withLock {
            lastCleanupRevision
        }
        guard currentRevision == observedRevision else {
            cleanupRevisionLock.withLock {
                lastCleanupRevision = currentRevision
            }
            return
        }
        guard let deadline = try? makeDeadline(after: nanoseconds) else {
            return
        }
        _ = try? await waitForChangeOrDeadline(
            after: currentRevision,
            deadline: deadline,
        )
        let settledRevision = signal.revision
        cleanupRevisionLock.withLock {
            lastCleanupRevision = settledRevision
        }
    }

    func markCleanupAttemptStarted() {
        let currentRevision = signal.revision
        cleanupRevisionLock.withLock {
            lastCleanupRevision = currentRevision
        }
    }

    private func makeDeadline(after nanoseconds: UInt64) throws -> UInt64 {
        let (deadline, overflow) = scheduler.nowNanoseconds()
            .addingReportingOverflow(nanoseconds)
        guard !overflow else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery timeout overflowed its monotonic clock",
            )
        }
        return deadline
    }

    private func waitForChangeOrDeadline(
        after revision: UInt64,
        deadline: UInt64,
    ) async throws -> WaitOutcome {
        try await withThrowingTaskGroup(of: WaitOutcome.self) { group in
            group.addTask { [signal] in
                let change = try await signal.waitForChange(
                    after: revision,
                )
                return .change(change)
            }
            group.addTask { [scheduler] in
                try await scheduler.sleepUntil(deadline)
                return .deadline
            }
            guard let outcome = try await group.next() else {
                throw InputDeliveryLedgerError.observerFailure(
                    "input delivery wait lost both structured waiters",
                )
            }
            group.cancelAll()
            return outcome
        }
    }
}

protocol InputDeliveryObserving: AnyObject, InputCleanupObligationTracking, Sendable {
    var route: InputDeliveryRoute { get }
    var generation: UInt64 { get }
    func invokeAttempt(
        _ attempt: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission
    func validateSettledCleanupAttempt(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission?
    func waitForAttempt(_ token: UInt64) async throws
    func waitForObligation(_ obligationID: UUID) async throws
    func isObligationSettled(_ obligationID: UUID) -> Bool
    func settledPostTime(for obligationID: UUID) -> UInt64?
    func recoverForCleanup() async throws
    func validateForPosting() async throws
    func waitWhileHealthy(nanoseconds: UInt64) async throws
    func waitForChangeOrDelay(nanoseconds: UInt64) async
    func complete() throws -> InputExecutionReceipt
    var hasObservedDelivery: Bool { get }
    func stopAndJoin() async
}

extension InputDeliveryObserving {
    func validateForPosting() async throws {}

    func waitWhileHealthy(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    func waitForChangeOrDelay(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

private final class InputPostAttemptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var eventPostCount = 0
    private var nonEventPhysicalEffectCount = 0

    func recordEventPost() {
        lock.withLock {
            eventPostCount += 1
        }
    }

    var attemptCount: Int {
        lock.withLock { eventPostCount }
    }

    func recordNonEventPhysicalEffect() {
        lock.withLock {
            nonEventPhysicalEffectCount += 1
        }
    }

    var physicalEffectOccurred: Bool {
        lock.withLock {
            eventPostCount > 0 || nonEventPhysicalEffectCount > 0
        }
    }
}

struct InputTapPortIdentity: Hashable, Sendable {
    let rawValue: UInt

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(port: CFMachPort) {
        rawValue = UInt(
            bitPattern: Unmanaged.passUnretained(port).toOpaque(),
        )
    }
}

final class InputTapPortLifetime: @unchecked Sendable {
    let identity: InputTapPortIdentity

    private let retainedPort: AnyObject

    init(port: CFMachPort) {
        identity = InputTapPortIdentity(port: port)
        retainedPort = port
    }

    init(
        identity: InputTapPortIdentity,
        retaining port: AnyObject,
    ) {
        self.identity = identity
        retainedPort = port
    }

    func isSameLifetime(as other: InputTapPortLifetime) -> Bool {
        retainedPort === other.retainedPort
    }
}

struct InputTapInvalidation: Equatable, Sendable {
    let port: InputTapPortIdentity
    let installationID: UUID
}

enum InputTapPostingCriticalOperation: Equatable, Sendable {
    case eventSink
    case terminalFailure
}

struct InputTapPostingCriticalSectionHooks: Sendable {
    let willAcquire: @Sendable (InputTapPostingCriticalOperation) -> Void
    let didAcquire: @Sendable (InputTapPostingCriticalOperation) -> Void

    init(
        willAcquire: @escaping @Sendable (
            InputTapPostingCriticalOperation,
        ) -> Void = { _ in },
        didAcquire: @escaping @Sendable (
            InputTapPostingCriticalOperation,
        ) -> Void = { _ in },
    ) {
        self.willAcquire = willAcquire
        self.didAcquire = didAcquire
    }
}

final class InputTapPostingCriticalSection: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let ownerCountLock = NSLock()
    private let hooks: InputTapPostingCriticalSectionHooks
    private var owners = 0

    init(
        hooks: InputTapPostingCriticalSectionHooks =
            InputTapPostingCriticalSectionHooks(),
    ) {
        self.hooks = hooks
    }

    func withCriticalSection<Result>(
        _ operation: InputTapPostingCriticalOperation,
        _ body: () throws -> Result,
    ) rethrows -> Result {
        hooks.willAcquire(operation)
        lock.lock()
        ownerCountLock.withLock {
            owners += 1
        }
        hooks.didAcquire(operation)
        defer {
            ownerCountLock.withLock {
                owners -= 1
            }
            lock.unlock()
        }
        return try body()
    }

    var activeOwnerCount: Int {
        ownerCountLock.withLock { owners }
    }
}

enum InputTapInvalidationRegistryError: Error, Equatable {
    case portAlreadyRegistered(InputTapPortIdentity)
}

final class InputTapInvalidationRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (InputTapInvalidation) -> Void

    static let shared = InputTapInvalidationRegistry()

    private struct Registration: Sendable {
        let port: InputTapPortLifetime
        let installationID: UUID
        let handler: Handler
    }

    private let lock = NSLock()
    private var registrations: [InputTapPortIdentity: Registration] = [:]

    func register(
        port: InputTapPortLifetime,
        installationID: UUID,
        handler: @escaping Handler,
    ) throws {
        try lock.withLock {
            guard registrations[port.identity] == nil else {
                throw InputTapInvalidationRegistryError.portAlreadyRegistered(
                    port.identity,
                )
            }
            registrations[port.identity] = Registration(
                port: port,
                installationID: installationID,
                handler: handler,
            )
        }
    }

    @discardableResult
    func unregister(
        port: InputTapPortLifetime,
        installationID: UUID,
    ) -> Bool {
        lock.withLock {
            guard let registration = registrations[port.identity],
                  registration.installationID == installationID,
                  registration.port.isSameLifetime(as: port)
            else {
                return false
            }
            registrations.removeValue(forKey: port.identity)
            return true
        }
    }

    @discardableResult
    func recordInvalidation(
        port: InputTapPortLifetime,
    ) -> Bool {
        let registration = lock.withLock {
            guard let registration = registrations[port.identity],
                  registration.port.isSameLifetime(as: port)
            else {
                return nil as Registration?
            }
            return registrations.removeValue(forKey: port.identity)
        }
        guard let registration else {
            return false
        }
        registration.handler(
            InputTapInvalidation(
                port: port.identity,
                installationID: registration.installationID,
            ),
        )
        return true
    }

    var activeRegistrationCount: Int {
        lock.withLock { registrations.count }
    }
}

final class InputTapCallbackContextLease: @unchecked Sendable {
    private let lock = NSLock()
    private let releaser: @Sendable (UnsafeMutableRawPointer) -> Void
    private var retainedContext: UnsafeMutableRawPointer?

    init<Object: AnyObject>(retaining object: Object) {
        retainedContext = Unmanaged.passRetained(object).toOpaque()
        releaser = { context in
            Unmanaged<Object>.fromOpaque(context).release()
        }
    }

    var context: UnsafeMutableRawPointer {
        lock.withLock {
            guard let retainedContext else {
                preconditionFailure("input tap callback context was already released")
            }
            return retainedContext
        }
    }

    func release() {
        let context = lock.withLock {
            let context = retainedContext
            retainedContext = nil
            return context
        }
        if let context {
            releaser(context)
        }
    }

    var isReleased: Bool {
        lock.withLock { retainedContext == nil }
    }

    deinit {
        release()
    }
}

actor InputObserverRecoveryCoordinator {
    private enum State {
        case active
        case stopping
        case stopped
    }

    private struct Recovery {
        let id: UUID
        let task: Task<Void, any Error>
    }

    private var state = State.active
    private var recovery: Recovery?
    private var stopTask: Task<Void, Never>?
    private let recoveryParticipantDidEnter: (@Sendable () -> Void)?
    private let stopDidBegin: (@Sendable () -> Void)?

    init(
        recoveryParticipantDidEnter: (@Sendable () -> Void)? = nil,
        stopDidBegin: (@Sendable () -> Void)? = nil,
    ) {
        self.recoveryParticipantDidEnter = recoveryParticipantDidEnter
        self.stopDidBegin = stopDidBegin
    }

    func recover(
        operation: @escaping @Sendable () async throws -> Void,
    ) async throws {
        guard state == .active else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer is stopping",
            )
        }
        recoveryParticipantDidEnter?()
        if let recovery {
            try await recovery.task.value
            return
        }

        let recoveryID = UUID()
        let task = Task {
            try await operation()
        }
        recovery = Recovery(id: recoveryID, task: task)
        do {
            try await task.value
            clearRecovery(recoveryID)
        } catch {
            clearRecovery(recoveryID)
            throw error
        }
    }

    func stop(
        operation: @escaping @Sendable () async -> Void,
    ) async {
        if state == .stopped {
            return
        }
        if let stopTask {
            await stopTask.value
            return
        }

        state = .stopping
        stopDidBegin?()
        let recoveryTask = recovery?.task
        let task = Task {
            if let recoveryTask {
                _ = try? await recoveryTask.value
            }
            await operation()
        }
        stopTask = task
        await task.value
        recovery = nil
        state = .stopped
        stopTask = nil
    }

    private func clearRecovery(_ recoveryID: UUID) {
        guard recovery?.id == recoveryID else {
            return
        }
        recovery = nil
    }
}

typealias InputTapEventHandler =
    @Sendable (CGEventType, CGEvent, UUID) -> Void

protocol InputTapInstallationOwning: AnyObject, Sendable {
    var installationID: UUID { get }
    var portLifetime: InputTapPortLifetime { get }

    func requireHealthy() throws

    @MainActor
    func finishAdmission(
        invalidationHandler: @escaping @Sendable (
            InputTapInvalidation,
        ) -> Void,
    ) async throws

    @MainActor
    func validateInventory() throws

    @MainActor
    func detach()

    @MainActor
    func awaitCallbackQuiescenceAndRelease() async
}

extension InputTapInstallationOwning {
    var portIdentity: InputTapPortIdentity {
        portLifetime.identity
    }
}

protocol InputTapInstallationPreparing: Sendable {
    @MainActor
    func prepare(
        route: InputDeliveryRoute,
        eventMask: CGEventMask,
        validateProcessRoute: @escaping @Sendable () throws -> Void,
        eventHandler: @escaping InputTapEventHandler,
    ) throws -> any InputTapInstallationOwning
}

final class InputTapEventCallbackContext: @unchecked Sendable {
    let installationID: UUID

    private let lock = NSLock()
    private let eventHandler: InputTapEventHandler
    private var active = true

    init(
        installationID: UUID,
        eventHandler: @escaping InputTapEventHandler,
    ) {
        self.installationID = installationID
        self.eventHandler = eventHandler
    }

    func record(type: CGEventType, event: CGEvent) {
        lock.withLock {
            guard active else {
                return
            }
            eventHandler(type, event, installationID)
        }
    }

    func deactivate() {
        lock.withLock {
            active = false
        }
    }
}

private let coreGraphicsInputTapEventCallback:
    CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let context = Unmanaged<InputTapEventCallbackContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        context.record(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

@discardableResult
func recordCoreGraphicsInputTapInvalidation(
    port: CFMachPort?,
    info _: UnsafeMutableRawPointer?,
    registry: InputTapInvalidationRegistry = .shared,
) -> Bool {
    guard let port else {
        return false
    }
    return registry.recordInvalidation(
        port: InputTapPortLifetime(port: port),
    )
}

private let coreGraphicsInputTapInvalidationCallback:
    CFMachPortInvalidationCallBack = { port, info in
        _ = recordCoreGraphicsInputTapInvalidation(
            port: port,
            info: info,
        )
    }

@MainActor
private func crossInputTapMainRunLoopBarrier() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private final class CoreGraphicsInputTapInstallationFactory:
    InputTapInstallationPreparing,
    @unchecked Sendable
{
    @MainActor
    func prepare(
        route: InputDeliveryRoute,
        eventMask: CGEventMask,
        validateProcessRoute: @escaping @Sendable () throws -> Void,
        eventHandler: @escaping InputTapEventHandler,
    ) throws -> any InputTapInstallationOwning {
        guard CGPreflightListenEventAccess() else {
            throw ExactMacError.accessibilityDenied
        }
        let previousTapIDs = try Set(
            CoreGraphicsInputTapInstallation.tapInformation()
                .map(\.eventTapID),
        )
        let installationID = UUID()
        let callbackContext = InputTapEventCallbackContext(
            installationID: installationID,
            eventHandler: eventHandler,
        )
        let callbackContextLease = InputTapCallbackContextLease(
            retaining: callbackContext,
        )

        do {
            try validateProcessRoute()
        } catch {
            callbackContext.deactivate()
            callbackContextLease.release()
            throw error
        }

        let port: CFMachPort? = switch route {
        case let .process(pid):
            CGEvent.tapCreateForPid(
                pid: pid,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: coreGraphicsInputTapEventCallback,
                userInfo: callbackContextLease.context,
            )
        case .session:
            CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: coreGraphicsInputTapEventCallback,
                userInfo: callbackContextLease.context,
            )
        }
        guard let port else {
            callbackContext.deactivate()
            callbackContextLease.release()
            throw ExactMacError.inputSimulationFailed(
                "failed to create an authorized input delivery observer",
            )
        }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            port,
            0,
        ) else {
            CFMachPortInvalidate(port)
            callbackContext.deactivate()
            callbackContextLease.release()
            throw ExactMacError.inputSimulationFailed(
                "failed to create the input delivery observer run-loop source",
            )
        }
        guard let runLoop = CFRunLoopGetMain() else {
            CFRunLoopSourceInvalidate(source)
            CFMachPortInvalidate(port)
            callbackContext.deactivate()
            callbackContextLease.release()
            throw ExactMacError.inputSimulationFailed(
                "failed to resolve the input delivery observer run loop",
            )
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return CoreGraphicsInputTapInstallation(
            route: route,
            eventMask: eventMask,
            installationID: installationID,
            port: port,
            source: source,
            runLoop: runLoop,
            previousTapIDs: previousTapIDs,
            callbackContext: callbackContext,
            callbackContextLease: callbackContextLease,
            invalidationRegistry: .shared,
        )
    }
}

private final class CoreGraphicsInputTapInstallation:
    InputTapInstallationOwning,
    @unchecked Sendable
{
    let installationID: UUID
    let portLifetime: InputTapPortLifetime

    private let route: InputDeliveryRoute
    private let eventMask: CGEventMask
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop
    private let previousTapIDs: Set<UInt32>
    private let callbackContext: InputTapEventCallbackContext
    private let callbackContextLease: InputTapCallbackContextLease
    private let invalidationRegistry: InputTapInvalidationRegistry
    private let lock = NSLock()
    private var inventoryID: UInt32?
    private var detached = false

    init(
        route: InputDeliveryRoute,
        eventMask: CGEventMask,
        installationID: UUID,
        port: CFMachPort,
        source: CFRunLoopSource,
        runLoop: CFRunLoop,
        previousTapIDs: Set<UInt32>,
        callbackContext: InputTapEventCallbackContext,
        callbackContextLease: InputTapCallbackContextLease,
        invalidationRegistry: InputTapInvalidationRegistry,
    ) {
        self.route = route
        self.eventMask = eventMask
        self.installationID = installationID
        self.port = port
        self.source = source
        self.runLoop = runLoop
        self.previousTapIDs = previousTapIDs
        self.callbackContext = callbackContext
        self.callbackContextLease = callbackContextLease
        self.invalidationRegistry = invalidationRegistry
        portLifetime = InputTapPortLifetime(port: port)
    }

    func requireHealthy() throws {
        let isDetached = lock.withLock { detached }
        guard !isDetached,
              CFMachPortIsValid(port),
              CFRunLoopSourceIsValid(source),
              CFRunLoopContainsSource(
                  runLoop,
                  source,
                  .commonModes,
              ),
              CGEvent.tapIsEnabled(tap: port)
        else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer lost its port or run-loop source",
            )
        }
    }

    @MainActor
    func finishAdmission(
        invalidationHandler: @escaping @Sendable (
            InputTapInvalidation,
        ) -> Void,
    ) async throws {
        try invalidationRegistry.register(
            port: portLifetime,
            installationID: installationID,
            handler: invalidationHandler,
        )
        CFMachPortSetInvalidationCallBack(
            port,
            coreGraphicsInputTapInvalidationCallback,
        )
        if !CFMachPortIsValid(port) {
            invalidationRegistry.recordInvalidation(
                port: portLifetime,
            )
        }
        try requireHealthy()
        await crossInputTapMainRunLoopBarrier()
        let candidates = try Self.tapInformation().filter {
            !previousTapIDs.contains($0.eventTapID)
                && tapInformationMatches($0)
        }
        guard candidates.count == 1, let installed = candidates.first else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer tap inventory was ambiguous",
            )
        }
        let ownsInstallation = lock.withLock {
            guard !detached else {
                return false
            }
            inventoryID = installed.eventTapID
            return true
        }
        guard ownsInstallation else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer lost its tap installation",
            )
        }
        try requireHealthy()
        try validateInventory()
    }

    @MainActor
    func validateInventory() throws {
        let expectedTapID = lock.withLock { inventoryID }
        guard let expectedTapID,
              let installed = try Self.tapInformation().first(where: {
                  $0.eventTapID == expectedTapID
              }),
              tapInformationMatches(installed)
        else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer no longer matches its tap inventory",
            )
        }
    }

    @MainActor
    func detach() {
        let shouldDetach = lock.withLock {
            guard !detached else {
                return false
            }
            detached = true
            return true
        }
        guard shouldDetach else {
            return
        }
        callbackContext.deactivate()
        invalidationRegistry.unregister(
            port: portLifetime,
            installationID: installationID,
        )
        CFMachPortSetInvalidationCallBack(port, nil)
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
    }

    @MainActor
    func awaitCallbackQuiescenceAndRelease() async {
        await crossInputTapMainRunLoopBarrier()
        callbackContextLease.release()
    }

    private func tapInformationMatches(
        _ information: CGEventTapInformation,
    ) -> Bool {
        guard information.tappingProcess == getpid(),
              information.options == .listenOnly,
              information.eventsOfInterest == eventMask,
              information.enabled
        else {
            return false
        }
        return switch route {
        case let .process(pid):
            information.processBeingTapped == pid
        case .session:
            information.processBeingTapped == 0
                && information.tapPoint == .cgAnnotatedSessionEventTap
        }
    }

    @MainActor
    fileprivate static func tapInformation() throws -> [CGEventTapInformation] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            throw InputDeliveryLedgerError.observerFailure(
                "failed to enumerate input delivery event taps",
            )
        }
        guard count > 0 else {
            return []
        }
        var information = Array(
            repeating: CGEventTapInformation(),
            count: Int(count),
        )
        var actualCount = count
        let result = information.withUnsafeMutableBufferPointer {
            CGGetEventTapList(count, $0.baseAddress, &actualCount)
        }
        guard result == .success else {
            throw InputDeliveryLedgerError.observerFailure(
                "failed to read input delivery event-tap inventory",
            )
        }
        return Array(information.prefix(Int(actualCount)))
    }
}

final class CoreGraphicsInputRouteObserver: InputDeliveryObserving, @unchecked Sendable {
    let route: InputDeliveryRoute
    let generation: UInt64

    private let eventMask: CGEventMask
    private let ledger: InputDeliveryLedger
    private let executionBoundary: InputExecutionBoundary
    private let tapInstallationFactory: any InputTapInstallationPreparing
    private let waitCoordinator: InputDeliveryWaitCoordinator
    private let recoveryCoordinator: InputObserverRecoveryCoordinator
    private let postingCriticalSection: InputTapPostingCriticalSection
    private let lock = NSLock()
    private var terminalHealthFailure: String?
    private var ownedTap: (any InputTapInstallationOwning)?

    private init(
        route: InputDeliveryRoute,
        eventMask: CGEventMask,
        generation: UInt64,
        executionBoundary: InputExecutionBoundary,
        tapInstallationFactory: any InputTapInstallationPreparing,
        waitCoordinator: InputDeliveryWaitCoordinator,
        recoveryCoordinator: InputObserverRecoveryCoordinator,
        postingCriticalSection: InputTapPostingCriticalSection,
    ) {
        self.route = route
        self.generation = generation
        self.eventMask = eventMask
        self.executionBoundary = executionBoundary
        self.tapInstallationFactory = tapInstallationFactory
        self.waitCoordinator = waitCoordinator
        self.recoveryCoordinator = recoveryCoordinator
        self.postingCriticalSection = postingCriticalSection
        ledger = InputDeliveryLedger(
            route: route,
            generation: generation,
        )
    }

    @MainActor
    static func start(
        route: InputDeliveryRoute,
        action: InputAction,
        executionBoundary: InputExecutionBoundary,
    ) async throws -> CoreGraphicsInputRouteObserver {
        let eventMask = try inputEventMask(for: action)
        return try await start(
            route: route,
            eventMask: eventMask,
            executionBoundary: executionBoundary,
            tapInstallationFactory: CoreGraphicsInputTapInstallationFactory(),
        )
    }

    @MainActor
    static func start(
        route: InputDeliveryRoute,
        eventMask: CGEventMask,
        executionBoundary: InputExecutionBoundary,
        tapInstallationFactory: any InputTapInstallationPreparing,
        waitCoordinator: InputDeliveryWaitCoordinator =
            InputDeliveryWaitCoordinator(),
        recoveryCoordinator: InputObserverRecoveryCoordinator =
            InputObserverRecoveryCoordinator(),
        postingCriticalSection: InputTapPostingCriticalSection =
            InputTapPostingCriticalSection(),
    ) async throws -> CoreGraphicsInputRouteObserver {
        let observer = CoreGraphicsInputRouteObserver(
            route: route,
            eventMask: eventMask,
            generation: randomNonzeroGeneration(),
            executionBoundary: executionBoundary,
            tapInstallationFactory: tapInstallationFactory,
            waitCoordinator: waitCoordinator,
            recoveryCoordinator: recoveryCoordinator,
            postingCriticalSection: postingCriticalSection,
        )
        try observer.validateProcessRoute()
        try await observer.installTap()
        return observer
    }

    func invokeAttempt(
        _ attempt: InputDeliveryAttempt,
        forCleanup: Bool,
        invocation: () throws -> Void,
    ) throws -> InputCleanupAttemptAdmission {
        try postingCriticalSection.withCriticalSection(.eventSink) {
            try validateProcessRoute()
            let admission: InputCleanupAttemptAdmission
            if forCleanup {
                try requireCurrentTapHealthy()
                admission = try ledger.admitCleanupAttemptIfUnsettled(
                    attempt,
                )
                if admission == .admitted {
                    waitCoordinator.markCleanupAttemptStarted()
                }
            } else {
                try requireHealthy()
                try ledger.registerAttempt(attempt)
                admission = .admitted
            }
            guard admission == .admitted else {
                return admission
            }
            try invocation()
            return admission
        }
    }

    func validateSettledCleanupAttempt(
        _ attempt: InputDeliveryAttempt,
    ) throws -> InputCleanupAttemptAdmission? {
        try ledger.validateSettledCleanupAttempt(attempt)
    }

    func armCleanupObligation(
        _ kind: InputCleanupObligationKind,
    ) -> InputCleanupObligation {
        ledger.armCleanupObligation(kind)
    }

    func settleCleanupObligation(_ obligation: InputCleanupObligation) {
        ledger.settleCleanupObligation(obligation)
    }

    func abandonCleanupObligation(_ obligation: InputCleanupObligation) {
        ledger.abandonCleanupObligation(obligation)
    }

    var outstandingCleanupObligationCount: Int {
        ledger.outstandingCleanupObligationCount
    }

    func waitForAttempt(_ token: UInt64) async throws {
        try await wait(
            timeoutNanoseconds: 5_000_000_000,
            isSettled: { self.ledger.isAttemptObserved(token) },
            timeoutMessage: "timed out waiting for routed input token \(token)",
            preserveOriginalObserverFailure: false,
        )
    }

    func waitForObligation(_ obligationID: UUID) async throws {
        try await wait(
            timeoutNanoseconds: 5_000_000_000,
            isSettled: {
                self.ledger.isObligationSettled(obligationID)
            },
            timeoutMessage: "timed out waiting for input release acknowledgement",
            preserveOriginalObserverFailure: true,
        )
    }

    func isObligationSettled(_ obligationID: UUID) -> Bool {
        ledger.isObligationSettled(obligationID)
    }

    func settledPostTime(for obligationID: UUID) -> UInt64? {
        ledger.settledPostTime(for: obligationID)
    }

    func recoverForCleanup() async throws {
        try validateProcessRoute()
        try await recoveryCoordinator.recover { [self] in
            try validateProcessRoute()
            try await recoverTapIfNeeded()
        }
    }

    @MainActor
    private func recoverTapIfNeeded() async throws {
        let canReuseCurrentTap: Bool
        do {
            try requireCurrentTapHealthy()
            try validateInstalledTapInventory()
            canReuseCurrentTap = true
        } catch {
            canReuseCurrentTap = false
        }
        if canReuseCurrentTap {
            return
        }

        let detached = detachTap()
        await detached?.awaitCallbackQuiescenceAndRelease()
        lock.withLock {
            terminalHealthFailure = nil
        }
        try await installTap()
        waitCoordinator.signalChange()
    }

    func validateForPosting() async throws {
        try Task.checkCancellation()
        try await Task { @MainActor in
            try self.requireHealthy()
            try self.validateInstalledTapInventory()
        }.value
        try Task.checkCancellation()
    }

    func waitWhileHealthy(nanoseconds: UInt64) async throws {
        try await waitCoordinator.waitWhileHealthy(
            nanoseconds: nanoseconds,
            validateHealth: requireHealthy,
        )
    }

    func waitForChangeOrDelay(nanoseconds: UInt64) async {
        await waitCoordinator.waitForChangeOrDelay(
            nanoseconds: nanoseconds,
        )
    }

    func complete() throws -> InputExecutionReceipt {
        try requireHealthy()
        let receipt = try ledger.complete()
        let waiters = waitCoordinator.activeWaiterCount
        guard waiters == 0 else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer retained acknowledgement waiters",
            )
        }
        return receipt
    }

    func validateStoppedCompletion(
        provisionalReceipt: InputExecutionReceipt,
    ) throws -> InputExecutionReceipt {
        let terminalState = lock.withLock {
            (
                terminalHealthFailure,
                ownedTap != nil,
            )
        }
        guard !terminalState.1 else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer was not stopped before finalization",
            )
        }
        if let failure = terminalState.0 {
            throw InputDeliveryLedgerError.observerFailure(failure)
        }
        let receipt = try ledger.complete()
        guard receipt == provisionalReceipt else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery evidence changed while callbacks were draining",
            )
        }
        let waiters = waitCoordinator.activeWaiterCount
        guard waiters == 0 else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer retained acknowledgement waiters",
            )
        }
        return receipt
    }

    var hasObservedDelivery: Bool {
        ledger.snapshot.hasObservedDelivery
    }

    var activeWaiterCount: Int {
        waitCoordinator.activeWaiterCount
    }

    func stopAndJoin() async {
        waitCoordinator.close()
        await recoveryCoordinator.stop { [self] in
            await stopTap()
        }
    }

    @MainActor
    private func stopTap() async {
        let detached = detachTap()
        await detached?.awaitCallbackQuiescenceAndRelease()
    }

    private func wait(
        timeoutNanoseconds: UInt64,
        isSettled: @escaping @Sendable () -> Bool,
        timeoutMessage: String,
        preserveOriginalObserverFailure: Bool,
    ) async throws {
        try await waitCoordinator.waitUntil(
            timeoutNanoseconds: timeoutNanoseconds,
            isSettled: isSettled,
            validateHealth: preserveOriginalObserverFailure
                ? requireCurrentTapHealthy
                : requireHealthy,
            timeoutError: {
                InputDeliveryLedgerError.observerFailure(timeoutMessage)
            },
        )
    }

    @MainActor
    private func installTap() async throws {
        try validateProcessRoute()
        let installation = try tapInstallationFactory.prepare(
            route: route,
            eventMask: eventMask,
            validateProcessRoute: { [weak self] in
                guard let self else {
                    throw InputDeliveryLedgerError.observerFailure(
                        "input delivery observer was released during installation",
                    )
                }
                try self.validateProcessRoute()
            },
            eventHandler: { [weak self] type, event, installationID in
                self?.record(
                    type: type,
                    event: event,
                    installationID: installationID,
                )
            },
        )
        let published = lock.withLock {
            guard ownedTap == nil else {
                return false
            }
            ownedTap = installation
            return true
        }
        guard published else {
            installation.detach()
            await installation.awaitCallbackQuiescenceAndRelease()
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer already owns a tap installation",
            )
        }
        do {
            try await installation.finishAdmission { [weak self] invalidation in
                self?.recordInvalidation(invalidation)
            }
            try requireCurrentTapHealthy()
            try validateInstalledTapInventory()
        } catch {
            let detached = detachTap(
                matching: installation.installationID,
            )
            await detached?.awaitCallbackQuiescenceAndRelease()
            throw error
        }
    }

    fileprivate func record(
        type: CGEventType,
        event: CGEvent,
        installationID: UUID,
    ) {
        let isCurrentInstallation = lock.withLock {
            ownedTap?.installationID == installationID
        }
        guard isCurrentInstallation else {
            return
        }
        switch type {
        case .tapDisabledByTimeout:
            recordHealthFailure(
                "input delivery observer timed out",
                installationID: installationID,
            )
        case .tapDisabledByUserInput:
            recordHealthFailure(
                "input delivery observer was disabled",
                installationID: installationID,
            )
        default:
            let token = UInt64(
                bitPattern: event.getIntegerValueField(
                    .eventSourceUserData,
                ),
            )
            if ledger.recordObserved(
                ObservedInputDelivery(
                    token: token,
                    eventType: type,
                    source: InputEventSourceIdentity(
                        unixProcessID: event.getIntegerValueField(
                            .eventSourceUnixProcessID,
                        ),
                        userID: event.getIntegerValueField(
                            .eventSourceUserID,
                        ),
                        sourceStateID: event.getIntegerValueField(
                            .eventSourceStateID,
                        ),
                    ),
                    route: route,
                    generation: generation,
                ),
            ) {
                waitCoordinator.signalChange()
            }
        }
    }

    private func recordHealthFailure(
        _ message: String,
        installationID: UUID,
    ) {
        let ownsFailure = postingCriticalSection.withCriticalSection(
            .terminalFailure,
        ) {
            lock.withLock {
                guard ownedTap?.installationID == installationID else {
                    return false
                }
                if terminalHealthFailure == nil {
                    terminalHealthFailure = message
                }
                return true
            }
        }
        guard ownsFailure else {
            return
        }
        ledger.recordObserverFailure(message)
        waitCoordinator.signalChange()
    }

    private func recordInvalidation(_ invalidation: InputTapInvalidation) {
        let message = "input delivery observer port was invalidated"
        let ownsInvalidation = postingCriticalSection.withCriticalSection(
            .terminalFailure,
        ) {
            lock.withLock {
                guard ownedTap?.installationID == invalidation.installationID,
                      ownedTap?.portIdentity == invalidation.port
                else {
                    return false
                }
                if terminalHealthFailure == nil {
                    terminalHealthFailure = message
                }
                return true
            }
        }
        guard ownsInvalidation else {
            return
        }
        ledger.recordObserverFailure(message)
        waitCoordinator.signalChange()
    }

    private func requireHealthy() throws {
        try ledger.validateNoFailure()
        try requireCurrentTapHealthy()
    }

    private func requireCurrentTapHealthy() throws {
        let snapshot = lock.withLock {
            (
                terminalHealthFailure,
                ownedTap,
            )
        }
        if let failure = snapshot.0 {
            throw InputDeliveryLedgerError.observerFailure(failure)
        }
        guard let owned = snapshot.1 else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer lost its port or run-loop source",
            )
        }
        try owned.requireHealthy()
    }

    @MainActor
    private func validateInstalledTapInventory() throws {
        guard let owned = lock.withLock({ ownedTap }) else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery observer no longer matches its tap inventory",
            )
        }
        try owned.validateInventory()
    }

    @MainActor
    private func detachTap(
        matching installationID: UUID? = nil,
    ) -> (any InputTapInstallationOwning)? {
        let detached: (any InputTapInstallationOwning)? = lock.withLock {
            if let installationID,
               ownedTap?.installationID != installationID
            {
                return nil
            }
            let result = ownedTap
            ownedTap = nil
            return result
        }
        detached?.detach()
        return detached
    }

    private static func inputEventMask(
        for action: InputAction,
    ) throws -> CGEventMask {
        try inputEventTypes(for: action).reduce(0) { mask, type in
            guard type.rawValue < 64 else {
                throw InputDeliveryLedgerError.observerFailure(
                    "input event type is outside the Core Graphics mask range",
                )
            }
            return mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private static func inputEventTypes(
        for action: InputAction,
    ) throws -> [CGEventType] {
        switch action {
        case .type, .typeText, .press, .pressHold, .pressKeyCode, .pressKeyCodeHold:
            [.keyDown, .keyUp]
        case .click, .doubleClick:
            [.leftMouseDown, .leftMouseUp]
        case .rightClick:
            [.rightMouseDown, .rightMouseUp]
        case let .clickSequence(_, button, _, _):
            try mouseButtonTypes(button)
        case .move, .movePointer, .hover:
            [.mouseMoved]
        case let .drag(_, _, button, _),
             let .dragPath(_, button, _, _):
            try mouseButtonTypes(button, includesDrag: true)
        case .scroll:
            [.scrollWheel]
        }
    }

    private static func mouseButtonTypes(
        _ button: CGMouseButton,
        includesDrag: Bool = false,
    ) throws -> [CGEventType] {
        switch button {
        case .left:
            includesDrag
                ? [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                : [.leftMouseDown, .leftMouseUp]
        case .right:
            includesDrag
                ? [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
                : [.rightMouseDown, .rightMouseUp]
        case .center:
            includesDrag
                ? [.otherMouseDown, .otherMouseDragged, .otherMouseUp]
                : [.otherMouseDown, .otherMouseUp]
        default:
            throw ExactMacError.inputInvalidArgument(
                "unsupported mouse button \(button.rawValue)",
            )
        }
    }

    private static func randomNonzeroGeneration() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        var value = UInt64.random(
            in: UInt64.min ... UInt64.max,
            using: &generator,
        )
        while value == 0 {
            value = UInt64.random(
                in: UInt64.min ... UInt64.max,
                using: &generator,
            )
        }
        return value
    }

    private func validateProcessRoute() throws {
        guard case let .process(pid) = route else {
            return
        }
        try executionBoundary.validateProcessRoute(pid)
    }
}

/// Executes one action with unpredictable per-event tokens and refuses success
/// until every post is observed on the exact process or session route.
@MainActor
public func executeObservedInputAction(
    _ action: InputAction,
    route: InputDeliveryRoute,
    executionBoundary: InputExecutionBoundary,
    backendOperation: (@MainActor @Sendable (any InputEventBackend) async throws -> Void)? = nil,
) async throws -> InputExecutionReceipt {
    let observer = try await CoreGraphicsInputRouteObserver.start(
        route: route,
        action: action,
        executionBoundary: executionBoundary,
    )
    let tracker = InputPostAttemptTracker()
    do {
        let backend = try CoreGraphicsInputEventBackend(
            route: route,
            deliveryObserver: observer,
            postInvocationRecorder: tracker.recordEventPost,
            nonEventPhysicalEffectRecorder: tracker.recordNonEventPhysicalEffect,
            executionBoundary: executionBoundary,
        )
        if let backendOperation {
            try await backendOperation(backend)
        } else {
            try await executeInputAction(action, backend: backend)
        }
        let receipt = try observer.complete()
        guard receipt.postedEventCount == tracker.attemptCount else {
            throw InputDeliveryLedgerError.observerFailure(
                "input delivery attempt count did not match its ledger",
            )
        }
        await observer.stopAndJoin()
        return try observer.validateStoppedCompletion(
            provisionalReceipt: receipt,
        )
    } catch {
        await observer.stopAndJoin()
        throw InputExecutionFailure(
            underlying: error,
            route: route,
            postedEventCount: tracker.attemptCount,
            routedDeliveryObserved: observer.hasObservedDelivery,
            physicalEffectOccurred: tracker.physicalEffectOccurred,
        )
    }
}
