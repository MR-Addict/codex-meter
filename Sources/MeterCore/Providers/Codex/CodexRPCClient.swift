import Foundation

/// Codex-specific JSON-RPC client layered on top of the generic `JSONRPCClient`.
///
/// Handles the `codex app-server` handshake (`initialize` / `initialized`),
/// ChatGPT account verification, bounded disconnect/timeout retries, and Codex error mapping.
@MainActor public final class CodexRPCClient {
    private let rpc: JSONRPCClient
    private let descriptor: ServiceDescriptor

    public init(
        descriptor: ServiceDescriptor = .codex,
        timeout: TimeInterval = 20,
        factory: @escaping () throws -> RPCTransport
    ) {
        self.descriptor = descriptor
        self.rpc = JSONRPCClient(timeout: timeout, factory: factory)
    }

    public func shutdown() {
        rpc.shutdown()
    }

    public func readUsage() async throws -> CodexUsage {
        for attempt in 0..<3 {
            try rpc.checkActive()
            do {
                try await rpc.connect { client in
                    _ = try await client.request(
                        "initialize",
                        params: [
                            "clientInfo": [
                                "name": AppMetadata.clientName,
                                "title": AppMetadata.displayName,
                                "version": AppMetadata.version,
                            ]
                        ]
                    )
                    try client.notify("initialized", params: [:])
                }
                try rpc.checkActive()

                let accountData = try await rpc.request("account/read", params: ["refreshToken": false])
                let account = try JSONSerialization.jsonObject(with: accountData) as? [String: Any]
                guard let details = account?["account"] as? [String: Any],
                      details["type"] as? String == "chatgpt" else {
                    throw ProviderError.authRequired(
                        serviceName: descriptor.name,
                        command: descriptor.loginCommand,
                        detail: "Sign in using ‘codex login’ in Terminal, then refresh. A ChatGPT login is required."
                    )
                }

                let accountPlanType = details["planType"] as? String
                let rateLimitData = try await rpc.request("account/rateLimits/read", params: [:])
                return try CodexUsage.decode(rateLimitData, fallbackPlanType: accountPlanType)
            } catch let error as JSONRPCError {
                let mapped = mapRPCError(error)
                let shouldRetry = error == .disconnected || error == .timeout
                if shouldRetry {
                    rpc.disconnect(error)
                    if attempt < 2 {
                        try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                        continue
                    }
                }
                throw mapped
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProviderError.malformed(serviceName: descriptor.name)
            }
        }
        throw ProviderError.disconnected(serviceName: descriptor.name)
    }

    private func mapRPCError(_ error: JSONRPCError) -> ProviderError {
        switch error {
        case .launchFailed:
            return ProviderError.launchFailed(serviceName: descriptor.name)
        case .disconnected:
            return ProviderError.disconnected(serviceName: descriptor.name)
        case .timeout:
            return ProviderError.timeout(serviceName: descriptor.name)
        case .malformed:
            return ProviderError.malformed(serviceName: descriptor.name)
        case .remote(let code, let message):
            let lower = message.lowercased()
            if code == -32601 {
                return ProviderError.unsupported(
                    serviceName: descriptor.name,
                    detail: "Update \(descriptor.name) CLI: this version does not support the required account interface."
                )
            }
            if lower.contains("auth") || lower.contains("login") || lower.contains("sign in") {
                return ProviderError.authRequired(
                    serviceName: descriptor.name,
                    command: descriptor.loginCommand,
                    detail: "Sign in using ‘codex login’ in Terminal, then refresh. A ChatGPT login is required."
                )
            }
            if lower.contains("upgrade")
                || lower.contains("not included")
                || lower.contains("subscription")
                || lower.contains("free plan")
                || lower.contains("plan") {
                return ProviderError.serviceUnavailable(
                    serviceName: descriptor.name,
                    detail: "\(descriptor.name) usage is not included in your current ChatGPT plan."
                )
            }
            return ProviderError.serviceUnavailable(serviceName: descriptor.name)
        }
    }
}
