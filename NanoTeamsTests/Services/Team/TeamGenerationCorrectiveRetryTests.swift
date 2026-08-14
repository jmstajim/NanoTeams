import XCTest
@testable import NanoTeams

/// `TeamGenerationService.generate`'s ONE corrective retry.
///
/// The retry shipped guarded by `!(error is GenerationError) && lastArgumentsJSON != nil`,
/// which is unsatisfiable: `lastArgumentsJSON` is set only on the three parse paths, and
/// every throw reachable from `decodeTeamConfig` is wrapped in
/// `GenerationError.invalidResponse`. The feature was dead from the day it was written and
/// no test noticed, because every existing test drives a SINGLE call.
///
/// These tests therefore assert the CALL COUNT, not just the outcome — an outcome-only
/// assertion passes with the retry disabled whenever the first attempt succeeds.
@MainActor
final class TeamGenerationCorrectiveRetryTests: XCTestCase {

    /// Yields one scripted response per call and records what it was asked.
    private final class ScriptedClient: LLMClient, @unchecked Sendable {
        /// `nil` element ⇒ throw for that call (`retryError`, else a transport timeout).
        var script: [String?] = []
        /// The error a `nil` script slot throws. Lets a test distinguish "the retry was
        /// cancelled" from "the retry failed" — the two must be reported differently.
        var retryError: Error?
        private(set) var calls: [[ChatMessage]] = []

        func streamChat(
            config: LLMConfig,
            messages: [ChatMessage],
            tools: [ToolSchema],
            logger: NetworkLogger?,
            stepID: String?,
            roleName: String?
        ) -> AsyncThrowingStream<StreamEvent, Error> {
            let index = calls.count
            calls.append(messages)
            let payload: String?? = index < script.count ? script[index] : .some(nil)
            let failure = retryError
            return AsyncThrowingStream { continuation in
                guard let body = payload ?? nil else {
                    continuation.finish(throwing: failure ?? URLError(.timedOut))
                    return
                }
                continuation.yield(StreamEvent(toolCallDeltas: [
                    StreamEvent.ToolCallDelta(
                        index: 0, id: "call_1", name: ToolNames.createTeam,
                        argumentsDelta: body)
                ]))
                continuation.finish()
            }
        }

        func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [String] { [] }
    }

    // MARK: - Fixtures

    /// Valid in every respect EXCEPT a misspelled `supervisor_mode`, which
    /// `GeneratedTeamConfig.init(from:)` rejects outright — a defect no fallback and no
    /// synthesized default can paper over, so the only way past it is the model fixing it.
    private let badMode = """
        {"name":"T","description":"d","roles":[{"name":"Eng","prompt":"p",\
        "produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],"tools":[]}],\
        "artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"],\
        "supervisor_mode":"autnomous"}
        """

    private let good = """
        {"name":"T","description":"d","roles":[{"name":"Eng","prompt":"p",\
        "produces_artifacts":["Code"],"requires_artifacts":["Supervisor Task"],"tools":[]}],\
        "artifacts":[{"name":"Code","description":"c"}],"supervisor_requires":["Code"]}
        """

    // MARK: - The retry runs

    func testDecodeFailure_retriesOnce_andSucceeds() async throws {
        let client = ScriptedClient()
        client.script = [badMode, good]

        let build = try await TeamGenerationService.generate(
            taskDescription: "build a team", config: LLMConfig(), client: client)

        XCTAssertEqual(build.team.name, "T")
        XCTAssertEqual(client.calls.count, 2, "the corrective retry must actually be issued")
    }

    func testRetryPrompt_echoesThePayloadAndNamesTheDefect() async throws {
        let client = ScriptedClient()
        client.script = [badMode, good]

        _ = try await TeamGenerationService.generate(
            taskDescription: "build a team", config: LLMConfig(), client: client)

        let retry = try XCTUnwrap(client.calls.last)
        // The model's own payload back, verbatim — anything vaguer reproduces the config.
        XCTAssertTrue(
            retry.contains { $0.role == .assistant && $0.content == badMode },
            "the retry must show the model its own rejected payload")
        let correction = try XCTUnwrap(
            retry.last(where: { $0.role == .user })?.content)
        XCTAssertTrue(correction.contains("rejected"), correction)
        XCTAssertTrue(
            correction.lowercased().contains("supervisor_mode"),
            "the correction must name the defect, not just say it failed: \(correction)")
    }

    // MARK: - The retry does NOT run

    func testTransportFailure_isNotRetried() async {
        let client = ScriptedClient()
        client.script = [nil, good]

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "build a team", config: LLMConfig(), client: client)
            XCTFail("expected the transport failure to surface")
        } catch {
            // Nothing to correct WITH — re-running verbatim would just pay the latency twice.
            XCTAssertEqual(client.calls.count, 1)
        }
    }

    func testFirstAttemptSucceeds_noRetry() async throws {
        let client = ScriptedClient()
        client.script = [good, good]

        _ = try await TeamGenerationService.generate(
            taskDescription: "build a team", config: LLMConfig(), client: client)

        XCTAssertEqual(client.calls.count, 1)
    }

    // MARK: - Cancellation must survive the retry

    /// The regression making the retry live introduced: `pauseRun` cancels team generation,
    /// and if that lands during the (multi-second) retry, returning attempt 1's parse error
    /// makes `TeamGenerationService.isCancellation` read false — so `runTeamGeneration`
    /// marks the step `.failed` instead of `.paused` and shows the user an error banner for
    /// an action they took themselves. Before the retry existed there was a single stream,
    /// so a cancellation always reached the classifier intact.
    func testCancellationDuringRetry_surfacesAsCancellation_notTheFirstParseError() async {
        let client = ScriptedClient()
        client.script = [badMode, nil]          // nil ⇒ the retry's stream throws
        client.retryError = CancellationError()

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "build a team", config: LLMConfig(), client: client)
            XCTFail("expected the cancellation to surface")
        } catch {
            XCTAssertTrue(
                TeamGenerationService.isCancellation(error),
                "a Pause during the retry must reach the classifier, got \(error)")
            XCTAssertFalse(
                "\(error)".lowercased().contains("supervisor_mode"),
                "attempt 1's parse error must not mask the cancellation")
        }
    }

    /// `URLSession` reports a cancelled streaming task as `URLError.cancelled`, not
    /// `CancellationError` — the classifier accepts both, so the retry arm must too.
    func testURLCancellationDuringRetry_alsoSurfacesAsCancellation() async {
        let client = ScriptedClient()
        client.script = [badMode, nil]
        client.retryError = URLError(.cancelled)

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "build a team", config: LLMConfig(), client: client)
            XCTFail("expected the cancellation to surface")
        } catch {
            XCTAssertTrue(TeamGenerationService.isCancellation(error), "\(error)")
        }
    }

    /// Nothing between attempt 1 returning and the retry's request consults cancellation,
    /// so a cancel that lands while the parse cascade runs would still spend a second LLM
    /// request on a run the user stopped.
    func testAlreadyCancelled_doesNotIssueTheRetry() async {
        let client = ScriptedClient()
        client.script = [badMode, good]

        let task = Task {
            try await TeamGenerationService.generate(
                taskDescription: "build a team", config: LLMConfig(), client: client)
        }
        task.cancel()
        let result = await task.result

        if case .success = result { XCTFail("expected cancellation, got success") }
        XCTAssertLessThanOrEqual(
            client.calls.count, 1, "no second request after the user cancelled")
    }

    func testRetryAlsoFails_reportsTheFirstError_andStopsAtTwo() async {
        let client = ScriptedClient()
        client.script = [badMode, badMode, good]

        do {
            _ = try await TeamGenerationService.generate(
                taskDescription: "build a team", config: LLMConfig(), client: client)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(client.calls.count, 2, "exactly one retry, never a loop")
            // The FIRST error describes the model's own config; the retry's may describe a
            // different, less representative one.
            XCTAssertTrue(
                "\(error)".lowercased().contains("supervisor_mode"), "\(error)")
        }
    }
}
