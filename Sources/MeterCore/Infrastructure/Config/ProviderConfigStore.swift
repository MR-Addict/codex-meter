import Foundation

/// Thread-safe key-value store shared between `ServiceCoordinator` and all `UsageProvider`s.
public protocol ProviderConfigStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
    func stringArray(forKey key: String) -> [String]?
    func setStringArray(_ value: [String], forKey key: String)
}

/// Production `UserDefaults`-backed configuration store.
public final class UserDefaultsConfigStore: ProviderConfigStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    public func stringArray(forKey key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    public func setStringArray(_ value: [String], forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Deterministic in-memory configuration store ideal for unit tests and previews.
public final class InMemoryConfigStore: ProviderConfigStore, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var stringArrays: [String: [String]] = [:]

    public init(
        strings: [String: String] = [:],
        stringArrays: [String: [String]] = [:]
    ) {
        self.strings = strings
        self.stringArrays = stringArrays
    }

    public func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return strings[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        strings[key] = value
    }

    public func stringArray(forKey key: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return stringArrays[key]
    }

    public func setStringArray(_ value: [String], forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        stringArrays[key] = value
    }
}
