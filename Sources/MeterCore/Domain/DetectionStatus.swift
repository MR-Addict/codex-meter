import Foundation

/// Outcome of probing the local Mac for a supported AI tool.
public enum DetectionStatus: Equatable, Sendable {
    case detected(source: String)
    case notFound

    public var isDetected: Bool {
        if case .detected = self { return true }
        return false
    }

    public var source: String? {
        if case .detected(let source) = self { return source }
        return nil
    }
}

/// Snapshot of a registered service's descriptor and local detection status.
public struct DetectedService: Identifiable, Equatable, Sendable {
    public let descriptor: ServiceDescriptor
    public let status: DetectionStatus

    public var id: ServiceID { descriptor.id }
    public var isDetected: Bool { status.isDetected }

    public init(descriptor: ServiceDescriptor, status: DetectionStatus) {
        self.descriptor = descriptor
        self.status = status
    }
}
