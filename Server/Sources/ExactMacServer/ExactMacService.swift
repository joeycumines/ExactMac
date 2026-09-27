import AppKit
import ApplicationServices
import CoreGraphics
import ExactMac
import ExactMacProto
import Foundation
import GRPCCore
import OSLog
import SwiftProtobuf

struct WindowMutationConvergencePolicy: Sendable {
    static let production = WindowMutationConvergencePolicy(
        timeout: .seconds(2),
        pollInterval: .milliseconds(25),
        geometryTolerance: 1,
        stableReadCount: 2,
    )

    let timeout: Duration
    let pollInterval: Duration
    let geometryTolerance: CGFloat
    let stableReadCount: Int

    init(
        timeout: Duration,
        pollInterval: Duration,
        geometryTolerance: CGFloat,
        stableReadCount: Int,
    ) {
        self.timeout = timeout > .zero ? timeout : .milliseconds(1)
        self.pollInterval = pollInterval > .zero ? pollInterval : .milliseconds(1)
        self.geometryTolerance = max(0, geometryTolerance)
        self.stableReadCount = max(1, stableReadCount)
    }
}

final class ExactMacService: Exactmac_V1_ExactMac.ServiceProtocol {
    static let logger = ExactMac.sdkLogger(category: "ExactMacService")
    let stateStore: AppStateStore
    let applicationCatalogProvider: any ApplicationCatalogProvider
    let legacyPIDResourceNamesForTests: Bool
    let operationStore: OperationStore
    let windowRegistry: WindowRegistry
    let system: SystemOperations
    let displayTopologyProvider: any DisplayTopologyProviding
    let screenshotCapture: any ScreenshotCapturing
    let captureWorkOwner: CaptureWorkOwner
    let elementRegistry: ElementRegistry
    let elementLocator: ElementLocator
    let automationCoordinator: AutomationCoordinator
    let inputOverlayPresenter: InputOverlayPresenter
    let inputTransactionExecutor: InputTransactionExecutor
    let observationManager: ObservationManager
    let macroRegistry: MacroRegistry
    let macroExecutor: MacroExecutor
    let sessionManager: SessionManager
    let scriptExecutor: ScriptExecutor
    let clipboardHistoryManager: ClipboardHistoryManager
    let clipboardManager: ClipboardManager
    let physicalDesktopMutationGate: PhysicalDesktopMutationGate
    /// The grant store, when one is open.
    ///
    /// OPTIONAL AND NIL BY DEFAULT, following the same shape as the clipboard manager, and
    /// nil is the safe answer: a nil store is not an empty one, so the listing RPCs report
    /// that grants could not be read rather than reporting zero. Which is the difference
    /// between an agent that asks once and an agent that asks forever.
    let grantStore: GrantStore?
    /// The ceiling on an envelope, and the consent path, both from configuration.
    let maximumEnvelopeSeconds: Int
    let consentBroker: (any ConsentBroker)?
    let applicationTerminationGracePeriod: Duration
    let applicationTerminationForcePeriod: Duration
    let windowMutationConvergencePolicy: WindowMutationConvergencePolicy

    init(
        stateStore: AppStateStore,
        operationStore: OperationStore,
        windowRegistry: WindowRegistry,
        applicationCatalogProvider: any ApplicationCatalogProvider = ProductionApplicationCatalogProvider(),
        legacyPIDResourceNamesForTests: Bool = false,
        system: SystemOperations = ProductionSystemOperations.shared,
        displayTopologyProvider: any DisplayTopologyProviding = ProductionDisplayTopologyProvider(),
        screenshotCapture: any ScreenshotCapturing = ProductionScreenshotCapturer(),
        captureWorkOwner: CaptureWorkOwner = CaptureWorkOwner(),
        automationCoordinator: AutomationCoordinator? = nil,
        inputOverlayPresenter: InputOverlayPresenter = InputOverlayPresenter(),
        elementLocator: ElementLocator? = nil,
        observationManager: ObservationManager? = nil,
        macroRegistry: MacroRegistry = MacroRegistry(),
        macroDeadlineWaiter: @escaping MacroDeadlineWaiter = {
            try await ContinuousClock().sleep(until: $0)
        },
        sessionManager: SessionManager = SessionManager(),
        scriptExecutor: ScriptExecutor? = nil,
        clipboardHistoryManager: ClipboardHistoryManager? = nil,
        clipboardManager: ClipboardManager? = nil,
        applicationTerminationGracePeriod: Duration = .seconds(2),
        applicationTerminationForcePeriod: Duration = .seconds(3),
        windowMutationConvergencePolicy: WindowMutationConvergencePolicy = .production,
        grantStore: GrantStore? = nil,
        maximumEnvelopeSeconds: Int = ServerConfig.defaultMaximumEnvelopeSeconds,
        consentBroker: (any ConsentBroker)? = nil,
    ) {
        let elementRegistry = automationCoordinator?.elementRegistry ?? ElementRegistry()
        let automationCoordinator = automationCoordinator ?? AutomationCoordinator(
            elementRegistry: elementRegistry,
            activationSystem: system,
        )
        let elementLocator = elementLocator ?? ElementLocator(
            elementRegistry: elementRegistry,
            stateStore: stateStore,
            windowRegistry: windowRegistry,
            legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            system: system,
            automationCoordinator: automationCoordinator,
        )
        let clipboardHistoryManager = clipboardHistoryManager ?? ClipboardHistoryManager()
        let clipboardManager = clipboardManager ?? ClipboardManager(
            mutationGate: automationCoordinator.mutationGate,
            historyManager: clipboardHistoryManager,
        )
        let inputTransactionExecutor = InputTransactionExecutor(
            stateStore: stateStore,
            legacyPIDResourceNamesForTests: legacyPIDResourceNamesForTests,
            windowRegistry: windowRegistry,
            system: system,
            displayTopologyProvider: displayTopologyProvider,
            automationCoordinator: automationCoordinator,
            inputOverlayPresenter: inputOverlayPresenter,
            clipboardManager: clipboardManager,
            windowMutationConvergencePolicy: windowMutationConvergencePolicy,
        )
        let macroExecutor = MacroExecutor(
            windowRegistry: windowRegistry,
            inputTransactionExecutor: inputTransactionExecutor,
            automationCoordinator: automationCoordinator,
            elementRegistry: elementRegistry,
            elementLocator: elementLocator,
            deadlineWaiter: macroDeadlineWaiter,
        )
        self.stateStore = stateStore
        self.applicationCatalogProvider = applicationCatalogProvider
        self.legacyPIDResourceNamesForTests = legacyPIDResourceNamesForTests
        self.operationStore = operationStore
        self.windowRegistry = windowRegistry
        self.system = system
        self.displayTopologyProvider = displayTopologyProvider
        self.screenshotCapture = screenshotCapture
        self.captureWorkOwner = captureWorkOwner
        self.elementRegistry = elementRegistry
        self.elementLocator = elementLocator
        self.automationCoordinator = automationCoordinator
        self.inputOverlayPresenter = inputOverlayPresenter
        self.inputTransactionExecutor = inputTransactionExecutor
        self.observationManager = observationManager ?? ObservationManager(
            windowRegistry: windowRegistry,
            system: system,
            automationCoordinator: automationCoordinator,
        )
        self.macroRegistry = macroRegistry
        self.macroExecutor = macroExecutor
        self.sessionManager = sessionManager
        physicalDesktopMutationGate = automationCoordinator.mutationGate
        self.scriptExecutor = scriptExecutor ?? ScriptExecutor(
            mutationGate: automationCoordinator.mutationGate,
        )
        self.clipboardHistoryManager = clipboardHistoryManager
        self.clipboardManager = clipboardManager
        self.applicationTerminationGracePeriod = applicationTerminationGracePeriod
        self.applicationTerminationForcePeriod = applicationTerminationForcePeriod
        self.windowMutationConvergencePolicy = windowMutationConvergencePolicy
        self.grantStore = grantStore
        self.maximumEnvelopeSeconds = maximumEnvelopeSeconds
        self.consentBroker = consentBroker
    }
}
