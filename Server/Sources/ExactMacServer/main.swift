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
@MainActor
func serve(
    config _: ServerConfig,
    transport: some ServerTransport,
    authorizationRuntime: AuthorizationRuntime,
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
    let server = GRPCServer(
        transport: productionServerTransport(transport),
        services: services,
        interceptors: productionServerInterceptors(AuthorizationInterceptor(runtime: authorizationRuntime)),
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
        healthService.provider.updateStatus(.serving, forService: "exactmac.v1.ExactMac")
        healthService.provider.updateStatus(.serving, forService: "")
        logger.info("Health service status set to SERVING")

        try await waitForServerTermination(
            serverTask: serverTask,
            shutdownSignals: signalSource.stream,
            beginGracefulShutdown: {
                healthService.provider.updateStatus(.notServing, forService: "exactmac.v1.ExactMac")
                healthService.provider.updateStatus(.notServing, forService: "")
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
        await composition.serviceLifetime.shutdown()
        _ = try? await serverTask.value
    }

    healthService.provider.updateStatus(.notServing, forService: "exactmac.v1.ExactMac")
    healthService.provider.updateStatus(.notServing, forService: "")
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
func main() async throws {
    // Set the owner-only umask before AppKit, Vision, CoreImage, or Metal can
    // create cache files and directories. Directories must retain owner execute
    // permission for framework cache trees to be traversable.
    _ = setServerProcessUmask()
    logger.info("Set server process umask: \(ServerProcessPolicy.umask, privacy: .public)")

    logger.info("ExactMacServer starting...")

    let config = ServerConfig.fromEnvironment()
    logger.info("Configuration loaded")
    let descriptorPolicy = try PublicRequestDescriptorPolicy.load()

    if let socketPath = config.unixSocketPath {
        logger.info("Will listen on Unix socket: \(socketPath, privacy: .private)")
        logger.info("Authorization: unix-socket variant; the owning user is the principal.")
        let registry = ConnectionPeerRegistry()
        let listener = PeerIdentifyingListenerFactory(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            socketPath: socketPath,
            registry: registry,
        )
        try await serve(
            config: config,
            transport: HTTP2ServerTransport.Custom(listenerFactory: listener),
            authorizationRuntime: .unixSocket(
                descriptorPolicy: descriptorPolicy,
                peerEvidence: .registry(registry),
            ),
            listenerFactory: listener,
        )
        return
    }

    logger.warning(
        "Authorization: reduced unauthenticated posture. This listener has no owning user, so every consent-requiring capability is denied and no approval can be given. Do not expose this port beyond the loopback interface.",
    )
    logger.info("Will listen on \(config.listenAddress, privacy: .public):\(config.port, privacy: .public)")
    try await serve(
        config: config,
        transport: HTTP2ServerTransport.Posix(
            address: .ipv4(host: config.listenAddress, port: config.port),
            transportSecurity: .plaintext,
        ),
        authorizationRuntime: .tcp(descriptorPolicy: descriptorPolicy),
        listenerFactory: nil,
    )
}

// A STARTUP FAILURE IS A CLEAN ERROR, NOT A TRAP. `try await main()` at top level turns any
// throw into a Swift runtime error, which prints a stack-ish "Fatal error: Error raised at
// top level" to stderr and aborts. The most likely startup failure in this system is a
// pathname another server already holds, and an operator who hits it deserves the sentence
// the server actually has — "is claimed by a running server; refusing to take the pathname
// over" — rather than a trap that hides it behind a transport error.
do {
    try await main()
} catch {
    logger.error("ExactMacServer failed to start: \(String(describing: error), privacy: .public)")
    Foundation.exit(1)
}
