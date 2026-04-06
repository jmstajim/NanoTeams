import XCTest

@testable import NanoTeams

final class ToolsTeammateTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var registry: ToolRegistry!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        let (reg, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0)
        )
        registry = reg
        runtime = run

        context = ToolExecutionContext(
            workFolderRoot: tempDir,
            taskID: Int(),
            runID: 0,
            roleID: "test_role"
        )
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        registry = nil
//        runtime = nil
        context = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Tool Registration Tests

    func testTeammateToolsRegistered() {
        let toolNames = registry.registeredToolNames

        XCTAssertTrue(toolNames.contains("ask_teammate"))
        XCTAssertTrue(toolNames.contains("request_team_meeting"))
        XCTAssertTrue(toolNames.contains("conclude_meeting"))
    }

    // MARK: - ask_teammate Tests

    func testAskTeammate_validRequest() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: """
            {
                "teammate": "softwareEngineer",
                "question": "How should I implement the caching layer?"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .teammateConsultation(id: "softwareEngineer", question: "How should I implement the caching layer?", context: nil))
    }

    func testAskTeammate_withContext() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: """
            {
                "teammate": "uxDesigner",
                "question": "What color palette should we use?",
                "context": "We're building a finance app for professionals."
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .teammateConsultation(id: "uxDesigner", question: "What color palette should we use?", context: "We're building a finance app for professionals."))
    }

    func testAskTeammate_allValidRoles() {
        let validRoles = ["productManager", "tpm", "uxDesigner", "softwareEngineer", "sre", "codeReviewer"]

        for role in validRoles {
            let call = StepToolCall(
                name: "ask_teammate",
                argumentsJSON: """
                {
                    "teammate": "\(role)",
                    "question": "Test question?"
                }
                """
            )
            let results = runtime.executeAll(context: context, toolCalls: [call])

            XCTAssertEqual(results.count, 1, "Failed for role: \(role)")
            XCTAssertFalse(results[0].isError, "Failed for role: \(role)")
            if case .teammateConsultation(let id, _, _) = results[0].signal { XCTAssertEqual(id, role) } else { XCTFail("Expected teammateConsultation signal for role: \(role)") }
        }
    }

    func testAskTeammate_unknownRole_passesToServiceLayer() {
        // Tool layer no longer validates role IDs — that's handled by the service layer
        // which has access to team context and supports built-in IDs, UUIDs, and names.
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: """
            {
                "teammate": "invalidRole",
                "question": "Test?"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        if case .teammateConsultation(let id, _, _) = results[0].signal { XCTAssertEqual(id, "invalidRole") } else { XCTFail("Expected teammateConsultation signal") }
    }

    func testAskTeammate_missingTeammate() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: "{\"question\": \"Test?\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    func testAskTeammate_missingQuestion() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: "{\"teammate\": \"designer\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    func testAskTeammate_outputContainsPendingStatus() {
        let call = StepToolCall(
            name: "ask_teammate",
            argumentsJSON: """
            {
                "teammate": "softwareEngineer",
                "question": "Test?"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertTrue(results[0].outputJSON.contains("pending"))
    }

    // MARK: - request_team_meeting Tests

    func testRequestTeamMeeting_validRequest() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: """
            {
                "topic": "Architecture discussion",
                "participants": ["softwareEngineer", "uxDesigner"]
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertEqual(results[0].signal, .teamMeeting(topic: "Architecture discussion", participants: ["softwareEngineer", "uxDesigner"], context: nil))
    }

    func testRequestTeamMeeting_withContext() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: """
            {
                "topic": "Sprint planning",
                "participants": ["productManager", "tpm", "softwareEngineer"],
                "context": "Need to align on Q2 priorities"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        if case .teamMeeting(_, _, let context) = results[0].signal { XCTAssertEqual(context, "Need to align on Q2 priorities") } else { XCTFail("Expected teamMeeting signal") }
    }

    func testRequestTeamMeeting_singleParticipant() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: """
            {
                "topic": "One-on-one",
                "participants": ["softwareEngineer"]
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        if case .teamMeeting(_, let participants, _) = results[0].signal { XCTAssertEqual(participants.count, 1) } else { XCTFail("Expected teamMeeting signal") }
    }

    func testRequestTeamMeeting_emptyParticipants() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: """
            {
                "topic": "Empty meeting",
                "participants": []
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
        XCTAssertTrue(results[0].outputJSON.contains("At least one participant"))
    }

    func testRequestTeamMeeting_anyParticipant_passesToServiceLayer() {
        // Tool layer no longer validates participant IDs — that's handled by the service layer
        // which has access to team context and supports built-in IDs, UUIDs, and names.
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: """
            {
                "topic": "Meeting",
                "participants": ["softwareEngineer", "customRole"]
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
    }

    func testRequestTeamMeeting_missingTopic() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: "{\"participants\": [\"designer\"]}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
    }

    func testRequestTeamMeeting_missingParticipants() {
        let call = StepToolCall(
            name: "request_team_meeting",
            argumentsJSON: "{\"topic\": \"Test\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
    }

    // MARK: - conclude_meeting Tests

    func testConcludeMeeting_validRequest() {
        let call = StepToolCall(
            name: "conclude_meeting",
            argumentsJSON: """
            {
                "decision": "We will use microservices architecture"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("We will use microservices architecture"))
        XCTAssertTrue(results[0].outputJSON.contains("concluded"))
    }

    func testConcludeMeeting_withRationale() {
        let call = StepToolCall(
            name: "conclude_meeting",
            argumentsJSON: """
            {
                "decision": "Use REST API",
                "rationale": "Better tooling support and team familiarity"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Better tooling support"))
    }

    func testConcludeMeeting_withNextSteps() {
        let call = StepToolCall(
            name: "conclude_meeting",
            argumentsJSON: """
            {
                "decision": "Implement caching",
                "next_steps": "1. Design cache layer\\n2. Implement Redis integration"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("Design cache layer"))
    }

    func testConcludeMeeting_fullDetails() {
        let call = StepToolCall(
            name: "conclude_meeting",
            argumentsJSON: """
            {
                "decision": "Adopt SwiftUI for new features",
                "rationale": "Better declarative syntax and future iOS compatibility",
                "next_steps": "Update project templates and documentation"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("SwiftUI"))
        XCTAssertTrue(results[0].outputJSON.contains("declarative syntax"))
        XCTAssertTrue(results[0].outputJSON.contains("Update project templates"))
    }

    func testConcludeMeeting_missingDecision() {
        let call = StepToolCall(
            name: "conclude_meeting",
            argumentsJSON: "{\"rationale\": \"Some reason\"}"
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].outputJSON.contains("INVALID_ARGS"))
    }

    // MARK: - Data Structure Tests

    func testAskTeammateData_codable() throws {
        let data = AskTeammateData(
            teammate: "uxDesigner",
            question: "What colors?",
            context: "Mobile app",
            status: "pending"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        let decoded = try JSONDecoder().decode(AskTeammateData.self, from: encoded)

        XCTAssertEqual(decoded.teammate, "uxDesigner")
        XCTAssertEqual(decoded.question, "What colors?")
        XCTAssertEqual(decoded.context, "Mobile app")
        XCTAssertEqual(decoded.status, "pending")
    }

    func testAskTeammateData_optionalContext() throws {
        let data = AskTeammateData(
            teammate: "sre",
            question: "Test coverage?",
            context: nil,
            status: "pending"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        let decoded = try JSONDecoder().decode(AskTeammateData.self, from: encoded)

        XCTAssertNil(decoded.context)
    }

    // MARK: - request_changes Tests (Round 2 regression)

    func testRequestChanges_customUUID_passesToServiceLayer() {
        let customUUID = UUID().uuidString
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "\(customUUID)",
                "changes": "Refactor the auth module",
                "reasoning": "Security concerns"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError, "Custom UUID should pass tool layer validation")
        XCTAssertEqual(
            results[0].signal,
            .changeRequest(targetRole: customUUID, changes: "Refactor the auth module", reasoning: "Security concerns")
        )
    }

    func testRequestChanges_validRequest() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "changes": "Add error handling",
                "reasoning": "Missing try/catch blocks"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isError)
        if case .changeRequest(let target, let changes, let reasoning) = results[0].signal {
            XCTAssertEqual(target, "softwareEngineer")
            XCTAssertEqual(changes, "Add error handling")
            XCTAssertEqual(reasoning, "Missing try/catch blocks")
        } else {
            XCTFail("Expected changeRequest signal")
        }
    }

    func testRequestChanges_missingChangesField() {
        let call = StepToolCall(
            name: "request_changes",
            argumentsJSON: """
            {
                "target_role": "softwareEngineer",
                "reasoning": "Missing try/catch blocks"
            }
            """
        )
        let results = runtime.executeAll(context: context, toolCalls: [call])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError, "Missing 'changes' field should produce an error")
    }

    // MARK: - Codable Data Models

    func testRequestMeetingData_codable() throws {
        let data = RequestMeetingData(
            topic: "Sprint planning",
            participants: ["productManager", "softwareEngineer"],
            context: "Q2 planning",
            status: "pending"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        let decoded = try JSONDecoder().decode(RequestMeetingData.self, from: encoded)

        XCTAssertEqual(decoded.topic, "Sprint planning")
        XCTAssertEqual(decoded.participants, ["productManager", "softwareEngineer"])
        XCTAssertEqual(decoded.context, "Q2 planning")
        XCTAssertEqual(decoded.status, "pending")
    }
}
