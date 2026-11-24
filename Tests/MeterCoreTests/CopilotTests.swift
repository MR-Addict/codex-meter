import Testing
import Foundation
@testable import MeterCore

struct CopilotUsageTests {
    let origin = Date(timeIntervalSince1970: 1_764_000_000)

    @Test func decodesProQuotaSnapshotsWithUnlimitedChatAndCompletions() throws {
        let json = """
        {
          "copilot_plan": "individual",
          "quota_reset_date_utc": "2026-12-01T00:00:00.000Z",
          "quota_snapshots": {
            "chat": {
              "entitlement": 0,
              "remaining": 0,
              "percent_remaining": 100.0,
              "unlimited": true,
              "overage_permitted": false
            },
            "completions": {
              "entitlement": 0,
              "remaining": 0,
              "percent_remaining": 100.0,
              "unlimited": true,
              "overage_permitted": false
            },
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 246,
              "percent_remaining": 82.0,
              "unlimited": false,
              "overage_permitted": false,
              "overage_count": 0
            }
          }
        }
        """
        let parsed = try CopilotUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.planLabel == "Copilot Pro")
        #expect(parsed.finiteBuckets.count == 1)
        #expect(parsed.unlimitedBuckets.count == 2)
        #expect(parsed.headlineBucket?.id == "premium_interactions")
        #expect(parsed.headlineBucket?.remainingPercent == 82)

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.serviceID == .copilot)
        #expect(snapshot.accountSubtitle == "Copilot Pro")
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.headline?.title == "Premium requests")
        #expect(snapshot.headline?.remainingPercent == 82)
        #expect(snapshot.headline?.nearestResetAt != nil)

        #expect(snapshot.sections.count == 1)
        #expect(snapshot.sections[0].title == "Monthly allowance")
        #expect(snapshot.sections[0].items.count == 1)
        #expect(snapshot.sections[0].items[0].title == "Premium requests")
        #expect(snapshot.sections[0].items[0].tag == "246 / 300")
        #expect(snapshot.sections[0].items[0].remainingPercent == 82)

        #expect(snapshot.badges.count == 1)
        #expect(snapshot.badges[0].text == "Unlimited Chat & Completions")
    }

    @Test func decodesAICreditsSchemaAndPrioritizesOverOtherBuckets() throws {
        let json = """
        {
          "copilot_plan": "pro_plus",
          "quota_reset_date": "2026-12-01",
          "quota_snapshots": {
            "ai_credits": {
              "entitlement": 1000,
              "remaining": 645.5,
              "percent_remaining": 64.55,
              "unlimited": false,
              "overage_permitted": true,
              "overage_count": 0
            },
            "completions": {
              "unlimited": true
            }
          }
        }
        """
        let parsed = try CopilotUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.planLabel == "Copilot Pro+")
        #expect(parsed.headlineBucket?.id == "ai_credits")
        #expect(parsed.headlineBucket?.remainingPercent == 64)
        #expect(parsed.headlineBucket?.countTag == "645.5 / 1000")

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.headline?.title == "AI credits")
        #expect(snapshot.headline?.remainingPercent == 64)
        #expect(snapshot.headline?.nearestResetAt != nil)
        #expect(snapshot.sections[0].items[0].tag == "645.5 / 1000")
        #expect(snapshot.badges.map(\.text) == ["Unlimited Completions"])
    }

    @Test func decodesFreeLimitedUserQuotasAndSelectsChatForHeadline() throws {
        let json = """
        {
          "copilot_plan": "free",
          "limited_user_reset_date": "2026-12-01",
          "limited_user_quotas": {
            "chat": 15,
            "completions": 1800
          },
          "monthly_quotas": {
            "chat": 50,
            "completions": 2000
          }
        }
        """
        let parsed = try CopilotUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.planLabel == "Copilot Free")
        #expect(parsed.finiteBuckets.count == 2)
        #expect(parsed.headlineBucket?.id == "chat")
        #expect(parsed.headlineBucket?.remainingPercent == 30)

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.accountSubtitle == "Copilot Free")
        #expect(snapshot.planName == "Free")
        #expect(snapshot.headline?.title == "Chat")
        #expect(snapshot.headline?.remainingPercent == 30)
        #expect(snapshot.sections[0].items.map(\.title) == ["Chat", "Completions"])
        #expect(snapshot.sections[0].items.map(\.tag) == ["15 / 50", "1800 / 2000"])
        #expect(snapshot.sections[0].items.map(\.remainingPercent) == [30, 90])
        #expect(snapshot.badges.isEmpty)
    }

    @Test func skipsUngrantedHasQuotaFalseBucketsAndDetectsFreeFromSKU() throws {
        let json = """
        {
          "copilot_plan": "individual",
          "access_type_sku": "free_limited_copilot",
          "quota_reset_date": "2026-12-01",
          "quota_reset_date_utc": "2026-12-01T00:00:00.000Z",
          "quota_snapshots": {
            "chat": {
              "entitlement": 200,
              "remaining": 199,
              "percent_remaining": 99.7,
              "unlimited": false,
              "has_quota": true,
              "overage_permitted": false,
              "overage_count": 0
            },
            "completions": {
              "entitlement": 2000,
              "remaining": 355,
              "percent_remaining": 17.7,
              "unlimited": false,
              "has_quota": true,
              "overage_permitted": false,
              "overage_count": 0
            },
            "premium_interactions": {
              "entitlement": 0,
              "remaining": 0,
              "percent_remaining": 0.0,
              "unlimited": false,
              "has_quota": false,
              "overage_permitted": false,
              "overage_count": 0
            }
          }
        }
        """
        let parsed = try CopilotUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.planLabel == "Copilot Free")
        #expect(parsed.finiteBuckets.map(\.id) == ["chat", "completions"])
        #expect(parsed.headlineBucket?.id == "chat")
        #expect(parsed.headlineBucket?.remainingPercent == 99)

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.accountSubtitle == "Copilot Free")
        #expect(snapshot.planName == "Free")
        #expect(snapshot.headline?.title == "Chat")
        #expect(snapshot.headline?.remainingPercent == 99)
        #expect(snapshot.sections[0].items.map(\.title) == ["Chat", "Completions"])
        #expect(snapshot.sections[0].items.map(\.tag) == ["199 / 200", "355 / 2000"])
        #expect(snapshot.sections[0].items.map(\.remainingPercent) == [99, 17])
    }

    @Test func surfacesOverageBadgeAndHandlesAllUnlimitedPlan() throws {
        let overageJSON = """
        {
          "copilot_plan": "business",
          "quota_reset_date_utc": "2026-12-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 0,
              "percent_remaining": 0.0,
              "unlimited": false,
              "overage_permitted": true,
              "overage_count": 14
            }
          }
        }
        """
        let overageSnapshot = try CopilotUsage.decode(Data(overageJSON.utf8), now: origin).toSnapshot(fetchedAt: origin)
        #expect(overageSnapshot.accountSubtitle == "Copilot Business")
        #expect(overageSnapshot.headline?.remainingPercent == 0)
        #expect(overageSnapshot.badges.map(\.text) == ["Overage 14"])

        let unlimitedJSON = """
        {
          "copilot_plan": "enterprise",
          "quota_snapshots": {
            "chat": { "unlimited": true },
            "completions": { "unlimited": true }
          }
        }
        """
        let unlimitedSnapshot = try CopilotUsage.decode(Data(unlimitedJSON.utf8), now: origin).toSnapshot(fetchedAt: origin)
        #expect(unlimitedSnapshot.accountSubtitle == "Copilot Enterprise")
        #expect(unlimitedSnapshot.headline?.remainingPercent == 100)
        #expect(unlimitedSnapshot.headline?.valueDisplay == "Unlimited")
        #expect(unlimitedSnapshot.sections[0].title == "Included features")
        #expect(unlimitedSnapshot.sections[0].items.map(\.valueDisplay) == ["Unlimited", "Unlimited"])
    }

    @Test func rejectsUnrecognizedOrMalformedPayloads() {
        for bad in ["", "not json", "[]", "{}", #"{"unrelated": 123}"#] {
            do {
                _ = try CopilotUsage.decode(Data(bad.utf8), now: origin)
                Issue.record("Expected malformed error for payload: \(bad)")
            } catch let error as ProviderError {
                #expect(error.category == .parse)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }
}

struct CopilotProviderTests {
    @Test @MainActor func fetchesFromGhCLISuccessfully() async throws {
        let json = """
        {
          "copilot_plan": "individual",
          "quota_reset_date_utc": "2026-12-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 210,
              "percent_remaining": 70.0,
              "unlimited": false
            },
            "chat": { "unlimited": true }
          }
        }
        """
        let runner = StubCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: Data(json.utf8))))
        let provider = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { false },
            hasCopilotFootprint: { true },
            runner: runner
        )

        #expect(provider.detect() == .detected(source: "/opt/homebrew/bin/gh"))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.serviceID == .copilot)
        #expect(snapshot.collapsibleSectionTitle == "Included features")
        #expect(snapshot.remainingPercent == 70)
        #expect(runner.recordedCalls.count == 1)
        #expect(runner.recordedCalls[0].executable == "/opt/homebrew/bin/gh")
        #expect(runner.recordedCalls[0].arguments.prefix(2) == ["api", "/copilot_internal/user"])
    }

    @Test @MainActor func detectionRequiresFootprintUnlessCustomPathSet() {
        let ghOnly = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { false },
            hasCopilotFootprint: { false },
            runner: StubCommandRunner(result: .failure(CommandRunnerError.launchFailed))
        )
        #expect(ghOnly.detect() == .notFound)

        let customEnabled = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { true },
            hasCopilotFootprint: { false },
            runner: StubCommandRunner(result: .failure(CommandRunnerError.launchFailed))
        )
        #expect(customEnabled.detect() == .detected(source: "/opt/homebrew/bin/gh"))

        #expect(CopilotProvider.defaultCopilotFootprintExists(
            homeDirectory: "/Users/test",
            fileExists: { $0 == "/Users/test/.copilot" },
            contentsOfDirectory: { _ in [] },
            locateCopilotCLI: { nil }
        ))
        #expect(CopilotProvider.defaultCopilotFootprintExists(
            homeDirectory: "/Users/test",
            fileExists: { _ in false },
            contentsOfDirectory: { $0 == "/Users/test/.vscode/extensions" ? ["github.copilot-chat-0.26.0"] : [] },
            locateCopilotCLI: { nil }
        ))
        #expect(!CopilotProvider.defaultCopilotFootprintExists(
            homeDirectory: "/Users/test",
            fileExists: { _ in false },
            contentsOfDirectory: { _ in [] },
            locateCopilotCLI: { nil }
        ))
    }

    @Test @MainActor func mapsAuthAccessTimeoutAndMissingExecutableErrors() async {
        // 1. Not logged in to gh
        let unauthRunner = StubCommandRunner(
            result: .success(CommandOutput(exitCode: 1, stdout: Data(), stderr: Data("To get started with GitHub CLI, please run:  gh auth login".utf8)))
        )
        let unauthProvider = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { true },
            runner: unauthRunner
        )
        do {
            _ = try await unauthProvider.fetchUsage()
            Issue.record("Expected authRequired error")
        } catch let error as ProviderError {
            #expect(error.category == .auth)
            #expect(error.recovery == .copyLoginCommand("gh auth login"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // 2. 403/404 missing Copilot license
        let forbiddenRunner = StubCommandRunner(
            result: .success(CommandOutput(exitCode: 1, stdout: Data(), stderr: Data("gh: This API requires a valid Copilot license (HTTP 403)".utf8)))
        )
        let forbiddenProvider = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { true },
            runner: forbiddenRunner
        )
        do {
            _ = try await forbiddenProvider.fetchUsage()
            Issue.record("Expected auth error for 403")
        } catch let error as ProviderError {
            #expect(error.category == .auth)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // 3. Timeout
        let timeoutProvider = CopilotProvider(
            locateExecutable: { "/opt/homebrew/bin/gh" },
            hasCustomExecutable: { true },
            runner: StubCommandRunner(result: .failure(CommandRunnerError.timedOut))
        )
        do {
            _ = try await timeoutProvider.fetchUsage()
            Issue.record("Expected timeout error")
        } catch let error as ProviderError {
            #expect(error.category == .connection)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // 4. Missing executable
        let missingProvider = CopilotProvider(
            locateExecutable: { nil },
            hasCustomExecutable: { false },
            hasCopilotFootprint: { false },
            runner: StubCommandRunner(result: .failure(CommandRunnerError.launchFailed))
        )
        do {
            _ = try await missingProvider.fetchUsage()
            Issue.record("Expected missingExecutable error")
        } catch let error as ProviderError {
            #expect(error.category == .setup)
            #expect(error.recovery == .locateExecutable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
