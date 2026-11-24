import Testing
import Foundation
@testable import MeterCore

struct AntigravityUsageTests {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func decodesAgyPrintUsageCommandGroupsEnvelope() throws {
        let json = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "response": "Gemini Models\\tWeekly Limit Remaining\\t97%",
          "duration_seconds": 0,
          "num_turns": 0,
          "usage": {
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0
          },
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Shared Gemini pool",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.9718,
                      "reset_time": "2026-11-30T06:47:24Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.9012,
                      "reset_time": "2026-11-23T11:47:24Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "description": "Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-30T07:20:11Z"
                    },
                    {
                      "id": "3p-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-23T12:20:11Z"
                    }
                  ]
                },
                {
                  "name": "Gemini 4 Argon",
                  "buckets": [
                    {
                      "id": "gemini-argon-wtu-weekly",
                      "name": "Gemini 4 Argon Weekly Limit",
                      "window": "weekly",
                      "remaining_fraction": 1,
                      "reset_time": "2026-11-30T07:20:11Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let parsed = try AntigravityUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.groups.count == 3)
        #expect(parsed.lowestRemaining == 90)

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.serviceID == .antigravity)
        #expect(snapshot.headline?.remainingPercent == 90)
        #expect(snapshot.sections.map(\.title) == ["Gemini Models", "Claude & GPT", "Gemini 4 Argon"])
        // Primary group is expanded; secondary groups are collapsible and collapsed by default
        #expect(!snapshot.sections[0].isCollapsible)
        #expect(snapshot.sections[0].isExpandedByDefault)
        #expect(snapshot.sections[1].isCollapsible)
        #expect(!snapshot.sections[1].isExpandedByDefault)
        #expect(snapshot.sections[1].summaryPercent == 100)
        #expect(snapshot.sections[1].detailText == "Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B")
        #expect(snapshot.sections[2].isCollapsible)
        #expect(!snapshot.sections[2].isExpandedByDefault)
        // Inside each group, 5-hour is ordered before Weekly
        #expect(snapshot.sections[0].items.map(\.title) == ["5-hour", "Weekly"])
        #expect(snapshot.sections[0].items.map(\.remainingPercent) == [90, 97])
        #expect(snapshot.sections[1].items.map(\.title) == ["5-hour", "Weekly"])
        #expect(snapshot.sections[2].items.map(\.title) == ["Weekly"])
        #expect(snapshot.badges.isEmpty)
    }

    @Test func decodesStatusLineQuotaMapAndExcludesDisabledFromHeadline() throws {
        let json = """
        {
          "plan": "Google AI Pro",
          "ai_credits": 120,
          "quota": {
            "gemini-5h": {
              "remaining_fraction": 0.90,
              "reset_in_seconds": 3600,
              "disabled": false
            },
            "gemini-weekly": {
              "remaining_fraction": 0.725,
              "disabled": false
            },
            "3p-5h": {
              "remaining_fraction": 0.10,
              "disabled": true
            }
          }
        }
        """
        let parsed = try AntigravityUsage.decode(Data(json.utf8), now: origin)
        #expect(parsed.planLabel == "Google AI Pro")
        #expect(parsed.aiCredits == "120")
        #expect(parsed.models.count == 3)
        // Disabled 10% bucket must not drag down lowest remaining %
        #expect(parsed.lowestRemaining == 72)

        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.serviceID == .antigravity)
        #expect(snapshot.collapsibleSectionTitle == "Other models")
        #expect(snapshot.accountSubtitle == "Google AI Pro")
        #expect(snapshot.planName == "Pro")
        #expect(snapshot.headline?.remainingPercent == 90)
        #expect(snapshot.headline?.nearestResetAt == origin.addingTimeInterval(3600))
        #expect(snapshot.sections.count == 2)
        #expect(snapshot.sections[0].title == "Gemini")
        #expect(snapshot.sections[0].items.map(\.title) == ["5-hour", "Weekly"])
        #expect(snapshot.sections[1].title == "Claude / GPT")
        // gemini-weekly has no reset timestamp -> ResetDisplayPolicy.none (no fake reset text!)
        #expect(snapshot.sections[0].items[1].resetPolicy == .none)
        #expect(snapshot.sections[0].items[1].resetPolicy.formattedText(now: origin) == nil)
        #expect(snapshot.sections[1].items[0].isDisabled)
        // Only AI Credits badge — never Codex's reset credits badge
        #expect(snapshot.badges.map(\.text) == ["AI Credits 120"])
    }

    @Test func decodesPerModelListWithoutResets() throws {
        let json = """
        {
          "result": {
            "plan_name": "Google AI Ultra",
            "models": [
              { "id": "gemini-3-pro", "display_name": "Gemini 3 Pro", "remaining_fraction": 0.84 },
              { "id": "gemini-3-flash", "display_name": "Gemini 3 Flash", "remaining_percent": 96 },
              { "id": "claude-sonnet", "display_name": "Claude Sonnet", "used_percent": 40 }
            ]
          }
        }
        """
        let parsed = try AntigravityUsage.decode(Data(json.utf8), now: origin)
        let snapshot = parsed.toSnapshot(fetchedAt: origin)
        #expect(snapshot.accountSubtitle == "Google AI Ultra")
        #expect(snapshot.planName == "Ultra")
        #expect(snapshot.headline?.remainingPercent == 84)
        #expect(snapshot.headline?.nearestResetAt == nil)
        #expect(snapshot.headline?.detailText(now: origin) == nil)
        #expect(snapshot.sections[0].items.map(\.title) == ["Gemini 3 Pro", "Gemini 3 Flash", "Claude Sonnet"])
        #expect(snapshot.sections[0].items.map(\.remainingPercent) == [84, 96, 60])
        let allResetNone = snapshot.sections[0].items.allSatisfy { $0.resetPolicy == .none }
        #expect(allResetNone)
        #expect(snapshot.badges.isEmpty)
    }

    @Test func unwrapsANSIAndLeadingPreambleAroundJSON() throws {
        let raw = "\u{001B}[32mChecking quota...\u{001B}[0m\n{\"quota\":{\"gemini-5h\":{\"remaining_fraction\":0.55,\"reset_time\":\"2026-10-06T22:28:10.000Z\"}}}\n"
        let parsed = try AntigravityUsage.decode(Data(raw.utf8), now: origin)
        #expect(parsed.lowestRemaining == 55)
        #expect(parsed.nearestResetAt != nil)
    }

    @Test func decodesFreeWeeklyOnlyAndProto3ZeroExhaustedBucketAndProInference() throws {
        // 1. Antigravity Free tier: weekly-only buckets, plus an exhausted bucket where proto3 omits remaining_fraction: 0.0
        let freeJSON = """
        {
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "reset_time": "2026-11-30T06:47:24Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.45,
                      "reset_time": "2026-11-30T08:00:00Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let freeParsed = try AntigravityUsage.decode(Data(freeJSON.utf8), now: origin)
        #expect(freeParsed.planName == "Free")
        #expect(freeParsed.lowestRemaining == 0)
        let freeSnapshot = freeParsed.toSnapshot(fetchedAt: origin)
        #expect(freeSnapshot.planName == "Free")
        #expect(freeSnapshot.headline?.remainingPercent == 0)
        #expect(freeSnapshot.sections[0].title == "Gemini Models")
        #expect(freeSnapshot.sections[0].items.map(\.remainingPercent) == [0])

        // 2. Paid Pro tier inferred from live Argon Pro description when no explicit plan_name is emitted
        let proJSON = """
        {
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    { "id": "gemini-5h", "window": "5h", "remaining_fraction": 0.72, "reset_time": "2026-11-23T11:47:24Z" },
                    { "id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.92, "reset_time": "2026-11-30T06:47:24Z" }
                  ]
                },
                {
                  "name": "Gemini 4 Argon",
                  "description": "For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.",
                  "buckets": [
                    { "id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 1, "reset_time": "2026-11-30T08:41:24Z" }
                  ]
                }
              ]
            }
          }
        }
        """
        let proSnapshot = try AntigravityUsage.decode(Data(proJSON.utf8), now: origin).toSnapshot(fetchedAt: origin)
        #expect(proSnapshot.planName == "Pro")
    }

    @Test func rejectsUnrecognizedOrMalformedPayloads() {
        for sample in ["not json", "{}", "{\"status\":\"ok\"}", "{\"usage\":{\"input_tokens\":0}}"] {
            do {
                _ = try AntigravityUsage.decode(Data(sample.utf8), now: origin)
                Issue.record("Expected malformed error for \(sample)")
            } catch {
                #expect((error as? ProviderError)?.category == .parse)
            }
        }
    }
}

struct AntigravityProviderTests {
    @Test @MainActor func fetchesFromAgyCLISuccessfully() async throws {
        let runner = StubCommandRunner { exec, args in
            #expect(exec == "/opt/homebrew/bin/agy")
            #expect(args == ["--print", "/usage", "--output-format", "json", "--print-timeout", "18s"])
            return CommandOutput(
                exitCode: 0,
                stdout: Data(#"{"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.80}]}]}}}"#.utf8)
            )
        }
        let provider = AntigravityProvider(
            locateExecutable: { "/opt/homebrew/bin/agy" },
            locateStatusFile: { nil },
            runner: runner
        )
        #expect(provider.detect() == .detected(source: "/opt/homebrew/bin/agy"))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.serviceID == .antigravity)
        #expect(snapshot.remainingPercent == 80)
    }

    @Test @MainActor func mapsAuthFailureToAuthCategory() async {
        let runner = StubCommandRunner { _, _ in
            CommandOutput(exitCode: 1, stdout: Data(), stderr: Data("Error: authentication required, please login".utf8))
        }
        let provider = AntigravityProvider(
            locateExecutable: { "/opt/homebrew/bin/agy" },
            locateStatusFile: { nil },
            runner: runner
        )
        do {
            _ = try await provider.fetchUsage()
            Issue.record("Expected auth failure")
        } catch {
            let err = error as? ProviderError
            #expect(err?.category == .auth)
            #expect(err?.recovery == .copyLoginCommand("agy"))
        }
    }

    @Test @MainActor func fallsBackToStatusFileWhenCLIAbsentOrUnsupported() async throws {
        let statusJSON = Data(#"{"models":[{"id":"gemini-pro","display_name":"Gemini Pro","remaining_fraction":0.64}]}"#.utf8)
        let providerNoCLI = AntigravityProvider(
            locateExecutable: { nil },
            locateStatusFile: { "/tmp/agy-status.json" },
            readStatusFile: { _ in statusJSON }
        )
        #expect(providerNoCLI.detect() == .detected(source: "/tmp/agy-status.json"))
        let snapshot1 = try await providerNoCLI.fetchUsage()
        #expect(snapshot1.remainingPercent == 64)

        let unsupportedRunner = StubCommandRunner { _, _ in
            CommandOutput(exitCode: 2, stdout: Data(), stderr: Data("unknown flag: --print".utf8))
        }
        let providerFallback = AntigravityProvider(
            locateExecutable: { "/opt/homebrew/bin/agy" },
            locateStatusFile: { "/tmp/agy-status.json" },
            readStatusFile: { _ in statusJSON },
            runner: unsupportedRunner
        )
        let snapshot2 = try await providerFallback.fetchUsage()
        #expect(snapshot2.remainingPercent == 64)
    }

    @Test @MainActor func mapsTimeoutAndMissingExecutable() async {
        let timeoutRunner = StubCommandRunner { _, _ in throw CommandRunnerError.timedOut }
        let timeoutProvider = AntigravityProvider(
            locateExecutable: { "/opt/homebrew/bin/agy" },
            locateStatusFile: { nil },
            runner: timeoutRunner
        )
        do {
            _ = try await timeoutProvider.fetchUsage()
            Issue.record("Expected timeout")
        } catch {
            #expect((error as? ProviderError)?.category == .connection)
        }

        let missingProvider = AntigravityProvider(
            locateExecutable: { nil },
            locateStatusFile: { nil }
        )
        #expect(missingProvider.detect() == .notFound)
        do {
            _ = try await missingProvider.fetchUsage()
            Issue.record("Expected missing executable")
        } catch {
            #expect((error as? ProviderError)?.category == .setup)
        }
    }

    @Test @MainActor func executableLocatorAndRegistryDiscovery() {
        let found = ExecutableLocator.locate(
            name: "agy",
            extraCandidates: ["/custom/bin/agy"],
            environment: ["PATH": "/usr/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/custom/bin/agy" }
        )
        #expect(found == "/custom/bin/agy")

        let codexFound = CodexProvider(locateExecutable: { "/opt/homebrew/bin/codex" })
        let agyMissing = AntigravityProvider(locateExecutable: { nil }, locateStatusFile: { nil })
        let registry = ServiceRegistry(providers: [codexFound, agyMissing])
        #expect(registry.detectAll().count == 2)
        #expect(registry.detectedServices().map(\.id) == [.codex])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTIGRAVITY_METER_LIVE_TEST"] == "1"))
    @MainActor func testLiveAntigravityUsageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ANTIGRAVITY_METER_LIVE_TEST"] == "1" else { return }
        let provider = AntigravityProvider()
        #expect(provider.detect().isDetected)
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.serviceID == .antigravity)
        #expect(!snapshot.sections.isEmpty)
        let allHaveItems = snapshot.sections.allSatisfy { !$0.items.isEmpty }
        #expect(allHaveItems)
        #expect(snapshot.remainingPercent != nil)
    }
}
