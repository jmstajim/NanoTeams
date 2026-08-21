import XCTest

@testable import NanoTeams

/// Exercises `WorkFolderContextService.generate`'s context-aware sizing:
/// the probe→budget→compose flow, the halve-and-retry overflow backstop, and
/// the actionable `contextWindowTooSmall` error when even the floored prompt
/// won't fit.
final class WorkFolderContextGenerationServiceTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // A big folder: long README (excerpt) + many source files (list) so a
        // small context budget produces a visibly shorter prompt. The README is
        // large enough that even a mid-size context must trim it, so halving the
        // budget on retry shrinks the prompt further.
        let readme = (0..<1000).map { "readme line \($0)" }.joined(separator: "\n")
        try readme.write(to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let srcDir = tempDir.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for i in 0..<200 {
            try "let x\(i) = \(i)\n".write(to: srcDir.appendingPathComponent("file\(i).swift"),
                                           atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeConfig() -> LLMConfig {
        LLMConfig(baseURLString: "http://localhost:1234", modelName: "m")
    }

    // MARK: - Probe → prompt shrink

    func testGenerate_smallContext_producesShorterPromptThanLarge() async throws {
        let big = ScriptedLLMClient(contextLength: 262144, successContent: "ok")
        _ = try await WorkFolderContextService(client: big).generate(workFolderRoot: tempDir, config: makeConfig())

        let small = ScriptedLLMClient(contextLength: 1024, successContent: "ok")
        _ = try await WorkFolderContextService(client: small).generate(workFolderRoot: tempDir, config: makeConfig())

        let bigMsg = try XCTUnwrap(big.capturedUserMessages.first)
        let smallMsg = try XCTUnwrap(small.capturedUserMessages.first)
        XCTAssertLessThan(smallMsg.count, bigMsg.count,
                          "A smaller probed context must yield a trimmed (shorter) prompt.")
    }

    func testGenerate_nilProbe_stillGenerates() async throws {
        let client = ScriptedLLMClient(contextLength: nil, successContent: "generated context")
        let result = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())
        XCTAssertEqual(result, "generated context")
        XCTAssertEqual(client.callCount, 1)
    }

    // MARK: - Overflow retry backstop

    func testGenerate_contextOverflow_retriesOnceWithHalvedBudget() async throws {
        let overflow = LLMClientError.providerError(
            "The number of tokens to keep from the initial prompt is greater than the context length."
        )
        // Mid-size context so attempt 1 already trims the 1000-line README (not
        // at the 50-line floor), leaving room for the halved retry to shrink more.
        let client = ScriptedLLMClient(contextLength: 4096, successContent: "recovered")
        client.errorScript = [overflow, nil] // fail attempt 1, succeed attempt 2

        let result = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(client.callCount, 2, "Exactly one retry after the overflow.")
        let first = try XCTUnwrap(client.capturedUserMessages.first)
        let second = try XCTUnwrap(client.capturedUserMessages.last)
        XCTAssertLessThan(second.count, first.count,
                          "The retry must re-compose with a halved budget → shorter prompt.")
    }

    func testGenerate_secondOverflow_throwsContextWindowTooSmall() async {
        let overflow = LLMClientError.providerError("context length exceeded, provide a shorter input")
        let client = ScriptedLLMClient(contextLength: 8192, successContent: "unused")
        client.errorScript = [overflow, overflow]

        do {
            _ = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())
            XCTFail("Expected contextWindowTooSmall")
        } catch let WorkFolderContextError.contextWindowTooSmall(modelName, _) {
            XCTAssertEqual(modelName, "m")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(client.callCount, 2, "Retry is bounded — never more than 2 attempts.")
    }

    func testGenerate_nonOverflowError_rethrowsImmediately() async {
        let boom = LLMClientError.providerError("Model crashed")
        let client = ScriptedLLMClient(contextLength: 8192, successContent: "unused")
        client.errorScript = [boom]

        do {
            _ = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())
            XCTFail("Expected the raw error")
        } catch let LLMClientError.providerError(message) {
            XCTAssertEqual(message, "Model crashed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(client.callCount, 1, "A non-overflow error must NOT trigger a retry.")
    }

    // MARK: - Corner cases

    func testGenerate_cancellation_propagates_notClassifiedAsOverflow() async {
        let client = ScriptedLLMClient(contextLength: 8192, successContent: "unused")
        client.errorScript = [CancellationError()]

        do {
            _ = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected — must NOT be turned into contextWindowTooSmall or retried
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(client.callCount, 1, "Cancellation must not trigger the overflow retry.")
    }

    func testGenerate_emptyModelOutput_returnsNil() async throws {
        let client = ScriptedLLMClient(contextLength: 8192, successContent: "   \n\t  ")
        let result = try await WorkFolderContextService(client: client).generate(workFolderRoot: tempDir, config: makeConfig())
        XCTAssertNil(result, "Whitespace-only output → nil (unchanged contract).")
    }

    func testGenerate_customPrompt_usedAsSystemMessage() async throws {
        let client = ScriptedLLMClient(contextLength: 262144, successContent: "ok")
        _ = try await WorkFolderContextService(client: client)
            .generate(workFolderRoot: tempDir, config: makeConfig(), customPrompt: "MY CUSTOM SYSTEM PROMPT")
        XCTAssertTrue(client.capturedSystemMessages.contains("MY CUSTOM SYSTEM PROMPT"),
                      "A non-empty custom prompt must override the default system prompt.")
    }
}

/// LLM client double that records the user message per `streamChat`, returns a
/// scripted context length, and can throw a scripted error per call.
private final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    let contextLength: Int?
    let successContent: String
    var errorScript: [Error?] = []
    private(set) var callCount = 0
    private(set) var capturedUserMessages: [String] = []
    private(set) var capturedSystemMessages: [String] = []

    init(contextLength: Int?, successContent: String) {
        self.contextLength = contextLength
        self.successContent = successContent
    }

    func modelContextLength(config: LLMConfig) async -> Int? { contextLength }

    func streamChat(
        config: LLMConfig,
        messages: [ChatMessage],
        tools: [ToolSchema],
        logger: NetworkLogger?,
        stepID: String?,
        roleName: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let index = callCount
        callCount += 1
        if let userMessage = messages.first(where: { $0.role == .user })?.content {
            capturedUserMessages.append(userMessage)
        }
        if let systemMessage = messages.first(where: { $0.role == .system })?.content {
            capturedSystemMessages.append(systemMessage)
        }
        let error: Error? = index < errorScript.count ? errorScript[index] : nil
        let content = successContent
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.yield(StreamEvent(contentDelta: content))
                continuation.finish()
            }
        }
    }

    func fetchModels(config: LLMConfig, visionOnly: Bool) async throws -> [LLMModelInfo] { [] }
}
