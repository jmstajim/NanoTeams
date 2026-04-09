import XCTest

@testable import NanoTeams

@MainActor
final class TeamActivityFeedViewModelAttachmentTests: XCTestCase {

    var viewModel: TeamActivityFeedViewModel!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
        viewModel = TeamActivityFeedViewModel()
        tempFiles = []
    }

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles = []
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Attachment State Management

    func testSupervisorAnswerAttachments_initiallyEmpty() {
        let stepID = "test_step"
        XCTAssertNil(viewModel.supervisorAnswerAttachments[stepID])
    }

    func testSupervisorAnswerAttachments_storeAndRetrieve() throws {
        let stepID = "test_step"
        let relativePath = ".nanoteams/staged/\(stepID)/test.png"
        let attachment = try makeAttachment(relativePath: relativePath)
        viewModel.supervisorAnswerAttachments[stepID] = [attachment]

        XCTAssertEqual(viewModel.supervisorAnswerAttachments[stepID]?.count, 1)
        XCTAssertEqual(viewModel.supervisorAnswerAttachments[stepID]?.first?.id, relativePath)
    }

    func testSupervisorAnswerAttachments_multipleSteps() throws {
        let step1 = "step1"
        let step2 = "step2"

        viewModel.supervisorAnswerAttachments[step1] = [
            try makeAttachment(relativePath: ".nanoteams/staged/\(step1)/a.png"),
        ]
        viewModel.supervisorAnswerAttachments[step2] = [
            try makeAttachment(relativePath: ".nanoteams/staged/\(step2)/b.png"),
            try makeAttachment(relativePath: ".nanoteams/staged/\(step2)/c.pdf"),
        ]

        XCTAssertEqual(viewModel.supervisorAnswerAttachments[step1]?.count, 1)
        XCTAssertEqual(viewModel.supervisorAnswerAttachments[step2]?.count, 2)
    }

    // MARK: - Submit Guard

    func testSubmitGuard_emptyTextAndNoAttachments_doesNotSubmit() {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = ""
        viewModel.supervisorAnswerAttachments[stepID] = []

        let store = NTMSOrchestrator(repository: NTMSRepository())
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        XCTAssertFalse(viewModel.isSubmittingAnswer.contains(stepID))
    }

    func testSubmitGuard_textOnly_submits() {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = "Answer"

        let store = NTMSOrchestrator(repository: NTMSRepository())
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        XCTAssertTrue(viewModel.isSubmittingAnswer.contains(stepID))
    }

    func testSubmitGuard_attachmentsOnly_submits() throws {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = ""
        viewModel.supervisorAnswerAttachments[stepID] = [
            try makeAttachment(relativePath: ".nanoteams/staged/\(stepID)/file.png"),
        ]

        let store = NTMSOrchestrator(repository: NTMSRepository())
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        XCTAssertTrue(viewModel.isSubmittingAnswer.contains(stepID))
    }

    func testSubmitGuard_doubleSubmit_blocked() {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = "Answer"

        let store = NTMSOrchestrator(repository: NTMSRepository())

        // First submit
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)
        XCTAssertTrue(viewModel.isSubmittingAnswer.contains(stepID))

        // Second submit should be blocked by the guard
        // (isSubmittingAnswer already contains stepID)
        viewModel.supervisorAnswerText[stepID] = "Second answer"
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        // Still submitting from first call — text was not cleared by second call
        XCTAssertTrue(viewModel.isSubmittingAnswer.contains(stepID))
    }

    // MARK: - Failure Preservation

    func testSubmit_failedAnswer_preservesInputForRetry() async throws {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = "My answer"
        viewModel.supervisorAnswerAttachments[stepID] = [
            try makeAttachment(relativePath: ".nanoteams/staged/\(stepID)/file.png"),
        ]

        // Store with no project → answerSupervisorQuestion returns false
        let store = NTMSOrchestrator(repository: NTMSRepository())
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        // Wait for the async Task to complete
        try? await Task.sleep(for: .milliseconds(100))

        // On failure, answer and attachments should be preserved for retry
        XCTAssertNotNil(viewModel.supervisorAnswerText[stepID])
        XCTAssertNotNil(viewModel.supervisorAnswerAttachments[stepID])
        XCTAssertFalse(viewModel.isSubmittingAnswer.contains(stepID))
    }

    // MARK: - Nil TaskID Preservation

    func testSubmit_nilTaskID_preservesAnswerAndAttachments() async throws {
        let stepID = "test_step"
        viewModel.supervisorAnswerText[stepID] = "My answer"
        viewModel.supervisorAnswerAttachments[stepID] = [
            try makeAttachment(relativePath: ".nanoteams/staged/\(stepID)/file.png"),
        ]

        // Store with no project → activeTaskID is nil
        let store = NTMSOrchestrator(repository: NTMSRepository())
        viewModel.submitSupervisorAnswer(stepID: stepID, store: store)

        // Wait for the async Task to complete
        try? await Task.sleep(for: .milliseconds(100))

        // Answer and attachments should be preserved (not cleared)
        XCTAssertNotNil(viewModel.supervisorAnswerText[stepID])
        XCTAssertNotNil(viewModel.supervisorAnswerAttachments[stepID])
        XCTAssertFalse(viewModel.isSubmittingAnswer.contains(stepID))
    }

    // MARK: - Timeline Fingerprint

    func testTimelineFingerprint_includesSupervisorInputCount() {
        let step1 = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "SWE",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Question?"
        )
        let step2 = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PM",
            status: .done
        )

        let fingerprint = viewModel.computeFingerprint(
            steps: [step1, step2], run: nil, activeTaskID: Int()
        )

        XCTAssertEqual(fingerprint.supervisorInputCount, 1)
    }

    func testTimelineFingerprint_answeredQuestionNotCounted() {
        var step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "SWE",
            status: .needsSupervisorInput,
            needsSupervisorInput: true,
            supervisorQuestion: "Question?"
        )
        step.supervisorAnswer = "Answer"
        // needsSupervisorInput still true but answer is set — shouldn't be counted
        // Actually, after answering, needsSupervisorInput is set to false by StepMessagingService
        step.needsSupervisorInput = false

        let fingerprint = viewModel.computeFingerprint(
            steps: [step], run: nil, activeTaskID: Int()
        )

        XCTAssertEqual(fingerprint.supervisorInputCount, 0)
    }

    // MARK: - Helpers

    private func makeAttachment(relativePath: String) throws -> StagedAttachment {
        // Create a temporary file so StagedAttachment can read file attributes
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        tempFiles.append(fileURL)
        return try StagedAttachment(url: fileURL, stagedRelativePath: relativePath)
    }
}
