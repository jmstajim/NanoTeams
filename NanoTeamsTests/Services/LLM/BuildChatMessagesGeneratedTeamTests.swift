import XCTest
@testable import NanoTeams

/// Part 4 of the generated-team pin fix: `LLMExecutionService.buildChatMessages`
/// must resolve a task's team via the generatedTeam/pin-aware `resolveTeam(task:)`,
/// not the old `preferredTeamID → activeTeam` lookup. A generated team lives on
/// `task.generatedTeam` (never in `workFolder.teams` / the delegate snapshot), so
/// the old path built the system prompt against the empty "Generated Team"
/// placeholder (wrong name, no roster, generic guidance). This pins that the
/// GENERATED roster reaches the system prompt.
@MainActor
final class BuildChatMessagesGeneratedTeamTests: XCTestCase, @unchecked Sendable {

    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
    }

    override func tearDown() async throws {
        service?.cancelAllExecutions()
        service = nil
        mockDelegate = nil
        try await super.tearDown()
    }

    func testBuildChatMessages_generatedTeam_systemPromptUsesGeneratedRoster() {
        let roleID = "gen_arch"
        let distinctiveRoleName = "MigrationArchitectZ9"

        let genTeam = Team(
            id: NTMSID.from(name: "gen_\(UUID().uuidString)"),
            name: "GeneratedMeditationTeamQ",
            description: "Migrates the app",
            roles: [TeamRoleDefinition(
                id: roleID, name: distinctiveRoleName, prompt: "", toolIDs: [],
                usePlanningPhase: false,
                dependencies: RoleDependencies(producesArtifacts: ["Out"]))],
            artifacts: [], settings: TeamSettings(), graphLayout: TeamGraphLayout())

        let step = StepExecution(id: roleID, role: .custom(id: roleID), title: "Step", status: .running)
        var task = NTMSTask(
            id: 7, title: "T", supervisorTask: "Migrate the app",
            runs: [Run(id: 0, steps: [step], teamID: genTeam.id)])
        // Placeholder preferredTeamID that is NOT in the (nil) snapshot — the OLD
        // path would resolve to nil here and build a "(unknown team)" prompt.
        task.preferredTeamID = NTMSID.from(name: "Generated Team")
        task.adoptGeneratedTeam(genTeam)
        mockDelegate.taskToMutate = task
        // mockDelegate.snapshot stays nil: resolveTeam still returns generatedTeam
        // (TeamResolution step 1), which is the whole point.

        let messages = service.buildChatMessages(
            for: task, stepID: roleID, tools: [], supervisorMode: .autonomous)

        guard let systemPrompt = messages.first(where: { $0.role == .system })?.content else {
            return XCTFail("expected a system message")
        }
        XCTAssertTrue(
            systemPrompt.contains(distinctiveRoleName),
            "system prompt must list the generated team's roster (resolved via generatedTeam); got: \(systemPrompt.prefix(500))")
        XCTAssertFalse(
            systemPrompt.contains("(unknown team)"),
            "the team must resolve via generatedTeam — not fall through to the no-team placeholder")
    }

    /// Behavior change from routing through `resolveTeam`: a run pinned to a
    /// genuinely-deleted team (no `generatedTeam`, not in the snapshot) now
    /// resolves to nil and surfaces the loud pin diagnostic — instead of silently
    /// falling back to `activeTeam`. `buildChatMessages` must still produce a
    /// (degraded) prompt rather than crash, and the diagnostic must reach the UI.
    func testBuildChatMessages_pinnedToDeletedTeam_noGeneratedTeam_degradesAndSurfacesDiagnostic() {
        let roleID = "x_role"
        let step = StepExecution(id: roleID, role: .custom(id: roleID), title: "Step", status: .running)
        let deletedID = NTMSID.from(name: "deleted_\(UUID().uuidString)")
        let task = NTMSTask(
            id: 8, title: "T", supervisorTask: "G",
            runs: [Run(id: 0, steps: [step], teamID: deletedID)])
        // No generatedTeam; mockDelegate.snapshot is nil → resolveTeam → .failed.
        mockDelegate.taskToMutate = task
        mockDelegate.lastErrorMessages.removeAll()

        let messages = service.buildChatMessages(
            for: task, stepID: roleID, tools: [], supervisorMode: .autonomous)

        XCTAssertFalse(messages.isEmpty,
                       "buildChatMessages must still produce a degraded prompt, not crash, on an unresolvable pin")
        XCTAssertTrue(
            mockDelegate.lastErrorMessages.contains(where: { $0.contains("pinned") }),
            "the loud pin diagnostic must surface via the delegate (resolveTeam .failed path); got: \(mockDelegate.lastErrorMessages)")
    }
}
