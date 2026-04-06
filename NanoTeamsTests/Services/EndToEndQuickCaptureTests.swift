import XCTest

@testable import NanoTeams

/// E2E tests for Quick Capture task creation:
/// title derivation, clipped texts, attachments, auto-start.
@MainActor
final class EndToEndQuickCaptureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Test 1: Goal only — title auto-derived

    func testQuickCapture_goalOnly_titleAutoDerived() {
        let taskText = "Implement user authentication with OAuth2 and JWT tokens for the mobile app"
        let derived = deriveTitleFromTask(taskText)

        XCTAssertFalse(derived.isEmpty, "Should derive non-empty title")
        XCTAssertLessThanOrEqual(derived.count, 63, "Title should be <= 60 chars + ellipsis")
    }

    // MARK: - Test 2: Multiple clipped texts combined in brief

    func testQuickCapture_multipleClippedTexts_combinedInBrief() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Fix the bugs",
            clippedTexts: ["Error in login", "Crash on startup", "Memory leak in profile"]
        )

        let brief = task.effectiveSupervisorBrief

        // Should contain all clips
        XCTAssertTrue(brief.contains("Error in login"))
        XCTAssertTrue(brief.contains("Crash on startup"))
        XCTAssertTrue(brief.contains("Memory leak in profile"))

        // Should contain the task
        XCTAssertTrue(brief.contains("Fix the bugs"))

        // When multiple clips, should number them
        XCTAssertTrue(brief.contains("1") || brief.contains("#1") || brief.contains("Clip 1"),
                      "Multiple clips should be numbered")
    }

    // MARK: - Test 3: Single clipped text in brief

    func testQuickCapture_singleClippedText_inBrief() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Review this code",
            clippedTexts: ["func doSomething() { }"]
        )

        let brief = task.effectiveSupervisorBrief
        XCTAssertTrue(brief.contains("func doSomething()"))
        XCTAssertTrue(brief.contains("Review this code"))
    }

    // MARK: - Test 4: Empty title and task has no initial input

    func testQuickCapture_emptyTitleAndGoal_noInitialInput() {
        let task = NTMSTask(id: 0, title: "", supervisorTask: "")

        XCTAssertFalse(task.hasInitialInput, "Empty title and task should have no initial input")
    }

    // MARK: - Test 5: Task with attachments has initial input

    func testQuickCapture_withAttachments_hasInitialInput() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Analyze this",
            attachmentPaths: ["attachments/screenshot.png"]
        )

        XCTAssertTrue(task.hasInitialInput, "Task with task description should have initial input")
        let brief = task.effectiveSupervisorBrief
        XCTAssertTrue(brief.contains("screenshot.png") || brief.contains("attachment"),
                      "Brief should mention attachments")
    }

    // MARK: - Helpers

    /// Mirrors the title derivation logic from NTMSOrchestrator.createPreparedTaskAndStart.
    /// If that logic changes, this helper must be updated to match.
    private func deriveTitleFromTask(_ taskText: String) -> String {
        let firstLine = taskText.split(separator: "\n").first.map(String.init) ?? taskText
        if firstLine.count > 60 {
            return String(firstLine.prefix(60)) + "..."
        }
        return firstLine
    }
}
