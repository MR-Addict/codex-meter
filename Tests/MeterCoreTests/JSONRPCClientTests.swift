import Foundation
import Testing
@testable import MeterCore

struct JSONRPCClientTests {
    @Test @MainActor func handlesFragmentedFramesHandshakeAndReuse() async throws {
        let pipe = FakeRPCTransport()
        pipe.response = { method, id in
            switch method {
            case "hello": return ["id": id, "result": ["ok": true]]
            case "echo": return ["id": id, "result": ["value": 42]]
            default: return ["id": id, "result": [:]]
            }
        }
        let client = JSONRPCClient { pipe }
        defer { client.shutdown() }

        try await client.connect { rpc in
            _ = try await rpc.request("hello", params: [:])
            try rpc.notify("ready", params: [:])
        }
        let first = try await client.request("echo", params: [:])
        let parsed = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        #expect((parsed?["value"] as? Int) == 42)

        // Second connect is a no-op once ready.
        try await client.connect { _ in Issue.record("Handshake should not rerun while connected") }
        #expect(pipe.methods == ["hello", "ready", "echo"])
    }

    @Test @MainActor func surfacesRemoteErrorsAndMalformedLines() async throws {
        let pipe = FakeRPCTransport()
        pipe.response = { _, id in
            ["id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
        let client = JSONRPCClient { pipe }
        defer { client.shutdown() }

        try await client.connect()
        do {
            _ = try await client.request("unknown")
            Issue.record("Expected remote RPC error")
        } catch let error as JSONRPCError {
            #expect(error == .remote(code: -32601, message: "Method not found"))
        }

        let badPipe = FakeRPCTransport()
        badPipe.response = { [weak badPipe] _, _ in
            badPipe?.onData?(Data("not-json\n".utf8))
            return nil
        }
        let badClient = JSONRPCClient { badPipe }
        try await badClient.connect()
        do {
            _ = try await badClient.request("ping")
            Issue.record("Expected malformed error")
        } catch let error as JSONRPCError {
            #expect(error == .malformed)
        }
        #expect(badPipe.stopped)
    }

    @Test @MainActor func timeoutAndShutdownCancelPendingRequests() async throws {
        let slowPipe = FakeRPCTransport()
        slowPipe.response = { _, _ in nil }
        let slowClient = JSONRPCClient(timeout: 0.02) { slowPipe }
        try await slowClient.connect()
        do {
            _ = try await slowClient.request("hang")
            Issue.record("Expected timeout")
        } catch let error as JSONRPCError {
            #expect(error == .timeout)
        }
        #expect(slowPipe.stopped)

        let shutdownPipe = FakeRPCTransport()
        shutdownPipe.response = { _, _ in nil }
        let shutdownClient = JSONRPCClient(timeout: 5) { shutdownPipe }
        try await shutdownClient.connect()
        let task = Task { try await shutdownClient.request("wait") }
        try await waitUntil { !shutdownPipe.methods.isEmpty }
        shutdownClient.shutdown()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(shutdownPipe.stopped)
    }
}
