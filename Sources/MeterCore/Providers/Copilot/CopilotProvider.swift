import Foundation

public extension ServiceID {
    static let copilot = ServiceID("copilot")
}

public extension ServiceDescriptor {
    static let copilot = ServiceDescriptor(
        id: .copilot,
        name: "Copilot",
        shortName: "Copilot",
        defaultSubtitle: "GitHub Copilot quota",
        docsURL: URL(string: "https://cli.github.com")!,
        loginCommand: "gh auth login",
        executableName: "gh",
        headlinePolicy: .allowances(finite: ["ai_credits", "premium_interactions"], fallback: "chat"),
        requirementLabel: "GitHub CLI (gh)"
    )
}

/// GitHub Copilot provider backed by the local GitHub CLI (`gh api /copilot_internal/user`).
///
/// Reuses the user's existing `gh auth login` session without storing or reading tokens directly.
@MainActor public final class CopilotProvider: UsageProvider {
    public let descriptor = ServiceDescriptor.copilot
    public let configSpec = ProviderConfigSpec(executablePathKey: "copilotCLIPath")

    private let locateExecutable: @MainActor () -> String?
    private let hasCustomExecutable: @MainActor () -> Bool
    private let hasCopilotFootprint: @MainActor () -> Bool
    private let session: CommandSession
    private let now: () -> Date

    public init(
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        locateExecutable: (@MainActor () -> String?)? = nil,
        hasCustomExecutable: (@MainActor () -> Bool)? = nil,
        hasCopilotFootprint: (@MainActor () -> Bool)? = nil,
        runner: any CommandRunning = ProcessCommandRunner(),
        timeout: TimeInterval = 20,
        now: @escaping () -> Date = Date.init
    ) {
        let key = "copilotCLIPath"
        self.locateExecutable = locateExecutable ?? {
            ExecutableLocator.locate(
                name: ServiceDescriptor.copilot.executableName,
                custom: configStore.string(forKey: key)
            )
        }
        self.hasCustomExecutable = hasCustomExecutable ?? {
            let custom = configStore.string(forKey: key) ?? ""
            return !custom.isEmpty
        }
        self.hasCopilotFootprint = hasCopilotFootprint ?? {
            Self.defaultCopilotFootprintExists()
        }
        self.session = CommandSession(runner: runner, timeout: timeout)
        self.now = now
    }

    public func detect() -> DetectionStatus {
        guard let executable = locateExecutable() else {
            return .notFound
        }
        // When the user explicitly chose a CLI path in Settings, honor it directly;
        // otherwise require at least one local Copilot footprint so `gh`-only machines
        // don't surface an unwanted Copilot tab.
        if hasCustomExecutable() || hasCopilotFootprint() {
            return .detected(source: executable)
        }
        return .notFound
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        try Task.checkCancellation()

        guard let executable = locateExecutable() else {
            throw ProviderError.missingExecutable(
                serviceName: descriptor.name,
                executableName: descriptor.executableName
            )
        }

        do {
            let output = try await session.run(
                executable: executable,
                arguments: [
                    "api",
                    "/copilot_internal/user",
                    "-H", "Accept: application/json",
                    "-H", "X-GitHub-Api-Version: 2025-04-01",
                ]
            )
            if output.exitCode == 0 {
                let parsed = try CopilotUsage.decode(output.stdout, now: now())
                return parsed.toSnapshot(fetchedAt: now())
            }
            let combined = (output.stderrString + "\n" + output.stdoutString).lowercased()
            if isAuthFailure(combined) {
                throw ProviderError.authRequired(
                    serviceName: descriptor.name,
                    command: descriptor.loginCommand,
                    detail: "Sign in using ‘gh auth login’ in Terminal, then refresh."
                )
            }
            if isAccessOrSubscriptionFailure(combined) {
                throw ProviderError.authRequired(
                    serviceName: descriptor.name,
                    command: descriptor.loginCommand,
                    detail: "GitHub denied access to Copilot quota. Check your Copilot plan or run ‘gh auth login’, then refresh."
                )
            }
            if isNetworkFailure(combined) {
                throw ProviderError.serviceUnavailable(
                    serviceName: descriptor.name,
                    detail: "Could not reach GitHub API. Check your connection and refresh."
                )
            }
            throw ProviderError.serviceUnavailable(serviceName: descriptor.name)
        } catch {
            throw CommandSession.mapError(error, serviceName: descriptor.name)
        }
    }

    public func shutdown() {
        session.cancel()
    }

    public func resetClient() {
        shutdown()
    }

    // MARK: - Helpers

    private func isAuthFailure(_ text: String) -> Bool {
        text.contains("not logged into")
            || text.contains("gh auth login")
            || text.contains("http 401")
            || text.contains("bad credentials")
            || text.contains("requires authentication")
            || text.contains("unauthenticated")
            || text.contains("unauthorized")
    }

    private func isAccessOrSubscriptionFailure(_ text: String) -> Bool {
        text.contains("http 403")
            || text.contains("http 404")
            || text.contains("copilot license")
            || text.contains("not have access to copilot")
            || text.contains("forbidden")
            || text.contains("not found")
    }

    private func isNetworkFailure(_ text: String) -> Bool {
        text.contains("dial tcp")
            || text.contains("no such host")
            || text.contains("connection refused")
            || text.contains("network is unreachable")
            || text.contains("tls")
            || text.contains("http 5")
    }

    /// Lightweight synchronous check for local GitHub Copilot installations (CLI or IDE extensions).
    public static func defaultCopilotFootprintExists(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        contentsOfDirectory: (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        },
        locateCopilotCLI: () -> String? = { ExecutableLocator.locate(name: "copilot") }
    ) -> Bool {
        if locateCopilotCLI() != nil {
            return true
        }

        let directPaths = [
            "\(homeDirectory)/.copilot",
            "\(homeDirectory)/.config/github-copilot",
            "\(homeDirectory)/Library/Application Support/GitHub Copilot",
        ]
        if directPaths.contains(where: fileExists) {
            return true
        }

        let extensionDirs = [
            "\(homeDirectory)/.vscode/extensions",
            "\(homeDirectory)/.vscode-insiders/extensions",
            "\(homeDirectory)/.cursor/extensions",
        ]
        for dir in extensionDirs {
            let entries = contentsOfDirectory(dir)
            if entries.contains(where: { $0.lowercased().hasPrefix("github.copilot") }) {
                return true
            }
        }

        return false
    }
}
