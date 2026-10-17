import AppKit
@testable import ExactMacConsole
@testable import ExactMacServer
import Foundation
import Testing

@Suite("SettingsViewModel and Default Access State Management", .serialized)
@MainActor
struct SettingsViewModelTests {
    private final class ScriptedCeremony: CeremonyPerforming {
        var outcome: BiometricCeremony.Outcome
        private(set) var callCount: Int = 0
        private(set) var lastReason: String?

        init(outcome: BiometricCeremony.Outcome = .performed) {
            self.outcome = outcome
        }

        func perform(nonce _: String, reason: String) async -> BiometricCeremony.Outcome {
            callCount += 1
            lastReason = reason
            return outcome
        }
    }

    private static func makeViewModel(
        ceremony: (any CeremonyPerforming)? = nil,
        store: any PreferencesStore = InMemoryPreferencesStore()
    ) -> (SettingsViewModel, HostedPostureHandle) {
        let source = PostureSource(override: nil, store: store)
        let handle = HostedPostureHandle(source: source)
        let vm = SettingsViewModel(
            windows: ConsoleWindowHost(),
            ceremony: ceremony,
            stateEnvironment: [:]
        )
        vm.adoptPostureHandle(handle)
        return (vm, handle)
    }

    @Test
    func `adoptPostureHandle initializes default access, touch id rules, and timeout`() {
        let (vm, handle) = Self.makeViewModel()
        #expect(vm.displayedDefaultAccess == handle.defaultAccess)
        #expect(vm.displayedTouchIDRules == handle.touchIDRules)
        #expect(vm.displayedConsentTimeoutSeconds == handle.consentTimeoutSeconds)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .windowsAndScreen) == .allow)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .clipboard) == .ask)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .appsAndInput) == .ask)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .scriptsAndTerminal) == .ask)
    }

    @Test
    func `setDefaultAccess updates capability group and persists to handle`() {
        let (vm, handle) = Self.makeViewModel()
        vm.setDefaultAccess(level: .allow, for: .clipboard)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .clipboard) == .allow)
        #expect(handle.defaultAccess.accessLevel(for: .clipboard) == .allow)

        vm.setDefaultAccess(level: .ask, for: .windowsAndScreen)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .windowsAndScreen) == .ask)
        #expect(handle.defaultAccess.accessLevel(for: .windowsAndScreen) == .ask)
    }

    @Test
    func `allowAll requires ceremony when broadApprovals rule is active`() async {
        let ceremony = ScriptedCeremony(outcome: .unavailable(.cancelled))
        let (vm, handle) = Self.makeViewModel(ceremony: ceremony)

        #expect(vm.displayedTouchIDRules.broadApprovals == true)
        await vm.performAllowAll()

        // Ceremony was called and failed -> settings remain unchanged
        #expect(ceremony.callCount == 1)
        #expect(vm.displayedDefaultAccess.isAllowingAll == false)
        #expect(handle.defaultAccess.isAllowingAll == false)

        // Now with successful ceremony
        ceremony.outcome = .performed
        await vm.performAllowAll()

        #expect(ceremony.callCount == 2)
        #expect(vm.displayedDefaultAccess.isAllowingAll == true)
        #expect(handle.defaultAccess.isAllowingAll == true)
    }

    @Test
    func `resetDefaults restores default access to standard`() {
        let (vm, handle) = Self.makeViewModel()
        vm.setDefaultAccess(level: .allow, for: .clipboard)
        vm.setDefaultAccess(level: .allow, for: .scriptsAndTerminal)
        #expect(vm.displayedDefaultAccess.accessLevel(for: .clipboard) == .allow)

        vm.resetDefaults()
        #expect(vm.displayedDefaultAccess == .standard)
        #expect(handle.defaultAccess == .standard)
    }

    @Test
    func `setTouchIDRule requires ceremony when disabling and none when enabling`() async {
        let ceremony = ScriptedCeremony(outcome: .unavailable(.cancelled))
        let (vm, handle) = Self.makeViewModel(ceremony: ceremony)

        #expect(vm.displayedTouchIDRules.scriptsAndTerminal == true)

        // Attempt to disable with failing ceremony
        await vm.performTouchIDRuleChange(.scriptsAndTerminal, enabled: false)
        #expect(ceremony.callCount == 1)
        #expect(vm.displayedTouchIDRules.scriptsAndTerminal == true, "rule must remain enabled if ceremony fails")
        #expect(handle.touchIDRules.scriptsAndTerminal == true)

        // Disable with successful ceremony
        ceremony.outcome = .performed
        await vm.performTouchIDRuleChange(.scriptsAndTerminal, enabled: false)
        #expect(ceremony.callCount == 2)
        #expect(vm.displayedTouchIDRules.scriptsAndTerminal == false)
        #expect(handle.touchIDRules.scriptsAndTerminal == false)

        // Enabling again requires NO ceremony
        let countBefore = ceremony.callCount
        await vm.performTouchIDRuleChange(.scriptsAndTerminal, enabled: true)
        #expect(ceremony.callCount == countBefore, "enabling rule must not trigger ceremony")
        #expect(vm.displayedTouchIDRules.scriptsAndTerminal == true)
        #expect(handle.touchIDRules.scriptsAndTerminal == true)
    }

    @Test
    func `setConsentTimeoutSeconds updates timeout and persists`() {
        let (vm, handle) = Self.makeViewModel()
        vm.setConsentTimeoutSeconds(30)
        #expect(vm.displayedConsentTimeoutSeconds == 30)
        #expect(handle.consentTimeoutSeconds == 30)

        vm.setConsentTimeoutSeconds(300)
        #expect(vm.displayedConsentTimeoutSeconds == 300)
        #expect(handle.consentTimeoutSeconds == 300)
    }

    @Test
    func `screenLock denies pending prompt fail-closed`() {
        let windows = ConsoleWindowHost()
        let model = ConsoleModel(windows: windows)
        let source = PostureSource(override: nil, store: InMemoryPreferencesStore())
        model.settingsViewModel.adoptPostureHandle(HostedPostureHandle(source: source))

        model.handleScreenLocked()
        #expect(model.waitingCount == 0)
    }
}
