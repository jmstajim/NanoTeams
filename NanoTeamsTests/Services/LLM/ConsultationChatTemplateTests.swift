import XCTest

@testable import NanoTeams

/// Pins that the LIVE consultation chat resolves its system prompt from the
/// team's user-editable `consultationPromptTemplate` — the same template the
/// Settings preview renders. Pre-fix the runtime shipped an unrelated
/// hand-built prose prompt ("You are X… Be concise and professional…") while
/// the preview showed the template, so user edits never reached the wire.
@MainActor
final class ConsultationChatTemplateTests: XCTestCase {

    var service: LLMExecutionService!
    var mockDelegate: MockLLMExecutionDelegate!
    var faang: Team!

    override func setUp() async throws {
        try await super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        service.attach(delegate: mockDelegate)
        faang = TeamTemplateFactory.faang()
    }

    override func tearDown() async throws {
        service = nil
        mockDelegate = nil
        faang = nil
        try await super.tearDown()
    }

    private func makeTask() -> NTMSTask {
        NTMSTask(
            id: 1, title: "Test Task", supervisorTask: "Build a calculator",
            runs: [Run(id: 0)]
        )
    }

    func testConsultationChat_systemPromptIsResolvedTeamTemplate() {
        guard let pm = faang.roles.first(where: { $0.name == "Product Manager" }) else {
            return XCTFail("FAANG team must have a PM")
        }
        let chat = service.getOrCreateConsultationChat(
            roleID: pm.id, task: makeTask(), runIndex: 0, team: faang
        )

        let expected = TemplateResolver.resolveSystemPrompt(
            faang.consultationPromptTemplate,
            placeholders: [
                "consultedRoleName": pm.name,
                "requestingRoleName": "a teammate",
                "roleGuidance": pm.prompt,
                "teamDescription": faang.description,
                "globalContext": PromptBuilder.formatGlobalContext(""),
            ],
            globalContext: ""
        )

        XCTAssertEqual(chat.messages.first?.role, .system)
        XCTAssertEqual(chat.messages.first?.content, expected,
                       "live consultation system prompt must be the resolved team template, "
                           + "byte-identical to what the Settings preview reconstructs")
        XCTAssertTrue(chat.messages.first?.content.contains("## Role") ?? false,
                      "template is `##`-sectioned; the old prose prompt was not")
        XCTAssertFalse(chat.messages.first?.content.contains("Be concise and professional") ?? true,
                       "the legacy hand-built prose prompt must be gone")
    }

    /// Task title/brief are variant data — they belong in the first user turn,
    /// not the system prompt (stable invariant prefix).
    func testConsultationChat_taskContextIsFirstUserTurn_notInSystemPrompt() {
        guard let pm = faang.roles.first(where: { $0.name == "Product Manager" }) else {
            return XCTFail("FAANG team must have a PM")
        }
        let chat = service.getOrCreateConsultationChat(
            roleID: pm.id, task: makeTask(), runIndex: 0, team: faang
        )

        XCTAssertFalse(chat.messages[0].content.contains("Build a calculator"),
                       "supervisor brief must not be baked into the system prompt")
        XCTAssertEqual(chat.messages[1].role, .user)
        XCTAssertTrue(chat.messages[1].content.contains("Test Task"))
        XCTAssertTrue(chat.messages[1].content.contains("Build a calculator"))
    }

    /// Unknown role on a nil team falls back to the generic template and the
    /// built-in role-prompt library — never crashes, never ships an empty prompt.
    func testConsultationChat_nilTeam_fallsBackToGenericTemplate() {
        let chat = service.getOrCreateConsultationChat(
            roleID: "productManager", task: makeTask(), runIndex: 0, team: nil
        )
        let system = chat.messages.first?.content ?? ""
        XCTAssertFalse(system.isEmpty)
        XCTAssertTrue(system.contains("## Role"),
                      "nil team must resolve the generic consultation template")
    }
}
