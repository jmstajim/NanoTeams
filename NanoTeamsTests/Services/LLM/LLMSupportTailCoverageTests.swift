import Foundation
import XCTest

@testable import NanoTeams

// =============================================================================
// MARK: - Shared doubles (prefixed so they cannot collide with another suite)
// =============================================================================

/// Error with a distinguishable `localizedDescription`, so an assertion on a
/// wrapped message can't accidentally pass on a different error.
private enum DLLMError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "dllm-boom-42" }
}

/// Two-phase rendezvous used to freeze an async call in flight (an unload, a
/// model-list fetch) so a test can observe the state that exists ONLY while it
/// is suspended. `@unchecked Sendable` + `NSLock` mirrors the existing
/// `RecordingLLMClient` shape.
private final class DLLMGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private var _released = false

    var isEntered: Bool { lock.withLock { _entered } }

    func release() { lock.withLock { _released = true } }

    /// Called from inside the frozen production call.
    /// The give-up budget is deliberately LARGE. It exists only so a test that
    /// forgets to `release()` fails instead of hanging forever — it must never be
    /// the thing that ends the freeze in a healthy run. At 5 s it was: under
    /// coverage instrumentation the holder timed out while the test was still
    /// waiting for the ensure to park, the unload completed, and the ensure took
    /// the ordinary adopt-or-load path — reported as a flaky failure of the
    /// assertion below it, twice, at the cost of a five-minute instrumented run
    /// each time.
    func hold() async {
        lock.withLock { _entered = true }
        for _ in 0..<30_000 {
            if lock.withLock({ _released }) { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Called from the test; returns once the production call is frozen.
    func waitUntilEntered() async {
        for _ in 0..<30_000 {
            if isEntered { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Minimal `LLMClient` whose chat stream fails with `DLLMError.boom`, for the
/// judges' transport-failure arms. (The error is a concrete `Sendable` enum,
/// not `any Error`, so the double can satisfy `LLMClient: Sendable`.)
private final class DLLMThrowingChatClient: LLMClient, @unchecked Sendable {

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DLLMError.boom)
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }
}

/// `LLMClient` that returns a scripted model list, frozen on a gate so a test
/// can observe the in-flight state.
private final class DLLMModelListClient: LLMClient, @unchecked Sendable {
    let models: [String]
    let gate: DLLMGate

    init(models: [String], gate: DLLMGate) {
        self.models = models
        self.gate = gate
    }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] {
        await gate.hold()
        return models
    }
}

/// `LLMClient` whose `listLoadedInstances` replays a script, one entry per call
/// (last entry repeats). Unlike `RecordingLLMClient` it does NOT prune the
/// listing on unload, so a test can model "the server acked but the instance is
/// still resident" — the window `awaitInstanceGone` exists for.
private final class DLLMSettleClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[LoadedModelInstance]]
    private var _listCallCount = 0
    private var _unloadCallCount = 0

    init(listingScript: [[LoadedModelInstance]]) {
        self.script = listingScript
    }

    var listCallCount: Int { lock.withLock { _listCallCount } }
    var unloadCallCount: Int { lock.withLock { _unloadCallCount } }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [String] { [] }

    func unloadModel(instanceID _: String, baseURLString _: String) async throws {
        lock.withLock { _unloadCallCount += 1 }
    }

    func listLoadedInstances(baseURLString _: String) async throws -> [LoadedModelInstance] {
        lock.withLock { () -> [LoadedModelInstance] in
            let index = _listCallCount
            _listCallCount += 1
            guard !script.isEmpty else { return [] }
            return index < script.count ? script[index] : script[script.count - 1]
        }
    }
}

/// `NetworkSession` that always answers with a NON-HTTP `URLResponse`, the one
/// shape every client turns into `missingResponse`.
private struct DLLMNonHTTPSession: NetworkSession {
    func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        (
            Data(),
            URLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil)
        )
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw DLLMError.boom
    }
}

/// `NetworkSession` whose byte stream fails before any bytes flow. `kind` is a
/// concrete `Sendable` enum rather than `any Error` so the struct stays
/// `Sendable` (which `NetworkSession` requires).
private struct DLLMFailingBytesSession: NetworkSession {
    enum Kind: Sendable { case cancellation, transport }

    let kind: Kind

    private func makeError() -> Error {
        switch kind {
        case .cancellation: return CancellationError()
        case .transport: return DLLMError.boom
        }
    }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw makeError()
    }

    func sessionBytes(for _: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw makeError()
    }
}

/// Replays canned NDJSON as a real `URLSession.AsyncBytes` (no public
/// initializer exists, so a `data:` URL is the only route). Same technique as
/// `OllamaStreamChatTests.NDJSONBytesSession`, which is file-private there.
private final class DLLMNDJSONSession: NetworkSession, @unchecked Sendable {
    let ndjson: String

    init(ndjson: String) { self.ndjson = ndjson }

    func sessionData(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw DLLMError.boom
    }

    func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let dataURL = URL(
            string: "data:application/x-ndjson;base64," + Data(ndjson.utf8).base64EncodedString())!
        let (bytes, _) = try await URLSession.shared.bytes(from: dataURL)
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (bytes, http)
    }
}

/// `SecureTokenStorage` whose WRITES fail. `InMemorySecureTokenStorage` only
/// exposes a read-error hook, so the write-failure arm needs its own double.
private struct DLLMWriteFailingTokenStorage: SecureTokenStorage {
    func setToken(_: String?, forKey _: String) throws { throw DLLMError.boom }
    func loadToken(forKey _: String) throws -> String? { nil }
}

// =============================================================================
// MARK: - EmbeddingModelLifecycleService — swap-path reap, and the swap error
// =============================================================================

@MainActor
final class DLLMEmbeddingLifecycleTailTests: XCTestCase {

    var client: RecordingLLMClient!
    var sut: EmbeddingModelLifecycleService!

    private let configA = EmbeddingConfig(baseURLString: "http://127.0.0.1:1234", modelName: "model-a")
    private let configB = EmbeddingConfig(baseURLString: "http://127.0.0.1:1234", modelName: "model-b")

    override func setUp() {
        super.setUp()
        client = RecordingLLMClient()
        sut = EmbeddingModelLifecycleService(client: client)
    }

    override func tearDown() {
        sut = nil
        client = nil
        super.tearDown()
    }

    /// Swap path with the server's listing DOWN. The prior model's siblings
    /// cannot be enumerated, so they may linger — and that is precisely the
    /// state that produced the live `nomic:2`/`nomic:3` pile-up, so it must not
    /// pass silently. The swap itself still has to complete.
    ///
    /// The reap warning is asserted SPECIFICALLY (it is the only one that names
    /// "reap duplicates"); the adoption-probe failure emits its own, different
    /// warning on the same call, so asserting merely "some warning" would pass
    /// with the reap branch deleted.
    ///
    /// RED: delete the `onWarning?` call in `reapSiblingInstances`'s
    /// `guard let listed = try? …` else-branch -> the "reap duplicates of
    /// 'model-a'" assertion fails (the adoption warning survives, which is what
    /// makes the specific match load-bearing).
    func testSwapWhileListingIsDown_warnsThatPriorSiblingsCouldNotBeEnumerated() async throws {
        client.loadResults = ["instance-a", "instance-b"]
        try await sut.ensureLoaded(configA)

        var warnings: [String] = []
        sut.onWarning = { warnings.append($0) }
        client.listLoadedInstancesError = DLLMError.boom

        try await sut.ensureLoaded(configB)

        // The swap completed — we passed THROUGH the reap, not around it.
        XCTAssertEqual(sut.loaded?.config, configB)
        XCTAssertEqual(sut.loaded?.instanceID, "instance-b")

        let reapWarnings = warnings.filter { $0.contains("reap duplicates") }
        XCTAssertEqual(
            reapWarnings.count, 1,
            "A listing failure during the swap-path reap must surface exactly one warning; got \(warnings)")
        let reap = try XCTUnwrap(reapWarnings.first)
        XCTAssertTrue(
            reap.contains("'model-a'"),
            "The warning must name the PRIOR model whose duplicates went un-reaped, not the new one")
        XCTAssertTrue(
            reap.contains("http://127.0.0.1:1234"),
            "…and the server it could not enumerate")
        XCTAssertFalse(
            reap.contains("'model-b'"),
            "The new model was never listed, so naming it would be a false claim")
    }

    /// The swap-failure error is the user's only explanation for a swap that
    /// refused to complete; it must name the model that may still hold VRAM and
    /// state that local state was kept (which is why a retry can finish the job).
    ///
    /// RED: drop `prior.modelName` from the interpolation (or change "Local
    /// state preserved" to "State cleared") -> the corresponding
    /// `XCTAssertTrue(description.contains(...))` fails.
    func testPriorUnloadFailedDuringSwap_errorDescriptionNamesModelAndPreservation() async {
        let underlying = DLLMError.boom
        let error = EmbeddingLifecycleError.priorUnloadFailedDuringSwap(
            prior: configA, underlying: underlying)

        let description = error.errorDescription ?? ""

        XCTAssertTrue(
            description.contains("model-a"),
            "Without the model name the user can't tell which instance may still be resident")
        XCTAssertTrue(
            description.contains(underlying.localizedDescription),
            "The underlying cause must survive the wrap, or the message is unactionable")
        XCTAssertTrue(
            description.contains("Local state preserved"),
            "The retry contract (state kept so the swap can be completed) is the point of this case")
        XCTAssertEqual(
            description, error.localizedDescription,
            "LocalizedError conformance must be what the UI surfaces")
    }
}

// =============================================================================
// MARK: - BashJudgeService — the NARROW-read confinement sentence
// =============================================================================

/// The judge reasons about the sandbox we DESCRIBE, not the one that runs. The
/// broad-read branch was covered; the narrow branch (`everythingElseRead ==
/// false`) was not, and it is the branch that fires exactly when the user has
/// locked reads down.
final class DLLMBashJudgeNarrowReadTests: XCTestCase {

    private func policy(
        workFolderRead: Bool = true,
        tempRead: Bool = true,
        homeRead: Bool = false,
        credentialRead: Bool = false,
        sandboxEnabled: Bool = true
    ) -> BashPolicy {
        BashPolicy(
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: BashSandboxPermissions(
                workFolderRead: workFolderRead,
                workFolderWrite: true,
                tempRead: tempRead,
                tempWrite: true,
                credentialRead: credentialRead,
                homeRead: homeRead,
                homeWrite: false,
                everythingElseRead: false,
                everythingElseWrite: false
            )
        )
    }

    /// RED: swap the `scopes.isEmpty` ternary's arms, or change "restricted to"
    /// -> the `hasSuffix` assertion fails.
    func testNarrowRead_singleScope_namesOnlyThatScope() {
        let sentence = BashJudgeService.sandboxConfinementDescription(
            policy: policy(workFolderRead: true, tempRead: false))

        XCTAssertTrue(
            sentence.hasSuffix("; reads are restricted to the project work folder."),
            "got: \(sentence)")
        XCTAssertFalse(
            sentence.contains("reads are broad"),
            "A narrow-read policy must never be described as broad — that is the under-scrutiny direction")
    }

    /// Order is part of the contract: the sentence is assembled work -> temp ->
    /// home -> credentials, so a reordering is a visible prompt-byte change.
    ///
    /// RED: move `if p.credentialRead` above `if p.workFolderRead` -> the exact
    /// suffix assertion fails.
    func testNarrowRead_allScopesGranted_listsThemInWorkTempHomeCredentialOrder() {
        let sentence = BashJudgeService.sandboxConfinementDescription(
            policy: policy(workFolderRead: true, tempRead: true, homeRead: true, credentialRead: true))

        XCTAssertTrue(
            sentence.hasSuffix(
                "; reads are restricted to the project work folder and temp directories "
                    + "and your home folder and credential stores."),
            "got: \(sentence)")
    }

    /// Every read scope off. "blocked everywhere" is the only honest phrasing —
    /// an empty "restricted to " tail would read as unrestricted.
    ///
    /// RED: delete the `scopes.isEmpty` arm and always use the join -> the
    /// sentence ends with "reads are restricted to ." and both assertions fail.
    func testNarrowRead_noScopes_saysBlockedEverywhere() {
        let sentence = BashJudgeService.sandboxConfinementDescription(
            policy: policy(workFolderRead: false, tempRead: false, homeRead: false, credentialRead: false))

        XCTAssertTrue(sentence.hasSuffix("; reads are blocked everywhere."), "got: \(sentence)")
        XCTAssertFalse(sentence.contains("restricted to"))
    }

    /// With the sandbox OFF the same read clause must still be stated — as the
    /// user's INTENDED policy — and paired with the deny instruction. Dropping
    /// the clause here would leave the judge with "anything goes", which is the
    /// documented under-scrutiny failure.
    ///
    /// RED: replace the `\(readClause)` interpolation in the sandbox-off return
    /// with a fixed string -> the "restricted to the project work folder"
    /// assertion fails.
    func testNarrowRead_sandboxOff_stillStatesTheIntendedReadScopeAndDeniesOutsideIt() {
        let sentence = BashJudgeService.sandboxConfinementDescription(
            policy: policy(workFolderRead: true, tempRead: false, sandboxEnabled: false))

        XCTAssertTrue(sentence.contains("There is no sandbox enforcing limits"), "got: \(sentence)")
        XCTAssertTrue(
            sentence.contains("reads are restricted to the project work folder"),
            "The intended read policy must still reach the judge when nothing enforces it")
        XCTAssertTrue(
            sentence.contains("DENY"),
            "Without the deny instruction an unenforced policy is advisory only")
    }

    /// The narrow-read clause is spliced into the live judge system prompt, not
    /// just returned by the helper — the two would otherwise be free to drift.
    ///
    /// RED: drop the `\(sandboxConfinementDescription(policy: policy))`
    /// interpolation from `judgeSystemPrompt` -> the `contains` assertion fails.
    func testNarrowRead_reachesTheJudgeSystemPrompt() {
        let p = policy(workFolderRead: true, tempRead: false)
        let prompt = BashJudgeService.judgeSystemPrompt(policy: p)

        XCTAssertTrue(
            prompt.contains(BashJudgeService.sandboxConfinementDescription(policy: p)),
            "The confinement sentence must ship verbatim inside the judge's system prompt")
    }
}

// =============================================================================
// MARK: - ComputerUseJudgeService — transport failure denies
// =============================================================================

final class DLLMComputerUseJudgeTransportTests: XCTestCase {

    /// Deny-on-uncertainty: a judge call that never produced a verdict must
    /// resolve to DENY and say why, or an unreachable judge silently becomes an
    /// approval channel.
    ///
    /// RED: change `Decision(allowed: false, …)` in the catch to
    /// `allowed: true` -> `XCTAssertFalse(decision.allowed)` fails.
    func testJudge_transportFailure_deniesAndNamesTheUnderlyingCause() async {
        let decision = await ComputerUseJudgeService.judge(
            action: .click(x: 10, y: 20, button: "left", double: false, target: "Safari"),
            policy: ComputerUsePolicy(mode: .auto, restrictionLevel: .standard),
            config: LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234", modelName: "m"),
            client: DLLMThrowingChatClient()
        )

        XCTAssertFalse(decision.allowed, "A failed judge call must never allow the action")
        XCTAssertTrue(
            decision.reason.contains("dllm-boom-42"),
            "The transport cause must reach the user; got: \(decision.reason)")
        XCTAssertTrue(
            decision.reason.contains("denied for safety"),
            "The reason must state the fail-closed rule; got: \(decision.reason)")
    }
}

// =============================================================================
// MARK: - OllamaClient — end-of-transport drain and cancellation
// =============================================================================

final class DLLMOllamaStreamTailTests: XCTestCase {

    private func config() -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: "http://127.0.0.1:11434", modelName: "m")
    }

    /// A stream that dies INSIDE a `<think>` block leaves the splitter holding a
    /// partial `</thi` close-tag prefix. `finalize()` at transport end is the
    /// only thing that surfaces it; without it the tail is silently dropped.
    ///
    /// (The pre-existing "connection drop" test cannot reach this: once real
    /// content has flowed, `ThinkTagSplitter` takes its pass-through fast path
    /// and holds nothing back, so its `finalize()` returns no events at all.)
    ///
    /// RED: delete the `for event in parser.finalize() { try handle(event) }`
    /// loop -> thinking is "abc" and the equality assertion fails.
    func testStreamDiesInsideThinkBlock_finalizeSurfacesTheHeldCloseTagPrefix() async {
        let ndjson = #"{"message":{"content":"<think>abc</thi"},"done":false}"#
        let client = OllamaClient(
            session: DLLMNDJSONSession(ndjson: ndjson), tokenResolver: StubLLMTokenResolver())

        var content = ""
        var thinking = ""
        var failure: Error?
        do {
            for try await event in client.streamChat(
                config: config(),
                messages: [ChatMessage(role: .user, content: "hi")],
                tools: [],
                logger: nil,
                stepID: nil
            ) {
                content += event.contentDelta
                thinking += event.thinkingDelta
            }
        } catch {
            failure = error
        }

        XCTAssertNil(failure)
        XCTAssertEqual(
            thinking, "abc</thi",
            "The held-back partial close tag must be flushed at transport end, not dropped")
        XCTAssertEqual(content, "", "Nothing escaped the think block onto the content channel")
    }

    /// A cancelled request is not a transport failure: it rethrows
    /// `CancellationError` so the cooperative tree unwinds, and it must NOT
    /// write an error record into `network_log.json` — Pause happens on every
    /// run, and logging it as a failure would bury the real ones.
    ///
    /// RED: delete the `catch is CancellationError` arm -> the generic arm
    /// appends a `.response` record and `XCTAssertEqual(records.count, 1)` fails.
    func testTransportCancellation_rethrowsCancellationAndWritesNoErrorRecord() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dllm-ollama-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)

        let client = OllamaClient(
            session: DLLMFailingBytesSession(kind: .cancellation),
            tokenResolver: StubLLMTokenResolver())

        var failure: Error?
        do {
            for try await _ in client.streamChat(
                config: config(),
                messages: [ChatMessage(role: .user, content: "hi")],
                tools: [],
                logger: logger,
                stepID: "step-1"
            ) {}
        } catch {
            failure = error
        }

        XCTAssertTrue(
            failure is CancellationError,
            "Cancellation must propagate as CancellationError, got \(String(describing: failure))")

        let data = try Data(contentsOf: logURL)
        let records = try JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(
            records.count, 1,
            "Only the request record belongs in the log; a cancel is not a failed response")
        let only = try XCTUnwrap(records.first)
        XCTAssertEqual(only.direction, .request)
    }
}

// =============================================================================
// MARK: - PromptBuilder — pipeline / artifact context tails
// =============================================================================

final class DLLMPromptBuilderContextTailTests: XCTestCase {

    /// A step can carry a Supervisor ANSWER with no live question — the question
    /// slot is single-use and is cleared/replaced on the next park, while the
    /// answer stays for the feed. Downstream roles must still see what the
    /// Supervisor said; dropping it loses the only record of a human decision.
    ///
    /// RED: delete the `else if let a = step.effectiveSupervisorAnswer` arm ->
    /// the "Supervisor A:" assertion fails.
    func testPipelineContext_answerWithoutQuestion_stillRendersTheAnswer() {
        let prior = StepExecution(
            id: "pm", role: .productManager, title: "PM", status: .done,
            supervisorQuestion: nil, supervisorAnswer: "Ship the smaller scope.")
        let current = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE")
        let run = Run(id: 0, steps: [prior, current])

        let text = PromptBuilder.buildPipelineContext(
            run: run, upToStepIndex: 1, artifactReader: { _ in nil })

        XCTAssertTrue(
            text.contains("Supervisor A: Ship the smaller scope."),
            "got: \(text)")
        XCTAssertFalse(
            text.contains("Supervisor Q:"),
            "There was no question — inventing an empty Q line would be a false transcript")
    }

    /// Amendments are the record that a downstream role forced a revision. They
    /// must reach later roles with the reason, the requester and the decision —
    /// a bare count would tell the model nothing actionable.
    ///
    /// RED: delete the `for amendment in step.amendments` loop -> the reason /
    /// requester / decision assertions fail while the count line survives, which
    /// is exactly why they are asserted separately.
    func testPipelineContext_amendments_renderCountAndEachReasonWithAttribution() {
        let amendment = StepAmendment(
            requestedByRoleID: "code_reviewer",
            reason: "Handle the empty-input case",
            meetingDecision: "approved")
        let prior = StepExecution(
            id: "pm", role: .productManager, title: "PM", status: .done,
            amendments: [amendment])
        let current = StepExecution(id: "swe", role: .softwareEngineer, title: "SWE")
        let run = Run(id: 0, steps: [prior, current])

        let text = PromptBuilder.buildPipelineContext(
            run: run, upToStepIndex: 1, artifactReader: { _ in nil })

        XCTAssertTrue(text.contains("Amendments: 1"), "got: \(text)")
        XCTAssertTrue(text.contains("Handle the empty-input case"), "got: \(text)")
        XCTAssertTrue(text.contains("code_reviewer"), "got: \(text)")
        XCTAssertTrue(text.contains("approved"), "got: \(text)")
    }

    /// An unreadable required artifact must be reported as unavailable, NOT
    /// silently omitted: a downstream role that sees the heading and no marker
    /// has no way to tell "empty deliverable" from "file gone".
    ///
    /// RED: change `"(content not available)"` to `""`, or drop the else-branch
    /// -> the assertion fails, and the distinctness assertion below catches a
    /// change that collapses it onto the empty-content wording.
    func testRequiredArtifacts_unreadableArtifact_saysContentNotAvailable() throws {
        let artifact = Artifact(name: "Design Spec", relativePath: "spec.md")

        let unreadable = try XCTUnwrap(
            PromptBuilder.buildRequiredArtifactsSection(
                artifacts: [artifact], artifactReader: { _ in nil }))
        let empty = try XCTUnwrap(
            PromptBuilder.buildRequiredArtifactsSection(
                artifacts: [artifact], artifactReader: { _ in "   \n " }))

        XCTAssertTrue(unreadable.contains("### Design Spec"), "got: \(unreadable)")
        XCTAssertTrue(unreadable.contains("(content not available)"), "got: \(unreadable)")
        XCTAssertTrue(empty.contains("(empty content)"), "got: \(empty)")
        XCTAssertNotEqual(
            unreadable, empty,
            "\"unreadable\" and \"empty\" are different facts and must render differently")
    }
}

// =============================================================================
// MARK: - MeetingCoordinator — the middle rung of the conciseness ladder
// =============================================================================

final class DLLMMeetingTurnDirectiveTests: XCTestCase {

    /// Discussion Club tightens the length budget as the meeting runs down:
    /// first half 3-5 sentences, second half 2-3, final two turns 1-2. The
    /// middle rung was the untested one.
    ///
    /// RED: change the `turnNumber > maxTurns / 2` rung's string, or make it
    /// fall through to the 3-5 default -> the mid-meeting assertions fail while
    /// the boundary ones still pass, isolating the rung.
    func testDiscussionClub_concisenessLadder_hasThreeDistinctRungs() {
        func directive(_ turn: Int) -> String {
            MeetingCoordinator.turnDirective(
                speakerName: "The Agreeable",
                turnNumber: turn,
                maxTurns: 10,
                isCoordinator: false,
                isDiscussionClub: true)
        }

        XCTAssertTrue(directive(3).contains("3-5 sentences."), "early turn: \(directive(3))")
        XCTAssertTrue(directive(5).contains("3-5 sentences."), "maxTurns/2 is still early: \(directive(5))")

        for turn in 6...8 {
            XCTAssertTrue(
                directive(turn).contains("2-3 sentences. Be very concise."),
                "turn \(turn) is past halfway but not final: \(directive(turn))")
            XCTAssertFalse(directive(turn).contains("3-5 sentences."), "turn \(turn)")
            XCTAssertFalse(directive(turn).contains("Final remarks only."), "turn \(turn)")
        }

        XCTAssertTrue(directive(9).contains("1-2 sentences max. Final remarks only."), "\(directive(9))")
        XCTAssertTrue(directive(10).contains("Final remarks only."), "\(directive(10))")
    }

    /// Every rung carries the turn counter and addresses the speaker — that is
    /// what moved out of the (cache-critical) system prompt into this recency
    /// slot, so losing it on one rung is a silent regression.
    func testDiscussionClub_everyRungKeepsCounterAndSpeaker() {
        for turn in 1...10 {
            let text = MeetingCoordinator.turnDirective(
                speakerName: "The Neurotic",
                turnNumber: turn,
                maxTurns: 10,
                isCoordinator: false,
                isDiscussionClub: true)
            XCTAssertTrue(text.hasPrefix("Turn \(turn) of 10."), "turn \(turn): \(text)")
            XCTAssertTrue(text.contains("The Neurotic"), "turn \(turn): \(text)")
        }
    }
}

// =============================================================================
// MARK: - ChatModelEnsurer — reclaim failure, settle, and adopt-a-corpse guard
// =============================================================================

final class DLLMChatModelEnsurerTailTests: XCTestCase, @unchecked Sendable {

    private let baseURL = "http://127.0.0.1:1234"

    /// A duplicate-reap whose unload fails must report the failure, not report
    /// success — the caller decides whether to warn, and a swallowed error would
    /// make a leaking `:2` instance invisible forever.
    ///
    /// RED: change `return .failed(error)` to `return .unloaded` -> the
    /// `.failed` pattern match fails.
    func testReclaimUnownedDuplicate_unloadFails_reportsFailedWithTheUnderlyingError() async {
        let base = baseURL
        let client = RecordingLLMClient()
        client.unloadError = DLLMError.boom
        let sut = ChatModelEnsurer()

        let outcome = await sut.reclaimUnownedDuplicate(
            instanceID: "qwen:2", modelName: "qwen", baseURLString: base, client: client)

        guard case .failed(let error) = outcome else {
            return XCTFail("Expected .failed, got \(outcome)")
        }
        XCTAssertEqual((error as? DLLMError)?.errorDescription, "dllm-boom-42")
        XCTAssertTrue(
            client.calls.contains(.unload(instanceID: "qwen:2", baseURL: base)),
            "The unload must actually have been attempted")
    }

    /// LM Studio acks an unload BEFORE the memory comes back, so a reap that
    /// trusted the ack would let the replacement load fail with
    /// `model_load_failed`. The reap settles on the OBSERVABLE state: it keeps
    /// listing until the instance is gone.
    ///
    /// RED: delete the `await Self.awaitInstanceGone(…)` call in
    /// `reclaimUnownedDuplicate` -> `listCallCount` is 0 and the
    /// "polled until gone" assertion fails.
    func testReclaimUnownedDuplicate_settlesOnTheListingNotTheAck() async {
        let base = baseURL
        let stillThere = [LoadedModelInstance(modelName: "qwen", instanceID: "qwen:2")]
        let client = DLLMSettleClient(listingScript: [stillThere, []])
        let sut = ChatModelEnsurer()

        let outcome = await sut.reclaimUnownedDuplicate(
            instanceID: "qwen:2", modelName: "qwen", baseURLString: base, client: client)

        guard case .unloaded = outcome else {
            return XCTFail("Expected .unloaded, got \(outcome)")
        }
        XCTAssertEqual(client.unloadCallCount, 1)
        XCTAssertGreaterThanOrEqual(
            client.listCallCount, 2,
            "The reap must keep listing until the instance disappears, not stop at the 200")
    }

    /// While a reclaim of this exact model is in flight the instance is still
    /// listed but is about to die. Adopting it would return "already loaded" and
    /// send the request to a corpse — so the ensure waits the unload out and
    /// then loads properly.
    ///
    /// RED: delete `if let pendingUnload = unloading[key] { _ = try? await
    /// pendingUnload.value }` -> the ensure lists while the dying instance is
    /// still resident, adopts it, and `client.loadUnloadCalls` never gains a
    /// `.load`, failing the assertion.
    func testEnsureLoaded_whileAReclaimOfTheSameModelIsInFlight_waitsThenLoads() async throws {
        let base = baseURL
        let client = RecordingLLMClient()
        client.listLoadedInstancesResults = [
            LoadedModelInstance(modelName: "qwen", instanceID: "qwen")
        ]
        client.loadResults = ["qwen-fresh"]
        let gate = DLLMGate()
        client.unloadHold = { await gate.hold() }

        let sut = ChatModelEnsurer()
        let owned = OwnedChatModel(modelName: "qwen", baseURLString: base, instanceID: "qwen")

        let reclaimTask = Task { try? await sut.reclaim(owned, client: client) }
        await gate.waitUntilEntered()

        let ensureTask = Task { () -> EnsureOutcome? in
            try? await sut.ensureLoaded(modelName: "qwen", baseURLString: base, client: client)
        }
        // WAIT for the ensure to actually park on the pending unload — do not sleep
        // and hope. A fixed 30 ms lost the race under parallel load and again under
        // coverage instrumentation: the gate opened before the ensure had entered, the
        // unload completed, and the ensure then took the ordinary adopt-or-load path
        // instead of the one under test. The parked counter is the exact signal.
        var parked = 0
        for _ in 0..<4_000 {                     // ≤ 20 s, then fail loudly below
            parked = await sut._testEnsuresParkedOnPendingUnload
            if parked > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Diagnostics on the failure paths only. This test has now flaked three
        // times under coverage instrumentation and never once in isolation, and
        // each investigation started by NOT KNOWING which assertion fired —
        // `xcodebuild` strips XCTAssert messages. Writing the state to a file on
        // failure is the house workaround, and it costs nothing on a green run.
        if parked != 1 {
            try? "parked=\(parked) calls=\(client.loadUnloadCalls)"
                .write(to: URL(fileURLWithPath: "/tmp/w17_ensurer.txt"),
                       atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(
            parked, 1,
            "precondition: the ensure must have parked on the in-flight unload — "
                + "without it this test exercises the ordinary path")
        gate.release()

        _ = await reclaimTask.value
        let outcome = await ensureTask.value

        guard case .loaded(let instanceID)? = outcome else {
            try? "parked=\(parked) outcome=\(String(describing: outcome)) calls=\(client.loadUnloadCalls)"
                .write(to: URL(fileURLWithPath: "/tmp/w17_ensurer.txt"),
                       atomically: true, encoding: .utf8)
            return XCTFail(
                "The ensure must LOAD a fresh instance, not adopt the one being unloaded; got \(String(describing: outcome))")
        }
        XCTAssertEqual(instanceID, "qwen-fresh")
        XCTAssertTrue(
            client.loadUnloadCalls.contains(.load(model: "qwen", baseURL: base)),
            "got: \(client.loadUnloadCalls)")
    }
}

// =============================================================================
// MARK: - EffectiveToolset.Storage — the orchestrator-URL bridge
// =============================================================================

@MainActor
final class DLLMEffectiveToolsetStorageTests: XCTestCase {

    /// The rule that used to live inline in two preview sheets: no folder, or
    /// the app's own internal default-storage folder, is `.defaultStorage`.
    /// Getting this wrong offers write/git/xcode tools a role can never run.
    ///
    /// RED: drop the `url != NTMSOrchestrator.defaultStorageURL` term ->
    /// the default-storage-URL case resolves to `.realFolder` and fails.
    func testStorageFromOrchestratorURL_collapsesNilAndTheDefaultStorageFolder() async {
        XCTAssertEqual(EffectiveToolset.Storage.from(orchestratorURL: nil), .defaultStorage)
        XCTAssertEqual(
            EffectiveToolset.Storage.from(orchestratorURL: NTMSOrchestrator.defaultStorageURL),
            .defaultStorage,
            "The internal Application Support folder is NOT a user project folder")
    }

    /// RED: return `.defaultStorage` unconditionally -> this fails.
    func testStorageFromOrchestratorURL_realFolderCarriesTheRoot() async {
        let root = URL(fileURLWithPath: "/tmp/dllm-project", isDirectory: true)
        XCTAssertEqual(
            EffectiveToolset.Storage.from(orchestratorURL: root), .realFolder(root: root))
    }

    /// The two states must be distinguishable downstream — `applyStorageFilters`
    /// branches on them, and a `Hashable` collapse would silently merge them.
    func testStorage_defaultAndRealFolderAreDistinct() async {
        let root = URL(fileURLWithPath: "/tmp/dllm-project", isDirectory: true)
        XCTAssertNotEqual(EffectiveToolset.Storage.defaultStorage, .realFolder(root: root))
    }
}

// =============================================================================
// MARK: - ModelCatalog — the in-flight signal
// =============================================================================

@MainActor
final class DLLMModelCatalogFetchingTests: XCTestCase {

    /// `isFetching` is what the pickers render a spinner from, and it is keyed
    /// by (url, provider, visionOnly) — an override surface can pin a provider
    /// while inheriting the global URL, so one URL is legitimately probed twice.
    ///
    /// RED: make `isFetching` key on the URL alone (drop `provider` from
    /// `CacheKey`) -> the "other provider is not fetching" assertion fails.
    func testIsFetching_trueOnlyWhileTheFetchForThatExactKeyIsInFlight() async {
        let url = "http://127.0.0.1:1234"
        let gate = DLLMGate()
        let client = DLLMModelListClient(models: ["m1"], gate: gate)
        let sut = ModelCatalog(clientFactory: { client })

        XCTAssertFalse(sut.isFetching(url, provider: .lmStudio), "nothing started yet")

        let task = Task { await sut.loadIfNeeded(url: url, provider: .lmStudio) }
        await gate.waitUntilEntered()

        XCTAssertTrue(sut.isFetching(url, provider: .lmStudio))
        XCTAssertFalse(
            sut.isFetching(url, provider: .ollama),
            "The same URL under another provider is a different cache key")
        XCTAssertFalse(
            sut.isFetching(url, provider: .lmStudio, visionOnly: true),
            "…and so is the vision-only variant")

        gate.release()
        await task.value

        XCTAssertFalse(sut.isFetching(url, provider: .lmStudio), "the defer must clear the key")
        XCTAssertEqual(sut.models(for: url, provider: .lmStudio), ["m1"])
        XCTAssertNil(sut.error(for: url, provider: .lmStudio))
    }

    /// URL spelling variations collapse to one entry, so the spinner shown for
    /// `http://x:1234/` is the one for `http://x:1234`.
    func testIsFetching_foldsTrailingSlashAndCasing() async {
        let gate = DLLMGate()
        let client = DLLMModelListClient(models: ["m1"], gate: gate)
        let sut = ModelCatalog(clientFactory: { client })

        let task = Task { await sut.loadIfNeeded(url: "http://127.0.0.1:1234", provider: .lmStudio) }
        await gate.waitUntilEntered()

        XCTAssertTrue(sut.isFetching("HTTP://127.0.0.1:1234/", provider: .lmStudio))

        gate.release()
        await task.value
    }
}

// =============================================================================
// MARK: - OllamaDownloadedModelStore — transport corners
// =============================================================================

final class DLLMOllamaDownloadedModelStoreTailTests: XCTestCase {

    private func store(_ session: any NetworkSession) -> OllamaDownloadedModelStore {
        OllamaDownloadedModelStore(session: session, tokenResolver: StubLLMTokenResolver())
    }

    private func config(_ url: String) -> LLMConfig {
        LLMConfig(provider: .ollama, baseURLString: url, modelName: "m")
    }

    /// A malformed base URL must fail loudly BEFORE any request is built —
    /// otherwise the delete silently targets nothing and reports success.
    ///
    /// RED: change the guard to `URL(string:) ?? someFallback` -> the throw
    /// disappears and `XCTFail("expected a throw")` fires.
    func testDelete_invalidBaseURL_throwsInvalidBaseURL() async {
        do {
            try await store(DLLMNonHTTPSession()).delete(modelID: "llama3.1:8b", config: config(""))
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.invalidBaseURL(let reported) = error else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
            XCTAssertEqual(reported, "", "The rejected spelling must be reported back")
        }
    }

    /// A non-HTTP response carries no status code, so "did the delete work?" is
    /// unanswerable. `missingResponse` is the honest outcome; treating it as
    /// success would tell the user 20 GB was freed when nothing happened.
    ///
    /// RED: replace the `guard let http = response as? HTTPURLResponse` with an
    /// early `return` -> the delete reports success and the test fails.
    func testDelete_nonHTTPResponse_throwsMissingResponse() async {
        do {
            try await store(DLLMNonHTTPSession())
                .delete(modelID: "llama3.1:8b", config: config("http://127.0.0.1:11434"))
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.missingResponse = error else {
                return XCTFail("expected missingResponse, got \(error)")
            }
        }
    }

    /// Same rule on the GET path used by listing.
    ///
    /// RED: same mutation in `get(path:timeout:config:)` -> listing decodes an
    /// empty body and returns `[]` instead of throwing.
    func testList_nonHTTPResponse_throwsMissingResponse() async {
        do {
            _ = try await store(DLLMNonHTTPSession())
                .listDownloaded(config: config("http://127.0.0.1:11434"))
            XCTFail("expected a throw")
        } catch {
            guard case LLMClientError.missingResponse = error else {
                return XCTFail("expected missingResponse, got \(error)")
            }
        }
    }

    /// The files live on the Ollama host, which may be another machine, so the
    /// UI must not print a local path that would be a lie.
    ///
    /// RED: return `NSHomeDirectory()` (or any path) -> `XCTAssertNil` fails.
    func testStorageLocationDescription_isNilBecauseTheFilesMayBeRemote() async {
        let description = await store(DLLMNonHTTPSession())
            .storageLocationDescription(config: config("http://10.0.0.7:11434"))
        XCTAssertNil(description)
    }
}

// =============================================================================
// MARK: - LMStudioDownloadedModelStore — models folder missing
// =============================================================================

final class DLLMLMStudioDeleteTailTests: XCTestCase {

    var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dllm-lmstudio-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
        super.tearDown()
    }

    /// With no `~/.lmstudio` at all there is no folder to delete FROM. Deleting
    /// must fail with the actionable "check the Models Directory" error rather
    /// than guessing a path and trashing something under it.
    ///
    /// RED: replace the `guard let root = …` with a hardcoded
    /// `home.appending(path: ".lmstudio/models")` -> no throw (or a different
    /// error) and the `modelsFolderNotFound` equality fails.
    func testDelete_noModelsFolder_throwsModelsFolderNotFound() async {
        let sut = LMStudioDownloadedModelStore(
            fileManager: .default, homeDirectory: tempHome)

        do {
            try await sut.delete(
                modelID: "publisher/repo",
                config: LLMConfig(provider: .lmStudio, baseURLString: "http://127.0.0.1:1234"))
            XCTFail("expected a throw")
        } catch {
            guard case LMStudioModelDeletionError.modelsFolderNotFound = error else {
                return XCTFail("expected modelsFolderNotFound, got \(error)")
            }
        }
    }

    /// The locality guard runs FIRST — a remote endpoint must be refused before
    /// the local filesystem is even consulted, since trashing this machine's
    /// files while the user manages a remote host is the unrecoverable mistake.
    func testDelete_remoteEndpoint_isRefusedBeforeTouchingTheFilesystem() async {
        let sut = LMStudioDownloadedModelStore(
            fileManager: .default, homeDirectory: tempHome)

        do {
            try await sut.delete(
                modelID: "publisher/repo",
                config: LLMConfig(provider: .lmStudio, baseURLString: "http://10.0.0.7:1234"))
            XCTFail("expected a throw")
        } catch {
            guard case LMStudioModelDeletionError.remoteServer = error else {
                return XCTFail("expected remoteServer, got \(error)")
            }
        }
    }
}

// =============================================================================
// MARK: - LLMTokenFieldPersistence — the non-throwing shim
// =============================================================================

final class DLLMTokenFieldPersistenceShimTests: XCTestCase {

    /// The static shim exists for call sites with nowhere to surface an error.
    /// It must report `false` ("storage was not touched") on a write failure —
    /// reporting `true` would tell the caller the token is saved when it is not.
    ///
    /// RED: change the catch's `return false` to `return true` -> the assertion
    /// fails. (The instance method's throw is asserted alongside so the test
    /// also pins that the shim is swallowing a REAL error, not a no-op.)
    func testStaticSaveTokenIfChanged_writeFailure_reportsFalseInsteadOfThrowing() {
        let storage = DLLMWriteFailingTokenStorage()

        let reported = LLMTokenFieldPersistence.saveTokenIfChanged(
            "tok-1", forBaseURL: "http://127.0.0.1:1234", storage: storage)

        XCTAssertFalse(reported, "A failed write must not be reported as a write")

        XCTAssertThrowsError(
            try LLMTokenFieldPersistence(storage: storage)
                .saveTokenIfChanged("tok-1", forBaseURL: "http://127.0.0.1:1234"),
            "The throwing instance API must still surface the failure — the shim is the only swallower")
    }
}

// =============================================================================
// MARK: - StreamingPreviewManager — model-token stripping on append
// =============================================================================

@MainActor
final class DLLMStreamingPreviewTokenStripTests: XCTestCase {

    /// Some models emit `<|channel|>`-style sentinels as plain text. They must
    /// never reach the on-screen bubble; stripping happens on the accumulated
    /// content, so a sentinel split across two deltas is still caught.
    ///
    /// RED: delete the `if ModelTokenCleaner.containsModelTokens(...)` block ->
    /// the preview keeps `<|channel|>` and the `contains` assertion fails.
    func testAppend_stripsModelTokensFromThePreview_evenWhenSplitAcrossDeltas() async {
        let sut = StreamingPreviewManager()
        let key = TaskStepKey(taskID: 1, stepID: "swe")
        let messageID = UUID()

        sut.append(stepID: "swe", taskID: 1, messageID: messageID, role: .softwareEngineer, content: "Hello <|chan")
        // Mid-token: nothing closes it yet, so the raw text is still accumulating.
        sut.append(stepID: "swe", taskID: 1, messageID: messageID, role: .softwareEngineer, content: "nel|> world")

        let preview = sut.previews[key]
        XCTAssertNotNil(preview)
        XCTAssertFalse(
            preview?.content.contains("<|") ?? true,
            "Model sentinels must not reach the UI; got: \(preview?.content ?? "nil")")
        XCTAssertEqual(preview?.content, "Hello  world")
    }

    /// Plain content must survive byte-for-byte — the strip is not allowed to
    /// trim or normalise while the stream is still arriving.
    func testAppend_plainContent_isPreservedIncludingTrailingWhitespace() async {
        let sut = StreamingPreviewManager()
        let key = TaskStepKey(taskID: 2, stepID: "pm")

        sut.append(stepID: "pm", taskID: 2, messageID: UUID(), role: .productManager, content: "one ")
        sut.append(stepID: "pm", taskID: 2, messageID: UUID(), role: .productManager, content: "two ")

        XCTAssertEqual(sut.previews[key]?.content, "one two ")
    }
}

// =============================================================================
// MARK: - NetworkLogger — a failed append is dropped, never fatal
// =============================================================================

final class DLLMNetworkLoggerFailureTests: XCTestCase {

    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dllm-netlog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        super.tearDown()
    }

    private func record(_ url: String) -> NetworkLogRecord {
        NetworkLogger.createRequestRecord(
            url: URL(string: url)!, method: "POST", body: nil, stepID: "s")
    }

    /// Logging is best-effort: a log path the app cannot create must not fail
    /// the operation being logged, and must not leave a partial file behind.
    /// It must also not BUFFER the dropped record — a later successful append
    /// writes only what was appended after recovery.
    ///
    /// RED: replace the catch body with a `fatalError` -> the process aborts;
    /// replace the drop with a retry-buffer -> the final `records.count == 1`
    /// assertion fails (two records land instead of one).
    func testAppend_unwritableParent_isSilentlyDroppedAndNotBuffered() async throws {
        // A regular FILE where a directory component must be: `createDirectory`
        // cannot create `blocker/sub`, which is the failure this exercises.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let logURL = blocker.appendingPathComponent("sub").appendingPathComponent("network_log.json")
        let logger = NetworkLogger(logURL: logURL)

        logger.append(record("http://127.0.0.1:1234/dropped"))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: logURL.path),
            "Nothing may be written when the parent cannot be created")

        // Recover the path, then append a second record.
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        logger.append(record("http://127.0.0.1:1234/kept"))

        let data = try Data(contentsOf: logURL)
        let records = try JSONCoderFactory.makeDateDecoder().decode([NetworkLogRecord].self, from: data)
        XCTAssertEqual(records.count, 1, "The dropped record must not be replayed after recovery")
        XCTAssertEqual(records.first?.url, "http://127.0.0.1:1234/kept")
    }
}

// =============================================================================
// MARK: - PromptBuilder wire preview — trailing orphan header, attributed path
// =============================================================================

/// `@MainActor` mirrors `PromptBuilderWirePreviewTests` — the attributed
/// renderer builds `NSMutableAttributedString` / `NSFont`, and that suite is the
/// proven-safe isolation for this API.
@MainActor
final class DLLMWirePreviewTrailingHeaderTests: XCTestCase {

    /// A user-authored template whose LAST line is a bare `## Header` (no body,
    /// no trailing newline) slips past the main orphan-header pass — its
    /// look-ahead requires a newline after the header text. The trailing pass is
    /// what removes it, and the attributed renderer has to mirror the plain one
    /// or the Settings preview stops matching the wire.
    ///
    /// RED: delete the trailing-pattern block in
    /// `stripOrphanHeadersInAttributed` -> the attributed string keeps
    /// `## Skills` while the plain one drops it, failing BOTH the equality and
    /// the `contains` assertion.
    func testAttributedPreview_stripsATrailingBodylessHeaderJustLikeThePlainPath() throws {
        var team = TeamTemplateFactory.startup()
        team.systemPromptTemplate = "You are {roleName}.\n\n## Skills"
        let role = try XCTUnwrap(team.nonSupervisorRoles.first)

        let inputs = PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: [team],
            workFolder: nil,
            workFolderState: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            isComputerUseEnabled: false,
            globalContext: ""
        )

        let plain = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(
            kind: .stepExecution, inputs: inputs)

        XCTAssertFalse(
            plain.contains("## Skills"),
            "A bodyless trailing header must not ship to the model; got: \(plain)")
        XCTAssertFalse(
            attributed.string.contains("## Skills"),
            "The attributed renderer must mirror the plain strip; got: \(attributed.string)")
        XCTAssertEqual(
            plain, attributed.string,
            "Preview and wire must stay byte-identical through the trailing-header case")
    }

    /// The strip must be surgical: a header WITH a body is untouched, so the
    /// trailing pattern can't be widened into "delete the last section".
    func testAttributedPreview_trailingHeaderWithABodyIsKept() throws {
        var team = TeamTemplateFactory.startup()
        team.systemPromptTemplate = "You are {roleName}.\n\n## Notes\n\nKeep the diff small."
        let role = try XCTUnwrap(team.nonSupervisorRoles.first)

        let inputs = PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: [team],
            workFolder: nil,
            workFolderState: .defaultStorage,
            selectedScheme: nil,
            isVisionConfigured: false,
            isComputerUseEnabled: false,
            globalContext: ""
        )

        let plain = try PromptBuilder.buildWirePromptPreview(kind: .stepExecution, inputs: inputs)
        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(
            kind: .stepExecution, inputs: inputs)

        XCTAssertTrue(plain.contains("## Notes"), "got: \(plain)")
        XCTAssertTrue(plain.contains("Keep the diff small."), "got: \(plain)")
        XCTAssertEqual(plain, attributed.string)
    }
}
