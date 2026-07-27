import XCTest
@testable import NanoTeams

/// Pins the `logger:` / `stepID:` / `roleName:` plumbing on `TeamGenerationService.generate`.
///
/// The whole point of wiring these through (per the team-generation visibility refactor)
/// is that an unparseable `create_team` envelope becomes diagnosable via the per-task
/// `network_log.json`. A future refactor that drops the argument from one call site
/// compiles cleanly and silently regresses the diagnosability win — so this suite
/// captures the streamChat parameters and asserts the contract verbatim.
@MainActor
final class TeamGenerationServiceLoggerWiringTests: XCTestCase {

    /// Captures the `logger:`, `stepID:`, `roleName:` arguments handed to `streamChat`
    /// and yields a single empty event so the call returns without provoking a parse.
    private final class CapturingClient: LLMClient, @unchecked Sendable {
        var capturedLogger: NetworkLogger?
        var capturedStepID: String?
        var capturedRoleName: String?

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            capturedLogger = logger
            capturedStepID = stepID
            capturedRoleName = roleName
            return AsyncThrowingStream { $0.finish() }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    /// `generate` always tags the streaming call with `roleName: "Team Generator"`
    /// regardless of what the caller passes. Operators rely on this attribution to
    /// distinguish team-gen rows from the delegating role's own LLM calls in the
    /// shared per-task log.
    func testGenerate_alwaysTagsRoleNameAsTeamGenerator() async {
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "build a team",
            config: LLMConfig(),
            client: cap
        )
        XCTAssertEqual(cap.capturedRoleName, "Team Generator",
                       "Team-gen rows must be attributed to 'Team Generator' in the network log")
    }

    /// The caller-supplied `stepID` is forwarded verbatim. Without this, log records
    /// have no way to associate team-gen with the step that triggered it.
    func testGenerate_passesStepIDThrough() async {
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "x",
            config: LLMConfig(),
            client: cap,
            stepID: "delegating_step_42"
        )
        XCTAssertEqual(cap.capturedStepID, "delegating_step_42")
    }

    /// `nil` stepID stays `nil` — pre-fix default for callers that don't have a step
    /// (e.g. the standalone "Generate Team..." sheet in TeamEditor).
    func testGenerate_nilStepID_remainsNil() async {
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "x",
            config: LLMConfig(),
            client: cap
        )
        XCTAssertNil(cap.capturedStepID)
    }

    /// The injected `NetworkLogger` instance is the same one the caller passed —
    /// `streamChat` does not wrap, replace, or null it out. Without this, even a
    /// non-nil logger could be silently dropped between the orchestrator and the
    /// HTTP client.
    func testGenerate_passesLoggerInstanceThrough() async {
        let logURL = tempDir.appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "x",
            config: LLMConfig(),
            client: cap,
            logger: logger,
            stepID: "step_1"
        )
        XCTAssertNotNil(cap.capturedLogger, "Logger must be threaded through to streamChat")
        XCTAssertTrue(cap.capturedLogger === logger,
                      "The exact logger instance must reach streamChat (no wrapper / replacement)")
    }

    /// Round-trip: when a real logger is wired and the streaming client appends a
    /// record, that record actually lands on disk. Pins (a) record persistence,
    /// (b) `roleName == "Team Generator"`, (c) caller-supplied `stepID` makes it
    /// into the row.
    func testGenerate_loggerRecordsLandOnDisk_withCorrectRoleNameAndStepID() async throws {
        // Client that records one request + one response into the logger then finishes.
        final class RecordingClient: LLMClient, @unchecked Sendable {
            func streamChat(
                config: LLMConfig, messages: [ChatMessage], tools: [ToolSchema],
                logger: NetworkLogger?,
                stepID: String?, roleName: String?
            ) -> AsyncThrowingStream<StreamEvent, Error> {
                if let logger {
                    let url = URL(string: "https://test.invalid/api/v1/chat")!
                    let req = NetworkLogger.createRequestRecord(
                        url: url, method: "POST", body: nil,
                        stepID: stepID, roleName: roleName)
                    logger.append(req)
                    let resp = NetworkLogger.createResponseRecord(
                        for: req, statusCode: 200, durationMs: 12.0,
                        body: "{}", error: nil
                    )
                    logger.append(resp)
                }
                return AsyncThrowingStream { $0.finish() }
            }
            func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
        }

        let logURL = tempDir.appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)
        _ = try? await TeamGenerationService.generate(
            taskDescription: "task",
            config: LLMConfig(),
            client: RecordingClient(),
            logger: logger,
            stepID: "step_xyz"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path),
                      "Logger must persist records to disk")
        let data = try Data(contentsOf: logURL)
        let records = try JSONCoderFactory.makeDateDecoder()
            .decode([NetworkLogRecord].self, from: data)
        XCTAssertGreaterThanOrEqual(records.count, 1,
                                     "At least one record must be written")
        XCTAssertTrue(records.allSatisfy { $0.roleName == "Team Generator" },
                      "All team-gen records must be attributed to 'Team Generator'")
        XCTAssertTrue(records.allSatisfy { $0.stepID == "step_xyz" },
                      "Caller-supplied stepID must thread through into every record")
    }

    /// `nil` logger argument means "logging disabled" — no wrapper, no synthetic
    /// records appear. Without this assertion a future refactor could quietly
    /// substitute a default in-memory logger and operators would lose the
    /// privacy-toggle contract that gates capture on `loggingEnabled`.
    func testGenerate_nilLogger_remainsNil() async {
        let cap = CapturingClient()
        _ = try? await TeamGenerationService.generate(
            taskDescription: "x",
            config: LLMConfig(),
            client: cap,
            logger: nil,
            stepID: nil
        )
        XCTAssertNil(cap.capturedLogger,
                     "nil logger must remain nil (privacy-toggle contract)")
    }
}
