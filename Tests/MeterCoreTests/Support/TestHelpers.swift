import Foundation
import Testing
@testable import MeterCore

struct WaitTimeout: Error {}

@MainActor func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw WaitTimeout()
}

final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    let handler: @Sendable (String, [String]) async throws -> CommandOutput
    private let lock = NSLock()
    private var _recordedCalls: [(executable: String, arguments: [String])] = []

    var recordedCalls: [(executable: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedCalls
    }

    init(handler: @escaping @Sendable (String, [String]) async throws -> CommandOutput) {
        self.handler = handler
    }

    convenience init(result: Result<CommandOutput, Error>) {
        self.init { _, _ in try result.get() }
    }

    private func recordCall(executable: String, arguments: [String]) {
        lock.withLock {
            _recordedCalls.append((executable, arguments))
        }
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        recordCall(executable: executable, arguments: arguments)
        return try await handler(executable, arguments)
    }
}

@MainActor final class FakeRPCTransport: RPCTransport {
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?
    var methods: [String] = []
    var stopped = false
    var response: ((String, Int) -> [String: Any]?)?

    func start() throws {}
    func stop() { stopped = true }

    func write(_ data: Data) throws {
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let method = message["method"] as! String
        methods.append(method)
        guard let id = message["id"] as? Int else { return }
        let reply: [String: Any]?
        if let response {
            reply = response(method, id)
        } else {
            let result: [String: Any]
            switch method {
            case "account/read": result = ["account": ["type": "chatgpt"]]
            case "account/rateLimits/read": result = ["rateLimits": ["primary": ["usedPercent": 25]]]
            default: result = [:]
            }
            reply = ["id": id, "result": result]
        }
        guard let reply else { return }
        // Notifications and unmatched responses must not complete a request.
        onData?(Data("{\"method\":\"unrelated\"}\n{\"id\":9999,\"result\":{}}\n".utf8))
        var encoded = try JSONSerialization.data(withJSONObject: reply)
        encoded.append(10)
        let midpoint = encoded.count / 2
        onData?(Data(encoded.prefix(midpoint)))
        onData?(Data(encoded.dropFirst(midpoint)))
    }
}

@MainActor final class ControlledTestProvider: UsageProvider {
    let descriptor: ServiceDescriptor
    let configSpec: ProviderConfigSpec
    var detected: Bool
    var fetchCount = 0
    var shutdownCount = 0
    var pendingContinuations: [CheckedContinuation<UsageSnapshot, Error>] = []
    var immediateResult: Result<UsageSnapshot, Error>?

    init(descriptor: ServiceDescriptor, detected: Bool = true) {
        self.descriptor = descriptor
        self.configSpec = ProviderConfigSpec(executablePathKey: "\(descriptor.id.rawValue)Path")
        self.detected = detected
    }

    func detect() -> DetectionStatus {
        detected ? .detected(source: "/mock/\(descriptor.executableName)") : .notFound
    }

    func fetchUsage() async throws -> UsageSnapshot {
        fetchCount += 1
        if let immediateResult {
            return try immediateResult.get()
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingContinuations.append(cont)
        }
    }

    func resolveNext(remaining: Int) {
        guard !pendingContinuations.isEmpty else { return }
        let cont = pendingContinuations.removeFirst()
        let snapshot = UsageSnapshot(
            serviceID: descriptor.id,
            headline: HeadlineMetric(title: "Remaining", remainingPercent: remaining),
            sections: []
        )
        cont.resume(returning: snapshot)
    }

    func failNext(_ error: Error) {
        guard !pendingContinuations.isEmpty else { return }
        let cont = pendingContinuations.removeFirst()
        cont.resume(throwing: error)
    }

    func shutdown() {
        shutdownCount += 1
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    func resetClient() {
        shutdown()
    }
}
