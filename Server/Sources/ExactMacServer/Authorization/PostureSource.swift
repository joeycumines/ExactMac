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
    public static let defaultAccessKey = "default_access"
    public static let touchIDRulesKey = "touch_id_rules"
    public static let consentTimeoutSecondsKey = "consent_timeout_seconds"

    private struct State: Sendable {
        var storedPosture: Posture?
        var storedDefaultAccess: DefaultAccessPolicy?
        var storedTouchIDRules: TouchIDRules?
        var storedTimeoutSeconds: Int?
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

        var loadedDefaultAccess: DefaultAccessPolicy?
        if let accessJson = store.string(forKey: Self.defaultAccessKey),
           let data = accessJson.data(using: .utf8) {
            loadedDefaultAccess = try? JSONDecoder().decode(DefaultAccessPolicy.self, from: data)
        }

        var loadedTouchIDRules: TouchIDRules?
        if let rulesJson = store.string(forKey: Self.touchIDRulesKey),
           let data = rulesJson.data(using: .utf8) {
            loadedTouchIDRules = try? JSONDecoder().decode(TouchIDRules.self, from: data)
        }

        let loadedTimeout = store.string(forKey: Self.consentTimeoutSecondsKey).flatMap(Int.init)

        // Non-strict stored posture, wider default access, or disabled biometric rules require confirmation.
        let isDefaultAccessPermissive = loadedDefaultAccess?.isAllowingAll == true
            || (loadedDefaultAccess != nil && loadedDefaultAccess != .standard)
        let isTouchIDRelaxed = loadedTouchIDRules != nil && (
            !loadedTouchIDRules!.scriptsAndTerminal
            || !loadedTouchIDRules!.broadApprovals
            || !loadedTouchIDRules!.unsignedCallers
            || !loadedTouchIDRules!.consoleOpen
        )
        let requiresConfirmation = (storedValue == .balanced) || isDefaultAccessPermissive || isTouchIDRelaxed

        self.state = Mutex<State>(State(
            storedPosture: storedValue,
            storedDefaultAccess: loadedDefaultAccess,
            storedTouchIDRules: loadedTouchIDRules,
            storedTimeoutSeconds: loadedTimeout,
            confirmed: !requiresConfirmation
        ))
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
        return current.storedPosture ?? .strict
    }

    /// Standing default access policy actually in force.
    public var defaultAccess: DefaultAccessPolicy {
        let current = state.withLock { $0 }
        guard current.confirmed else {
            // Unconfirmed permissive settings fail closed to standard defaults
            return .standard
        }
        return current.storedDefaultAccess ?? .standard
    }

    /// Standing Touch ID rules actually in force.
    public var touchIDRules: TouchIDRules {
        let current = state.withLock { $0 }
        guard current.confirmed else {
            // Unconfirmed relaxed rules fail closed to standard rules (all on)
            return .standard
        }
        return current.storedTouchIDRules ?? .standard
    }

    /// Current prompt timeout in seconds.
    public var consentTimeoutSeconds: Int {
        state.withLock { $0.storedTimeoutSeconds } ?? ServerConfig.defaultConsentTimeoutSeconds
    }

    /// Whether the environment override holds.
    public var isOverriddenByEnvironment: Bool {
        override != nil
    }

    /// The operator's stored choice.
    public var storedPreference: Posture? {
        state.withLock { $0.storedPosture }
    }

    /// The operator's stored default access policy.
    public var storedDefaultAccess: DefaultAccessPolicy? {
        state.withLock { $0.storedDefaultAccess }
    }

    /// The operator's stored Touch ID rules.
    public var storedTouchIDRules: TouchIDRules? {
        state.withLock { $0.storedTouchIDRules }
    }

    /// Whether stored preferences have been confirmed by operator Touch ID.
    public var isConfirmed: Bool {
        state.withLock { $0.confirmed }
    }

    /// Whether Touch ID confirmation is needed to activate stored permissive settings.
    public var needsConfirmation: Bool {
        if override != nil {
            return false
        }
        return state.withLock { !$0.confirmed }
    }

    /// Confirms stored preferences via interactive Touch ID.
    public func confirmStoredPreference() {
        state.withLock { $0.confirmed = true }
    }

    /// Records the operator's choice of posture.
    public func setStoredPreference(_ posture: Posture, confirmed: Bool = true) {
        state.withLock {
            $0.storedPosture = posture
            $0.confirmed = confirmed
        }
        store.setString(posture.rawValue, forKey: Self.preferenceKey)
    }

    /// Records the operator's default access policy.
    public func setDefaultAccessPreference(_ policy: DefaultAccessPolicy, confirmed: Bool = true) {
        state.withLock {
            $0.storedDefaultAccess = policy
            $0.confirmed = confirmed
        }
        if let data = try? JSONEncoder().encode(policy), let string = String(data: data, encoding: .utf8) {
            store.setString(string, forKey: Self.defaultAccessKey)
        }
    }

    /// Records the operator's Touch ID rules.
    public func setTouchIDRulesPreference(_ rules: TouchIDRules, confirmed: Bool = true) {
        state.withLock {
            $0.storedTouchIDRules = rules
            $0.confirmed = confirmed
        }
        if let data = try? JSONEncoder().encode(rules), let string = String(data: data, encoding: .utf8) {
            store.setString(string, forKey: Self.touchIDRulesKey)
        }
    }

    /// Records the operator's consent timeout seconds choice.
    public func setConsentTimeoutSecondsPreference(_ seconds: Int) {
        state.withLock {
            $0.storedTimeoutSeconds = seconds
        }
        store.setString(String(seconds), forKey: Self.consentTimeoutSecondsKey)
    }

    /// Resets all settings to factory defaults.
    public func resetToDefaults() {
        state.withLock {
            $0.storedPosture = .balanced
            $0.storedDefaultAccess = .standard
            $0.storedTouchIDRules = .standard
            $0.storedTimeoutSeconds = ServerConfig.defaultConsentTimeoutSeconds
            $0.confirmed = true
        }
        store.setString(Posture.balanced.rawValue, forKey: Self.preferenceKey)
        if let accessData = try? JSONEncoder().encode(DefaultAccessPolicy.standard),
           let accessStr = String(data: accessData, encoding: .utf8) {
            store.setString(accessStr, forKey: Self.defaultAccessKey)
        }
        if let rulesData = try? JSONEncoder().encode(TouchIDRules.standard),
           let rulesStr = String(data: rulesData, encoding: .utf8) {
            store.setString(rulesStr, forKey: Self.touchIDRulesKey)
        }
        store.setString(String(ServerConfig.defaultConsentTimeoutSeconds), forKey: Self.consentTimeoutSecondsKey)
    }

    /// Durably persists the preference to the configured PreferencesStore.
    public func persist(environment _: [String: String] = ProcessInfo.processInfo.environment) throws {
        let current = state.withLock { $0 }
        if let posture = current.storedPosture {
            store.setString(posture.rawValue, forKey: Self.preferenceKey)
        }
        if let access = current.storedDefaultAccess,
           let data = try? JSONEncoder().encode(access),
           let string = String(data: data, encoding: .utf8) {
            store.setString(string, forKey: Self.defaultAccessKey)
        }
        if let rules = current.storedTouchIDRules,
           let data = try? JSONEncoder().encode(rules),
           let string = String(data: data, encoding: .utf8) {
            store.setString(string, forKey: Self.touchIDRulesKey)
        }
        if let timeout = current.storedTimeoutSeconds {
            store.setString(String(timeout), forKey: Self.consentTimeoutSecondsKey)
        }
    }

    /// Reads a stored preference from the preferences store.
    public static func loadStoredPreference(
        store: any PreferencesStore = UserDefaultsPreferencesStore(),
        environment _: [String: String] = ProcessInfo.processInfo.environment,
    ) -> Posture? {
        store.string(forKey: preferenceKey).flatMap(Posture.init(rawValue:))
    }
}
