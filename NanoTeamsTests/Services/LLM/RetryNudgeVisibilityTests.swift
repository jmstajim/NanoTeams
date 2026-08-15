import XCTest

@testable import NanoTeams

/// Every `.user` turn production records must carry attribution, or state why it does not.
///
/// The defect: all eight nudge sites wrote `role: .user` with `sourceRole == nil` and
/// `sourceContext == nil`, and `ActivityFeedBuilder` drops exactly that shape. So the app
/// was talking to the model on the user's behalf — "you replied with text but did not call
/// a tool", "your JSON was malformed", "you haven't submitted all artifacts" — and none of
/// it reached the screen. What the user saw in the wedged Autovisor pass was a column of
/// identical assistant bubbles with no cause; the cause was there, filtered out.
///
/// The nudges are NOT collapsed in place the way `.serverError` retry notices are, and
/// that is deliberate: a nudge is separated from the previous nudge by the model's own
/// committed reply, so a "replace if the last entry is a nudge" collapse would fire only
/// for envelope-only turns (whose assistant content commits empty) and not for prose ones.
/// A collapse that works in half the cases reads as a bug; N nudges for N retries is the
/// honest record, and F3 now bounds N.
@MainActor
final class RetryNudgeVisibilityTests: XCTestCase {
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        let step = StepExecution(id: "swe", role: .softwareEngineer, title: "Step", status: .running)
        stepID = step.id
        task = NTMSTask(id: 0, title: "T", supervisorTask: "do work", runs: [Run(id: 0, steps: [step])])
        mockDelegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() async throws {
        mockDelegate = nil
        service = nil
        task = nil
        stepID = nil
        try await super.tearDown()
    }

    private func producingRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "swe", name: "SWE", prompt: "", toolIDs: [], usePlanningPhase: false,
            dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]),
            isSystemRole: true, systemRoleID: "softwareEngineer")
    }

    /// Every `.user` turn the step recorded, in order.
    private var recordedNudges: [LLMMessage] {
        (mockDelegate.taskToMutate?.runs.last?.steps.first?.llmConversation ?? [])
            .filter { $0.role == .user }
    }

    // MARK: - Per-branch tagging

    func testGenericNoToolNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "All done!", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testMissingArtifactsNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "Working on it.", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: producingRole(),
            conversationMessages: &messages)
        XCTAssertTrue((recordedNudges.last?.content ?? "").contains("Missing deliverables"),
                      "Sanity: this must be the artifact branch")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testMalformedEnvelopeRetry_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: true,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages,
            harmonyBuffer: "<|channel|>commentary to=swift_build code<|message|>")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testTokensOnlyRetry_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "<|return|>", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages)
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testDriftNudge_isTagged() async {
        var messages: [ChatMessage] = []
        _ = await service._testHandleNoToolCalls(
            stepID: stepID, assistantContent: "", sawHarmonyMarker: false,
            task: mockDelegate.taskToMutate!, roleDefinition: nil,
            conversationMessages: &messages,
            thinkingContent: String(repeating: "x", count: 12_000))
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    func testRepetitiveNudge_isTagged() async {
        var shared: [ChatMessage] = []
        for _ in 1...3 {
            shared.append(ChatMessage(role: .assistant, content: "wait_for_events"))
            _ = await service._testHandleNoToolCalls(
                stepID: stepID, assistantContent: "wait_for_events", sawHarmonyMarker: false,
                task: mockDelegate.taskToMutate!, roleDefinition: nil,
                conversationMessages: &shared)
        }
        XCTAssertTrue((recordedNudges.last?.content ?? "").contains("near-identical"),
                      "Sanity: this must be the repetition branch")
        XCTAssertEqual(recordedNudges.last?.sourceContext, .retryNudge)
    }

    // MARK: - Replay contract

    /// A nudge really WAS sent, so the legacy display-record replay must keep it —
    /// unlike `.serverError`, which is display-only. Dropping it would make a replayed
    /// conversation show the model its own unproductive turns with the corrections
    /// removed, i.e. teach it that those turns were accepted.
    func testReplay_keepsRetryNudges() {
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord([
            LLMMessage(role: .assistant, content: "Waiting."),
            LLMMessage(role: .user, content: "You replied with text but did not call a tool.",
                       sourceContext: .retryNudge),
            LLMMessage(role: .assistant, content: "Waiting."),
        ])
        XCTAssertEqual(rebuilt.count, 3)
        XCTAssertTrue(rebuilt.contains { ($0.content ?? "").contains("did not call a tool") },
                      "a retry nudge was sent, so a replay must resend it")
    }

    // MARK: - Structural pin

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // NanoTeamsTests
            .deletingLastPathComponent()  // repo root
    }

    /// The production root the scan walks. EVERY `*.swift` under it, not a list.
    ///
    /// A list was the hole this pin kept falling into. It began at one file; scanning only
    /// `+StepFlowControl.swift` missed the loop warning in `+ToolLoopState.swift` one file
    /// over, which had shipped with no `sourceContext` from the day it was written — the
    /// Supervisor watched a role read the same six files forever with nothing on screen
    /// saying the app had noticed. Adding that second path fixed the instance and left the
    /// class open: three more files still held five unattributed sites, among them the
    /// `update_scratchpad` acknowledgement (fires on every plan update) and the recovery
    /// steering after a failed tool call (31 of 40 `edit_file` calls in one observed run).
    /// The property is "no site was forgotten", and a pin that enumerates the places to look
    /// forgets sites for a living.
    private static let scannedRoot = "NanoTeams"

    /// Anti-vacuity floor for the walk: a broken `#filePath` derivation, a renamed root or a
    /// glob that stops recursing would otherwise scan nothing and pass. Far below the real
    /// count (~700 files, ~20 `.user` sites) so ordinary growth or pruning never trips it.
    private static let minimumFilesScanned = 200
    private static let minimumUserRecordSites = 12

    /// The only way to record an unattributed `.user` turn: say why, at the call site.
    /// Assembled at runtime so this file's own prose cannot satisfy the scan.
    private static var exemptionMarker: String { "feed-invisible" + "-by-design:" }

    /// Index of the `)` closing the argument list that starts at `openAfter`.
    private static func matchingParen(
        in source: String, openAfter start: String.Index
    ) -> String.Index? {
        var depth = 1
        var i = start
        while i < source.endIndex {
            let c = source[i]
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = source.index(after: i)
        }
        return nil
    }

    /// Every `*.swift` under the production root, in a stable order.
    private func productionSources() throws -> [(path: String, source: String)] {
        let root = repoRoot.appendingPathComponent(Self.scannedRoot)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// No `.user` turn recorded ANYWHERE in production may lack attribution.
    ///
    /// A source pin because the property is "no site was forgotten" — and eight of them were,
    /// then one more, then five more. A branch added later would compile, pass every
    /// behavioural test above, and be invisible on screen, which is precisely the failure mode
    /// this fixes.
    ///
    /// Keyed on `appendLLMMessage(` — the helper that writes to `step.llmConversation` and
    /// nothing else. That is what makes a target-wide walk precise rather than noisy: it
    /// catches every real site and naturally excludes the consultation-chat sites, which build
    /// a bare `LLMMessage(` into `RoleConsultationChat.messages`, a store the activity feed
    /// never reads.
    func testEveryUserTurnRecordedInProduction_carriesAContext() throws {
        let sources = try productionSources()
        var checked = 0
        for (path, source) in sources {
            // The call spans lines, so join the whole file and scan each `appendLLMMessage(`
            // invocation up to its closing paren.
            let opener = "appendLLMMessage" + "("
            var searchStart = source.startIndex
            while let open = source.range(of: opener, range: searchStart..<source.endIndex) {
                // Balanced scan, NOT the first `)`. A call whose content argument
                // interpolates — `content: "\(prefix)\(answer)"` — closes a paren before the
                // argument list ends, so a first-`)` scan cut the call in half and reported
                // the surviving fragment as unattributed. It flagged a correctly attributed
                // site, which is the failure mode that gets a pin deleted.
                guard let close = Self.matchingParen(in: source, openAfter: open.upperBound)
                else { break }
                let call = String(source[open.upperBound..<close])
                searchStart = source.index(after: close)
                guard call.contains("role: .user") else { continue }
                checked += 1
                // An unattributed site is allowed only with a stated reason on the call —
                // an escape hatch rather than a file-level blind spot, because the property
                // is "no site was forgotten" and a whole-file exclusion is how one gets
                // forgotten. Searched in the 400 characters before the call so the reason
                // can sit in the doc comment above it.
                let contextStart = source.index(
                    open.lowerBound, offsetBy: -400, limitedBy: source.startIndex)
                    ?? source.startIndex
                let preamble = String(source[contextStart..<open.lowerBound])
                XCTAssertTrue(
                    call.contains("sourceContext:") || preamble.contains(Self.exemptionMarker),
                    "A `.user` turn recorded by \(path) with no sourceContext is dropped by "
                    + "ActivityFeedBuilder's no-source filter — attribute it, or state why "
                    + "not with a `\(Self.exemptionMarker)` note. Call: \(call)")
            }
        }
        XCTAssertGreaterThanOrEqual(
            checked, Self.minimumUserRecordSites,
            "Only \(checked) `.user` record sites found across \(sources.count) files — the "
            + "walk or the opener is wrong, and a pin that checks almost nothing passes")
    }

    /// A walk that silently reaches nothing passes the pin above vacuously, which is how a
    /// source scan dies: `#filePath` derivation breaks, or the root is renamed, and the
    /// assertion loop simply never runs.
    func testTheWalkReachesTheWholeProductionTree() throws {
        let sources = try productionSources()
        XCTAssertGreaterThanOrEqual(sources.count, Self.minimumFilesScanned)
        // Recursion, not just the top level: these live several directories deep, and the
        // five sites the file-list version missed were all in nested folders.
        for expected in [
            "NanoTeams/Services/LLM/LLMExecutionService+StepFlowControl.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+ToolLoopState.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+ToolResultSideEffects.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+ToolResultDispatching.swift",
            "NanoTeams/Services/LLM/LLMExecutionService+ComputerUse.swift",
        ] {
            XCTAssertTrue(sources.contains { $0.path == expected }, "walk missed \(expected)")
        }
    }

    /// RED: revert `matchingParen` to "first `)` after the opener" → this fires while the
    /// pin above ALSO fires, for a different and misleading reason.
    ///
    /// The supervisor auto-answer's call interpolates into its `content:` argument —
    /// `"\(MessageSourceContext.supervisorAnswerPrefix)\(answer)"` — so a first-`)` scan
    /// stops inside the string, hands the assertion a fragment, and reports a correctly
    /// attributed site as unattributed. A pin that cries wolf about a compliant call is one
    /// somebody deletes; this test names the scanner as the culprit so the next reader does
    /// not go looking at the production code.
    func testTheScanSeesWholeCalls_notFragmentsCutAtAnInterpolation() throws {
        let path = "NanoTeams/Services/LLM/LLMExecutionService+ToolLoopState.swift"
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        let opener = "appendLLMMessage" + "("

        var searchStart = source.startIndex
        var sawInterpolatingCall = false
        while let open = source.range(of: opener, range: searchStart..<source.endIndex) {
            guard let close = Self.matchingParen(in: source, openAfter: open.upperBound)
            else { break }
            let call = String(source[open.upperBound..<close])
            searchStart = source.index(after: close)
            guard call.contains("supervisorAnswerPrefix") else { continue }
            sawInterpolatingCall = true
            XCTAssertTrue(
                call.contains("sourceContext:"),
                "the scan must reach past the interpolation to the argument list's end; got: \(call)")
        }
        XCTAssertTrue(
            sawInterpolatingCall,
            "anti-vacuity: the interpolating call this guards must still exist in \(path)")
    }

    /// A broken `#filePath`→repoRoot derivation would scan nothing and pass vacuously.
    ///
    /// The marker is the production root itself — a directory every compiling checkout
    /// carries, including the public mirror, which ships build sources only.
    func testRepoRootResolves() {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(Self.scannedRoot).path,
                isDirectory: &isDirectory),
            "production root missing: \(Self.scannedRoot)")
        XCTAssertTrue(isDirectory.boolValue, "\(Self.scannedRoot) must be the source directory")
    }
}
