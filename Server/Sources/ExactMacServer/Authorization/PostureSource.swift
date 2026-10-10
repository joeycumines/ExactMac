import Foundation
import Synchronization

/// THE OPERATOR'S STANDING CHOICE, LIVE.
///
/// The posture is enforcement state and is re-derived PER REQUEST — never cached in a
/// decision, because a decision already made must not change when the operator changes
/// their mind.
///
/// THE SOURCE IS A MUTEX-WRAPPED VALUE backed by `PreferencesStore` (`UserDefaults` suite
/// `com.exactmac.console` in production, `InMemoryPreferencesStore` in tests).
///
/// THE ENVIRONMENT OVERRIDE LIVES ABOVE THE STORE: `EXACTMAC_POSTURE`, when set, is an
/// immutable launch override that takes precedence over any stored preference.
///
/// THREAT MODEL DEFENSE (Option 2): Any same-UID process can run `defaults write` to alter
/// preferences. Therefore, an unconfirmed stored non-strict posture (.balanced) at launch
/// defaults to `.strict` in enforcement until interactively confirmed by the operator
/// via Touch ID in the Console UI.
public final class PostureSource: Sendable {
    public static let preferenceKey = "posture"

    private struct State: Sendable {
        var stored: Posture?
        var confirmed: Bool
    }

    private let store: any PreferencesStore
    private let override: Posture?
    private let state: Mutex<State>

    public init(
        override: Posture?,
        store: any PreferencesStore = UserDefaultsPreferencesStore(),
    ) {
        self.override = override
        self.store = store
        let storedValue = store.string(forKey: Self.preferenceKey).flatMap(Posture.init(rawValue:))
        // .strict, .lockedDown, or unset never requires confirmation (they are safe).
        // Non-strict (.balanced) loaded from stored preferences on launch requires Touch ID confirmation.
        let requiresConfirmation = (storedValue == .balanced)
        self.state = Mutex<State>(State(stored: storedValue, confirmed: !requiresConfirmation))
    }

    /// The posture actually in force, evaluated at the moment a decision needs it.
    public var current: Posture {
        if let override {
            return override
        }
        let current = state.withLock { $0 }
        guard current.confirmed else {
            // Unconfirmed non-strict stored preference fails closed to .strict
            return .strict
        }
        return current.stored ?? .strict
    }

    /// Whether the environment override holds.
    public var isOverriddenByEnvironment: Bool {
        override != nil
    }

    /// The operator's stored choice.
    public var storedPreference: Posture? {
        state.withLock { $0.stored }
    }

    /// Whether the stored preference has been confirmed by operator Touch ID.
    public var isConfirmed: Bool {
        state.withLock { $0.confirmed }
    }

    /// Whether Touch ID confirmation is needed to activate a stored non-strict posture.
    public var needsConfirmation: Bool {
        if override != nil {
            return false
        }
        return state.withLock { !$0.confirmed && $0.stored == .balanced }
    }

    /// Confirms the stored posture via interactive Touch ID.
    public func confirmStoredPreference() {
        state.withLock { $0.confirmed = true }
    }

    /// Records the operator's choice. An interactive choice made in the Console UI is confirmed immediately.
    public func setStoredPreference(_ posture: Posture, confirmed: Bool = true) {
        state.withLock {
            $0.stored = posture
            $0.confirmed = confirmed
        }
        store.setString(posture.rawValue, forKey: Self.preferenceKey)
    }

    /// Durably persists the preference to the configured PreferencesStore.
    public func persist(environment _: [String: String] = ProcessInfo.processInfo.environment) throws {
        let posture = state.withLock { $0.stored }
        store.setString(posture?.rawValue, forKey: Self.preferenceKey)
    }

    /// Reads a stored preference from the preferences store.
    public static func loadStoredPreference(
        store: any PreferencesStore = UserDefaultsPreferencesStore(),
        environment _: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Posture? {
        store.string(forKey: preferenceKey).flatMap(Posture.init(rawValue:))
    }
}
