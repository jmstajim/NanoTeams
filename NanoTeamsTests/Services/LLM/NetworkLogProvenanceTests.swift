import XCTest

@testable import NanoTeams

/// A run must record what it RAN ON.
///
/// `NetworkLogRecord`'s 18 fields carry nothing about model, server or build, and the
/// sampler settings deliberately never reach the wire — LM Studio's per-model config is
/// the single source of truth for them (a decision the request builder pins). So a
/// request body could not be traced back to what produced it even in principle, which is
/// why every "re-test this on a build change" gate in the audit trail has never once
/// fired: nothing in a run says which build it was.
final class NetworkLogProvenanceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prov-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        NetworkLogger._testResetProvenanceRegistry()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeRecord() -> NetworkLogRecord {
        NetworkLogger.createProvenanceRecord(
            provider: LLMProvider.lmStudio.rawValue, baseURL: "http://localhost:1234",
            model: "gpt-oss-20b", appVersion: "1.9.5", promptVersion: "abc123", runtimePromptVersion: "rt1",
            stepID: "faang_team_software_engineer", roleName: "Software Engineer")
    }

    private func body(of record: NetworkLogRecord) throws -> [String: Any] {
        let raw = try XCTUnwrap(record.body)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            "body must be valid JSON: \(raw)")
    }

    // MARK: - Shape

    func testRecord_carriesEveryFieldTheAuditNeeds() throws {
        let payload = try body(of: makeRecord())
        XCTAssertEqual(payload["event"] as? String, "provenance")
        XCTAssertEqual(payload["provider"] as? String, LLMProvider.lmStudio.rawValue)
        XCTAssertEqual(payload["baseURL"] as? String, "http://localhost:1234")
        XCTAssertEqual(payload["model"] as? String, "gpt-oss-20b")
        XCTAssertEqual(payload["appVersion"] as? String, "1.9.5")
        XCTAssertEqual(payload["promptVersion"] as? String, "abc123")
        XCTAssertEqual(payload["runtimePromptVersion"] as? String, "rt1",
                       "the composed texts' version rides beside the bundled one (2026-09-07)")
    }

    /// The convention `createToolCallRecord` established, and the reason this needed no new
    /// property: an audit record is not wire traffic, so empty `httpMethod`/`url` is the
    /// truthful answer, and the payload rides `body` as an escaped JSON string. Zero new
    /// named properties is what keeps the token-leak guard (reflection over property names)
    /// and the header guard (JSON keys) green by construction.
    func testRecord_inventsNoWireFieldsAndPairsWithNothing() {
        let record = makeRecord()
        XCTAssertEqual(record.direction, .provenance)
        XCTAssertEqual(record.httpMethod, "")
        XCTAssertEqual(record.url, "")
        XCTAssertNil(record.statusCode)
        XCTAssertNil(record.durationMs)
        XCTAssertNil(record.errorMessage)
        XCTAssertEqual(record.stepID, "faang_team_software_engineer")
        XCTAssertEqual(record.roleName, "Software Engineer")
    }

    /// Every existing consumer selects by `direction`, so a new case must be a case the
    /// old ones do not answer to.
    func testDirection_isDistinctFromRequestResponseAndToolCall() {
        XCTAssertEqual(NetworkDirection.provenance.rawValue, "provenance")
        for other: NetworkDirection in [.request, .response, .toolCall] {
            XCTAssertNotEqual(other, .provenance)
        }
    }

    func testRecord_survivesTheJSONLRoundTripUsedByTheLog() throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        let logger = NetworkLogger(logURL: logURL)
        logger.append(makeRecord())

        // Through the STRICT reader every other log test uses: the point of the
        // no-new-properties convention is that the file stays fully decodable.
        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(records.count, 1, "one record, one line")
        XCTAssertEqual(records[0].direction, .provenance)
        XCTAssertEqual(try body(of: records[0])["model"] as? String, "gpt-oss-20b")
    }

    /// The response record's `doneReason` (2026-09-13) is optional on the way IN too: a line
    /// written before the field existed decodes with nil instead of failing the strict reader.
    func testResponseRecord_carriesTheDoneReason_andALineWithoutItStillDecodes() throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        let logger = NetworkLogger(logURL: logURL)
        logger.append(NetworkLogger.createResponseRecord(
            for: makeRecord(), statusCode: 200, durationMs: 12, error: nil, doneReason: "length"))
        let withReason = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(withReason.map(\.doneReason), ["length"])

        // The same line as a pre-field writer would have left it: the key removed.
        let text = try String(contentsOf: logURL, encoding: .utf8)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "doneReason"))
        try JSONSerialization.data(withJSONObject: object).write(to: logURL)
        let legacy = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy[0].doneReason)
        XCTAssertEqual(legacy[0].statusCode, 200)
    }

    // MARK: - Dedup

    /// Per (log, server, model) — not per call and not per logger INSTANCE. A step builds
    /// a fresh logger on every entry (pause/resume, revision, a delivered supervisor
    /// answer), and every one-shot caller in the same run — vision, a judge, the
    /// auto-answer — shares the file; each would otherwise repeat a constant into it.
    func testWriter_writesOncePerLogServerAndModel_thenStaysSilent() throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")

        func note(model: String, baseURL: String = "http://localhost:1234", step: String = "s1") {
            // A NEW instance each time — the registry is keyed by path, not by object.
            NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(
                config: LLMConfig(provider: .lmStudio, baseURLString: baseURL, modelName: model),
                stepID: step, roleName: "R")
        }

        note(model: "a")
        note(model: "a")                       // same step re-entering
        note(model: "a", step: "s2")           // a different step, same model
        note(model: "b")                       // a per-role override, or a judge / vision config
        note(model: "a", baseURL: "http://other:1234")  // a different server

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3,
                       "one per distinct (server, model), not one per call: \(lines)")
    }

    /// A different log file is a different audit: the same (server, model) is written again.
    func testWriter_aDifferentLogFile_getsItsOwnRecord() throws {
        let a = tempDir.appendingPathComponent("a.jsonl")
        let b = tempDir.appendingPathComponent("b.jsonl")
        let config = LLMConfig(provider: .ollama, baseURLString: "u", modelName: "m")
        NetworkLogger(logURL: a).noteProvenanceIfNeeded(config: config, stepID: "s", roleName: "R")
        NetworkLogger(logURL: b).noteProvenanceIfNeeded(config: config, stepID: "s", roleName: "R")
        XCTAssertEqual(try NetworkLogTestReading.strictRecords(at: a).count, 1)
        XCTAssertEqual(try NetworkLogTestReading.strictRecords(at: b).count, 1)
    }

    /// The record names whoever FIRST saw the triple: the Supervisor auto-answer's request
    /// arrives under `roleName: "Supervisor"` with the asking step's id, and a vision or
    /// judge config that no step runs on still gets its line.
    func testWriter_stampsTheCallerThatFirstSawTheTriple() throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "judge-model"),
            stepID: "faang_team_software_engineer", roleName: SupervisorAutoAnswerService.answererRoleName)
        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].direction, .provenance)
        XCTAssertEqual(records[0].roleName, "Supervisor")
        XCTAssertEqual(records[0].stepID, "faang_team_software_engineer")
        XCTAssertEqual(try body(of: records[0])["model"] as? String, "judge-model")
    }

    /// A logger the app hands to a run (`forRun`) primes the runtime fingerprint first, so
    /// the record the seam writes carries the real value; a logger built without it says
    /// `unprimed` rather than carrying a value computed off the main actor.
    @MainActor
    func testWriter_stampsThePrimedRuntimePromptVersion() async throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        let logger = NetworkLogger.forRun(logURL: logURL)
        logger.noteProvenanceIfNeeded(
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "m"),
            stepID: "s", roleName: "R")
        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(try body(of: records[0])["runtimePromptVersion"] as? String, RuntimePromptFingerprint.current)
        XCTAssertNotEqual(RuntimePromptFingerprint.current, RuntimePromptFingerprint.unprimedMarker)
    }

    /// The other half of the contract above, made deterministic: with no prime in the
    /// process, a directly constructed logger writes the marker — whatever ran earlier.
    /// (Under parallel testing this branch was covered on one run and not the next,
    /// depending on which class had primed the process first.)
    @MainActor
    func testWriter_withoutAPrime_stampsTheUnprimedMarker() throws {
        RuntimePromptFingerprint._testResetPrimed()
        defer { RuntimePromptFingerprint.prime() }
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://localhost:1234", modelName: "m"),
            stepID: "s", roleName: "R")
        let records = try NetworkLogTestReading.strictRecords(at: logURL)
        XCTAssertEqual(try body(of: records[0])["runtimePromptVersion"] as? String,
                       RuntimePromptFingerprint.unprimedMarker)
    }

    // MARK: - The seam

    /// Both provider clients note provenance immediately before their first request
    /// record — the one seam every wire request passes through, so a vision call, a judge,
    /// a meeting turn or the Supervisor auto-answer is covered without knowing about it.
    /// Until 2026-09-07 only `startStepExecution` wrote the record: a judge override or the
    /// vision config in the same run log had no line naming its model.
    ///
    /// RED: delete the `noteProvenanceIfNeeded` line from either client → that client's
    /// `XCTUnwrap` fails naming the file.
    func testBothClients_noteProvenanceBeforeTheRequestRecord() throws {
        let call = "logger.noteProvenanceIfNeeded(config: config, stepID: stepID, roleName: roleName)"
        for file in [
            "NanoTeams/Services/LLM/NativeLMStudioClient.swift",
            "NanoTeams/Services/LLM/OllamaClient.swift",
            "NanoTeams/Services/LLM/OpenAICompatLMStudioClient.swift",
        ] {
            let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            let note = try XCTUnwrap(source.range(of: call), "\(file) must note provenance")
            let append = try XCTUnwrap(source.range(of: "logger.append(requestRecord!)"), file)
            XCTAssertLessThan(note.lowerBound, append.lowerBound,
                              "\(file): provenance precedes the request it describes")
        }
        let step = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("NanoTeams/Services/LLM/LLMExecutionService+StepLifecycle.swift"),
            encoding: .utf8)
        XCTAssertFalse(step.contains("createProvenanceRecord("),
                       "the step no longer writes provenance itself — the client seam does")
    }

    // MARK: - The tool-calling mode is part of the triple (2026-09-13)

    /// One run can drive one model under BOTH protocols — a step pinned before the setting
    /// changed beside a fresh one — and a record naming the model alone would say nothing
    /// about which wire the requests after it carried.
    func testWriter_writesOncePerMode_soAModelDrivenBothWaysGetsTwoRecords() throws {
        let logURL = tempDir.appendingPathComponent("network_log.jsonl")
        var config = LLMConfig(provider: .ollama, baseURLString: "http://localhost:11434", modelName: "ornith")
        config.toolCallingMode = .promptTaught
        NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(config: config, stepID: "s1", roleName: "R")
        config.toolCallingMode = .native
        NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(config: config, stepID: "s2", roleName: "R")
        NetworkLogger(logURL: logURL).noteProvenanceIfNeeded(config: config, stepID: "s3", roleName: "R")

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "one per (server, model, MODE): \(lines)")
        XCTAssertTrue(lines[0].contains("promptTaught"), lines[0])
        XCTAssertTrue(lines[1].contains("native"), lines[1])
        XCTAssertFalse(lines[0].contains("\"native\""))
        XCTAssertTrue(lines.allSatisfy { $0.contains("toolCalling") }, "the body names the field")
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LLM
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // NanoTeamsTests
        .deletingLastPathComponent()  // repo root
}
