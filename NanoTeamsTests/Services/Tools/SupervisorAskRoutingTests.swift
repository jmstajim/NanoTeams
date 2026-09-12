import XCTest

@testable import NanoTeams

/// The two supervisor-ask tools told apart by their arguments.
///
/// From the live run of 2026-09-10: a correct `{headline, form}` payload arrived under the
/// name `ask_supervisor` and was refused with "Missing required argument: question". The
/// model then re-sent the identical form under the right name — one wasted round trip on a
/// call whose intent was never in doubt.
final class SupervisorAskRoutingTests: XCTestCase {

    private func corrected(_ name: String, _ keys: String...) -> String? {
        SupervisorAskRouting.correctedName(for: name, argumentKeys: Set(keys))
    }

    // MARK: - The two corrections

    /// The observed defect, verbatim in shape.
    func testAFormPayloadNamedAsThePlainAskRoutesToTheForm() {
        XCTAssertEqual(
            corrected(ToolNames.askSupervisor, "form", "headline"),
            ToolNames.askSupervisorForm)
    }

    func testAPlainQuestionNamedAsTheFormRoutesToThePlainAsk() {
        XCTAssertEqual(
            corrected(ToolNames.askSupervisorForm, "question"),
            ToolNames.askSupervisor)
    }

    // MARK: - What it refuses to guess at

    func testACallWhoseNameAlreadyFitsIsLeftAlone() {
        XCTAssertNil(corrected(ToolNames.askSupervisor, "question"))
        XCTAssertNil(corrected(ToolNames.askSupervisorForm, "form", "headline"))
    }

    /// Both keys is a genuine ambiguity, and picking one would ask the human a question the
    /// model did not send — with no way for either of them to see what was dropped.
    func testACallCarryingBothKeysIsNotRouted() {
        XCTAssertNil(corrected(ToolNames.askSupervisor, "question", "form"))
        XCTAssertNil(corrected(ToolNames.askSupervisorForm, "question", "form"))
    }

    /// Neither key: the handler's own "missing required argument" is the right answer, and it
    /// names the argument the tool the model NAMED actually wants.
    func testACallCarryingNeitherKeyIsNotRouted() {
        XCTAssertNil(corrected(ToolNames.askSupervisor, "headline"))
        XCTAssertNil(corrected(ToolNames.askSupervisorForm))
    }

    /// `headline` is the form's argument but not its discriminator: a plain question sent
    /// with one has still asked a question, and routing it to the form would refuse it for a
    /// missing `form` instead of parking on it.
    func testHeadlineAloneDoesNotMakeACallAForm() {
        XCTAssertNil(corrected(ToolNames.askSupervisor, "question", "headline"))
    }

    /// Every other tool passes through untouched — a `search {"query": …}` must never be
    /// re-pointed by a key that happens to be named `form` somewhere else in the tree.
    func testOtherToolsAreNeverRouted() {
        for name in [ToolNames.search, ToolNames.readFile, ToolNames.createArtifact] {
            XCTAssertNil(SupervisorAskRouting.correctedName(
                for: name, argumentKeys: ["form", "question", "headline"]), name)
        }
    }

    /// Anti-vacuity: the set this gates on is the same closed set every other park-aware site
    /// reads, so a third ask tool joins the routing by joining the set.
    func testTheGateIsTheClosedSetOfParkingTools() {
        XCTAssertEqual(
            ToolNames.supervisorAskTools,
            [ToolNames.askSupervisor, ToolNames.askSupervisorForm])
    }

    // MARK: - Wired at the dispatch boundary

    /// The policy is only worth anything if `ToolRuntime` actually consults it, and it does so
    /// AFTER the handler lookup — a place easy to leave un-called. Drives the real registry
    /// with the exact shape the live run sent: a well-formed questionnaire under the name of
    /// the plain ask.
    ///
    /// RED: delete the `SupervisorAskRouting.correctedName` block in `ToolRuntime.executeOne`
    /// → `Missing required argument: question`, which is what the model actually got.
    func testTheRuntimeDispatchesAMisnamedFormToTheFormHandler() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (_, runtime) = ToolRegistry.defaultRegistry(workFolderRoot: root, toolCallsLogURL: nil)
        let form = #"{"questions":[{"prompt":"Anything else?","kind":"free_text"}]}"#
        let args = try XCTUnwrap(String(data: JSONSerialization.data(
            withJSONObject: ["headline": "M20 clarifications", "form": form]), encoding: .utf8))

        let results = await runtime.executeAll(
            context: ToolExecutionContext(
                workFolderRoot: root, taskID: 1, runID: 0, roleID: "planner"),
            toolCalls: [StepToolCall(
                name: ToolNames.askSupervisor, argumentsJSON: args)])

        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.isError, result.outputJSON)
        guard case .supervisorForm(let headline, let inquiry) = result.signal else {
            return XCTFail("expected a form signal, got \(String(describing: result.signal))")
        }
        XCTAssertEqual(headline, "M20 clarifications")
        XCTAssertEqual(inquiry.questions.count, 1)

        // The RESULT names the tool that actually ran — same as any alias, and the one place
        // the model can see which of the two answered it. `tool_calls.jsonl` separately keeps
        // the name the model emitted (`ToolCallLogRecord` is built from `call.name`), so the
        // slip stays visible to a human reading the run.
        XCTAssertEqual(result.toolName, ToolNames.askSupervisorForm)
    }

    /// The questionnaire's own top-level key routes like `form`: a model that writes the
    /// form's CONTENT into the arguments has described the questionnaire and nothing else.
    /// Live shape, under the WRONG name it would otherwise be refused for (2026-09-12).
    ///
    /// RED: drop `questionsKey` → the call keeps the plain ask's name and is refused for a
    /// missing `question`.
    func testAQuestionsArrayRoutesToTheFormEvenWithoutAFormKey() {
        XCTAssertEqual(
            SupervisorAskRouting.correctedName(
                for: ToolNames.askSupervisor, argumentKeys: ["headline", "questions"]),
            ToolNames.askSupervisorForm)
    }

    /// Already the right name — nothing to correct.
    func testAQuestionsArrayUnderTheFormsOwnNameIsLeftAlone() {
        XCTAssertNil(
            SupervisorAskRouting.correctedName(
                for: ToolNames.askSupervisorForm, argumentKeys: ["headline", "questions"]))
    }

    /// `question` beside `questions` is genuinely ambiguous — the same doctrine that leaves
    /// `{question, form}` alone, and for the same reason: guessing drops one of them.
    func testAQuestionBesideAQuestionsArrayIsLeftAlone() {
        XCTAssertNil(
            SupervisorAskRouting.correctedName(
                for: ToolNames.askSupervisor, argumentKeys: ["question", "questions"]))
    }
}
