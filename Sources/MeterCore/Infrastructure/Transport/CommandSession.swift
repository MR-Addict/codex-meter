import Foundation

/// Cancellable one-shot CLI execution wrapper shared across CLI-backed providers.
@MainActor public final class CommandSession {
    private let runner: any CommandRunning
    private let timeout: TimeInterval
    private var activeTask: Task<CommandOutput, Error>?

    public init(runner: any CommandRunning = ProcessCommandRunner(), timeout: TimeInterval = 20) {
        self.runner = runner
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        activeTask?.cancel()
        let runner = self.runner
        let timeout = self.timeout
        let task = Task<CommandOutput, Error> {
            try await runner.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        activeTask = task
        defer { activeTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// Standard error translation for CLI providers.
    public static func mapError(_ error: Error, serviceName: String) -> Error {
        if let providerError = error as? ProviderError {
            return providerError
        }
        if error is CancellationError {
            return CancellationError()
        }
        if let runnerError = error as? CommandRunnerError {
            switch runnerError {
            case .timedOut:
                return ProviderError.timeout(serviceName: serviceName)
            case .launchFailed:
                return ProviderError.launchFailed(serviceName: serviceName)
            }
        }
        return ProviderError.malformed(serviceName: serviceName)
    }
}
