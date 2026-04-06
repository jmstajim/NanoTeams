import XCTest

@testable import NanoTeams

final class StepExecutionAttachmentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - effectiveSupervisorAnswer

    func testEffectiveSupervisorAnswer_nilWhenNoAnswer() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        XCTAssertNil(step.effectiveSupervisorAnswer)
    }

    func testEffectiveSupervisorAnswer_textOnlyWhenNoAttachments() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = "Use async/await"

        XCTAssertEqual(step.effectiveSupervisorAnswer, "Use async/await")
    }

    func testEffectiveSupervisorAnswer_includesAttachmentPaths() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = "See attached screenshot"
        step.supervisorAnswerAttachmentPaths = [
            ".nanoteams/tasks/abc/attachments/screenshot.png"
        ]

        let result = step.effectiveSupervisorAnswer!
        XCTAssertTrue(result.hasPrefix("See attached screenshot"))
        XCTAssertTrue(result.contains("--- Attached Files ---"))
        XCTAssertTrue(result.contains("- .nanoteams/tasks/abc/attachments/screenshot.png"))
    }

    func testEffectiveSupervisorAnswer_multipleAttachments() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = "Here are the files"
        step.supervisorAnswerAttachmentPaths = [
            ".nanoteams/tasks/abc/attachments/image.png",
            ".nanoteams/tasks/abc/attachments/spec.pdf",
        ]

        let result = step.effectiveSupervisorAnswer!
        let lines = result.components(separatedBy: "\n")
        let attachmentLines = lines.filter { $0.hasPrefix("- ") }
        XCTAssertEqual(attachmentLines.count, 2)
    }

    func testEffectiveSupervisorAnswer_nilAnswer_withAttachments_returnsAttachmentInfo() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = nil  // empty text was trimmed to nil by StepMessagingService
        step.supervisorAnswerAttachmentPaths = [".nanoteams/tasks/abc/attachments/file.png"]

        let result = step.effectiveSupervisorAnswer
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("file.png"))
        XCTAssertTrue(result!.contains("--- Attached Files ---"))
        // Should NOT contain empty answer text prefix
        XCTAssertTrue(result!.hasPrefix("--- Attached Files ---"))
    }

    func testEffectiveSupervisorAnswer_nilAnswerAndNoAttachments_returnsNil() {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        XCTAssertNil(step.effectiveSupervisorAnswer)
    }

    func testEffectiveSupervisorAnswer_emptyAttachmentPaths_noSection() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = "Just text"
        step.supervisorAnswerAttachmentPaths = []

        XCTAssertEqual(step.effectiveSupervisorAnswer, "Just text")
        XCTAssertFalse(step.effectiveSupervisorAnswer!.contains("Attached Files"))
    }

    // MARK: - reset() clears attachment paths

    func testReset_clearsSupervisorAnswerAttachmentPaths() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "test",
            status: .done,
            supervisorAnswer: "Answer",
            supervisorAnswerAttachmentPaths: [".nanoteams/tasks/abc/attachments/file.txt"]
        )

        step.reset()

        XCTAssertTrue(step.supervisorAnswerAttachmentPaths.isEmpty)
        XCTAssertNil(step.supervisorAnswer)
    }

    // MARK: - Continuation detection

    func testHasSupervisorContinuation_textAnswer() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.llmSessionID = "session-123"
        step.supervisorAnswer = "Yes, proceed"

        // effectiveSupervisorAnswer is non-nil → continuation should be detected
        XCTAssertNotNil(step.effectiveSupervisorAnswer)
    }

    func testHasSupervisorContinuation_attachmentsOnly() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.llmSessionID = "session-123"
        step.supervisorAnswer = nil  // trimmed empty → nil
        step.supervisorAnswerAttachmentPaths = [".nanoteams/tasks/abc/attachments/file.png"]

        // effectiveSupervisorAnswer must be non-nil for attachment-only answers
        // otherwise hasSupervisorContinuation would be false (bug fixed)
        XCTAssertNotNil(step.effectiveSupervisorAnswer)
    }

    func testHasSupervisorContinuation_noAnswerNoAttachments() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.llmSessionID = "session-123"
        step.supervisorAnswer = nil
        step.supervisorAnswerAttachmentPaths = []

        // No answer at all → continuation should NOT be detected
        XCTAssertNil(step.effectiveSupervisorAnswer)
    }

    func testRevisionContinuation_notTriggeredByAttachmentOnlyAnswer() {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.llmSessionID = "session-123"
        step.supervisorAnswer = nil
        step.supervisorAnswerAttachmentPaths = [".nanoteams/tasks/abc/attachments/file.png"]
        step.revisionComment = "Fix the bug"

        // effectiveSupervisorAnswer is non-nil (attachments present)
        // → revision continuation should NOT activate (it requires effectiveSupervisorAnswer == nil)
        XCTAssertNotNil(step.effectiveSupervisorAnswer)
    }

    // MARK: - Codable round-trip

    func testCodable_roundTrip_withAttachmentPaths() throws {
        var step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")
        step.supervisorAnswer = "See files"
        step.supervisorAnswerAttachmentPaths = [
            ".nanoteams/tasks/abc/attachments/a.png",
            ".nanoteams/tasks/abc/attachments/b.pdf",
        ]

        let encoder = JSONCoderFactory.makePersistenceEncoder()
        let decoder = JSONCoderFactory.makeDateDecoder()
        let data = try encoder.encode(step)
        let decoded = try decoder.decode(StepExecution.self, from: data)

        XCTAssertEqual(decoded.supervisorAnswer, "See files")
        XCTAssertEqual(decoded.supervisorAnswerAttachmentPaths, step.supervisorAnswerAttachmentPaths)
    }

    func testCodable_roundTrip_emptyAttachmentPaths_omittedFromJSON() throws {
        let step = StepExecution(id: "test_step", role: .softwareEngineer, title: "test")

        let data = try JSONCoderFactory.makePersistenceEncoder().encode(step)
        let json = String(data: data, encoding: .utf8)!

        // Empty array should not be in JSON (encodeIfPresent-like behavior)
        XCTAssertFalse(json.contains("supervisorAnswerAttachmentPaths"))
    }

    func testCodable_decodesLegacyJSON_withoutAttachmentPaths() throws {
        // Simulate legacy JSON without the new field
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "role": "softwareEngineer",
            "title": "test",
            "status": "pending",
            "expectedArtifacts": [],
            "needsSupervisorInput": false,
            "messages": [],
            "artifacts": [],
            "toolCalls": [],
            "consultations": [],
            "meetingIDs": [],
            "amendments": [],
            "llmConversation": []
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONCoderFactory.makeDateDecoder().decode(StepExecution.self, from: data)

        XCTAssertTrue(decoded.supervisorAnswerAttachmentPaths.isEmpty)
    }
}
