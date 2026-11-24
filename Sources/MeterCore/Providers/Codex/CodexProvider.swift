import Foundation

public extension ServiceID {
    static let codex = ServiceID("codex")
}

public extension ServiceDescriptor {
    static let codex = ServiceDescriptor(
        id: .codex,
        name: "Codex",
        shortName: "Codex",
        defaultSubtitle: "ChatGPT allowance",
        docsURL: URL(string: "https://developers.openai.com/codex/cli")!,
        loginCommand: "codex login",
        executableName: "codex",
        headlinePolicy: .windows(preferredGroup: "codex-core"),
        requirementLabel: "Codex CLI"
    )
}

/// OpenAI Codex provider backed by persistent JSON-RPC over `codex app-server`.
@MainActor public final class CodexProvider: UsageProvider {
    public let descriptor = ServiceDescriptor.codex
    public let configSpec = ProviderConfigSpec(executablePathKey: "codexPath")

    private let locateExecutable: @MainActor () -> String?
    private let makeClient: @MainActor () -> CodexRPCClient
    private var client: CodexRPCClient?

    public init(
        configStore: any ProviderConfigStore = UserDefaultsConfigStore(),
        locateExecutable: (@MainActor () -> String?)? = nil,
        makeClient: (@MainActor () -> CodexRPCClient)? = nil
    ) {
        let key = "codexPath"
        let locator: @MainActor () -> String? = locateExecutable ?? {
            ExecutableLocator.locate(
                name: ServiceDescriptor.codex.executableName,
                custom: configStore.string(forKey: key)
            )
        }
        self.locateExecutable = locator
        self.makeClient = makeClient ?? {
            CodexRPCClient(descriptor: .codex) {
                guard let executable = locator() else {
                    throw ProviderError.missingExecutable(
                        serviceName: ServiceDescriptor.codex.name,
                        executableName: ServiceDescriptor.codex.executableName
                    )
                }
                return ProcessTransport(executable: executable, arguments: ["app-server"])
            }
        }
    }

    public func detect() -> DetectionStatus {
        guard let path = locateExecutable() else { return .notFound }
        return .detected(source: path)
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        if client == nil {
            client = makeClient()
        }
        guard let client else {
            throw ProviderError.disconnected(serviceName: descriptor.name)
        }
        let usage = try await client.readUsage()
        return usage.toSnapshot()
    }

    public func shutdown() {
        client?.shutdown()
        client = nil
    }

    public func resetClient() {
        shutdown()
    }
}
