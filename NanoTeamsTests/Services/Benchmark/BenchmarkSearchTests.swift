import XCTest

@testable import NanoTeams

/// Pins the filter rule shared by the leaderboard and the Runs tab. Pure value types throughout,
/// so the suite is not `@MainActor` and never constructs a main-actor class.
final class BenchmarkSearchTests: XCTestCase {

    // MARK: - The empty query is not a gate

    /// RED: treating an empty query as "match nothing" → the table empties the moment the field
    /// exists, before the reader has typed a character into it.
    func testEmptyQuery_matchesEveryRowAndRun() {
        XCTAssertTrue(BenchmarkSearch.matches(row(model: "qwen3.6"), query: ""))
        XCTAssertTrue(BenchmarkSearch.matches(run(model: "qwen3.6"), query: ""))
    }

    /// A field holding only spaces is an empty field — the tokenizer, not the caller, has to say so.
    func testWhitespaceOnlyQuery_matchesEverything() {
        XCTAssertTrue(BenchmarkSearch.matches(row(model: "qwen3.6"), query: "   \n\t "))
        XCTAssertTrue(BenchmarkSearch.matches(run(model: "qwen3.6"), query: "   "))
    }

    // MARK: - What is searched

    func testMatchesModelName_regardlessOfCase() {
        let r = row(model: "Qwen3-Coder-30B")
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen"))
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "CODER"))
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "llama"))
    }

    /// RED: searching the model alone → "lm studio" returns nothing, and the two rows the table
    /// deliberately keeps apart (same model, two servers) become unreachable by filter.
    func testMatchesProviderDisplayName() {
        XCTAssertTrue(BenchmarkSearch.matches(row(provider: .lmStudio), query: "lm studio"))
        XCTAssertFalse(BenchmarkSearch.matches(row(provider: .ollama), query: "lm studio"))
        XCTAssertTrue(BenchmarkSearch.matches(row(provider: .ollama), query: "ollama"))
    }

    func testMatchesServerVersion() {
        XCTAssertTrue(BenchmarkSearch.matches(row(providerVersion: "0.32.14"), query: "0.32"))
        XCTAssertFalse(BenchmarkSearch.matches(row(providerVersion: "0.31.0"), query: "0.32"))
    }

    /// The endpoint is half of a row's identity, so it has to be searchable even though no column
    /// draws it — it lives on the tooltip over a model's name and in the delete confirmation.
    func testMatchesEndpoint() {
        XCTAssertTrue(
            BenchmarkSearch.matches(row(baseURL: "http://192.168.1.9:1234"), query: "192.168"))
        XCTAssertFalse(
            BenchmarkSearch.matches(row(baseURL: "http://127.0.0.1:1234"), query: "192.168"))
    }

    /// The filter is over NAMES, not figures: a row generating 40 tok/s is not what "40" asks for,
    /// and matching it would make every numeric query return an arbitrary handful of rows.
    func testDoesNotMatchMeasuredFigures() {
        let r = row(model: "qwen3.6", baseURL: "http://127.0.0.1:1234", generation: 40)
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "40"))
    }

    /// The Format column is on screen, so a filter that cannot find it reads as broken.
    /// Case-insensitive both ways: the value is stored as the server spells it (`gguf`), the
    /// column renders it uppercased, and the reader types whichever they saw.
    func testMatchesFormatColumn() {
        XCTAssertTrue(BenchmarkSearch.matches(row(format: "gguf"), query: "gguf"))
        XCTAssertTrue(BenchmarkSearch.matches(row(format: "gguf"), query: "GGUF"))
        XCTAssertFalse(BenchmarkSearch.matches(row(format: "mlx"), query: "gguf"))
    }

    /// Verbatim in the column and verbatim here — `Q4_K_M` is typed the way a model card spells
    /// it, and matching is case-insensitive so either casing finds the row.
    func testMatchesQuantizationColumn() {
        XCTAssertTrue(BenchmarkSearch.matches(row(quantization: "Q4_K_M"), query: "q4_k_m"))
        XCTAssertTrue(BenchmarkSearch.matches(row(quantization: "4bit"), query: "4bit"))
        XCTAssertFalse(BenchmarkSearch.matches(row(quantization: "Q4_K_M"), query: "4bit"))
    }

    /// A row whose server reported no details (both columns showing a dash) must not be swallowed
    /// by its own missing fields — the same rule `testMissingServerVersion` pins for the version.
    func testMissingFormatAndQuantization_doNotHideTheRow() {
        let r = row(model: "qwen3.6", format: nil, quantization: nil)
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen"))
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "gguf"))
    }

    // MARK: - Tokens

    /// RED: one `contains` over the whole query → "qwen 30b" finds nothing, because the model id
    /// spells it `qwen3-coder-30b` and the space the reader typed is not in it.
    func testTokensAreMatchedIndependently() {
        let r = row(model: "qwen/qwen3-coder-30b-a3b-instruct-mlx")
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen 30b"))
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "30b qwen"))
    }

    /// RED: OR-ing the tokens → "qwen llama" matches the qwen row, so adding a word to narrow a
    /// search would widen it instead.
    func testEveryTokenMustMatch() {
        let r = row(model: "qwen3-coder-30b")
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "qwen llama"))
    }

    /// Tokens are free to land in different fields — that is what makes "this model, on that
    /// server" expressible in one line.
    func testTokensMayMatchAcrossDifferentFields() {
        let r = row(model: "qwen3-coder-30b", provider: .lmStudio, providerVersion: "0.32.14")
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen studio"))
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen 0.32"))
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "qwen ollama"))
    }

    // MARK: - Degenerate rows

    /// A server that reports no version renders as "—". The dash is the TABLE's stand-in, not a
    /// name, so it must not be searchable — and the missing field must not swallow the row.
    func testMissingServerVersion_doesNotMatchTheDashAndDoesNotHideTheRow() {
        let r = row(model: "qwen3.6", providerVersion: nil)
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "—"))
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "qwen"))
    }

    func testEmptyModelName_stillMatchesOnItsServer() {
        let r = row(model: "", providerVersion: "0.32.14")
        XCTAssertTrue(BenchmarkSearch.matches(r, query: "0.32"))
        XCTAssertFalse(BenchmarkSearch.matches(r, query: "qwen"))
    }

    // MARK: - Runs tab

    /// The Runs tab filters raw runs rather than aggregated rows; both have to answer one query
    /// the same way, or switching tabs would silently change what the field means.
    func testRunMatchesTheSameSixFields() {
        let candidate = run(
            model: "qwen3-coder-30b", provider: .lmStudio,
            baseURL: "http://192.168.1.9:1234", providerVersion: "0.32.14",
            format: "gguf", quantization: "Q4_K_M")
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "qwen"))
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "lm studio"))
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "0.32"))
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "192.168"))
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "gguf"))
        XCTAssertTrue(BenchmarkSearch.matches(candidate, query: "q4_k_m"))
        XCTAssertFalse(BenchmarkSearch.matches(candidate, query: "llama"))
    }

    /// The same query over a row and over the run behind it agrees. RED: letting the two overloads
    /// search different field sets → a model visible on one tab vanishes on the other.
    func testRowAndRunAgreeOnTheSameQuery() {
        let queries = ["qwen", "lm studio", "0.32", "192.168", "gguf", "q4", "mlx", "llama", ""]
        for q in queries {
            let onRow = BenchmarkSearch.matches(
                row(
                    model: "qwen3.6", provider: .lmStudio,
                    baseURL: "http://192.168.1.9:1234", providerVersion: "0.32.14",
                    format: "gguf", quantization: "Q4_K_M"),
                query: q)
            let onRun = BenchmarkSearch.matches(
                run(
                    model: "qwen3.6", provider: .lmStudio,
                    baseURL: "http://192.168.1.9:1234", providerVersion: "0.32.14",
                    format: "gguf", quantization: "Q4_K_M"),
                query: q)
            XCTAssertEqual(onRow, onRun, "disagreed on \"\(q)\"")
        }
    }

    // MARK: - Builders

    private func row(
        model: String = "qwen3.6",
        provider: LLMProvider = .lmStudio,
        baseURL: String = "http://127.0.0.1:1234",
        providerVersion: String? = "0.32.14",
        format: String? = nil,
        quantization: String? = nil,
        generation: Double? = 40
    ) -> BenchmarkLeaderboard.Row {
        BenchmarkLeaderboard.Row(
            id: BenchmarkLeaderboard.groupKey(
                provider: provider, baseURLString: baseURL, modelName: model),
            provider: provider,
            modelName: model,
            baseURLString: baseURL,
            providerVersion: providerVersion,
            modelFormat: format,
            quantization: quantization,
            generationTokensPerSecond: generation,
            generationRateSource: .serverDecodeWindow,
            bestGenerationTokensPerSecond: generation,
            timeToFirstTokenMs: 600,
            prefillTokensPerSecond: 2000,
            prefillSource: .serverPromptEval,
            runCount: 1,
            failedRunCount: 0,
            lastMeasuredAt: Date(timeIntervalSince1970: 1000),
            isThrottled: false)
    }

    private func run(
        model: String = "qwen3.6",
        provider: LLMProvider = .lmStudio,
        baseURL: String = "http://127.0.0.1:1234",
        providerVersion: String? = "0.32.14",
        format: String? = nil,
        quantization: String? = nil
    ) -> GenerationBenchmarkRun {
        GenerationBenchmarkRun(
            startedAt: Date(timeIntervalSince1970: 1000),
            provider: provider,
            baseURLString: baseURL,
            modelName: model,
            providerVersion: providerVersion,
            modelFormat: format,
            quantization: quantization,
            requestTimeoutSeconds: 600,
            promptID: "prose-ru-en",
            promptVersion: BenchmarkPrompt.version,
            repeats: 5,
            thermalState: BenchmarkThermalState.nominal,
            lowPowerMode: false,
            modelWasResident: true,
            appVersion: "1.8.8")
    }
}
