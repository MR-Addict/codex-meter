import Foundation

/// Google Antigravity provider using the documented `agy` CLI headless JSON command,
/// with optional `statusLine` JSON cache file fallback.
@MainActor public final class AntigravityProvider: UsageProvider {
    public let descriptor = ServiceDescriptor.antigravity
    public let configKeys = ProviderConfigKeys(
        executablePathKey: "antigravityCLIPath",
        statusFilePathKey: "antigravityStatusFilePath"
    )

    public static let defaultStatusFileRelativePath = ".gemini/antigravity-cli/meter-status.json"

    private let locateExecutable: @MainActor () -> String?
    private let locateStatusFile: @MainActor () -> String?
    private let readStatusFile: (String) throws -> Data
    private let runner: any CommandRunning
    private let timeout: TimeInterval
    private let now: () -> Date
    private var activeTask: Task<CommandOutput, Error>?

    public init(
        locateExecutable: (@MainActor () -> String?)? = nil,
        locateStatusFile: (@MainActor () -> String?)? = nil,
        readStatusFile: ((String) throws -> Data)? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        timeout: TimeInterval = 20,
        now: @escaping () -> Date = Date.init
    ) {
        self.locateExecutable = locateExecutable ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ExecutableLocator.locate(
                name: "agy",
                custom: UserDefaults.standard.string(forKey: "antigravityCLIPath"),
                extraCandidates: [
                    "\(home)/.antigravity/bin/agy",
                    "\(home)/.gemini/antigravity/bin/agy",
                ]
            )
        }
        self.locateStatusFile = locateStatusFile ?? {
            if let custom = UserDefaults.standard.string(forKey: "antigravityStatusFilePath"), !custom.isEmpty {
                let expanded = (custom as NSString).expandingTildeInPath
                return FileManager.default.isReadableFile(atPath: expanded) ? expanded : nil
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let fallback = "\(home)/\(AntigravityProvider.defaultStatusFileRelativePath)"
            return FileManager.default.isReadableFile(atPath: fallback) ? fallback : nil
        }
        self.readStatusFile = readStatusFile ?? { path in
            try Data(contentsOf: URL(fileURLWithPath: path))
        }
        self.runner = runner
        self.timeout = timeout
        self.now = now
    }

    public func detect() -> DetectionStatus {
        if let executable = locateExecutable() {
            return .detected(source: executable)
        }
        if let statusFile = locateStatusFile() {
            return .detected(source: statusFile)
        }
        return .notFound
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()

        if let executable = locateExecutable() {
            do {
                let output = try await runCommand(executable: executable)
                if output.exitCode == 0 {
                    let parsed = try AntigravityUsage.decode(output.stdout, now: now())
                    return parsed.toSnapshot(fetchedAt: now())
                }
                let combined = (output.stderrString + "\n" + output.stdoutString).lowercased()
                if isAuthFailure(combined) {
                    throw ProviderError.authRequired(
                        serviceName: descriptor.name,
                        command: descriptor.loginCommand,
                        detail: "Sign in by running ‘agy’ in Terminal, then refresh."
                    )
                }
                if isUnsupportedFlag(combined) {
                    if let fallback = try? readStatusFileSnapshot() {
                        return fallback
                    }
                    throw ProviderError.unsupported(
                        serviceName: descriptor.name,
                        detail: "Update Antigravity CLI (`agy`) or configure a statusLine JSON file in Settings."
                    )
                }
                if let fallback = try? readStatusFileSnapshot() {
                    return fallback
                }
                throw ProviderError.serviceUnavailable(serviceName: descriptor.name)
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let runnerError as CommandRunnerError {
                switch runnerError {
                case .timedOut:
                    throw ProviderError.timeout(serviceName: descriptor.name)
                case .launchFailed:
                    throw ProviderError.launchFailed(serviceName: descriptor.name)
                }
            } catch {
                throw ProviderError.malformed(serviceName: descriptor.name)
            }
        }

        if let fallback = try readStatusFileSnapshot() {
            return fallback
        }

        throw ProviderError.missingExecutable(
            serviceName: descriptor.name,
            executableName: descriptor.executableName
        )
    }

    public func shutdown() {
        activeTask?.cancel()
        activeTask = nil
    }

    public func resetClient() {
        shutdown()
    }

    // MARK: - Helpers

    private func runCommand(executable: String) async throws -> CommandOutput {
        activeTask?.cancel()
        let runner = self.runner
        let timeout = self.timeout
        let task = Task<CommandOutput, Error> {
            try await runner.run(
                executable: executable,
                arguments: ["--print", "/usage", "--output-format", "json", "--print-timeout", "18s"],
                timeout: timeout
            )
        }
        activeTask = task
        defer { activeTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func readStatusFileSnapshot() throws -> UsageSnapshot? {
        guard let statusFile = locateStatusFile() else { return nil }
        let data: Data
        do {
            data = try readStatusFile(statusFile)
        } catch {
            throw ProviderError.serviceUnavailable(
                serviceName: descriptor.name,
                detail: "Could not read the Antigravity status JSON file."
            )
        }
        let parsed = try AntigravityUsage.decode(data, now: now())
        return parsed.toSnapshot(fetchedAt: now())
    }

    private func isAuthFailure(_ text: String) -> Bool {
        text.contains("auth") || text.contains("login") || text.contains("sign in")
            || text.contains("unauthenticated") || text.contains("unauthorized")
            || text.contains("credentials")
    }

    private func isUnsupportedFlag(_ text: String) -> Bool {
        text.contains("unknown flag") || text.contains("unknown option")
            || text.contains("unrecognized") || text.contains("invalid option")
    }
}
