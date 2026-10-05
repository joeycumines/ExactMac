import AppKit
import Darwin
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import GRPCHealthService
import GRPCNIOTransportHTTP2
import GRPCReflectionService
import NIOCore
import NIOPosix
import OSLog

private let logger = ExactMac.sdkLogger(category: "Main")

/// Set the server umask before AppKit, Vision, CoreImage, or Metal initialization.
/// Returns the previous umask value.
private func setServerProcessUmask() -> mode_t {
    umask(ServerProcessPolicy.umask)
}

// MARK: - Graceful Shutdown

/// Performs graceful shutdown of server resources.
///
/// This function ensures all resources are properly cleaned up in the correct order:
/// 1. Await the composition-owned service lifetime drain started with transport shutdown
/// 2. Drop the claim on the socket pathname, which removes this process's node
///
/// - Parameters:
///   - listenerFactory: The listener this server ran, or nil for a TCP listener. The claim
///     lives in it, so a server that never claimed the pathname — because another server is
///     serving it — removes nothing at all.
///   - serviceLifetime: The composition-owned producer and mutation lifetime.
@MainActor
private func performGracefulShutdown(
    listenerFactory: PeerIdentifyingListenerFactory?,
    serviceLifetime: ServiceLifetime,
) async throws {
    logger.info("Initiating graceful shutdown...")

    await serviceLifetime.shutdown()
    logger.info("Composition-owned service work drained")

    if let listenerFactory {
        try listenerFactory.releaseClaim()
        logger.info("Released the Unix socket claim: \(listenerFactory.socketPath, privacy: .private)")
    }

    ServerInspectionService.unregister()

    logger.info("Graceful shutdown complete")
}

// MARK: - Main Entry Point

/// Main entry point for the ExactMacServer.
///
/// ## Initialization Order (Dependency Graph)
///
/// The server components MUST be initialized in a specific order due to their dependencies.
/// Violating this order will cause runtime failures or undefined behavior.
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────────┐
/// │                        INITIALIZATION ORDER                                   │
/// │                                                                               │
/// │  1. NSApplication.shared                                                      │
/// │     └─ REQUIRED FIRST: AppKit runloop foundation for accessibility/UI        │
/// │        Must be initialized before ANY ExactMac or AX API calls            │
/// │                                                                               │
/// │  2. ServerConfig.fromEnvironment()                                           │
/// │     └─ Loads environment variables for socket paths, ports, addresses        │
/// │        No dependencies, but needed early for logging config state            │
/// │                                                                               │
/// │  3. AppStateStore()                                                           │
/// │     └─ Copy-on-write state container for query isolation                      │
/// │        No dependencies                                                        │
/// │                                                                               │
/// │  4. OperationStore()                                                          │
/// │     └─ LRO (Long-Running Operation) store for async operations               │
/// │        No dependencies                                                        │
/// │                                                                               │
/// │  5. ProductionSystemOperations.shared                                        │
/// │     └─ System API adapter for AX, CG, etc.                                   │
/// │        Depends on: NSApplication.shared                                      │
/// │                                                                               │
/// │  6. WindowRegistry(system:)                                                   │
/// │     └─ Window state tracking via Quartz/AX                                   │
/// │        Depends on: ProductionSystemOperations                                 │
/// │                                                                               │
/// │  7. ObservationManager(windowRegistry:, system:, coordinator:)                │
/// │     └─ Composition-owned actor for observation polling/streaming              │
/// │        Depends on: WindowRegistry, ProductionSystemOperations, coordinator    │
/// │                                                                               │
/// │  8. ExactMacService(stateStore:, operationStore:, windowRegistry:, system:)   │
/// │     └─ Owns one exact InputTransactionExecutor and MacroExecutor graph         │
/// │        Depends on: state, window, system, topology, and mutation ownership     │
/// │                                                                               │
/// │  9. ServiceLifetime(service-owned executors and all producer owners)           │
/// │     └─ Captures the exact service-owned macro/input authority graph            │
/// │        Depends on: ExactMacService and every composition-owned work owner      │
/// │                                                                               │
/// │ 10. GRPCServer.serve()                                                         │
/// │     └─ Start accepting connections - ALL singletons MUST be initialized      │
/// └─────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Why Order Matters
///
/// 1. **NSApplication.shared**: macOS accessibility APIs (AXUIElement) require
///    an active AppKit runloop. Without this, AX calls may hang or return errors.
///
/// 2. **Composition ownership**: Observation and macro handlers use the exact
///    instances injected into `ExactMacService`, so every physical producer shares
///    the service coordinator and mutation gate.
///
/// 3. **WindowRegistry sharing**: ObservationManager, MacroExecutor, and ExactMacService
///    all share the SAME WindowRegistry instance for consistent window state.
///    This avoids cache inconsistencies and duplicate CG queries.
///
/// GENERIC OVER THE TRANSPORT, and the generic parameter is the only thing that is not
/// spelled out twice. `GRPCServer` is generic over its transport type, so the Unix-socket
/// and TCP variants cannot share one binding — and duplicating the whole lifecycle to
/// accommodate that would put two copies of the shutdown ordering on this file. The
/// transport is therefore chosen by `main()` before anything is built.
/// NOT `public`, and not by an oversight. A public function may not name an internal type in
/// its signature, and three of the parameter types are internal declarations that live in
/// `Authorization/`: `AuthorizationRuntime`, `PeerIdentifyingListenerFactory`, and
/// `ConsoleServerEndpoint`. Publishing this function means publishing those three, and
/// `Authorization/` is being restructured in parallel. `main()` above is the whole public
/// surface a host needs today, and it has no such parameter to expose.
@MainActor
func serve(
    config _: ServerConfig,
    transport: some ServerTransport,
    authorizationRuntime: AuthorizationRuntime? = nil,
    listenerFactory: PeerIdentifyingListenerFactory?,
) async throws {
    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 1: NSApplication.shared
    // CRITICAL: Must be initialized FIRST before any SDK or AccessibilityAPI calls
    // Reason: AppKit runloop is required for macOS accessibility APIs to function
    // ═══════════════════════════════════════════════════════════════════════════
    _ = NSApplication.shared
    logger.info("NSApplication initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 3: AppStateStore
    // Copy-on-write state container for query isolation (CQRS pattern)
    // ═══════════════════════════════════════════════════════════════════════════
    let composition = ExactMacServiceComposition()
    try await composition.sessionManager.startCleanup()
    try await composition.elementRegistry.startCleanup()
    // Hydrate the composition-owned macro registry so previously created macros
    // survive a server restart. Failures are logged and swallowed inside the
    // composition so a bad persisted file cannot block startup.
    await composition.loadPersistedMacros()
    logger.info("State store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4: OperationStore
    // LRO (Long-Running Operation) store for async operations like OpenApplication
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Operation store initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 4.5: HealthService
    // gRPC health check service for load balancer integration
    // ═══════════════════════════════════════════════════════════════════════════
    let healthService = HealthService()
    logger.info("Health service initialized")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 5-6: ProductionSystemOperations + WindowRegistry
    // System adapter for AX/CG APIs, and window state tracking
    // WindowRegistry depends on SystemOperations for AX queries
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Shared window registry created")

    // Load descriptor sets for reflection service
    let descriptorSetPaths = ResourceBundleHelper.bundle.paths(
        forResourcesOfType: "pb",
        inDirectory: "DescriptorSets",
    )
    if descriptorSetPaths.isEmpty {
        logger.warning("No descriptor sets found for reflection service. Reflection will not be enabled.")
    } else {
        logger.info("Found \(descriptorSetPaths.count, privacy: .public) descriptor set(s) for reflection: \(descriptorSetPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "), privacy: .public)")
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 7-8: Composition-owned actors
    // The service, observation manager, and macro executor already share the exact
    // registry, system adapter, coordinator, and mutation gate.
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("Composition-owned actors initialized with shared mutation runtime")

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 9: ExactMacService + OperationsProvider
    // Main gRPC service providers - depend on ALL above components
    // ═══════════════════════════════════════════════════════════════════════════
    let exactMacService = composition.exactMacService
    logger.info("Service provider created")

    let operationsProvider = composition.operationsProvider
    logger.info("Operations provider created")

    // Build services array - all services must conform to GRPCCore.RegistrableRPCService
    var services: [any GRPCCore.RegistrableRPCService] = [exactMacService, operationsProvider, healthService]

    if !descriptorSetPaths.isEmpty {
        do {
            let reflectionService = try ReflectionService(descriptorSetFilePaths: descriptorSetPaths)
            services.append(reflectionService)
            logger.info("Reflection service registered")
        } catch {
            logger.error("Failed to initialize reflection service: \(error.localizedDescription, privacy: .public)")
            logger.warning("Continuing without reflection service")
        }
    }

    // The transport arrives already built, and so does the authorization posture it implies.
    // Both are decided in `main()` from the LISTENER, because whether the server can say who
    // is calling is a property of the listener and not of a flag.
    //
    // The session manager is wired here because the composition owns it and the runtime was
    // built before this function ran: a transaction commit's declared operation count can
    // only come from the state that counts the operations. This is the seam that made
    // invariant 9 real — without it every transaction was authorized UNBOUNDED while the
    // prompt said otherwise.
    let interceptors: [any ServerInterceptor]
    if let authorizationRuntime {
        var runtime = authorizationRuntime
        runtime.declaredOperationCount = { [sessionManager = composition.sessionManager] sessionName, transactionId in
            await sessionManager.declaredOperationCount(
                sessionName: sessionName,
                transactionId: transactionId,
            )
        }
        interceptors = productionServerInterceptors(AuthorizationInterceptor(runtime: runtime))
    } else {
        interceptors = handlerContractTestInterceptors()
    }
    let server = GRPCServer(
        transport: productionServerTransport(transport),
        services: services,
        interceptors: interceptors,
    )

    // ═══════════════════════════════════════════════════════════════════════════
    // STEP 10: Start gRPC Server
    // At this point every composition-owned dependency is initialized.
    // ═══════════════════════════════════════════════════════════════════════════
    logger.info("gRPC server starting")

    let signalSource = ShutdownSignalSource()
    let serverTask = Task {
        try await server.serve()
    }
    var lifecycleError: (any Error)?
    do {
        healthService.provider.updateStatus(.serving, forService: RPCAuthorizationMap.serviceName)
        healthService.provider.updateStatus(.serving, forService: "")
        // The consent path is a NAMED status rather than a qualifier on the service status,
        // because `ServingStatus` has no "degraded" and reporting the service itself as
        // not serving would be the other kind of false: the TCP variant does serve, and every
        // consent-requiring capability on it is denied. A health checker that asks about the
        // service gets the truth; one that asks about consent gets the posture.
        if let authorizationRuntime {
            healthService.provider.updateStatus(
                ProductionAuthorizationRuntime.consentServingStatus(
                    isConsoleReachable: authorizationRuntime.isConsoleReachable(),
                ),
                forService: ProductionAuthorizationRuntime.consentHealthServiceName,
            )
        }
        logger.info("Health service status set to SERVING")

        try await waitForServerTermination(
            serverTask: serverTask,
            shutdownSignals: signalSource.stream,
            beginGracefulShutdown: {
                healthService.provider.updateStatus(.notServing, forService: RPCAuthorizationMap.serviceName)
                healthService.provider.updateStatus(.notServing, forService: "")
                if authorizationRuntime != nil {
                    healthService.provider.updateStatus(
                        .notServing,
                        forService: ProductionAuthorizationRuntime.consentHealthServiceName,
                    )
                }
                server.beginGracefulShutdown()
                await composition.serviceLifetime.shutdown()
            },
        )
        logger.info("gRPC server stopped normally")
    } catch {
        lifecycleError = error
        logger.error("gRPC server error: \(error.localizedDescription, privacy: .public)")
        healthService.provider.updateStatus(.notServing, forService: "exactmac.v1.ExactMac")
        healthService.provider.updateStatus(.notServing, forService: "")
        server.beginGracefulShutdown()
        if authorizationRuntime != nil {
            healthService.provider.updateStatus(
                .notServing,
                forService: ProductionAuthorizationRuntime.consentHealthServiceName,
            )
        }
        await composition.serviceLifetime.shutdown()
        _ = try? await serverTask.value
    }

    healthService.provider.updateStatus(.notServing, forService: RPCAuthorizationMap.serviceName)
    healthService.provider.updateStatus(.notServing, forService: "")
    if authorizationRuntime != nil {
        healthService.provider.updateStatus(
            .notServing,
            forService: ProductionAuthorizationRuntime.consentHealthServiceName,
        )
    }
    logger.info("Health service status set to NOT_SERVING")

    var cleanupError: (any Error)?
    do {
        try await performGracefulShutdown(
            listenerFactory: listenerFactory,
            serviceLifetime: composition.serviceLifetime,
        )
    } catch {
        cleanupError = error
        logger.error("Graceful shutdown failed: \(error.localizedDescription, privacy: .public)")
    }

    if let lifecycleError, let cleanupError {
        throw ServerLifecycleError.lifecycleAndCleanup(
            lifecycle: lifecycleError,
            cleanup: cleanupError,
        )
    }
    if let lifecycleError {
        throw lifecycleError
    }
    if let cleanupError {
        throw cleanupError
    }
}

// MARK: - Entry point

/// Runs the server in a host process that brings its own operator interface.
///
/// THIS IS THE APP'S ENTRY POINT and `main()` is the standalone one, and the difference is
/// one argument: a host has somewhere to put a consent prompt, so it hands that place over
/// as a `ConsentAnswering`, and the server asks through it. `main()` hands over nothing, so
/// every consent-requiring capability denies — which is the correct behaviour for a server
/// running on its own with nobody to ask.
///
/// NOT `main()` WITH A FLAG, because the two have genuinely different jobs and a flag would
/// make "am I the app or the server" a question asked at runtime rather than answered by
/// the entry point the process chose to call.
@MainActor
/// The live posture the hosted server enforces, published so the console — the same
/// process, per gf-4 — can write the operator's choice into it. THE ENVIRONMENT OVERRIDE
/// WINS over anything stored here, and `isOverriddenByEnvironment` is what the settings
/// control consults to say so: those orderings are settled where the source is built and
/// this handle cannot disturb them.
///
/// A PUBLIC HANDLE RATHER THAN THE WHOLE RUNTIME, because a public function may not name
/// an internal type and the runtime's other fields have no business being public.
public struct HostedPostureHandle: Sendable {
    private let source: PostureSource

    /// TEST-VISIBLE: the console suite drives the control's display and write path
    /// against a handle built directly, because hosting a real server in a test is the
    /// thing the suite exists to avoid.
    public nonisolated init(source: PostureSource) {
        self.source = source
    }

    /// The posture actually in force right now, which is what the control displays.
    public var current: Posture { source.current }

    /// Whether the environment override holds — the control states that the setting is
    /// controlled by the server's environment when this is true.
    public var isOverriddenByEnvironment: Bool { source.isOverriddenByEnvironment }

    /// The operator's own stored choice, or nil when nothing has been stored.
    public var storedPreference: Posture? { source.storedPreference }

    /// Records the operator's choice and persists it, so it survives a relaunch. The
    /// in-memory write is in force immediately for every later request; the persist is
    /// best-effort for the same reason a failed disk write elsewhere in the product is:
    /// the choice is honest until the process dies, and a persist failure is logged
    /// rather than thrown into the control's face.
    public func setStoredPreference(_ posture: Posture) {
        source.setStoredPreference(posture)
        do {
            try source.persist()
        } catch {
            ExactMacServerLogger.posturePersistFailed(error)
        }
    }
}

enum ExactMacServerLogger {
    static let logger = Logger(
        subsystem: "io.github.joeycumines.exactmac",
        category: "server.hosting",
    )

    static func posturePersistFailed(_ error: any Error) {
        logger.error("The posture preference could not be persisted: \(String(describing: error), privacy: .public)")
    }
}

/// The hosted entry, and the seam through which the console reaches the server's live
/// state. RETURNS A HANDLE over the live posture, because the app and the server are ONE
/// PROCESS (gf-4) and the operator's settings are writes into shared enforcement state
/// rather than RPCs: the posture control writes into the handle, the interceptor reads
/// the source per request from then on. The environment override still wins over
/// anything the operator stores — that ordering is settled at construction and the
/// control states when it holds.
///
/// THE HANDLE ARRIVES BEFORE THE SERVER RUNS, not after it stops. This function still
/// does not return until the server has stopped — that is the contract the console's
/// startup task is written against — so the handle is delivered through
/// `onPostureReady`, invoked the moment the runtime exists, and the console adopts it
/// there. A return value cannot do that job: `serve` awaits termination, so anything the
/// caller reads after the await is read at shutdown, when there is no server left to
/// enforce the posture it names.
@discardableResult
public func serveHosted(
    consent: ConsentAnswering?,
    onPostureReady: (@MainActor @Sendable (HostedPostureHandle) -> Void)? = nil,
) async throws -> HostedPostureHandle {
    _ = setServerProcessUmask()
    let config = ServerConfig.fromEnvironment()
    logger.info("Hosted server starting; operator interface: \(consent != nil ? "installed" : "absent", privacy: .public)")

    guard let socketPath = config.unixSocketPath else {
        // A HOST WITH NO UNIX SOCKET HAS NO PRINCIPAL. TCP has no owning user to authenticate,
        // so it is the reduced posture by construction and a host that reached here cannot
        // consent for anything regardless of the handler it was given.
        logger.warning(
            "Hosted server: no Unix socket is configured, so the reduced unauthenticated posture applies and every consent-requiring capability is denied.",
        )
        let descriptorPolicy = try PublicRequestDescriptorPolicy.load()
        // THE OVERRIDE IS WHAT THE ENVIRONMENT NAMED, INCLUDING STRICT. Mapping a named
        // strict to no override would let an operator write overwrite a deployment that
        // said strict — the opposite of the rule the source enforces everywhere else.
        let source = PostureSource(override: config.defaultPosture)
        await MainActor.run { onPostureReady?(HostedPostureHandle(source: source)) }
        try await serve(
            config: config,
            transport: HTTP2ServerTransport.Posix(
                address: .ipv4(host: config.listenAddress, port: config.port),
                transportSecurity: .plaintext,
            ),
            authorizationRuntime: .tcp(
                descriptorPolicy: descriptorPolicy,
                postureSource: source,
            ),
            listenerFactory: nil,
        )
        return HostedPostureHandle(source: source)
    }

    let runtime = try ProductionAuthorizationRuntime.make(config: config, consent: consent)
    let listener = PeerIdentifyingListenerFactory(
        eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
        socketPath: socketPath,
        registry: runtime.registry,
    )
    logger.info("Hosted server listening on a Unix socket: \(socketPath, privacy: .private)")
    await MainActor.run { onPostureReady?(HostedPostureHandle(source: runtime.postureSource)) }
    try await serve(
        config: config,
        transport: HTTP2ServerTransport.Custom(listenerFactory: listener),
        authorizationRuntime: runtime.authorizationRuntime,
        listenerFactory: listener,
    )
    return HostedPostureHandle(source: runtime.postureSource)
}

/// Chooses the listener, and with it the authorization posture, before anything is built.
///
/// THE VARIANT IS CHOSEN HERE AND NOWHERE ELSE, because the two differ in a security
/// property rather than in a preference. A Unix-socket listener has an owning user and
/// therefore a caller it can name, and it runs its own accept so it can name it: the accept
/// is the only place `LOCAL_PEERPID` and `LOCAL_PEERCRED` can be read, and no
/// `ServerInterceptor` in the pinned gRPC/NIO can reach the accepted socket. A TCP listener
/// has no principal at all, so it never enters the consent or verification path and every
/// consent-requiring capability is denied.
///
/// The Unix-socket variant binds its OWN pathname rather than adopting one launchd created
/// for it, because `ServerBootstrap` — the only way to hand SwiftNIO a connected socket —
/// cannot adopt an existing listening descriptor, and the accept is worth more than the
/// descriptor handoff. launchd still supervises the process through the LaunchAgent; the
/// node's permissions are established by `UnixSocketNode` around the bind.
@MainActor
public func main() async throws {
    // Set the owner-only umask before AppKit, Vision, CoreImage, or Metal can
    // create cache files and directories. Directories must retain owner execute
    // permission for framework cache trees to be traversable.
    _ = setServerProcessUmask()
    logger.info("Set server process umask: \(ServerProcessPolicy.umask, privacy: .public)")

    logger.info("ExactMacServer starting (headless dangerous variant)...")

    let config = ServerConfig.fromEnvironment()
    logger.info("Configuration loaded")

    if let socketPath = config.unixSocketPath {
        logger.info("Will listen on Unix socket: \(socketPath, privacy: .private)")
        logger.info("Operating mode: headless/dangerous variant (unrestricted automation without consent prompt).")

        let registry = ConnectionPeerRegistry()
        let listener = PeerIdentifyingListenerFactory(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            socketPath: socketPath,
            registry: registry,
        )

        try await serve(
            config: config,
            transport: HTTP2ServerTransport.Custom(listenerFactory: listener),
            authorizationRuntime: nil,
            listenerFactory: listener,
        )
        return
    }

    logger.info("Operating mode: headless/dangerous variant on TCP.")
    logger.info("Will listen on \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    try await serve(
        config: config,
        transport: HTTP2ServerTransport.Posix(
            address: .ipv4(host: config.listenAddress, port: config.port),
            transportSecurity: .plaintext,
        ),
        authorizationRuntime: nil,
        listenerFactory: nil,
    )
}
