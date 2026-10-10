import Foundation
import Synchronization

/// WHETHER OPENING THE CONSOLE'S REVEALING SURFACES COSTS A FINGERPRINT, LIVE.
///
/// The console's settings row "Require Touch ID to open the console" governs exactly two
/// surfaces — Grants and Activity — and nothing else.
///
/// THE SOURCE IS A MUTEX-WRAPPED VALUE backed by `PreferencesStore` (`UserDefaults` suite
/// `com.exactmac.console` in production, `InMemoryPreferencesStore` in tests).
///
/// THREAT MODEL DEFENSE (Option 2): If stored preferences indicate a relaxed gate (`false`),
/// it requires operator Touch ID confirmation on launch before the gate opens without ceremony.
/// Until confirmed, it fails closed to `true` (ceremony required), preventing privilege
/// escalation via unauthorized `defaults write`.
public final class BiometricGateSource: Sendable {
    public static let preferenceKey = "ceremonyRequired"

    private struct State: Sendable {
        var ceremonyRequired: Bool
        var confirmed: Bool
    }

    private let store: any PreferencesStore
    private let state: Mutex<State>

    public init(store: any PreferencesStore = UserDefaultsPreferencesStore()) {
        self.store = store
        let storedValue = store.bool(forKey: Self.preferenceKey) ?? true
        // If stored preference is false (gate disabled/relaxed), require confirmation on launch.
        // If true (ceremony required), it is already safe and confirmed.
        let isSafe = (storedValue == true)
        self.state = Mutex<State>(State(ceremonyRequired: storedValue, confirmed: isSafe))
    }

    /// `true` when opening Grants or Activity costs a ceremony, which is the default.
    public var isCeremonyRequired: Bool {
        let current = state.withLock { $0 }
        guard current.confirmed else {
            // Unconfirmed relaxed gate defaults to requiring ceremony (fail-closed)
            return true
        }
        return current.ceremonyRequired
    }

    /// Whether the stored gate setting has been confirmed by operator Touch ID.
    public var isConfirmed: Bool {
        state.withLock { $0.confirmed }
    }

    /// Whether Touch ID confirmation is needed to activate a stored relaxed gate.
    public var needsConfirmation: Bool {
        let current = state.withLock { $0 }
        return !current.confirmed && !current.ceremonyRequired
    }

    /// Confirms the stored gate via interactive Touch ID.
    public func confirmStoredGate() {
        state.withLock { $0.confirmed = true }
    }

    /// Records the operator's choice. An interactive choice made in the Console UI is confirmed immediately.
    public func setCeremonyRequired(_ required: Bool, confirmed: Bool = true) {
        state.withLock {
            $0.ceremonyRequired = required
            $0.confirmed = confirmed
        }
        store.setBool(required, forKey: Self.preferenceKey)
    }

    /// Durably persists the gate to the configured PreferencesStore.
    public func persist(environment _: [String: String] = ProcessInfo.processInfo.environment) throws {
        let required = state.withLock { $0.ceremonyRequired }
        store.setBool(required, forKey: Self.preferenceKey)
    }

    /// Reads a stored gate from the preferences store.
    public static func loadStoredGate(
        store: any PreferencesStore = UserDefaultsPreferencesStore(),
        environment _: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Bool {
        store.bool(forKey: preferenceKey) ?? true
    }
}
