import XCTest

@testable import NanoTeams

/// Pins the comparability rules and the ordering. Pure value types throughout, so the suite is
/// not `@MainActor` and never constructs a main-actor class.
final class BenchmarkLeaderboardTests: XCTestCase {

    private let promptVersion = 3

    // MARK: - Aggregation

    /// RED: taking `max` instead of the median crowns whichever run was thermally luckiest —
    /// this model → would read 80 instead of 40.
    func testRanksByMedianAcrossRuns_notByBestRun() throws {
        let (runs, samples) = history([
            (model: "m", rate: 20.0),
            (model: "m", rate: 40.0),
            (model: "m", rate: 80.0),
        ])
        let row = try XCTUnwrap(
            BenchmarkLeaderboard.rows(
                runs: runs, samples: samples, currentPromptVersion: promptVersion
            ).first)
        XCTAssertEqual(try XCTUnwrap(row.generationTokensPerSecond), 40.0, accuracy: 0.001)
    }

    /// RED: computing `best` as the median too → makes the two columns identical, so the second one
    /// carries no information.
    func testBestColumn_isTheMaximum() throws {
        let (runs, samples) = history([
            (model: "m", rate: 20.0),
            (model: "m", rate: 40.0),
            (model: "m", rate: 80.0),
        ])
        let row = try XCTUnwrap(
            BenchmarkLeaderboard.rows(
                runs: runs, samples: samples, currentPromptVersion: promptVersion
            ).first)
        XCTAssertEqual(try XCTUnwrap(row.bestGenerationTokensPerSecond), 80.0, accuracy: 0.001)
    }

    /// RED: counting samples instead of runs → reports 9 where three runs were measured, and the
    /// "median over N runs" reading becomes false.
    func testRunCount_countsRunsNotSamples() throws {
        let (runs, samples) = history([
            (model: "m", rate: 20.0),
            (model: "m", rate: 40.0),
            (model: "m", rate: 80.0),
        ], samplesPerRun: 3)
        let row = try XCTUnwrap(
            BenchmarkLeaderboard.rows(
                runs: runs, samples: samples, currentPromptVersion: promptVersion
            ).first)
        XCTAssertEqual(samples.count, 9)
        XCTAssertEqual(row.runCount, 3)
    }

    /// RED: drop the provider from the group key → the same model measured on two different
    /// engines collapses into one row.
    func testGroupsByProvider() {
        let a = run(model: "qwen", provider: .lmStudio)
        let b = run(model: "qwen", provider: .ollama)
        let samples = measuredSamples(for: a, rate: 40) + measuredSamples(for: b, rate: 60)
        let rows = BenchmarkLeaderboard.rows(
            runs: [a, b], samples: samples, currentPromptVersion: promptVersion)
        XCTAssertEqual(rows.count, 2)
    }

    /// RED: drop the server from the group key → two different machines average into one figure
    /// that describes neither.
    func testGroupsByServer() {
        let a = run(model: "qwen", baseURL: "http://127.0.0.1:1234")
        let b = run(model: "qwen", baseURL: "http://192.168.1.9:1234")
        let samples = measuredSamples(for: a, rate: 40) + measuredSamples(for: b, rate: 90)
        let rows = BenchmarkLeaderboard.rows(
            runs: [a, b], samples: samples, currentPromptVersion: promptVersion)
        XCTAssertEqual(rows.count, 2)
    }

    /// RED: compare raw URL strings instead of normalized ones → one server splits into two rows
    /// on a trailing slash or a capital letter.
    func testServerKeyIsNormalized() {
        let a = run(model: "qwen", baseURL: "http://127.0.0.1:1234")
        let b = run(model: "qwen", baseURL: "HTTP://127.0.0.1:1234/")
        let samples = measuredSamples(for: a, rate: 40) + measuredSamples(for: b, rate: 40)
        let rows = BenchmarkLeaderboard.rows(
            runs: [a, b], samples: samples, currentPromptVersion: promptVersion)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.runCount, 2)
    }

    /// RED: drop the prompt-version filter → numbers measured against different work rank side
    /// by side as if they were comparable.
    func testExcludesOtherPromptVersions() {
        let current = run(model: "m", promptVersion: promptVersion)
        let stale = run(model: "m", promptVersion: promptVersion - 1)
        let samples = measuredSamples(for: current, rate: 40) + measuredSamples(for: stale, rate: 5)
        let rows = BenchmarkLeaderboard.rows(
            runs: [current, stale], samples: samples, currentPromptVersion: promptVersion)
        XCTAssertEqual(rows.first?.runCount, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first?.generationTokensPerSecond), 40.0, accuracy: 0.001)
    }

    /// RED: let throttled runs contribute → the figure drops for a reason that has nothing to do
    /// with the model.
    func testThrottledRunsDoNotContributeWhenCleanOnesExist() throws {
        let clean = run(model: "m")
        let hot = run(model: "m", throttled: true)
        let samples = measuredSamples(for: clean, rate: 40) + measuredSamples(for: hot, rate: 10)
        let rows = BenchmarkLeaderboard.rows(
            runs: [clean, hot], samples: samples, currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.generationTokensPerSecond), 40.0, accuracy: 0.001)
        XCTAssertEqual(row.runCount, 1)
        XCTAssertFalse(row.isThrottled)
    }

    func testThrottledRunsContributeWhenIncluded() throws {
        let clean = run(model: "m")
        let hot = run(model: "m", throttled: true)
        let samples = measuredSamples(for: clean, rate: 40) + measuredSamples(for: hot, rate: 10)
        let rows = BenchmarkLeaderboard.rows(
            runs: [clean, hot], samples: samples, currentPromptVersion: promptVersion,
            includeThrottled: true)
        XCTAssertEqual(try XCTUnwrap(rows.first).runCount, 2)
    }

    /// A model measured ONLY while throttled still appears, marked.
    ///
    /// RED: drop such a row → the model vanishes from the table, hiding that it was measured at
    /// all — the same silent-drop failure that void reasons exist to avoid.
    func testModelWithOnlyThrottledRuns_stillAppears_andIsMarked() throws {
        let hot = run(model: "m", throttled: true)
        let rows = BenchmarkLeaderboard.rows(
            runs: [hot], samples: measuredSamples(for: hot, rate: 10),
            currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isThrottled)
        XCTAssertEqual(row.runCount, 1)
    }

    /// A run whose every sample was voided prices nothing.
    ///
    /// RED: count it anyway → `runCount` reads 2, so a median over one run presents as a median
    /// over two.
    func testRunWithNoUsableSamples_doesNotCount() throws {
        let good = run(model: "m")
        let broken = run(model: "m")
        var voided = measuredSamples(for: broken, rate: 40)
        voided = voided.map { s in
            var copy = s
            copy.void = .transportError
            return copy
        }
        let rows = BenchmarkLeaderboard.rows(
            runs: [good, broken], samples: measuredSamples(for: good, rate: 40) + voided,
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).runCount, 1)
    }

    /// RED: return `sources.first` unconditionally → a mixed figure is labelled exact.
    func testPrefillSource_nilWhenRunsDisagree() throws {
        let a = run(model: "m")
        let b = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a, b],
            samples: measuredSamples(for: a, rate: 40, prefillSource: .serverPromptEval)
                + measuredSamples(for: b, rate: 40, prefillSource: .timeToFirstToken),
            currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.prefillSource)
        XCTAssertTrue(row.prefillIsApproximate)
    }

    func testPrefillSource_carriedWhenRunsAgree() throws {
        let a = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a], samples: measuredSamples(for: a, rate: 40, prefillSource: .serverPromptEval),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).prefillSource, .serverPromptEval)
        XCTAssertFalse(try XCTUnwrap(rows.first).prefillIsApproximate)
    }

    /// The generation column gets the same treatment as prefill, and needs it for the same reason:
    /// it is the RANKED figure, so a row where the app had to time the window itself must not sit
    /// unmarked beside rows the servers measured.
    ///
    /// RED: return `rateSources.first` unconditionally → a row whose runs measured generation two
    /// different ways is labelled exact.
    func testGenerationRateSource_nilWhenRunsDisagree() throws {
        let a = run(model: "m")
        let b = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a, b],
            samples: measuredSamples(for: a, rate: 40, serverGenerationMs: 10_000)
                + measuredSamples(for: b, rate: 40),
            currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.generationRateSource)
        XCTAssertTrue(row.generationRateIsApproximate)
    }

    func testGenerationRateSource_carriedWhenRunsAgree() throws {
        let a = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a], samples: measuredSamples(for: a, rate: 40, serverGenerationMs: 10_000),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).generationRateSource, .serverDecodeWindow)
        XCTAssertFalse(try XCTUnwrap(rows.first).generationRateIsApproximate)
    }

    /// The complement: with no server figure at all the row is the app's own window, and says so.
    /// RED: default an absent source to "exact" → every provider that reports no timing is
    /// promoted to a measured one.
    func testGenerationRateSource_clientWindowIsMarkedApproximate() throws {
        let a = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a], samples: measuredSamples(for: a, rate: 40),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).generationRateSource, .clientWindow)
        XCTAssertTrue(try XCTUnwrap(rows.first).generationRateIsApproximate)
    }

    /// The version shown belongs to the most recent run, not to whichever came first out of a
    /// dictionary. RED: taking `contributing[0]` → yields the older string.
    func testProviderVersion_comesFromTheNewestRun() throws {
        let old = run(model: "m", providerVersion: "0.32.10",
                      startedAt: Date(timeIntervalSince1970: 1000))
        let new = run(model: "m", providerVersion: "0.32.14",
                      startedAt: Date(timeIntervalSince1970: 2000))
        let rows = BenchmarkLeaderboard.rows(
            runs: [old, new],
            samples: measuredSamples(for: old, rate: 40) + measuredSamples(for: new, rate: 40),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).providerVersion, "0.32.14")
    }

    /// Same newest-run rule as `providerVersion`, and for a real reason: an Ollama tag re-pulled
    /// under the same name can change its quantization, and then the latest measurement is the
    /// honest claim about what the row's chips describe. RED: taking `contributing[0]` → the
    /// dictionary decides which run's format the row wears.
    func testFormatAndQuantization_comeFromTheNewestRun() throws {
        let old = run(model: "m", format: "gguf", quantization: "Q4_K_M",
                      startedAt: Date(timeIntervalSince1970: 1000))
        let new = run(model: "m", format: "mlx", quantization: "4bit",
                      startedAt: Date(timeIntervalSince1970: 2000))
        let rows = BenchmarkLeaderboard.rows(
            runs: [old, new],
            samples: measuredSamples(for: old, rate: 40) + measuredSamples(for: new, rate: 40),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).modelFormat, "mlx")
        XCTAssertEqual(try XCTUnwrap(rows.first).quantization, "4bit")
    }

    /// A history with no details ever reported produces a chipless row, not a defaulted one.
    func testFormatAndQuantization_absentStayAbsent() throws {
        let a = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [a], samples: measuredSamples(for: a, rate: 40),
            currentPromptVersion: promptVersion)
        XCTAssertNil(try XCTUnwrap(rows.first).modelFormat)
        XCTAssertNil(try XCTUnwrap(rows.first).quantization)
    }

    // MARK: - Ordering

    /// RED: leaving ties to input order → lets two equal rows swap places between renders.
    func testTieBreak_isDeterministicByModelName() {
        let rows = [
            makeRow(id: "1", model: "zebra", generation: 40),
            makeRow(id: "2", model: "alpha", generation: 40),
        ]
        let forwards = BenchmarkLeaderboard.sorted(rows, by: .generation, descending: true)
        let backwards = BenchmarkLeaderboard.sorted(rows.reversed(), by: .generation, descending: true)
        XCTAssertEqual(forwards.map(\.modelName), ["alpha", "zebra"])
        XCTAssertEqual(backwards.map(\.modelName), ["alpha", "zebra"])
    }

    /// RED: `?? 0` on the sort key → puts a model with no measured TTFT first, reading as zero
    /// latency. The nil branch must ignore the direction flag entirely.
    func testMissingValuesSortLast_inBothDirections() {
        let rows = [
            makeRow(id: "1", model: "none", timeToFirstToken: nil),
            makeRow(id: "2", model: "fast", timeToFirstToken: 300),
            makeRow(id: "3", model: "slow", timeToFirstToken: 900),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .timeToFirstToken, descending: false)
                .map(\.modelName),
            ["fast", "slow", "none"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .timeToFirstToken, descending: true)
                .map(\.modelName),
            ["slow", "fast", "none"])
    }

    /// RED: implement the reverse as `sorted().reversed()` → the tie-break reverses too, so equal
    /// rows change places when the user only meant to flip the column.
    func testReversingTheColumn_keepsTheTieBreakStable() {
        let rows = [
            makeRow(id: "1", model: "zebra", generation: 40),
            makeRow(id: "2", model: "alpha", generation: 40),
            makeRow(id: "3", model: "beta", generation: 90),
        ]
        let desc = BenchmarkLeaderboard.sorted(rows, by: .generation, descending: true)
        let asc = BenchmarkLeaderboard.sorted(rows, by: .generation, descending: false)
        XCTAssertEqual(desc.map(\.modelName), ["beta", "alpha", "zebra"])
        XCTAssertEqual(asc.map(\.modelName), ["alpha", "zebra", "beta"])
    }

    /// RED: not partitioning on `isThrottled` → lets a throttled row take the top slot, which is
    /// exactly the reading the marker exists to prevent.
    func testThrottledRowsSortLast_inBothDirections() {
        let rows = [
            makeRow(id: "1", model: "hot", generation: 999, throttled: true),
            makeRow(id: "2", model: "cool", generation: 40),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .generation, descending: true).map(\.modelName),
            ["cool", "hot"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .generation, descending: false).map(\.modelName),
            ["cool", "hot"])
    }

    func testSortByModelName_isCaseInsensitive() {
        let rows = [
            makeRow(id: "1", model: "beta"),
            makeRow(id: "2", model: "Alpha"),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .model, descending: false).map(\.modelName),
            ["Alpha", "beta"])
    }

    func testSortByRunCount() {
        let rows = [
            makeRow(id: "1", model: "a", runCount: 2),
            makeRow(id: "2", model: "b", runCount: 7),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .runCount, descending: true).map(\.modelName),
            ["b", "a"])
    }

    /// A provider that reports no version must not sort as if it reported an empty one.
    func testSortByProviderVersion_missingSortsLast() {
        let rows = [
            makeRow(id: "1", model: "a", providerVersion: nil),
            makeRow(id: "2", model: "b", providerVersion: "0.32.14"),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .providerVersion, descending: false)
                .map(\.modelName),
            ["b", "a"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .providerVersion, descending: true)
                .map(\.modelName),
            ["b", "a"])
    }

    /// Sorting is over the STORED value, and the column prints it uppercased — the two orderings
    /// have to agree, or clicking Format reorders rows into a sequence the screen contradicts.
    /// RED: compare with `<` instead of `localizedCaseInsensitiveCompare` → "MLX" sorts before
    /// "gguf" because uppercase letters have the lower code points.
    func testSortByFormat_isAlphabeticalWhateverTheServersCasing() {
        let rows = [
            makeRow(id: "1", model: "a", format: "mlx"),
            makeRow(id: "2", model: "b", format: "GGUF"),
            makeRow(id: "3", model: "c", format: "safetensors"),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .format, descending: false).map(\.modelName),
            ["b", "a", "c"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .format, descending: true).map(\.modelName),
            ["c", "a", "b"])
    }

    /// A server that reported no format must not sort as if it reported an empty one — in EITHER
    /// direction. RED: route the case through `text(lhs ?? "", …)` → the unknown row leads the
    /// ascending sort, so the first thing the reader sees after clicking Format is the rows that
    /// have none.
    func testSortByFormat_missingSortsLastInBothDirections() {
        let rows = [
            makeRow(id: "1", model: "unknown", format: nil),
            makeRow(id: "2", model: "known", format: "gguf"),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .format, descending: false).map(\.modelName),
            ["known", "unknown"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .format, descending: true).map(\.modelName),
            ["known", "unknown"])
    }

    /// The quantization column is its own sort, not a shadow of the format one. RED: point the
    /// `.quantization` arm at `modelFormat` → clicking Quantization reorders by format, which is
    /// invisible when the two happen to correlate and wrong the moment they do not.
    func testSortByQuantization_sortsOnItsOwnFieldAndPutsMissingLast() {
        let rows = [
            makeRow(id: "1", model: "a", format: "gguf", quantization: "Q4_K_M"),
            makeRow(id: "2", model: "b", format: "gguf", quantization: "4bit"),
            makeRow(id: "3", model: "c", format: "gguf", quantization: nil),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .quantization, descending: false)
                .map(\.modelName),
            ["b", "a", "c"])
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .quantization, descending: true)
                .map(\.modelName),
            ["a", "b", "c"])
    }

    /// Every column the header row offers must actually sort. RED: fall through to a `default:`
    /// arm → clicking a column changes the indicator and nothing else, which reads as a frozen UI.
    func testSortByBest() {
        let rows = [makeRow(id: "1", model: "a", generation: 40), makeRow(id: "2", model: "b", generation: 90)]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .best, descending: true).map(\.modelName),
            ["b", "a"])
    }

    func testSortByPrefill_missingSortsLast() {
        var slow = makeRow(id: "1", model: "slow")
        slow.prefillTokensPerSecond = 100
        var fast = makeRow(id: "2", model: "fast")
        fast.prefillTokensPerSecond = 900
        var unknown = makeRow(id: "3", model: "unknown")
        unknown.prefillTokensPerSecond = nil
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted([slow, fast, unknown], by: .prefill, descending: true)
                .map(\.modelName),
            ["fast", "slow", "unknown"])
    }

    func testSortByLastMeasured() {
        var older = makeRow(id: "1", model: "older")
        older.lastMeasuredAt = Date(timeIntervalSince1970: 1000)
        var newer = makeRow(id: "2", model: "newer")
        newer.lastMeasuredAt = Date(timeIntervalSince1970: 5000)
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted([older, newer], by: .lastMeasured, descending: true)
                .map(\.modelName),
            ["newer", "older"])
    }

    func testSortByProvider() {
        let rows = [
            makeRow(id: "1", model: "a", provider: .ollama),
            makeRow(id: "2", model: "b", provider: .lmStudio),
        ]
        XCTAssertEqual(
            BenchmarkLeaderboard.sorted(rows, by: .provider, descending: false).map(\.provider),
            [.lmStudio, .ollama])
    }

    /// The last tie-break: same figure, same model name, different provider. RED: stop at the
    /// model name → two rows that differ only by engine swap places between renders.
    func testTieBreak_fallsThroughToTheProvider() {
        let rows = [
            makeRow(id: "1", model: "same", provider: .ollama),
            makeRow(id: "2", model: "same", provider: .lmStudio),
        ]
        let forwards = BenchmarkLeaderboard.sorted(rows, by: .generation, descending: true)
        let backwards = BenchmarkLeaderboard.sorted(rows.reversed(), by: .generation, descending: true)
        XCTAssertEqual(forwards.map(\.provider), [.lmStudio, .ollama])
        XCTAssertEqual(backwards.map(\.provider), [.lmStudio, .ollama])
    }

    func testEmptyHistory_hasNoRows() {
        XCTAssertTrue(
            BenchmarkLeaderboard.rows(runs: [], samples: [], currentPromptVersion: promptVersion)
                .isEmpty)
    }

    // MARK: - Which runs a row is made of

    /// RED: match on the model name alone → deleting one row takes the same model's runs on every
    /// other server with it, and the table's whole premise is that those are different machines.
    func testRunIDsForRow_areScopedToOneModelAndOneServer() {
        let here = run(model: "m", baseURL: "http://127.0.0.1:1234")
        let elsewhere = run(model: "m", baseURL: "http://192.168.1.9:1234")
        let otherModel = run(model: "other", baseURL: "http://127.0.0.1:1234")
        let rowID = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")

        let ids = BenchmarkLeaderboard.runIDs(
            forRow: rowID, in: [here, elsewhere, otherModel])

        XCTAssertEqual(ids, [here.id])
    }

    /// The width is the point: a throttled run does not contribute to the row's figures while a
    /// clean one exists, and an older-prompt run produces no row at all — but both share the row's
    /// identity. RED: filter to the contributing runs → the row rebuilds itself from what was
    /// spared and reappears after the user deleted it.
    func testRunIDsForRow_includeThrottledAndOlderPromptRunsOfTheSameModel() {
        let clean = run(model: "m")
        let throttled = run(model: "m", throttled: true)
        let older = run(model: "m", promptVersion: promptVersion - 1)
        let rowID = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")

        let ids = BenchmarkLeaderboard.runIDs(forRow: rowID, in: [clean, throttled, older])

        XCTAssertEqual(ids, [clean.id, throttled.id, older.id])
    }

    /// The row id is built from a NORMALIZED endpoint, so a run recorded with a trailing slash or
    /// a different case must still be found. RED: compare the raw strings → the delete silently
    /// matches nothing and the user watches the row survive.
    func testRunIDsForRow_matchThroughTheEndpointNormalizer() {
        let sloppy = run(model: "m", baseURL: "HTTP://127.0.0.1:1234/")
        let rowID = BenchmarkLeaderboard.groupKey(
            provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m")

        XCTAssertEqual(BenchmarkLeaderboard.runIDs(forRow: rowID, in: [sloppy]), [sloppy.id])
    }

    func testRunIDsForRow_unknownRow_isEmpty() {
        XCTAssertTrue(
            BenchmarkLeaderboard.runIDs(forRow: "nope", in: [run(model: "m")]).isEmpty)
    }

    // MARK: - Builders

    private func history(
        _ spec: [(model: String, rate: Double)],
        samplesPerRun: Int = 1
    ) -> ([GenerationBenchmarkRun], [GenerationBenchmarkSample]) {
        var runs: [GenerationBenchmarkRun] = []
        var samples: [GenerationBenchmarkSample] = []
        for (index, entry) in spec.enumerated() {
            let r = run(
                model: entry.model,
                startedAt: Date(timeIntervalSince1970: 1000 + Double(index)))
            runs.append(r)
            samples += measuredSamples(for: r, rate: entry.rate, count: samplesPerRun)
        }
        return (runs, samples)
    }

    // MARK: - Runs that produced nothing

    /// A run whose every sample was void contributes no figure, and used to leave no trace: the
    /// row said "2" after five attempts and nothing said what became of the other three.
    /// RED: return `0` for `failedRunCount` → the count of attempts is lost again.
    func testFailedRunCount_countsContributingRunsThatProducedNoFigure() throws {
        let good = run(model: "m")
        let broken = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        let rows = BenchmarkLeaderboard.rows(
            runs: [good, broken],
            samples: measuredSamples(for: good, rate: 40),
            currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.runCount, 1)
        XCTAssertEqual(row.failedRunCount, 1)
    }

    /// The fixture has to select the branch (CLAUDE.md #93): a throttled run held back by the
    /// default view is NOT a failure, and counting it as one would libel the model for a decision
    /// the leaderboard made. RED: count `groupRuns` instead of `contributing` → this goes to 1.
    func testFailedRunCount_doesNotCountRunsTheViewDeliberatelyHeldBack() throws {
        let clean = run(model: "m")
        let throttled = run(model: "m", throttled: true, startedAt: Date(timeIntervalSince1970: 2000))
        let rows = BenchmarkLeaderboard.rows(
            runs: [clean, throttled],
            samples: measuredSamples(for: clean, rate: 40)
                + measuredSamples(for: throttled, rate: 10),
            currentPromptVersion: promptVersion)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.runCount, 1)
        XCTAssertEqual(row.failedRunCount, 0, "held back is not failed")
    }

    /// The field is drawn now, so its unreachable fallback must not be a plausible-looking date
    /// from the Unix epoch. RED: restore `?? Date(timeIntervalSince1970: 0)` and weaken the guard
    /// above it → the Last run column prints 1 Jan 1970.
    func testLastMeasuredAt_isAlwaysARealRunsTimestamp() throws {
        let recent = Date(timeIntervalSince1970: 1_755_000_000)
        let r = run(model: "m", startedAt: recent)
        let rows = BenchmarkLeaderboard.rows(
            runs: [r], samples: measuredSamples(for: r, rate: 40),
            currentPromptVersion: promptVersion)
        XCTAssertEqual(try XCTUnwrap(rows.first).lastMeasuredAt, recent)
    }

    // MARK: - Best is a sample, not a run

    /// The defect this changed: `max` over run MEDIANS can never report a number any single
    /// generation produced, so the column could not be compared with what a chat window shows.
    ///
    /// Two runs: one whose samples are 30 and 50 tok/s (median 40), one whose samples are both
    /// 41 (median 41). The old rule answered 41 — the better of the two medians. The honest
    /// answer is 50, which is a generation that really happened.
    ///
    /// RED: take the max over `priced.map(\.generationTokensPerSecond)` again → the column
    /// answers 41, a number no generation produced.
    func testBest_isTheFastestSample_notTheFastestRunsMedian() throws {
        let spread = run(model: "m", startedAt: Date(timeIntervalSince1970: 1000))
        let flat = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        let rows = BenchmarkLeaderboard.rows(
            runs: [spread, flat],
            samples: samples(for: spread, rates: [30, 50]) + samples(for: flat, rates: [41, 41]),
            currentPromptVersion: promptVersion)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.bestGenerationTokensPerSecond, 50)
        XCTAssertEqual(
            try XCTUnwrap(row.generationTokensPerSecond), 40.5, accuracy: 0.001,
            "the median of the two run medians, 40 and 41 — unchanged by this")
    }

    /// `max` grows with the number of draws, so the figure is meaningless without its base. RED:
    /// drop the count → two rows sampled 2 and 20 times are ranked against each other on a column
    /// where the second is expected to win for no reason to do with the model.
    func testBest_carriesTheNumberOfSamplesItWasTheBestOf() throws {
        let only = run(model: "m")
        let rows = BenchmarkLeaderboard.rows(
            runs: [only],
            samples: samples(for: only, rates: [30, 50, 40]),
            currentPromptVersion: promptVersion)

        XCTAssertEqual(try XCTUnwrap(rows.first).bestSampleCount, 3)
    }

    /// A run every sample of which ran into the output ceiling is not a failure, and the row has
    /// to be able to say so. RED: fold it into `failedRunCount` → the cell reads "1 of 2" and a
    /// user goes looking for a broken server instead of a verbose model.
    func testCeilingRuns_areCountedApartFromFailures() throws {
        let good = run(model: "m", startedAt: Date(timeIntervalSince1970: 1000))
        let verbose = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        let cut = samples(for: verbose, rates: [30, 30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .outputCeilingReached
            return voided
        }
        let rows = BenchmarkLeaderboard.rows(
            runs: [good, verbose],
            samples: samples(for: good, rates: [40]) + cut,
            currentPromptVersion: promptVersion)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.runCount, 1)
        XCTAssertEqual(row.ceilingRunCount, 1)
        XCTAssertEqual(row.bestSampleCount, 1, "a voided sample is behind no figure at all")
    }

    // MARK: - Models that produced no row at all

    /// The case the ceiling counters could never reach: when EVERY contributing run was cut by
    /// the guard, the group is dropped before `ceilingRunCount` is ever computed, so the model
    /// left the table without a word. RED: return only rows → the model vanishes and the card
    /// falls back to "no comparable run produced a usable sample", which names the wrong cause.
    func testEveryRunHitTheCeiling_leavesNoRowButIsReportedAsUnranked() throws {
        let verbose = run(model: "m")
        let cut = samples(for: verbose, rates: [30, 30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .outputCeilingReached
            return voided
        }
        let table = BenchmarkLeaderboard.table(
            runs: [verbose], samples: cut, currentPromptVersion: promptVersion)

        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertEqual(
            table.unranked,
            [BenchmarkLeaderboard.Unranked(
                modelName: "m", runCount: 1, reason: .everyRunHitTheCeiling)])
    }

    /// The two reasons point at different fixes — a verbose model against a broken server — so
    /// they must not collapse. RED: report `.everyRunHitTheCeiling` for any unrankable model →
    /// an HTTP 500 is described to the user as a model that writes too much.
    func testEveryRunFailedOutright_isUnrankedForTheOtherReason() throws {
        let broken = run(model: "m")
        let failed = samples(for: broken, rates: [30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .httpError
            return voided
        }
        let table = BenchmarkLeaderboard.table(
            runs: [broken], samples: failed, currentPromptVersion: promptVersion)

        XCTAssertEqual(table.unranked.map(\.reason), [.noUsableSample])
    }

    /// The third reason, and the one a default Ollama install hits: the SERVER cut every
    /// answer at its own context window. RED: collapse it into `.noUsableSample` → the emptiest
    /// possible leaderboard on the commonest possible misconfiguration explains nothing, and
    /// the one setting that would fix it is never named.
    func testEveryRunCutByTheContextWindow_isItsOwnUnrankedReason() throws {
        let narrow = run(model: "m")
        let cut = samples(for: narrow, rates: [30, 30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .contextWindowReached
            return voided
        }
        let table = BenchmarkLeaderboard.table(
            runs: [narrow], samples: cut, currentPromptVersion: promptVersion)

        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertEqual(table.unranked.map(\.reason), [.everyRunHitTheContextWindow])
    }

    /// The two bounds mixed across runs is a story about neither. RED: test the window arm
    /// before checking it covers every run → a single narrow-window run relabels a model that
    /// is also genuinely runaway.
    func testCeilingAndContextWindowMixed_fallBackToTheGeneralReason() throws {
        let a = run(model: "m", startedAt: Date(timeIntervalSince1970: 1000))
        let b = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        func voided(_ r: GenerationBenchmarkRun, _ reason: BenchmarkVoidReason) -> [GenerationBenchmarkSample] {
            samples(for: r, rates: [30]).map { sample in
                var s = sample
                s.void = reason
                return s
            }
        }
        let table = BenchmarkLeaderboard.table(
            runs: [a, b],
            samples: voided(a, .outputCeilingReached) + voided(b, .contextWindowReached),
            currentPromptVersion: promptVersion)

        XCTAssertEqual(table.unranked.map(\.reason), [.noUsableSample])
    }

    /// A mixture is not a ceiling story: one run cut by the guard and one that failed outright
    /// means the honest answer is the general one. RED: test `ceiling > 0` instead of
    /// `ceiling == all` → a single verbose run relabels a genuinely broken server.
    func testMixedFailures_areNotReportedAsACeilingStory() throws {
        let verbose = run(model: "m", startedAt: Date(timeIntervalSince1970: 1000))
        let broken = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        let cut = samples(for: verbose, rates: [30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .outputCeilingReached
            return voided
        }
        let failed = samples(for: broken, rates: [30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .transportError
            return voided
        }
        let table = BenchmarkLeaderboard.table(
            runs: [verbose, broken], samples: cut + failed,
            currentPromptVersion: promptVersion)

        XCTAssertEqual(table.unranked.map(\.reason), [.noUsableSample])
    }

    /// The defect in its real shape: a POPULATED table silently missing a model. RED: report
    /// unranked models only when the table is empty → the all-ceiling model disappears beside
    /// rows that rank fine, and nothing on screen says a model was left out.
    func testAnUnrankableModel_isReportedEvenWhenOtherModelsRank() throws {
        let good = run(model: "fast")
        let verbose = run(model: "verbose", startedAt: Date(timeIntervalSince1970: 2000))
        let cut = samples(for: verbose, rates: [30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .outputCeilingReached
            return voided
        }
        let table = BenchmarkLeaderboard.table(
            runs: [good, verbose],
            samples: samples(for: good, rates: [40]) + cut,
            currentPromptVersion: promptVersion)

        XCTAssertEqual(table.rows.map(\.modelName), ["fast"])
        XCTAssertEqual(table.unranked.map(\.modelName), ["verbose"])
    }

    /// The list is sorted by model name because its source is a Dictionary, whose order is not
    /// stable between renders. RED: return `unranked` unsorted → the sentence naming the missing
    /// models reshuffles itself on screen for no reason, and this fails intermittently rather
    /// than never, which is worse.
    func testUnrankedModels_areSortedByName() throws {
        func allCut(_ model: String, at seconds: TimeInterval) -> ([GenerationBenchmarkRun], [GenerationBenchmarkSample]) {
            let r = run(model: model, startedAt: Date(timeIntervalSince1970: seconds))
            let cut = samples(for: r, rates: [30]).map { sample -> GenerationBenchmarkSample in
                var voided = sample
                voided.void = .outputCeilingReached
                return voided
            }
            return ([r], cut)
        }
        let (r1, s1) = allCut("zeta", at: 1000)
        let (r2, s2) = allCut("alpha", at: 2000)
        let (r3, s3) = allCut("mu", at: 3000)

        let table = BenchmarkLeaderboard.table(
            runs: r1 + r2 + r3, samples: s1 + s2 + s3, currentPromptVersion: promptVersion)

        XCTAssertEqual(table.unranked.map(\.modelName), ["alpha", "mu", "zeta"])
    }

    /// The anti-vacuum twin: a model that ranks must never appear in the unranked list, or the
    /// footer accuses a healthy row of being missing. RED: append unconditionally → every model
    /// is reported as both ranked and unranked.
    func testARankableModel_isNotReportedAsUnranked() throws {
        let (runs, samples) = history([(model: "m", rate: 40.0)])
        let table = BenchmarkLeaderboard.table(
            runs: runs, samples: samples, currentPromptVersion: promptVersion)

        XCTAssertEqual(table.rows.count, 1)
        XCTAssertTrue(table.unranked.isEmpty)
    }

    /// `rows` is now a view onto `table`, and every existing caller goes through it. RED: let the
    /// two compute the ranking separately → they drift, and the card's footer describes a table
    /// the card did not draw.
    func testRowsIsTheTablesRows() throws {
        let (runs, samples) = history([(model: "a", rate: 40.0), (model: "b", rate: 20.0)])
        XCTAssertEqual(
            Set(BenchmarkLeaderboard.rows(
                runs: runs, samples: samples, currentPromptVersion: promptVersion).map(\.id)),
            Set(BenchmarkLeaderboard.table(
                runs: runs, samples: samples, currentPromptVersion: promptVersion)
                .rows.map(\.id)))
    }

    /// A model measured only on an older prompt is not "unrankable" — it is out of scope, and the
    /// card already has a sentence for it. RED: count dropped prompt versions as unranked → the
    /// upgrade that retires the old rows reads as every model being broken at once.
    func testAnOlderPromptVersion_isNotReportedAsUnranked() throws {
        let stale = run(model: "m", promptVersion: promptVersion - 1)
        let table = BenchmarkLeaderboard.table(
            runs: [stale], samples: samples(for: stale, rates: [40]),
            currentPromptVersion: promptVersion)

        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertTrue(table.unranked.isEmpty)
    }

    /// The anti-vacuum twin: an ordinary failure must NOT be counted as a ceiling run, or the new
    /// count says "verbose model" about a server that returned HTTP 500.
    func testOrdinaryFailures_areNotCountedAsCeilingRuns() throws {
        let good = run(model: "m", startedAt: Date(timeIntervalSince1970: 1000))
        let broken = run(model: "m", startedAt: Date(timeIntervalSince1970: 2000))
        let failed = samples(for: broken, rates: [30]).map { sample -> GenerationBenchmarkSample in
            var voided = sample
            voided.void = .httpError
            return voided
        }
        let rows = BenchmarkLeaderboard.rows(
            runs: [good, broken],
            samples: samples(for: good, rates: [40]) + failed,
            currentPromptVersion: promptVersion)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.failedRunCount, 1)
        XCTAssertEqual(row.ceilingRunCount, 0)
    }

    /// Samples at named rates, one per entry. `clientRate` divides `tokens - 1` by the window, so
    /// a 10 s window needs `rate * 10 + 1` tokens to land on `rate` exactly.
    private func samples(
        for run: GenerationBenchmarkRun, rates: [Double]
    ) -> [GenerationBenchmarkSample] {
        rates.enumerated().map { index, rate in
            GenerationBenchmarkSample(
                runID: run.id,
                recordedAt: run.startedAt.addingTimeInterval(Double(index)),
                phase: .measured,
                sampleIndex: index,
                inputTokens: 800,
                outputTokens: Int(rate * 10) + 1,
                timeToFirstTokenMs: 600,
                generationMs: 10_000,
                prefillMs: 400,
                prefillSource: .serverPromptEval)
        }
    }

    private func run(
        model: String,
        provider: LLMProvider = .lmStudio,
        baseURL: String = "http://127.0.0.1:1234",
        promptVersion: Int? = nil,
        throttled: Bool = false,
        providerVersion: String? = nil,
        format: String? = nil,
        quantization: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            startedAt: startedAt,
            provider: provider,
            baseURLString: baseURL,
            modelName: model,
            providerVersion: providerVersion,
            modelFormat: format,
            quantization: quantization,
            requestTimeoutSeconds: 600,
            promptID: "prose-ru-en",
            promptVersion: promptVersion ?? self.promptVersion,
            repeats: 5,
            thermalState: throttled ? BenchmarkThermalState.serious : BenchmarkThermalState.nominal,
            lowPowerMode: false,
            modelWasResident: true,
            appVersion: "1.8.8")
    }

    /// Samples engineered to produce exactly `rate` tok/s through `clientRate`: with a 10 s
    /// window, `tokens - 1` must equal `rate * 10`.
    private func measuredSamples(
        for run: GenerationBenchmarkRun,
        rate: Double,
        count: Int = 1,
        prefillSource: PrefillSource = .serverPromptEval,
        serverGenerationMs: Double? = nil
    ) -> [GenerationBenchmarkSample] {
        (0..<count).map { index in
            GenerationBenchmarkSample(
                runID: run.id,
                recordedAt: run.startedAt.addingTimeInterval(Double(index)),
                phase: .measured,
                sampleIndex: index,
                inputTokens: 800,
                outputTokens: Int(rate * 10) + 1,
                timeToFirstTokenMs: 600,
                generationMs: 10_000,
                prefillMs: 400,
                prefillSource: prefillSource,
                serverGenerationMs: serverGenerationMs)
        }
    }

    private func makeRow(
        id: String,
        model: String,
        provider: LLMProvider = .lmStudio,
        providerVersion: String? = "0.32.14",
        format: String? = nil,
        quantization: String? = nil,
        generation: Double? = 40,
        timeToFirstToken: Double? = 600,
        runCount: Int = 1,
        throttled: Bool = false
    ) -> BenchmarkLeaderboard.Row {
        BenchmarkLeaderboard.Row(
            id: id,
            provider: provider,
            modelName: model,
            baseURLString: "http://127.0.0.1:1234",
            providerVersion: providerVersion,
            modelFormat: format,
            quantization: quantization,
            generationTokensPerSecond: generation,
            generationRateSource: .serverDecodeWindow,
            bestGenerationTokensPerSecond: generation,
            bestSampleCount: 1,
            timeToFirstTokenMs: timeToFirstToken,
            prefillTokensPerSecond: 2000,
            prefillSource: .serverPromptEval,
            runCount: runCount,
            failedRunCount: 0,
            ceilingRunCount: 0,
            lastMeasuredAt: Date(timeIntervalSince1970: 1000),
            isThrottled: throttled)
    }
}
