import Foundation
import Combine

/// Per-service snapshot and fetch lifecycle state.
@MainActor public final class ServiceState: ObservableObject {
    public let descriptor: ServiceDescriptor
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var lastSuccess: Date?
    @Published public private(set) var error: String?
    @Published public private(set) var failure: ProviderError?
    @Published public private(set) var refreshing = false
    @Published public private(set) var retryAt: Date?

    public init(descriptor: ServiceDescriptor) {
        self.descriptor = descriptor
    }

    public var isStale: Bool {
        error != nil && snapshot != nil
    }

    public var menuBarValue: String {
        snapshot?.remainingPercent.map { "\($0)%" } ?? "—"
    }

    public var title: String {
        "\(descriptor.name) \(menuBarValue)\(isStale ? " ⚠︎" : "")"
    }

    public func begin() -> Bool {
        guard !refreshing else { return false }
        refreshing = true
        retryAt = nil
        return true
    }

    public func cancelRefresh() {
        refreshing = false
    }

    public func clearRetry() {
        retryAt = nil
    }

    public func succeed(_ value: UsageSnapshot, now: Date = Date()) {
        snapshot = value
        lastSuccess = now
        error = nil
        failure = nil
        retryAt = nil
        refreshing = false
    }

    public func fail(_ failure: Error, retryAt: Date? = nil) {
        self.failure = failure as? ProviderError
        self.error = failure.localizedDescription
        self.retryAt = retryAt
        refreshing = false
    }
}
