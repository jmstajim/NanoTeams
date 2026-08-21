import XCTest

@testable import NanoTeams

/// Pins the ordering and the exclusion rules of a sweep plan.
///
/// Pure input, pure output — the planner takes rows and returns entries, so every rule below is
/// checkable by handing it two servers.
final class BenchmarkSweepPlanTests: XCTestCase {

    private func server(
        _ provider: LLMProvider,
        url: String? = nil,
        models: [String],
        included: Bool = true
    ) -> BenchmarkSweepServer {
        BenchmarkSweepServer(
            provider: provider,
            baseURLString: url ?? provider.defaultBaseURL,
            isIncluded: included,
            outcome: .answered(models))
    }

    // MARK: - Order

    /// Provider-major and server-consecutive, and that is load-bearing rather than tidy: each run
    /// clears the OTHER servers first, so a plan that alternated would evict and reload a whole
    /// model between every neighbouring pair of measurements.
    ///
    /// RED: sort by model name across the whole plan → the two servers interleave, and a sweep of
    /// 20 models pays 20 cross-server evictions instead of one.
    func testEntries_groupEveryServersModelsTogether() {
        let plan = BenchmarkSweepPlan.entries(from: [
            server(.ollama, models: ["b-ollama", "a-ollama"]),
            server(.lmStudio, models: ["z-lm"]),
        ])

        XCTAssertEqual(plan.map(\.target.provider), [.lmStudio, .ollama, .ollama],
                       "every LM Studio model must precede every Ollama one")
    }

    /// RED: keep the server's own list order → Ollama's `/api/tags` order is not stable across
    /// restarts, so "it slowed down after the third model" stops being checkable between runs.
    func testEntries_sortModelsWithinAServer() {
        let plan = BenchmarkSweepPlan.entries(from: [
            server(.ollama, models: ["llama3.10", "llama3.2", "llama3.9"]),
        ])

        XCTAssertEqual(plan.map(\.target.modelName), ["llama3.2", "llama3.9", "llama3.10"],
                       "localizedStandardCompare orders 10 after 9, not after 1")
    }

    // MARK: - Exclusions

    /// Switching a provider off means it literally.
    ///
    /// RED: filter only at render time → the models still enter the plan and the sweep measures
    /// the provider the user just switched off.
    func testEntries_omitAnExcludedServer() {
        let plan = BenchmarkSweepPlan.entries(from: [
            server(.lmStudio, models: ["a"], included: false),
            server(.ollama, models: ["b"]),
        ])

        XCTAssertEqual(plan.map(\.target.modelName), ["b"])
    }

    /// A server that answered with nothing contributes nothing — but it is not an error, and the
    /// complement below is what keeps it from being treated as one.
    func testEntries_serverWithNoModels_contributesNothing() {
        let plan = BenchmarkSweepPlan.entries(from: [server(.ollama, models: [])])
        XCTAssertTrue(plan.isEmpty)
    }

    /// RED: keep unanswered rows → an address nobody heard from contributes its (empty) model list
    /// and, worse, is counted as a server.
    func testEntries_unscannedServerContributesNothing() {
        let row = BenchmarkSweepServer(
            provider: .ollama, baseURLString: LLMProvider.ollama.defaultBaseURL)
        XCTAssertTrue(BenchmarkSweepPlan.entries(from: [row]).isEmpty)
    }

    /// RED: skip the trim/empty filter → a blank name becomes a target, and the run posts a
    /// request with no model in it.
    func testEntries_dropBlankModelNames() {
        let plan = BenchmarkSweepPlan.entries(from: [server(.ollama, models: ["  ", "real"])])
        XCTAssertEqual(plan.map(\.target.modelName), ["real"])
    }

    /// RED: trust the server's spelling → a model listed twice with different padding becomes two
    /// entries measuring one thing, and they collide on `id` inside `ForEach` (CLAUDE.md #22).
    func testEntries_areUniqueByIdentity() {
        let plan = BenchmarkSweepPlan.entries(from: [server(.ollama, models: ["dup", " dup ", "dup"])])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)
    }

    /// The same model name on two providers is two measurements of two different things — and the
    /// leaderboard already keys on provider, so the plan must not collapse them.
    ///
    /// RED: dedupe on model NAME → whichever provider sorts first silently wins, and the other
    /// provider's copy is never measured.
    func testEntries_sameModelNameOnBothProviders_staysTwoEntries() {
        let plan = BenchmarkSweepPlan.entries(from: [
            server(.lmStudio, models: ["gpt-oss"]),
            server(.ollama, models: ["gpt-oss"]),
        ])

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(Set(plan.map(\.id)).count, 2, "the provider leads the key")
    }

    /// The entry's identity is the leaderboard's group key, so a sweep row and the row it produces
    /// are the same row.
    ///
    /// RED: mint a fresh UUID per entry → the card can no longer point at what a measurement
    /// became, and a second definition of "same model on same server" exists to drift.
    func testEntryID_isTheLeaderboardGroupKey() {
        let entry = BenchmarkSweepPlan.entries(from: [server(.ollama, models: ["qwen3.8"])]).first

        XCTAssertEqual(
            entry?.id,
            BenchmarkLeaderboard.groupKey(
                provider: .ollama,
                baseURLString: LLMProvider.ollama.defaultBaseURL,
                modelName: "qwen3.8"))
    }

    // MARK: - Verified servers

    /// The list handed to the residency pass as `otherServers` — and the whole read-earns-write
    /// rule lives in this function.
    ///
    /// RED: return every row → an address nobody answered from receives unload commands, which is
    /// exactly what `DEBTS.md` D-B1 §2 refused.
    func testVerifiedServers_excludeAnythingThatDidNotAnswer() {
        let silent = BenchmarkSweepServer(
            provider: .lmStudio,
            baseURLString: LLMProvider.lmStudio.defaultBaseURL,
            outcome: .noAnswer(detail: "connection refused"))
        let unknown = BenchmarkSweepServer(
            provider: .ollama, baseURLString: "http://x:11434", outcome: .undetermined)

        XCTAssertTrue(BenchmarkSweepPlan.verifiedServers(from: [silent, unknown]).isEmpty)
    }

    /// A server holding only an embedding model answers `[]` — `fetchModels` filters embedders out
    /// on both providers — while holding real memory. It contributes no targets and must still be
    /// cleared.
    ///
    /// RED: derive verification from "has at least one model" → the server most likely to be
    /// poisoning the numbers is the one server never cleared.
    func testVerifiedServers_includeAServerThatAnsweredWithNoModels() {
        let empty = server(.ollama, models: [])

        XCTAssertEqual(BenchmarkSweepPlan.verifiedServers(from: [empty]).map(\.provider), [.ollama])
    }

    /// RED: ignore `isIncluded` here → switching a provider off stops it being MEASURED but not
    /// being UNLOADED, so the toggle silently keeps half its promise.
    func testVerifiedServers_excludeASwitchedOffServer() {
        let off = server(.ollama, models: ["a"], included: false)

        XCTAssertTrue(BenchmarkSweepPlan.verifiedServers(from: [off]).isEmpty)
    }

    /// RED: drop the normalization → one machine reached under two spellings is cleared twice and
    /// the provenance line claims a machine that does not exist.
    func testVerifiedServers_deduplicateOnTheNormalizedAddress() {
        let a = server(.lmStudio, url: "http://127.0.0.1:1234", models: ["a"])
        let b = server(.ollama, url: "http://127.0.0.1:1234/", models: ["b"])

        XCTAssertEqual(BenchmarkSweepPlan.verifiedServers(from: [a, b]).count, 1)
    }

    // MARK: - Row identity

    /// The row's id is its PROVIDER, not its address: the endpoint field is editable, and an
    /// identity that moved with it would destroy and recreate the row mid-edit, taking that row's
    /// scan result with it.
    /// RED: `var id: String { baseURLString }` → the two ids below stop being equal, which is the
    /// state in which SwiftUI discards the row the user is typing into.
    func testServerID_isTheProviderSoRetypingAnAddressKeepsTheRow() {
        let before = BenchmarkSweepServer(provider: .ollama, baseURLString: "http://box:11434")
        let during = BenchmarkSweepServer(provider: .ollama, baseURLString: "http://bo")

        XCTAssertEqual(before.id, during.id)
        XCTAssertEqual(before.id, LLMProvider.ollama.rawValue)
        XCTAssertNotEqual(
            before.id,
            BenchmarkSweepServer(provider: .lmStudio, baseURLString: "http://box:11434").id,
            "one row per provider — two providers at one address are still two rows")
    }

    /// Two servers of ONE provider still need a total order, and the tiebreak is the normalized
    /// address — so a plan built twice from the same machine measures in the same sequence, which
    /// is what makes "it got slower after the third model" checkable at all.
    /// RED: `return false` from the tiebreak → the two rows compare equal in both directions and
    /// the order stops being total, so the assertion on the leading model's address fails.
    func testEntries_twoServersOfOneProvider_orderByNormalizedAddress() {
        let later = server(.ollama, url: "http://zz:11434", models: ["m"])
        let earlier = server(.ollama, url: "http://aa:11434", models: ["m"])

        let plan = BenchmarkSweepPlan.entries(from: [later, earlier])

        XCTAssertEqual(plan.map(\.target.baseURLString), ["http://aa:11434", "http://zz:11434"])
    }
}
