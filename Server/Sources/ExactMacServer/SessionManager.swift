import ExactMac
import ExactMacProto
import Foundation
import OSLog
import SwiftProtobuf

private let logger = ExactMac.sdkLogger(category: "SessionManager")

/// Thread-safe session and transaction manager for the ExactMac gRPC server.
/// Manages session lifecycle, transaction state, operation history, and resource tracking.
actor SessionManager {
    /// Active sessions keyed by session name
    private var sessions: [String: SessionState] = [:]

    /// Default session timeout in seconds
    private let defaultSessionTimeout: TimeInterval
    private let cleanupOperation: (@Sendable () async -> Void)?
    private var cleanupTask: Task<Void, Never>?
    private var acceptingSessions = true

    /// Session state wrapper containing session proto and associated metadata
    private struct SessionState {
        var session: Exactmac_V1_Session
        var activeTransaction: TransactionState?
        var operations: [Exactmac_V1_OperationRecord]
        var applications: [String] // Application resource names
        var observations: [String] // Observation resource names
        var snapshots: [SessionSnapshotState] // State snapshots for rollback
    }

    /// Transaction state wrapper
    private struct TransactionState {
        var transaction: Exactmac_V1_Transaction
        var operationStartIndex: Int // Index in operations array where transaction started
    }

    /// Session snapshot for rollback
    private struct SessionSnapshotState {
        var revisionId: String
        var timestamp: Date
        var operationIndex: Int
    }

    init(
        defaultSessionTimeout: TimeInterval = 3600,
        cleanupOperation: (@Sendable () async -> Void)? = nil,
    ) {
        self.defaultSessionTimeout = defaultSessionTimeout
        self.cleanupOperation = cleanupOperation
    }

    func startCleanup() throws {
        guard acceptingSessions else { throw SessionError.admissionClosed }
        guard cleanupTask == nil else { return }

        let cleanupOperation = self.cleanupOperation
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            if let cleanupOperation {
                await cleanupOperation()
            } else {
                await runCleanupLoop()
            }
            await cleanupDidExit()
        }
    }

    func cleanupTaskCount() -> Int {
        cleanupTask == nil ? 0 : 1
    }

    /// Create a new session
    func createSession(
        sessionId: String?,
        displayName: String,
        metadata: [String: String],
    ) async throws -> Exactmac_V1_Session {
        guard acceptingSessions else { throw SessionError.admissionClosed }
        let id = sessionId ?? UUID().uuidString
        let name = "sessions/\(id)"
        guard sessions[name] == nil else { throw SessionError.alreadyExists }

        let now = Date()
        let expireTime = now.addingTimeInterval(defaultSessionTimeout)

        let session = Exactmac_V1_Session.with {
            $0.name = name
            $0.displayName = displayName
            $0.state = .active
            $0.createTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.expireTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: expireTime)
            $0.metadata = metadata
        }

        let state = SessionState(
            session: session,
            activeTransaction: nil,
            operations: [],
            applications: [],
            observations: [],
            snapshots: [],
        )

        sessions[name] = state
        return session
    }

    /// Get a session by name
    func getSession(name: String) async -> Exactmac_V1_Session? {
        guard var state = sessions[name] else {
            return nil
        }

        // Update last access time
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
        sessions[name] = state

        return state.session
    }

    /// List all sessions with pagination
    func listSessions(
        pageSize: Int,
        pageToken: String?,
        skip: Int = 0,
    ) async throws -> (
        sessions: [Exactmac_V1_Session], nextPageToken: String?,
    ) {
        let effectivePageSize = pageSize > 0 ? pageSize : 50
        let queryBinding = ParsingHelpers.pageTokenQuery(method: "ListSessions")
        let cursor = try ParsingHelpers.pageCursor(
            token: pageToken ?? "",
            skip: skip,
            queryBinding: queryBinding,
        )
        let allSessions = sessions.values.map(\.session).sorted { $0.name < $1.name }
        let range = try ParsingHelpers.pageRange(
            cursor: cursor,
            pageSize: effectivePageSize,
            totalCount: allSessions.count,
        )
        let pageSessions = Array(allSessions[range])
        let encodedNextToken = ParsingHelpers.nextPageToken(
            endOffset: range.upperBound,
            totalCount: allSessions.count,
            queryBinding: queryBinding,
        )
        let nextToken = encodedNextToken.isEmpty ? nil : encodedNextToken

        return (pageSessions, nextToken)
    }

    /// Delete a session
    func deleteSession(name: String) async -> Bool {
        guard sessions[name] != nil else {
            return false
        }

        sessions.removeValue(forKey: name)
        return true
    }

    /// Invalidates all active sessions during graceful shutdown.
    ///
    /// This method:
    /// 1. Marks all sessions as expired
    /// 2. Removes all sessions from the store
    /// 3. Clears any active transactions
    ///
    /// - Returns: The number of sessions that were invalidated.
    @discardableResult
    func invalidateAllSessions() async -> Int {
        acceptingSessions = false
        let task = cleanupTask
        task?.cancel()
        let sessionNames = Array(sessions.keys)
        let count = sessionNames.count

        for name in sessionNames {
            if var state = sessions[name] {
                // Clear any active transaction
                state.activeTransaction = nil
                // Mark as expired
                state.session.state = .expired
                state.session.transactionID = ""
            }
        }

        // Remove all sessions
        sessions.removeAll()
        await task?.value
        cleanupTask = nil

        logger.info("Invalidated \(count, privacy: .public) session(s) during shutdown")
        return count
    }

    /// Begin a transaction for a session
    func beginTransaction(
        sessionName: String,
        isolationLevel: Exactmac_V1_BeginTransactionRequest.IsolationLevel,
        timeout _: TimeInterval,
    ) async throws -> (transactionId: String, revisionId: String, session: Exactmac_V1_Session) {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        // Check if session is already in a transaction
        if state.activeTransaction != nil {
            throw SessionError.transactionAlreadyActive
        }

        // Check session state
        if state.session.state != .active {
            throw SessionError.invalidSessionState
        }

        let transactionId = UUID().uuidString
        let now = Date()

        let transaction = Exactmac_V1_Transaction.with {
            $0.transactionID = transactionId
            $0.session = sessionName
            $0.state = .active
            $0.startTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)
            $0.operationsCount = 0
        }

        // A revision ID is only meaningful when a rollback snapshot is actually
        // stored. Returning a revision ID for a non-SERIALIZABLE isolation level
        // would hand the client a rollback handle that resolves to no stored
        // snapshot (rollbackTransaction would reject it with revisionNotFound) —
        // a design trap. Only SERIALIZABLE transactions are rollback-capable, so
        // only they receive a revision ID; others get an empty revision ID,
        // signalling that rollback is unavailable for that isolation level.
        let revisionId: String
        if isolationLevel == .serializable {
            revisionId = "snapshot-\(transactionId)"
            let snapshot = SessionSnapshotState(
                revisionId: revisionId,
                timestamp: now,
                operationIndex: state.operations.count,
            )
            state.snapshots.append(snapshot)
        } else {
            revisionId = ""
        }

        state.activeTransaction = TransactionState(
            transaction: transaction,
            operationStartIndex: state.operations.count,
        )

        // Update session state
        state.session.state = .inTransaction
        state.session.transactionID = transactionId
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: now)

        sessions[sessionName] = state
        return (transactionId, revisionId, state.session)
    }

    /// Commit a transaction
    func commitTransaction(sessionName: String, transactionId: String) async throws -> Exactmac_V1_Transaction {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        guard let transactionState = state.activeTransaction else {
            throw SessionError.noActiveTransaction
        }

        if transactionState.transaction.transactionID != transactionId {
            throw SessionError.transactionMismatch
        }

        // Count operations in transaction
        let operationsCount =
            Int32(state.operations.count - transactionState.operationStartIndex)

        // Update session state
        state.activeTransaction = nil
        state.session.state = .active
        state.session.transactionID = ""
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())

        sessions[sessionName] = state

        // Update transaction state with updated_session
        var committedTransaction = transactionState.transaction
        committedTransaction.state = .committed
        committedTransaction.operationsCount = operationsCount
        committedTransaction.updatedSession = state.session

        return committedTransaction
    }

    /// Rollback a transaction to a specific revision
    func rollbackTransaction(
        sessionName: String,
        transactionId: String,
        revisionId: String,
    ) async throws -> Exactmac_V1_Transaction {
        guard var state = sessions[sessionName] else {
            throw SessionError.sessionNotFound
        }

        guard let transactionState = state.activeTransaction else {
            throw SessionError.noActiveTransaction
        }

        if transactionState.transaction.transactionID != transactionId {
            throw SessionError.transactionMismatch
        }

        // Find snapshot by revision ID
        guard
            let snapshot = state.snapshots.first(where: { $0.revisionId == revisionId })
        else {
            throw SessionError.revisionNotFound
        }

        // Rollback operations to snapshot point
        let rolledBackCount = state.operations.count - snapshot.operationIndex
        state.operations = Array(state.operations.prefix(snapshot.operationIndex))

        // Update session state
        state.activeTransaction = nil
        state.session.state = .active
        state.session.transactionID = ""
        state.session.lastAccessTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())

        sessions[sessionName] = state

        // Update transaction state with updated_session
        var rolledBackTransaction = transactionState.transaction
        rolledBackTransaction.state = .rolledBack
        rolledBackTransaction.operationsCount = Int32(rolledBackCount)
        rolledBackTransaction.updatedSession = state.session

        return rolledBackTransaction
    }

    /// How many operations the named transaction has accumulated so far, which is the
    /// count a commit or rollback is authorized AS A SCOPE WITH.
    ///
    /// The count is not in the request — no request message in the API carries such a
    /// field — so the interceptor asks here, through the runtime, at derive time. NIL
    /// WHEN IT CANNOT BE TRUTHFUL: no such session, no active transaction, or a
    /// transaction id that does not match, which the authorization layer renders as a
    /// scope with no declared count rather than a guessed one. A commit of a transaction
    /// that has gone away fails in the handler anyway; the authorization layer refusing
    /// to invent a number is the honest half.
    func declaredOperationCount(sessionName: String, transactionId: String) -> Int? {
        guard let state = sessions[sessionName],
              let transactionState = state.activeTransaction,
              transactionState.transaction.transactionID == transactionId
        else {
            return nil
        }
        return state.operations.count - transactionState.operationStartIndex
    }

    /// Record an operation in session history
    func recordOperation(        sessionName: String,
        operationType: String,
        resource: String,
        success: Bool,
        error: String?,
    ) async {
        guard var state = sessions[sessionName] else {
            return
        }

        let operation = Exactmac_V1_OperationRecord.with {
            $0.operationTime = SwiftProtobuf.Google_Protobuf_Timestamp(date: Date())
            $0.operationType = operationType
            $0.resource = resource
            $0.success = success
            if let error {
                $0.error = error
            }
            if let transaction = state.activeTransaction {
                $0.transactionID = transaction.transaction.transactionID
            }
        }

        state.operations.append(operation)
        sessions[sessionName] = state
    }

    /// Add an application to session context
    func addApplication(sessionName: String, applicationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        if !state.applications.contains(applicationName) {
            state.applications.append(applicationName)
            sessions[sessionName] = state
        }
    }

    /// Remove an application from session context
    func removeApplication(sessionName: String, applicationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        state.applications.removeAll { $0 == applicationName }
        sessions[sessionName] = state
    }

    /// Add an observation to session context
    func addObservation(sessionName: String, observationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        if !state.observations.contains(observationName) {
            state.observations.append(observationName)
            sessions[sessionName] = state
        }
    }

    /// Remove an observation from session context
    func removeObservation(sessionName: String, observationName: String) async {
        guard var state = sessions[sessionName] else {
            return
        }

        state.observations.removeAll { $0 == observationName }
        sessions[sessionName] = state
    }

    /// Get a snapshot of session state
    func getSessionSnapshot(sessionName: String) async -> Exactmac_V1_SessionSnapshot? {
        guard let state = sessions[sessionName] else {
            return nil
        }

        return Exactmac_V1_SessionSnapshot.with {
            $0.session = state.session
            $0.applications = state.applications
            $0.observations = state.observations
            $0.operationRecords = state.operations
        }
    }

    /// Background task to clean up expired sessions
    private func runCleanupLoop() async {
        while !Task.isCancelled {
            // Sleep for 1 minute
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                logger.error("Session cleanup sleep failed")
                return
            }

            guard !Task.isCancelled else { return }

            let now = Date()

            // Find expired sessions
            let expiredSessions = sessions.filter { _, state in
                let expireTime = state.session.expireTime.date
                return expireTime < now
            }

            // Remove expired sessions
            for (name, _) in expiredSessions {
                guard var state = sessions[name] else {
                    // Already removed by another operation
                    continue
                }
                state.session.state = .expired
                sessions[name] = state

                // Remove after marking as expired
                sessions.removeValue(forKey: name)
                logger.info("Cleaned up expired session: \(name, privacy: .public)")
            }
        }
    }

    private func cleanupDidExit() {
        cleanupTask = nil
    }
}

enum SessionError: Error, CustomStringConvertible, Equatable {
    case admissionClosed
    case alreadyExists
    case sessionNotFound
    case transactionAlreadyActive
    case noActiveTransaction
    case transactionMismatch
    case invalidSessionState
    case revisionNotFound

    var description: String {
        switch self {
        case .admissionClosed:
            "Session admission is closed"
        case .alreadyExists:
            "Session already exists"
        case .sessionNotFound:
            "Session not found"
        case .transactionAlreadyActive:
            "Transaction already active for this session"
        case .noActiveTransaction:
            "No active transaction for this session"
        case .transactionMismatch:
            "Transaction ID does not match active transaction"
        case .invalidSessionState:
            "Session is not in a valid state for this operation"
        case .revisionNotFound:
            "Revision ID not found"
        }
    }
}
