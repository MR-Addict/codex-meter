import Foundation
import Testing
@testable import MeterCore

struct RefreshPolicyTests {
    let origin = Date(timeIntervalSince1970: 1000)

    @Test func cadenceAndClosingUseSnapshotTime() {
        #expect(RefreshPolicy.delay(open: true, lastSuccess: origin, retryAt: nil, now: origin) == 20)
        #expect(RefreshPolicy.delay(open: false, lastSuccess: origin, retryAt: nil, now: origin) == 60)
        #expect(RefreshPolicy.delay(open: false, lastSuccess: origin, retryAt: nil,
                                    now: origin.addingTimeInterval(19)) == 41)
    }

    @Test func overdueAndMissingSnapshotRefreshImmediately() {
        #expect(RefreshPolicy.delay(open: false, lastSuccess: origin, retryAt: nil,
                                    now: origin.addingTimeInterval(70)) == 0)
        #expect(RefreshPolicy.delay(open: false, lastSuccess: nil, retryAt: nil, now: origin) == 0)
    }

    @Test func visibilityNeverPostponesFailureRetry() {
        for open in [false, true] {
            #expect(RefreshPolicy.delay(open: open, lastSuccess: origin,
                retryAt: origin.addingTimeInterval(5), now: origin.addingTimeInterval(2)) == 3)
            #expect(RefreshPolicy.delay(open: open, lastSuccess: nil,
                retryAt: origin, now: origin.addingTimeInterval(1)) == 0)
        }
    }

    @Test func backoffCapsAndSpecialErrors() {
        let connectionErr = ProviderError.serviceUnavailable(serviceName: "Codex")
        #expect((1...7).map { RefreshPolicy.retryDelay(error: connectionErr, failures: $0) }
            == [5, 10, 20, 40, 60, 60, 60])
        #expect(RefreshPolicy.retryDelay(error: ProviderError.timeout(serviceName: "Antigravity"), failures: Int.max) == 60)
        #expect(RefreshPolicy.retryDelay(error: ProviderError.missingExecutable(serviceName: "Codex", executableName: "codex"), failures: 1) == 60)
        for error in [
            ProviderError.authRequired(serviceName: "Codex", command: "codex login"),
            ProviderError.unsupported(serviceName: "Antigravity"),
        ] {
            #expect(RefreshPolicy.retryDelay(error: error, failures: 1) == 120)
        }
    }

    @Test func dismissalOutsideClickAndEscapeWindowScope() {
        for shown in [false, true] {
            for presenting in [false, true] {
                #expect(PanelDismissalPolicy.outsideClick(isShown: shown, isPresentingPanel: presenting) == (shown && !presenting))
            }
            for isPanel in [false, true] {
                #expect(PanelDismissalPolicy.escape(isShown: shown, isPanelWindow: isPanel) == (shown && isPanel))
            }
        }
    }

    @Test @MainActor func cancellingRefreshRetainsSnapshotAndPermitsReplacement() throws {
        let state = ServiceState(descriptor: .codex)
        let snapshot = try CodexUsage.decode(Data(#"{"rateLimits":{}}"#.utf8)).toSnapshot(fetchedAt: origin)
        state.succeed(snapshot, now: origin)
        #expect(state.begin())
        state.cancelRefresh()
        #expect(state.lastSuccess == origin)
        #expect(state.snapshot != nil)
        #expect(state.begin())
        #expect(!state.begin())
    }

    @Test @MainActor func shutdownWithoutTaskCancellationNeverReconnects() async throws {
        let pipe = FakeRPCTransport()
        pipe.response = { _, _ in nil }
        var starts = 0
        let client = CodexRPCClient(timeout: 1) { starts += 1; return pipe }
        let task = Task { try await client.readUsage() }
        try await waitUntil { !(pipe.methods.isEmpty) }
        client.shutdown()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(starts == 1)
        do { _ = try await client.readUsage(); Issue.record("Stopped client must stay stopped") }
        catch { #expect(error is CancellationError) }
        #expect(starts == 1)
    }
}
