import XCTest

@testable import NanoTeams

/// **Append at `count` is the only prefix-preserving mutation of a conversation**, and almost
/// every safety claim in the stateless design rests on that one property:
///
/// - Ollama merges consecutive user-side turns, so an array append is a wire-level rewrite of the
///   LAST message. That is harmless *only* because nothing ever inserts ahead of the tail
///   (`PromptPrefixWireParityTests` measures both halves).
/// - `collapseRedundantAssistantTextRuns` was deleted on the strength of "two adjacent text-only
///   assistant turns are unreachable" — which is a claim about the append sites, not about the
///   function.
/// - `PlanningPhasePolicy` deliberately has no insert-before-the-brief path.
///
/// The property was load-bearing and completely unpinned. These tests hold both halves: the
/// behavioural one (no tool-loop path can produce two adjacent assistant turns) and the
/// structural one (no mutation site writes through an index outside a named exemption).
@MainActor
final class ConversationAppendInvariantTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var task: NTMSTask!
    private var stepID: String!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)

        let step = StepExecution(
            id: "test_step", role: .softwareEngineer, title: "Work", status: .running)
        stepID = step.id
        let run = Run(id: 0, steps: [step])
        task = NTMSTask(id: 0, title: "T", supervisorTask: "goal", runs: [run])
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: task.id)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        task = nil
        stepID = nil
        super.tearDown()
    }

    // MARK: - Behavioural: no `.continueLoop` leaves the conversation without a reply turn

    /// Every branch of `handleNoToolCalls` that continues the loop must first append a
    /// non-assistant turn. If any did not, the next iteration's assistant turn would land
    /// directly against this one — the only shape in which a run of text-only assistant turns
    /// can form, and the shape the deleted collapse function existed to compact.
    private func drive(
        content: String,
        harmonyMarker: Bool = false,
        harmonyBuffer: String = "",
        roleDefinition: TeamRoleDefinition? = nil,
        into messages: inout [ChatMessage]
    ) async -> LLMStepStop {
        await service._testHandleNoToolCalls(
            stepID: stepID,
            assistantContent: content,
            sawHarmonyMarker: harmonyMarker,
            task: task,
            roleDefinition: roleDefinition,
            conversationMessages: &messages,
            harmonyBuffer: harmonyBuffer,
            allowedToolNames: ["create_artifact", "ask_supervisor"])
    }

    private func producingRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "swe", name: "Software Engineer", prompt: "", toolIDs: ["create_artifact"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]),
            systemRoleID: "softwareEngineer")
    }

    private func advisoryRole() -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: "assistant", name: "Assistant", prompt: "", toolIDs: ["ask_supervisor"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: ["Supervisor Task"], producesArtifacts: []),
            systemRoleID: "assistant")
    }

    /// The table covers every distinct `.continueLoop` arm reachable without a live runtime:
    /// the generic no-tool nudge, the malformed-envelope retry, the tokens-only retry, and the
    /// producing-role missing-artifacts retry.
    func testEveryContinueLoopPath_appendsANonAssistantTurn() async {
        let cases: [(label: String, content: String, marker: Bool, buffer: String,
                     role: TeamRoleDefinition?)] = [
            ("generic no-tool nudge", "I think we are done here.", false, "", advisoryRole()),
            ("malformed harmony envelope", "\n\n", true, "<|call|>{\"name\":", nil),
            ("model tokens only", "<|channel|>commentary<|message|>", false, "", nil),
            ("producing role, artifacts missing", "Here is my summary.", false, "",
             producingRole()),
        ]

        for testCase in cases {
            var messages: [ChatMessage] = [
                ChatMessage(role: .system, content: "s"),
                ChatMessage(role: .assistant, content: testCase.content),
            ]
            let stop = await drive(
                content: testCase.content, harmonyMarker: testCase.marker,
                harmonyBuffer: testCase.buffer, roleDefinition: testCase.role, into: &messages)

            guard case .continueLoop = stop else { continue }  // terminal arms end the step
            XCTAssertNotEqual(
                messages.last?.role, .assistant,
                "\(testCase.label): continuing the loop without a reply turn would let the next "
                    + "assistant turn land against this one")
            XCTAssertGreaterThan(messages.count, 2, "\(testCase.label): nothing was appended")
        }
    }

    /// The same claim stated as the property it protects, over a simulated multi-iteration loop.
    func testAssistantTurnsAreNeverAdjacent_acrossRepeatedNoToolIterations() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "s")]

        for iteration in 0..<4 {
            // What `processStreamingResult` does on a text-only turn.
            messages.append(ChatMessage(role: .assistant, content: "prose \(iteration)"))
            let stop = await drive(
                content: "prose \(iteration)", roleDefinition: advisoryRole(), into: &messages)
            guard case .continueLoop = stop else { break }
        }

        let adjacentPairs = zip(messages, messages.dropFirst())
            .filter { $0.role == .assistant && $1.role == .assistant }
        XCTAssertTrue(
            adjacentPairs.isEmpty,
            "a run of assistant turns is unreachable — the nudge always separates them")
    }

    /// The empty anchor `processStreamingResult` writes when a turn resolved to nothing is not
    /// collapsible either: it carries no content, so it breaks a run rather than extending one.
    func testEmptyAssistantAnchor_breaksARun() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prose"),
            ChatMessage(role: .assistant, content: nil),
            ChatMessage(role: .assistant, content: "more prose"),
        ]
        let textOnlyRun = zip(messages, messages.dropFirst()).filter {
            $0.role == .assistant && !($0.content?.isEmpty ?? true)
                && $1.role == .assistant && !($1.content?.isEmpty ?? true)
        }
        XCTAssertTrue(
            textOnlyRun.isEmpty,
            "an anchor with nil content sits between them, so no compactable run forms")
    }

    /// The one reachable source of adjacency — and it is already a total prefix loss reported as
    /// `degradedReplay`, so nothing downstream can make it worse. This is the whole reason the
    /// collapse function could be deleted rather than bounded.
    func testLegacyReplay_canProduceAdjacency_butIsAlreadyATotalMiss() {
        let display: [LLMMessage] = [
            LLMMessage(role: .assistant, content: "first pass"),
            LLMMessage(
                role: .assistant, content: "the server exploded",
                sourceContext: .serverError),
            LLMMessage(role: .assistant, content: "second pass"),
        ]
        let rebuilt = ConversationReplay.rebuildFromDisplayRecord(display)

        XCTAssertEqual(rebuilt.count, 2, "the server-error turn is dropped from the replay")
        XCTAssertTrue(
            rebuilt.allSatisfy { $0.role == .assistant },
            "…which leaves two text-only assistant turns adjacent — the only way it happens")
    }

    // MARK: - Structural: every mutation site is an append

    /// Source pin. Index writes into `conversationMessages` are allowed only where a named
    /// exemption already exists in the prompt-prefix subsystem; everything else must be
    /// `.append(`. Needles are assembled at runtime and line comments stripped, so this file's
    /// own prose cannot satisfy or trip the scan.
    func testEveryConversationMutationIsAnAppend() throws {
        let subscriptNeedle = "conversationMessages" + "["
        let appendNeedle = "conversationMessages" + ".append("

        /// Each entry is a file that legitimately writes through an index, with the exemption
        /// that covers it. Adding a file here without an exemption in
        /// `reportPrefixCacheMissIfAny` re-introduces a silent prefix break.
        let exempt: [String: String] = [
            "NanoTeams/Services/LLM/LLMExecutionService+ToolIteration.swift":
                "single-use image strip — exemption 2",
            "NanoTeams/Services/LLM/LLMExecutionService+ToolLoopState.swift":
                "injectMemories (disabled) and the unreachable supervisor auto-answer replacement",
        ]

        var appendCount = 0
        var offenders: [String] = []

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("NanoTeams/Services")
        let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil)

        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)

            for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
                let line = Self.strippingLineComments(rawLine)
                if line.contains(appendNeedle) { appendCount += 1 }
                guard line.contains(subscriptNeedle), exempt[relative] == nil else { continue }
                offenders.append("\(relative):\(offset + 1)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "these write through an index instead of appending, which breaks the prompt-prefix "
                + "cache from that point: \(offenders.joined(separator: ", "))")
        XCTAssertGreaterThan(
            appendCount, 20,
            "anti-vacuity: the scan must actually be seeing the mutation sites")
    }

    /// Everything before an unquoted `//`. House shape, verbatim from
    /// `PrefixCacheLedgerOwnershipPinTests`.
    private static func strippingLineComments(_ line: String) -> String {
        var out = ""
        var inString = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/" { return String(out.dropLast()) }
            out.append(character)
            previous = character
            index = line.index(after: index)
        }
        return out
    }
}
