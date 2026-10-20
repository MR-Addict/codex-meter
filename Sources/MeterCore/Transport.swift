import Foundation
import Darwin

@MainActor public protocol RPCTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func start() throws
    func write(_ data: Data) throws
    func stop()
}

@MainActor public final class ProcessTransport: RPCTransport {
    public var onData: ((Data) -> Void)?
    public var onExit: (() -> Void)?
    private let executable: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    public init(executable: String) { self.executable = executable }
    public func start() throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = "\(directory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                if data.isEmpty { self?.onExit?() } else { self?.onData?(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.onExit?() } }
        try process.run()
    }
    public func write(_ data: Data) throws { try input.fileHandleForWriting.write(contentsOf: data) }
    public func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}

@MainActor public final class RPCClient {
    private let factory: () throws -> RPCTransport
    private let timeout: TimeInterval
    private var transport: RPCTransport?
    private var buffer = Data()
    private var nextID = 0
    private var ready = false
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    public init(timeout: TimeInterval = 20, factory: @escaping () throws -> RPCTransport) {
        self.timeout = timeout; self.factory = factory
    }
    public func shutdown() { disconnect(MeterError.disconnected) }
    private func disconnect(_ error: Error) {
        generation = UUID(); ready = false
        let old = transport; transport = nil
        old?.onData = nil; old?.onExit = nil; old?.stop()
        buffer.removeAll()
        let requests = pending; pending.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        requests.values.forEach { $0.resume(throwing: error) }
    }
    private func connect() async throws {
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
            self.disconnect(MeterError.disconnected)
        }
        do {
            try pipe.start()
            _ = try await request("initialize", params: ["clientInfo": ["name": "codex_meter", "title": "Codex Meter", "version": "0.2.0"]])
            try send(["method": "initialized", "params": [:]])
            ready = true
        } catch let error as MeterError {
            disconnect(error); throw error
        } catch {
            // The executable exists but could not be launched (arch, quarantine,
            // permissions, or a just-removed install).
            disconnect(MeterError.launch); throw MeterError.launch
        }
    }
    public func readUsage() async throws -> Usage {
        for attempt in 0..<3 {
            do {
                try await connect()
                let accountData = try await request("account/read", params: ["refreshToken": false])
                let account = try JSONSerialization.jsonObject(with: accountData) as? [String: Any]
                guard let details = account?["account"] as? [String: Any], details["type"] as? String == "chatgpt" else {
                    throw MeterError.login
                }
                return try Usage.decode(await request("account/rateLimits/read", params: [:]))
            } catch let error as MeterError {
                switch error {
                case .disconnected, .timeout:
                    disconnect(error)
                    if attempt < 2 {
                        try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                        continue
                    }
                default: break
                }
                throw error
            } catch { throw MeterError.malformed }
        }
        throw MeterError.disconnected
    }
    private func send(_ message: [String: Any]) throws {
        guard let transport else { throw MeterError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try transport.write(data) } catch { throw MeterError.disconnected }
    }
    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self, timeout] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                self?.disconnect(MeterError.timeout)
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch { disconnect(error) }
        }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else { disconnect(MeterError.malformed); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                disconnect(MeterError.malformed); return
            }
            guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { continue }
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int
                let text = (error["message"] as? String ?? "").lowercased()
                let failure: MeterError = code == -32601 ? .unsupported :
                    (text.contains("auth") || text.contains("login") || text.contains("sign in") ? .login : .service)
                continuation.resume(throwing: failure)
            } else if let result = message["result"], JSONSerialization.isValidJSONObject(result),
                      let encoded = try? JSONSerialization.data(withJSONObject: result) {
                continuation.resume(returning: encoded)
            } else { continuation.resume(throwing: MeterError.malformed) }
        }
    }
}
