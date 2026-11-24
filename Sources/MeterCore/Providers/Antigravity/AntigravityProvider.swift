import Foundation

public extension ServiceID {
    static let antigravity = ServiceID("antigravity")
}

public extension ServiceDescriptor {
    static let antigravity = ServiceDescriptor(
        id: .antigravity,
        name: "Antigravity",
        shortName: "Antigravity",
        defaultSubtitle: "Google AI quota",
        docsURL: URL(string: "https://antigravity.google/docs/cli/reference")!,
        loginCommand: "agy",
        executableName: "agy",
        headlinePolicy: .windows(preferredGroup: "gemini"),
        requirementLabel: "Antigravity CLI (agy)"
    )
}

/// Google Antigravity provider using the documented `agy` CLI headless JSON command,
/// with optional `statusLine` JSON cache file fallback.
@MainActor public final class AntigravityProvider: UsageProvider {
    public static let defaultStatusFileRelativePath = ".gemini/antigravity-cli/meter-status.json"

    public let descriptor = ServiceDescriptor.antigravity
    public let configSpec = ProviderConfigSpec(
        executablePathKey: "antigravityCLIPath",
        supplementalFile: SupplementalFileConfig(
            defaultsKey: "antigravityStatusFilePath",
            buttonTitle: "Status JSON…",
            clearButtonTitle: "Clear JSON",
            panelTitle: "Choose Antigravity status JSON file",
            defaultRelativeDirectory: ".gemini/antigravity-cli",
            unreadableErrorMessage: "Choose a readable JSON file exported by Antigravity."
        )
    )

    private let locateExecutable: @MainActor () -> String?
    private let locateStatusFile: @MainActor () -> String?
    private let readStatusFile: (String) throws -> Data
    private let readPlan: @Sendable (String) async throws -> String?
    private var planTask: Task<String?, Error>?
    private let session: CommandSession
    private let now: () -> Date

    public init(
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        locateExecutable: (@MainActor () -> String?)? = nil,
        locateStatusFile: (@MainActor () -> String?)? = nil,
        readStatusFile: ((String) throws -> Data)? = nil,
        readPlan: (@Sendable (String) async throws -> String?)? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        timeout: TimeInterval = 20,
        now: @escaping () -> Date = Date.init
    ) {
        let executableKey = "antigravityCLIPath"
        let statusFileKey = "antigravityStatusFilePath"
        self.locateExecutable = locateExecutable ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ExecutableLocator.locate(
                name: ServiceDescriptor.antigravity.executableName,
                custom: configStore.string(forKey: executableKey),
                extraCandidates: [
                    "\(home)/.antigravity/bin/agy",
                    "\(home)/.gemini/antigravity/bin/agy",
                ]
            )
        }
        self.locateStatusFile = locateStatusFile ?? {
            if let custom = configStore.string(forKey: statusFileKey), !custom.isEmpty {
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
        self.readPlan = readPlan ?? { try await AntigravityPlanReader.read(executable: $0) }
        self.session = CommandSession(runner: runner, timeout: timeout)
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
                let output = try await session.run(
                    executable: executable,
                    arguments: ["--print", "/usage", "--output-format", "json", "--print-timeout", "18s"]
                )
                if output.exitCode == 0 {
                    let parsed = try AntigravityUsage.decode(output.stdout, now: now())
                    let tier = parsed.planName == nil ? try await fetchPlan(executable: executable) : nil
                    return parsed.toSnapshot(fetchedAt: now(), statusLinePlan: tier)
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
            } catch {
                throw CommandSession.mapError(error, serviceName: descriptor.name)
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
        planTask?.cancel()
        session.cancel()
    }

    public func resetClient() {
        shutdown()
    }

    // MARK: - Helpers

    private func fetchPlan(executable: String) async throws -> String? {
        try Task.checkCancellation()
        planTask?.cancel()
        let readPlan = self.readPlan
        let task = Task { try await readPlan(executable) }
        planTask = task
        defer { if planTask == task { planTask = nil } }
        return try await withTaskCancellationHandler {
            do {
                return try await task.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Quota is still usable when this CLI version cannot report an account tier.
                return nil
            }
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
