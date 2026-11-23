import Foundation

/// OpenAI Codex provider backed by persistent JSON-RPC over `codex app-server`.
@MainActor public final class CodexProvider: UsageProvider {
    public let descriptor = ServiceDescriptor.codex
    public let configKeys = ProviderConfigKeys(executablePathKey: "codexPath")

    private let locateExecutable: @MainActor () -> String?
    private let makeClient: @MainActor () -> RPCClient
    private var client: RPCClient?

    public init(
        locateExecutable: (@MainActor () -> String?)? = nil,
        makeClient: (@MainActor () -> RPCClient)? = nil
    ) {
        let locator: @MainActor () -> String? = locateExecutable ?? {
            ExecutableLocator.locate(
                name: "codex",
                custom: UserDefaults.standard.string(forKey: "codexPath")
            )
        }
        self.locateExecutable = locator
        self.makeClient = makeClient ?? {
            RPCClient(serviceName: ServiceDescriptor.codex.name, loginCommand: ServiceDescriptor.codex.loginCommand) {
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
        let usage = try await client.readCodexUsage()
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
