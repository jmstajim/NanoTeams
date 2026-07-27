import XCTest

@testable import NanoTeams

/// Covers `LLMExecutionService.injectQueuedSupervisorMessage` and its iteration-1
/// continuation guard. Delegate-side consumption rules (priority tiers, queue
/// mutation) are exercised via `MockLLMExecutionDelegate.consumeQueuedSupervisorMessage`
/// here and via orchestrator-level tests separately.
@MainActor
final class LLMQueuedMessageInjectionTests: XCTestCase {
    private var service: LLMExecutionService!
    private var delegate: MockLLMExecutionDelegate!

    override func setUp() {
        super.setUp()
        service = LLMExecutionService(repository: NTMSRepository())
        delegate = MockLLMExecutionDelegate()
        service.attach(delegate: delegate)
    }

    override func tearDown() {
        service = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Injection — happy paths

    func testInject_iterationTwo_consumesRoleTargetedMessage() async {
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: "pm", content: "Supervisor: доложи статус")
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "initial"),
            ChatMessage(role: .assistant, content: "prior"),
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.count, 4, "A single user turn should be appended")
        XCTAssertEqual(conversation.last?.role, .user)
        XCTAssertEqual(conversation.last?.content, "Supervisor: доложи статус")
        XCTAssertEqual(delegate.consumedQueuedMessages.count, 1)
        XCTAssertTrue(delegate.scriptedQueuedMessages.isEmpty, "Queue drained on delivery")
    }

    func testInject_freshStep_allowsInjection() async {
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: "pm", content: "Supervisor: hi")
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "initial"),
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm", // fresh step (e.g. after restartRole)
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.last?.content, "Supervisor: hi",
                       "A fresh step's first iteration accepts a queued message — the restartRole case")
    }

    func testInject_untargetedQueue_consumedWhenNoRoleMatch() async {
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: nil, content: "Supervisor: team-wide note")
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prior")
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.last?.content, "Supervisor: team-wide note")
    }

    func testInject_targetedWinsOverUntargeted_sameTask() async {
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: nil, content: "Supervisor: team first"),
            (taskID: 1, roleID: "pm", content: "Supervisor: PM specific"),
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prior")
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.last?.content, "Supervisor: PM specific",
                       "Role-targeted message pops before untargeted even when untargeted is older")
        XCTAssertEqual(delegate.scriptedQueuedMessages.count, 1)
        XCTAssertEqual(delegate.scriptedQueuedMessages.first?.roleID, nil,
                       "Untargeted message stays for the next consumer")
    }

    // MARK: - Guards

    func testInject_otherRoleTarget_doesNotConsume() async {
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: "tech_lead", content: "Supervisor: TL-only")
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prior")
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.count, 1, "Nothing appended when no match")
        XCTAssertFalse(delegate.scriptedQueuedMessages.isEmpty,
                       "Message targeted at another role stays queued")
    }

    func testInject_emptyQueue_isNoOp() async {
        var conversation: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "prior")
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        XCTAssertEqual(conversation.count, 1)
    }

    // MARK: - Non-interference with retry nudge (finding #11)

    func testInject_appendsAfterPriorTurns_preservingOrder() async {
        // Documents the "queued message + later no-tool-call nudge pile on top" behavior.
        // `handleNoToolCalls` appends its own user nudge further down the loop; this
        // test confirms the queued injection doesn't clobber prior conversation tail.
        delegate.scriptedQueuedMessages = [
            (taskID: 1, roleID: "pm", content: "Supervisor: go")
        ]
        var conversation: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "ok"),
            ChatMessage(role: .user, content: "prior nudge"),
            ChatMessage(role: .assistant, content: "drift"),
        ]

        await service.injectQueuedSupervisorMessage(
            stepID: "pm",
            taskID: 1,
            roleID: "pm",
            conversationMessages: &conversation
        )

        let roles = conversation.map(\.role)
        XCTAssertEqual(roles, [.system, .user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(conversation.last?.content, "Supervisor: go")
    }
}
