import XCTest
@testable import NanoTeams

/// F6 wave D2 (2026-11-12), live finding L5: the notice a step posts while it retries a failed
/// model request read «Could not connect to the server.. Retrying in 10s…» — the composer put a
/// period after the error's own description, which Foundation already ends with one. The person
/// reads it in the feed, the external agent in `task_status.steps[].llm_retry`.
@MainActor
final class LLMRetryNoticeTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    private let agent = AgentIdentity(
        id: UUID(uuidString: "eeeeeeee-4444-2222-3333-444444444441")!,
        label: "Claude Code"
    )

    /// Through the real run: the step's server refuses with `URLError(.cannotConnectToHost)`
    /// carrying the live text, «Could not connect to the server.».
    /// RED before D2: «…server.. Retrying in 10s…».
    func testTheNoticeOfAnUnreachableServer_hasOnePeriodBeforeRetrying() async throws {
        // The test host does not load Foundation's error strings (it reads «The operation
        // couldn’t be completed. (NSURLErrorDomain error -1004.)»), so the live sentence is the
        // error's own description here.
        sut.stopAllEngines()
        sut = TestOrchestrator.make(
            embeddingClient: embeddingClient, chatLifecycleClient: chatLifecycleClient,
            stepExecutionClient: FailingChatClient(error: URLError(
                .cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])))
        await sut.openWorkFolder(tempDir)
        let pipeline = try XCTUnwrap(sut.snapshot?.workFolder.teams.first { !$0.isChatMode && !$0.isHiddenFromPickers })
        await sut.mutateWorkFolder { $0.setActiveTeam(pipeline.id) }
        await sut.setAutovisorDriver(.externalAgent)
        await sut.setAutovisorEnabled(true)
        let folderID = try XCTUnwrap(sut.snapshot?.projection.id.uuidString)

        let created = await sut.executeExternalAutovisorTool(
            name: ExternalAutovisorToolNames.createManagedTask,
            args: ["folder_id": folderID, "title": "Calculator", "brief": "Build a calculator"],
            agent: agent)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(created.outputJSON.utf8)) as? [String: Any])
        let taskID = try XCTUnwrap((object["data"] as? [String: Any])?["task_id"] as? Int)

        var notice: String?
        await waitUntil("a step posts its retry notice") {
            let status = await self.sut.executeExternalAutovisorTool(
                name: ExternalAutovisorToolNames.taskStatus,
                args: ["folder_id": folderID, "task_id": taskID], agent: self.agent)
            guard let object = try? JSONSerialization.jsonObject(with: Data(status.outputJSON.utf8)) as? [String: Any],
                  let steps = (object["data"] as? [String: Any])?["steps"] as? [[String: Any]]
            else { return false }
            notice = steps.compactMap { $0["llm_retry"] as? String }.first
            return notice != nil
        }

        let text = try XCTUnwrap(notice)
        XCTAssertTrue(text.contains("Could not connect to the server."), "premise: the live error: \(text)")
        XCTAssertFalse(text.contains(".."), text)
        XCTAssertTrue(text.contains("server. Retrying in"), text)
    }
}

/// A model server that refuses every request with `error`.
private final class FailingChatClient: LLMClient, @unchecked Sendable {
    private let error: any Error
    init(error: any Error) { self.error = error }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { throw error }
}

/// The composer itself: the error's own closing mark is kept, a period is added only where it
/// has none.
final class LLMRetryNoticeCompositionTests: XCTestCase {

    func testAnErrorEndingWithAPeriod_getsNoSecondOne() {
        XCTAssertEqual(
            LLMRetryNotice.text(attempt: 2, maxRetries: 3, errorDescription: "Could not connect to the server.", delaySeconds: 10),
            "LLM server error (attempt 2/3): Could not connect to the server. Retrying in 10s…")
    }

    func testAnErrorWithNoClosingMark_getsAPeriod() {
        XCTAssertEqual(
            LLMRetryNotice.text(attempt: 1, maxRetries: 0, errorDescription: "HTTP 503", delaySeconds: 5),
            "LLM server error (attempt 1): HTTP 503. Retrying in 5s…",
            "0 retries means unlimited: no bound printed")
    }

    func testEachClosingMark_isKept() {
        for text in ["Rate limited!", "Is the server up?", "Timed out…"] {
            XCTAssertEqual(LLMRetryNotice.sentence(text), text)
        }
    }

    func testSurroundingWhitespace_isDropped_beforeTheMarkIsRead() {
        XCTAssertEqual(LLMRetryNotice.sentence("  The request timed out. \n"), "The request timed out.")
        XCTAssertEqual(LLMRetryNotice.sentence(" HTTP 500 \n"), "HTTP 500.")
    }

    /// A description that closes a parenthesis after its period (Foundation without its strings:
    /// «… (NSURLErrorDomain error -1004.)») takes one: «.).» is punctuation, «..» was the defect.
    func testAParenthesisAfterThePeriod_takesOne() {
        XCTAssertEqual(LLMRetryNotice.sentence("Failed. (code -1004.)"), "Failed. (code -1004.).")
    }

    func testAnEmptyDescription_staysEmpty() {
        XCTAssertEqual(LLMRetryNotice.sentence(" \n"), "")
    }
}
