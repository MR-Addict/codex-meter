import Foundation
import Darwin

/// Captured output from a one-shot CLI invocation.
public struct CommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
}

/// Abstract one-shot subprocess runner so CLI providers are deterministically testable.
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
}

/// Real macOS `Process`-backed runner with timeout, cancellation, and deadlock-free pipe draining.
public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval = 20) async throws -> CommandOutput {
        try Task.checkCancellation()

        final class ExecutionBox: @unchecked Sendable {
            private let lock = NSLock()
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            var stdoutData = Data()
            var stderrData = Data()
            var finished = false
            var continuation: CheckedContinuation<CommandOutput, Error>?

            func appendStdout(_ chunk: Data) {
                lock.lock()
                if stdoutData.count + chunk.count <= 4 * 1024 * 1024 {
                    stdoutData.append(chunk)
                }
                lock.unlock()
            }

            func appendStderr(_ chunk: Data) {
                lock.lock()
                if stderrData.count + chunk.count <= 1 * 1024 * 1024 {
                    stderrData.append(chunk)
                }
                lock.unlock()
            }

            func setContinuation(_ cont: CheckedContinuation<CommandOutput, Error>) {
                lock.lock()
                continuation = cont
                lock.unlock()
            }

            func finish(_ result: Result<CommandOutput, Error>) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                let cont = continuation
                continuation = nil
                lock.unlock()

                if case .failure = result {
                    terminateProcess(process)
                }
                cont?.resume(with: result)
            }

            func buildOutput(exitCode: Int32) -> CommandOutput {
                // Drain any remaining buffered bytes after termination.
                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if !tailOut.isEmpty, stdoutData.count + tailOut.count <= 4 * 1024 * 1024 {
                    stdoutData.append(tailOut)
                }
                if !tailErr.isEmpty, stderrData.count + tailErr.count <= 1 * 1024 * 1024 {
                    stderrData.append(tailErr)
                }
                let out = stdoutData
                let err = stderrData
                lock.unlock()
                return CommandOutput(exitCode: exitCode, stdout: out, stderr: err)
            }
        }

        let box = ExecutionBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = box.stdoutPipe
        process.standardError = box.stderrPipe

        var environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = "\(directory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
                box.finish(.failure(CommandRunnerError.timedOut))
            } catch {}
        }

        return try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)

                box.stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        box.appendStdout(data)
                    }
                }
                box.stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        box.appendStderr(data)
                    }
                }
                process.terminationHandler = { terminated in
                    let output = box.buildOutput(exitCode: terminated.terminationStatus)
                    box.finish(.success(output))
                }

                do {
                    try process.run()
                } catch {
                    box.finish(.failure(CommandRunnerError.launchFailed))
                }
            }
        } onCancel: {
            timeoutTask.cancel()
            box.finish(.failure(CancellationError()))
        }
    }
}

private func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
