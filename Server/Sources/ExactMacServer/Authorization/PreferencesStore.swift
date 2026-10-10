import Foundation
import Synchronization

/// Abstract protocol for operator preference storage.
///
/// In production, preferences are stored in the user defaults suite `com.exactmac.console`.
/// In tests, preferences are stored in an in-memory dictionary to prevent side effects.
public protocol PreferencesStore: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool?
    func setBool(_ value: Bool?, forKey key: String)
}

/// Production implementation backed by `UserDefaults` with suite name `com.exactmac.console`.
public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    public static let suiteName = "com.exactmac.console"
    private let defaults: UserDefaults

    public init(suiteName: String = UserDefaultsPreferencesStore.suiteName) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func bool(forKey key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    public func setBool(_ value: Bool?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory preference storage for unit and integration testing.
public final class InMemoryPreferencesStore: PreferencesStore, Sendable {
    private let stringStorage: Mutex<[String: String]>
    private let boolStorage: Mutex<[String: Bool]>

    public init(strings: [String: String] = [:], bools: [String: Bool] = [:]) {
        self.stringStorage = Mutex<[String: String]>(strings)
        self.boolStorage = Mutex<[String: Bool]>(bools)
    }

    public func string(forKey key: String) -> String? {
        stringStorage.withLock { $0[key] }
    }

    public func setString(_ value: String?, forKey key: String) {
        stringStorage.withLock {
            if let value {
                $0[key] = value
            } else {
                $0.removeValue(forKey: key)
            }
        }
    }

    public func bool(forKey key: String) -> Bool? {
        boolStorage.withLock { $0[key] }
    }

    public func setBool(_ value: Bool?, forKey key: String) {
        boolStorage.withLock {
            if let value {
                $0[key] = value
            } else {
                $0.removeValue(forKey: key)
            }
        }
    }
}
