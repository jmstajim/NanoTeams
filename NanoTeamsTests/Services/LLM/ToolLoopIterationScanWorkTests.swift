import XCTest

@testable import NanoTeams

/// Work-bound pins for the tool loop's per-iteration scans, driven through the REAL iteration
/// (`runOneLLMToolIteration`) rather than the no-tool helper, so the counts include everything
/// an iteration does between the planning phase and the nudge.
///
/// Three O(conversation) walks used to run without changing a decision, on a wire with no
/// ceiling (`LLMConstants.maxToolIterations == 0`) — two per tool-loop iteration (1, 2) and one
/// per committed turn on a delegation child (3, in `commitStreaming`, outside the iteration):
///
///  1. `handleNoToolCalls` and `processScratchpadResult` each re-derived "still mid-planning"
///     by rescanning the wire `applyPlanningPhase` had scanned moments earlier. The fact is now
///     carried on `PlanningPhasePolicy.Authorization.wireIsMidPlanning`.
///  2. `detectMessageLoop` walked `conversationMessages.reversed()` on every no-tool turn; a
///     tool-heavy wire has no qualifying turn near its tail, so the walk was Θ(N). The tool loop
///     now keeps the last three qualifying contents as a ring in `StepExecutionState`.
///  3. `commitStreaming` evaluated `ConversationInformationBoundary.lastArrival` once per
///     committed turn on a child, behind `watchesCommitted` but before the watcher's cooldown
///     gate — pinned in `CommittedScanInputsTests`, not here.
///
/// Every count here is a `#if DEBUG` work counter INSIDE the walk (CLAUDE.md #62), never a
/// clock. A regression in any of the three is invisible in output: the rescan, the walk and the
/// eager boundary all answer exactly what the cheap path answers.
@MainActor
final class ToolLoopIterationScanWorkTests: XCTestCase {

    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var tracker: ToolCallTracker!
    private var memoryStore: MemoryTagStore!

    private let stepID = "scan_work_step"
    private let taskID = 9

    private let config = LLMConfig(
        provider: .lmStudio, baseURLString: "http://localhost", modelName: "stub", temperature: nil)

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-scan-work-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        delegate.workFolderURL = tempDir
        service.attach(delegate: delegate)

        // An EMPTY registry: these tests exercise the iteration's scans, not any handler.
        runtime = ToolRuntime(registry: ToolRegistry(), logger: nil)
        tracker = ToolCallTracker()
        memoryStore = MemoryTagStore(workFolderRoot: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        memoryStore = nil
        tracker = nil
        runtime = nil
        service = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// One step, registered. With `planning` the task adopts a team whose role for this step has
    /// the planning phase on (the `AdvisoryAutoFinishTests.attachTeam` shape), so
    /// `applyPlanningPhase` finds `usePlanningPhase == true` for `step.effectiveRoleID`.
    private func seedTask(planning: Bool) -> NTMSTask {
        let step = StepExecution(id: stepID, role: .softwareEngineer, title: "Engineer", status: .running)
        var task = NTMSTask(id: taskID, title: "T", supervisorTask: "build")
        task.runs = [Run(id: 0, steps: [step])]
        if planning {
            let supervisor = TeamRoleDefinition(
                id: "sup", name: "Supervisor", prompt: "", toolIDs: [], usePlanningPhase: false,
                dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Supervisor Task"]),
                isSystemRole: true, systemRoleID: "supervisor")
            let engineer = TeamRoleDefinition(
                id: stepID, name: "Software Engineer", prompt: "", toolIDs: [ToolNames.updateScratchpad],
                usePlanningPhase: true,
                dependencies: RoleDependencies(requiredArtifacts: [], producesArtifacts: ["Engineering Notes"]),
                systemRoleID: "softwareEngineer")
            let team = Team(
                id: "scan-work-team", name: "Scan Work", roles: [supervisor, engineer], artifacts: [],
                settings: TeamSettings(), graphLayout: TeamGraphLayout())
            task.adoptGeneratedTeam(team)
        }
        delegate.taskToMutate = task
        service._testRegisterStepTask(stepID: stepID, taskID: taskID)
        return task
    }

    private var scratchpadTool: [ToolSchema] {
        [ToolSchema(name: ToolNames.updateScratchpad, description: "Scratchpad",
                    parameters: .object(properties: [:]))]
    }

    /// A mid-planning wire: system, task, the brief at index 2, then `pairs` distinct
    /// assistant/user pairs — long, and with no loop in it.
    private func midPlanningWire(pairs: Int) -> [ChatMessage] {
        var wire: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: "Build the thing"),
            ChatMessage(role: .user, content: PlanningPhasePolicy.planningBrief(
                exploreToolNames: [ToolNames.readFile], expectedArtifacts: ["Engineering Notes"])),
        ]
        for i in 0..<pairs {
            wire.append(ChatMessage(role: .assistant, content: "finding \(i)"))
            wire.append(ChatMessage(role: .user, content: "go on"))
        }
        return wire
    }

    private func runIteration(
        client: any LLMClient, task: NTMSTask, tools: [ToolSchema],
        conversation: inout [ChatMessage]
    ) async throws -> LLMStepStop {
        var usage = TokenUsage()
        return try await service.runOneLLMToolIteration(
            stepID: stepID,
            roleForMessage: .softwareEngineer,
            client: client,
            config: config,
            tools: tools,
            runtime: runtime,
            task: task,
            runIndex: 0,
            stepIndex: 0,
            supervisorMode: .manual,
            conversationMessages: &conversation,
            tracker: tracker,
            memoryStore: memoryStore,
            cumulativeUsage: &usage
        )
    }

    private func step() -> StepExecution? {
        delegate.taskToMutate?.runs.last?.steps.first { $0.id == stepID }
    }

    // MARK: - 1. The planning wire is scanned once per iteration, not once per consumer

    /// `applyPlanningPhase` pays exactly one `briefIndex` walk (stops at the brief, index 2)
    /// and one `wireCarriesClosedMarker` walk (the whole wire). The prose-plan branch that
    /// fires later in the same iteration must not pay either again.
    ///
    /// RED: revert the prose-plan branch in `handleNoToolCalls` to
    /// `if PlanningPhasePolicy.isMidPlanning(conversationMessages) {` → `examined()` reads ≥ 2N:
    /// the same wire is walked again by the consumer, while the scratchpad is still recorded.
    func testNoToolIteration_scansThePlanningWireOnce_notOncePerConsumer() async throws {
        let task = seedTask(planning: true)
        var conversation = midPlanningWire(pairs: 200)
        let n = conversation.count
        XCTAssertGreaterThanOrEqual(n, 400, "premise: a long mid-planning wire")
        XCTAssertTrue(PlanningPhasePolicy.isMidPlanning(conversation), "premise: mid-planning")
        let client = ScanWorkScriptedClient(events: [
            StreamEvent(contentDelta: "I'll read the sources, then edit the parser."),
        ])

        PlanningWireScanProbe.reset()
        let stop = try await runIteration(
            client: client, task: task, tools: scratchpadTool, conversation: &conversation)

        guard case .continueLoop = stop else {
            return XCTFail("a prose turn mid-planning must record the plan and continue, got \(stop)")
        }
        XCTAssertEqual(step()?.scratchpad, "I'll read the sources, then edit the parser.",
                       "anti-vacuum: the later consumer (the prose-plan branch) fired")
        let examined = PlanningWireScanProbe.examined()
        XCTAssertLessThanOrEqual(
            examined, n + 8,
            "one brief walk stopping at the brief plus one full closed-marker walk, nothing "
                + "else — examined \(examined) of \(n): a consumer is rescanning the wire")
        XCTAssertGreaterThan(examined, 0,
                             "anti-vacuum: the two scans `applyPlanningPhase` owns must have run")
    }

    // MARK: - 2. `isMidPlanning` has no production caller outside its home

    /// Source pin for the fact the counts above rest on. The function stays as the DEFINITION
    /// (and the reference spelling for tests and the DEBUG helper); a production caller is a
    /// rescan by construction.
    ///
    /// RED: re-add `PlanningPhasePolicy.isMidPlanning(conversationMessages)` at either former
    /// site (`+StepFlowControl`, `+ToolResultSideEffects`) → fails naming file:line.
    func testIsMidPlanning_hasNoProductionCallSiteOutsideItsHome() throws {
        let needle = "isMidPlanning" + "("
        let allowed: Set<String> = [
            "PlanningPhasePolicy.swift",
            "LLMExecutionService+TestHelpers.swift",
        ]
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams")
        var offenders: [String] = []
        var scannedAllowed: Set<String> = []
        for url in RatchetSourceScan.swiftFiles(under: root) {
            let code = RatchetSourceScan.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
            let lines = code.components(separatedBy: "\n")
            let hitLines = lines.indices.filter { lines[$0].contains(needle) }
            guard !hitLines.isEmpty else { continue }
            if allowed.contains(url.lastPathComponent) {
                scannedAllowed.insert(url.lastPathComponent)
                continue
            }
            let relative = RatchetSourceScan.relativePath(of: url)
            offenders += hitLines.map { "\(relative):\($0 + 1)" }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "`isMidPlanning` is called from production again — a rescan of the wire "
                          + "the iteration already scanned; read `Authorization.wireIsMidPlanning` "
                          + "instead: \(offenders)")
        XCTAssertEqual(scannedAllowed, allowed,
                       "anti-vacuum: both allowed files must exist and mention the needle")
    }

    // MARK: - 3. Loop detection through the ring, across real iterations

    /// Three byte-identical prose turns through the REAL iteration: `processStreamingResult`
    /// pushes each onto the ring, `handleNoToolCalls` classifies the ring, and the third turn
    /// earns the repetitive-non-tool nudge — with the wire never walked once the seed is paid.
    ///
    /// RED: drop the `pushMessageLoopContent` call from `appendAssistantTurn` (+Streaming) →
    /// the ring stays empty, the third iteration emits the generic nudge, and the assertions on
    /// the nudge wording and on the ring fail.
    func testThreeIdenticalProseTurns_fireTheRepetitiveNudge_throughTheRing() async throws {
        let task = seedTask(planning: false)
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are Software Engineer."),
            ChatMessage(role: .user, content: "Build the thing"),
        ]
        // What step entry does: seed once from the assembled wire.
        service._testSeedMessageLoopRing(stepID: stepID, taskID: taskID, from: conversation)
        let prose = "Okay, continuing with the task."
        let client = ScanWorkScriptedClient(events: [StreamEvent(contentDelta: prose)])

        MessageLoopScanProbe.reset()
        for iteration in 1...3 {
            let stop = try await runIteration(
                client: client, task: task, tools: [], conversation: &conversation)
            guard case .continueLoop = stop else {
                return XCTFail("iteration \(iteration): expected .continueLoop, got \(stop)")
            }
        }

        // Read the counter before this test's own reference walk (below) adds to it.
        let examinedDuringIterations = MessageLoopScanProbe.examined()

        let lastUserTurn = conversation.last { $0.role == .user }?.content ?? ""
        XCTAssertTrue(lastUserTurn.contains("near-identical"),
                      "the third identical turn must earn the repetitive-non-tool nudge; got: "
                          + "\(lastUserTurn)")
        XCTAssertEqual(service._testMessageLoopRing(stepID: stepID, taskID: taskID),
                       [prose, prose, prose],
                       "the ring holds the three wire turns, pushed by the single append site")
        XCTAssertEqual(service._testMessageLoopRing(stepID: stepID, taskID: taskID),
                       ConversationRepairService.recentNoToolAssistantContents(in: conversation),
                       "ring ≡ walk over the wire that was actually sent")
        XCTAssertEqual(examinedDuringIterations, 0,
                       "after the one seed, no iteration walks the wire for loop detection")
    }

    // MARK: - 4. Every wire-shrinking site re-seeds the ring

    /// The ring is correct only while every event that REPLACES or SHRINKS the wire re-derives
    /// it: step entry (a replayed transcript already carries turns), the planning boundary
    /// (the slice keeps a prefix that may hold turns), and the poisoned-tail repair. A new
    /// truncation path without a reseed desynchronises the detector silently.
    ///
    /// RED: drop the `reseedMessageLoopRing` call after `seedTagCounters` (entry), after
    /// `implementationWire` (boundary) or inside the `repairConversationIfNeeded` arm (retry)
    /// → fails naming the site.
    func testEveryWireShrinkSite_isFollowedByARingReseed() throws {
        let reseed = "reseedMessageLoopRing" + "("
        let root = RatchetSourceScan.repoRoot.appendingPathComponent("NanoTeams/Services/LLM")
        func code(_ url: URL) throws -> String {
            RatchetSourceScan.strippingLineComments(try String(contentsOf: url, encoding: .utf8))
        }
        func assertReseedFollows(_ anchor: String, in file: String, within chars: Int) throws {
            let src = try code(root.appendingPathComponent(file))
            guard let site = src.range(of: anchor) else {
                return XCTFail("\(file): `\(anchor)` not found — the shrink site moved; re-aim this pin")
            }
            let end = src.index(site.upperBound, offsetBy: chars, limitedBy: src.endIndex) ?? src.endIndex
            XCTAssertTrue(String(src[site.upperBound..<end]).contains(reseed),
                          "\(file): `\(anchor)` replaces or shrinks the wire and is not followed "
                              + "by a ring reseed — the loop detector goes blind there")
        }
        try assertReseedFollows("seedTagCounters(replaying: conversation)",
                                in: "LLMExecutionService+StepLifecycle.swift", within: 700)
        try assertReseedFollows("repairConversationIfNeeded(&conversation)",
                                in: "LLMExecutionService+StepLifecycle.swift", within: 700)
        try assertReseedFollows("resetConversationScopedState()",
                                in: "LLMExecutionService+PlanningPhase.swift", within: 400)

        // Anti-vacuum: exactly the three production call sites above, plus the definition and
        // the DEBUG helper, and no reseed sitting somewhere this pin does not know about.
        var callSites = 0
        for url in RatchetSourceScan.swiftFiles(under: root) {
            let src = try code(url)
            let hits = src.components(separatedBy: reseed).count - 1
            switch url.lastPathComponent {
            case "LLMExecutionService+StepFlowControl.swift":
                // The one hit is the declaration `func reseedMessageLoopRing(`, not a call.
                XCTAssertEqual(hits, 1, "the home of `reseedMessageLoopRing` declares it once and never calls it")
                XCTAssertEqual(src.components(separatedBy: "func " + reseed).count - 1, 1,
                               "…and that one hit must be the declaration")
            case "LLMExecutionService+TestHelpers.swift":
                XCTAssertGreaterThan(hits, 0, "the DEBUG helper must route through the production seed")
            default:
                callSites += hits
            }
        }
        XCTAssertEqual(callSites, 3,
                       "three production reseed sites (entry, boundary, repair) — a fourth means a "
                           + "new shrink path this pin must name, a missing one means a blind detector")
    }
}

// MARK: - Scripted client

/// Replays the same scripted events on every call — the `DTScriptedStreamClient` shape.
private final class ScanWorkScriptedClient: LLMClient, @unchecked Sendable {
    private let events: [StreamEvent]

    init(events: [StreamEvent]) { self.events = events }

    func streamChat(
        config _: LLMConfig,
        messages _: [ChatMessage],
        tools _: [ToolSchema],
        logger _: NetworkLogger?,
        stepID _: String?,
        roleName _: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let scripted = events
        return AsyncThrowingStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func fetchModels(config _: LLMConfig, visionOnly _: Bool) async throws -> [LLMModelInfo] { [] }
}
