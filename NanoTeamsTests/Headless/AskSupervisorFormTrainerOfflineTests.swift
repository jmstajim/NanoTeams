import XCTest
@testable import NanoTeams

/// Everything about the `ask_supervisor_form` trainer that can be checked without a server:
/// the classifier scored against the three REAL field runs it was derived from, and one full
/// pass of the trainer's own loop driven through the orchestrator seam around a scripted
/// client. Runs on every build — the live entry point (`AskSupervisorFormTrainerTests`) does
/// not.
@MainActor
final class AskSupervisorFormTrainerOfflineTests: XCTestCase {

    // MARK: - The classifier, over the field runs it was derived from

    /// The baseline the wave is measured against, emission by emission.
    ///
    /// Synthetic rows would say nothing here: every one of these four failure mechanisms was
    /// a surprise when it was read off a real run, and a fixture written from the classifier's
    /// own assumptions can only confirm them (the lesson of task 60, 2026-09-11).
    ///
    /// RED: drop the text-only `shape` fallback in `FormEmissionClassifier` → both
    /// `malformed_tool_call` rows read `unknown` and this table fails on two lines.
    func testTheThreeFieldRuns_classifyExactlyAsTheyWereReadByHand() throws {
        let expected: [String: [(shape: FormEmission.Shape, envelope: Bool, doc: Bool, diagnosis: String, repairs: Int)]] = [
            "form_field_task71_run4": [
                // The questionnaire written straight into the arguments — syntactically
                // flawless, and the one emission the tool refused.
                (.questionsAtTop, true, false, "INVALID_ARGS", 0),
                // Told it needed a string, the model re-serialized by hand and corrupted it.
                (.string, true, false, "not_json", 0),
                (.string, true, true, "-", 0),
            ],
            "form_field_task71_run5": [
                // `form`'s own closing quote never written: dies on the outer envelope.
                (.string, false, false, "malformed_tool_call", 0),
                // Parked, but only after the ladder adopted two rewrites.
                (.string, true, true, "-", 2),
            ],
            "form_field_task74_run1": [
                (.string, false, false, "malformed_tool_call", 0),
                (.string, true, true, "-", 0),
            ],
        ]

        for (name, rows) in expected.sorted(by: { $0.key < $1.key }) {
            let emissions = try Self.fieldEmissions(name)
            XCTAssertEqual(emissions.count, rows.count, "\(name): emission count")
            for (index, row) in rows.enumerated() where index < emissions.count {
                let actual = emissions[index]
                XCTAssertEqual(actual.attempt, index + 1, "\(name)[\(index)]: attempt")
                XCTAssertEqual(actual.shape, row.shape, "\(name)[\(index)]: shape")
                XCTAssertEqual(actual.envelopeParsed, row.envelope, "\(name)[\(index)]: envelope")
                XCTAssertEqual(actual.documentAccepted, row.doc, "\(name)[\(index)]: document")
                XCTAssertEqual(actual.diagnosis, row.diagnosis, "\(name)[\(index)]: diagnosis")
                XCTAssertEqual(actual.repairs, row.repairs, "\(name)[\(index)]: repairs")
            }
        }
    }

    /// The headline numbers of 2026-09-12, which the wave's after-measurement is compared to.
    /// They must not move when the tool changes: these runs are finished history, and a
    /// classifier that re-scores them differently has changed the ruler along with the thing
    /// it measures.
    func testTheFieldBaselineSummary_isTheOneTheWaveIsMeasuredAgainst() throws {
        let summary = FormEmissionClassifier.summarize(try Self.allFieldEmissions())
        XCTAssertEqual(summary.runs, 3)
        XCTAssertEqual(summary.emissions, 7)
        XCTAssertEqual(summary.cleanOnFirst, 0, "not one of the three got the form out on its first try")
        XCTAssertEqual(summary.parked, 3, "all three did park eventually — the ladder works, it just costs")
        XCTAssertEqual(summary.callsPerPark, 7.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.shapeCounts, ["string": 6, "questions@top": 1])
        XCTAssertEqual(summary.diagnosisCounts,
                       ["-": 3, "malformed_tool_call": 2, "not_json": 1, "INVALID_ARGS": 1])
    }

    /// Anti-vacuum for the summary: a run that never parked must not be divided into.
    func testCallsPerPark_isZeroRatherThanInfiniteWhenNothingParked() {
        let failed = [FormEmission(attempt: 1, shape: .string, envelopeParsed: false,
                                   documentAccepted: false, diagnosis: "malformed_tool_call", repairs: 0)]
        let summary = FormEmissionClassifier.summarize([failed])
        XCTAssertEqual(summary.parked, 0)
        XCTAssertEqual(summary.callsPerPark, 0)
        XCTAssertEqual(summary.cleanOnFirst, 0)
    }

    /// A run with no form attempt is not evidence about the form, so it is not counted at all —
    /// otherwise a folder whose model never reached for the tool would dilute the rate toward
    /// zero while looking like a measurement.
    func testRunsWithNoFormAttempt_areNotCounted() {
        let summary = FormEmissionClassifier.summarize([[], []])
        XCTAssertEqual(summary.runs, 0)
        XCTAssertEqual(summary.emissions, 0)
    }

    // MARK: - One iteration, offline

    /// The trainer's own loop, driven through the orchestrator seam around a scripted client:
    /// two runs, a broken form then an accepted one, and the folder left exactly as it was found.
    ///
    /// RED: drop the `closeTask` at the end of `runOnce` → the parked step stays
    /// `.needsSupervisorInput`, `busyRoleIDs` names the role, and the next open's
    /// bundled-content reconcile defers this team (MeditationApp task 60, 2026-09-11).
    /// RED: drop the supervisor-mode restore → the folder is left on `.manual`.
    func testTwoIterations_scoreTheirRunsAndLeaveTheFolderAsItWasFound() async throws {
        let workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("form-trainer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        // Seed the folder on a mode the trainer must put back — `.manual` is the bundled
        // default, so restoring to it would prove nothing.
        let seed = TestOrchestrator.make(configuration: TestOrchestrator.makeConfiguration())
        await seed.openWorkFolder(workFolder)
        await seed.mutateWorkFolder { projection in
            guard let index = projection.teams.firstIndex(where: { $0.templateID == "codingAssistant" })
            else { return }
            projection.teams[index].settings.supervisorMode = .autonomous
            projection.setActiveTeam(projection.teams[index].id)
        }

        let broken = try Self.firstFormArguments("form_field_task71_run4", attempt: 2)
        let client = ScriptedToolCallClient(script: [
            .toolCall(name: ToolNames.askSupervisorForm, argumentsJSON: broken),
            .toolCall(name: ToolNames.askSupervisorForm, argumentsJSON: Self.acceptableForm),
        ])
        let service = LLMExecutionService(repository: NTMSRepository(), clientFactory: { client })

        let outputPath = workFolder.appendingPathComponent("results.json").path
        let config = AskSupervisorFormTrainerConfig(
            projectPath: workFolder.path, teamTemplate: "codingAssistant",
            runs: 2, runTimeoutSeconds: 20, outputPath: outputPath)
        let trainer = AskSupervisorFormTrainer(config: config) { configuration in
            TestOrchestrator.make(llmExecutionService: service, configuration: configuration)
        }

        let result = try await trainer.run()

        XCTAssertEqual(client.callCount, 3, "anti-vacuum: three requests — two in run 1, one in run 2")
        XCTAssertEqual(result.cases.count, 2)
        XCTAssertEqual(result.cases.map(\.outcome), [.parkedOnForm, .parkedOnForm])
        XCTAssertEqual(result.cases.map { $0.emissions.count }, [2, 1])
        XCTAssertEqual(result.cases[0].emissions.map(\.documentAccepted), [false, true])
        XCTAssertEqual(result.summary.cleanOnFirst, 1, "only the second run got it out first try")
        XCTAssertEqual(result.summary.emissions, 3)
        XCTAssertEqual(result.summary.callsPerPark, 1.5, accuracy: 0.001)
        for row in result.cases {
            XCTAssertTrue(row.errors.isEmpty, "[run \(row.run)] \(row.errors.joined(separator: "; "))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath), "results file is the receipt")

        // The folder, as the next reader of it finds it.
        let taskID = try XCTUnwrap(result.taskID)
        let task = try NTMSRepository().loadTask(at: workFolder, taskID: taskID)
        XCTAssertTrue(NTMSRepository.busyRoleIDs(task).isEmpty,
                      "a measured run must not pin its team against the next reconcile")
        XCTAssertEqual(task.runs.count, 2, "one run per iteration")
        let reopened = TestOrchestrator.make(configuration: TestOrchestrator.makeConfiguration())
        await reopened.openWorkFolder(workFolder)
        XCTAssertEqual(reopened.workFolder?.activeTeam?.settings.supervisorMode, .autonomous,
                       "the trainer put the team's supervisor mode back")
    }

    // MARK: - Fixtures

    /// A questionnaire the handler accepts: two answers on the choice, as
    /// `SupervisorInquiryCompleteness` requires.
    private static let acceptableForm = """
    {"headline":"Which way","form":{"questions":[{"prompt":"Which way?","kind":"single_choice",\
    "options":[{"label":"Left"},{"label":"Right"}]},{"prompt":"Anything else?","kind":"free_text"}]}}
    """

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Headless/
            .deletingLastPathComponent() // NanoTeamsTests/
            .deletingLastPathComponent() // repo root
    }

    private static func fieldLog(_ name: String) throws -> [ToolCallLogRecord] {
        let url = repoRoot
            .appendingPathComponent("NanoTeamsTests/Fixtures/ToolCallLogs")
            .appendingPathComponent("\(name).jsonl")
        // The public CI mirror ships build sources only, so a fixture log can be absent there —
        // skip rather than fail, the same rule the xcodebuild-log fixtures follow.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("field log fixture not present in this checkout (\(url.path))")
        }
        return try ToolCallLogReader.records(at: url)
    }

    private static func fieldEmissions(_ name: String) throws -> [FormEmission] {
        FormEmissionClassifier.emissions(in: try fieldLog(name))
    }

    private static func allFieldEmissions() throws -> [[FormEmission]] {
        try ["form_field_task71_run4", "form_field_task71_run5", "form_field_task74_run1"]
            .map { try fieldEmissions($0) }
    }

    /// The raw `argumentsJSON` of one field emission, so the offline run is driven by bytes a
    /// model actually emitted rather than by a hand-written imitation of one.
    private static func firstFormArguments(_ name: String, attempt: Int) throws -> String {
        let records = try fieldLog(name).filter { $0.toolName == ToolNames.askSupervisorForm }
        guard records.indices.contains(attempt - 1) else {
            throw XCTSkip("\(name) has no dispatched form emission #\(attempt)")
        }
        return records[attempt - 1].argumentsJSON
    }
}
