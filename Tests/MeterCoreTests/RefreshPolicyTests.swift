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
        #expect((1...7).map { RefreshPolicy.retryDelay(error: MeterError.service, failures: $0) }
            == [5, 10, 20, 40, 60, 60, 60])
        #expect(RefreshPolicy.retryDelay(error: MeterError.timeout, failures: Int.max) == 60)
        #expect(RefreshPolicy.retryDelay(error: MeterError.missingCLI, failures: 1) == 60)
        for error in [MeterError.login, .unsupported] {
            #expect(RefreshPolicy.retryDelay(error: error, failures: 1) == 120)
        }
    }
    @Test func dismissalPreferenceAndEscapeWindowScope() {
        for shown in [false, true] {
            for enabled in [false, true] {
                #expect(PanelDismissalPolicy.outsideClick(isShown: shown, enabled: enabled) == (shown && enabled))
                #expect(PanelDismissalPolicy.escape(isShown: shown, isPanelWindow: enabled) == (shown && enabled))
            }
        }
    }
    @Test @MainActor func cancellingRefreshRetainsSnapshotAndPermitsReplacement() throws {
        let state = UsageState()
        let usage = try Usage.decode(Data(#"{"rateLimits":{}}"#.utf8))
        state.succeed(usage, now: origin)
        #expect(state.begin())
        state.cancelRefresh()
        #expect(state.lastSuccess == origin)
        #expect(state.usage != nil)
        #expect(state.begin())
        #expect(!state.begin())
    }
    @Test @MainActor func shutdownWithoutTaskCancellationNeverReconnects() async throws {
        let pipe = FakeTransport()
        pipe.response = { _, _ in nil }
        var starts = 0
        let client = RPCClient(timeout: 1) { starts += 1; return pipe }
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

private struct WaitTimeout: Error {}
@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw WaitTimeout()
}
