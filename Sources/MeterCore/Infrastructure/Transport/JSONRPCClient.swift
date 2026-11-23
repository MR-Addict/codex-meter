import Foundation

/// Bidirectional byte stream transport for persistent line-delimited JSON-RPC subprocesses.
@MainActor public protocol RPCTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func start() throws
    func write(_ data: Data) throws
    func stop()
}

/// Real macOS `Process`-backed stdio transport for JSON-RPC servers.
@MainActor public final class ProcessTransport: RPCTransport {
    public var onData: ((Data) -> Void)?
    public var onExit: (() -> Void)?
    private let executable: String
    private let arguments: [String]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public func start() throws {
        SubprocessSupport.configure(process, executable: executable, arguments: arguments)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                if data.isEmpty { self?.onExit?() } else { self?.onData?(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.onExit?() }
        }
        try process.run()
    }

    public func write(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        SubprocessSupport.terminate(process)
    }
}

/// Transport-level and protocol-level errors emitted by `JSONRPCClient`.
public enum JSONRPCError: Error, Equatable, Sendable {
    case launchFailed
    case disconnected
    case timeout
    case malformed
    case remote(code: Int?, message: String)
}

/// Provider-agnostic persistent line-delimited JSON-RPC client over `RPCTransport`.
@MainActor public final class JSONRPCClient {
    private let factory: () throws -> RPCTransport
    private let timeout: TimeInterval
    private var transport: RPCTransport?
    private var buffer = Data()
    private var nextID = 0
    private var ready = false
    private var stopped = false
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]

    public init(
        timeout: TimeInterval = 20,
        factory: @escaping () throws -> RPCTransport
    ) {
        self.timeout = timeout
        self.factory = factory
    }

    public func checkActive() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }

    public func shutdown() {
        stopped = true
        disconnect(CancellationError())
    }

    public func disconnect(_ error: Error = JSONRPCError.disconnected) {
        generation = UUID()
        ready = false
        let old = transport
        transport = nil
        old?.onData = nil
        old?.onExit = nil
        old?.stop()
        buffer.removeAll()
        let requests = pending
        pending.removeAll()
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
    }

    public func connect(handshake: (@MainActor (JSONRPCClient) async throws -> Void)? = nil) async throws {
        try checkActive()
        guard !ready else { return }

        let pipe = try factory()
        transport = pipe
        let token = generation
        pipe.onData = { [weak self] data in
            guard let self, self.generation == token else { return }
            self.receive(data)
        }
        pipe.onExit = { [weak self] in
            guard let self, self.generation == token else { return }
            self.disconnect(JSONRPCError.disconnected)
        }

        do {
            try pipe.start()
            if let handshake {
                try await handshake(self)
            }
            ready = true
        } catch is CancellationError {
            disconnect(CancellationError())
            throw CancellationError()
        } catch let error as JSONRPCError {
            disconnect(error)
            throw error
        } catch let error as ProviderError {
            disconnect(error)
            throw error
        } catch {
            disconnect(JSONRPCError.launchFailed)
            throw JSONRPCError.launchFailed
        }
    }

    public func notify(_ method: String, params: [String: Any] = [:]) throws {
        try send(["method": method, "params": params])
    }

    public func request(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        try checkActive()
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self, timeout] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                guard let self else { return }
                self.disconnect(JSONRPCError.timeout)
            }
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                disconnect(error)
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let transport else { throw JSONRPCError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do {
            try transport.write(data)
        } catch {
            throw JSONRPCError.disconnected
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else {
            disconnect(JSONRPCError.malformed)
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                disconnect(JSONRPCError.malformed)
                return
            }
            guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int
                let text = error["message"] as? String ?? ""
                continuation.resume(throwing: JSONRPCError.remote(code: code, message: text))
            } else if let result = message["result"], JSONSerialization.isValidJSONObject(result),
                      let encoded = try? JSONSerialization.data(withJSONObject: result) {
                continuation.resume(returning: encoded)
            } else {
                continuation.resume(throwing: JSONRPCError.malformed)
            }
        }
    }
}
