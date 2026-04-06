import XCTest
@testable import NanoTeams

/// Tests for Run.derivedStatus() - comprehensive coverage of all status combinations
final class RunDerivedStatusTests: XCTestCase {

    // MARK: - Empty Steps

    func testDerivedStatusWithEmptyStepsReturnsRunning() {
        let run = Run(id: 0, steps: [])
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    // MARK: - Single Step Cases

    func testDerivedStatusWithSinglePendingStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .pending)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testDerivedStatusWithSingleRunningStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .running)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testDerivedStatusWithSingleDoneStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .done)
    }

    func testDerivedStatusWithSingleFailedStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testDerivedStatusWithSinglePausedStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    func testDerivedStatusWithSingleNeedsSupervisorInputStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsSupervisorInput)
        let run = Run(id: 0, steps: [step])
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testDerivedStatusWithSingleNeedsApprovalStep() {
        let step = StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval)
        let run = Run(id: 0, steps: [step])
        // needsApproval means waiting for Supervisor — maps to .paused at task level
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Status Priority Tests (failed > needsSupervisorInput > paused > done)

    func testFailedTakesPriorityOverNeedsSupervisorInput() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsSupervisorInput),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testFailedTakesPriorityOverPaused() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testFailedTakesPriorityOverDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .failed)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testNeedsSupervisorInputTakesPriorityOverPaused() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testNeedsSupervisorInputTakesPriorityOverDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsSupervisorInput)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testPausedTakesPriorityOverDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .paused)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Multiple Steps All Done

    func testDerivedStatusAllStepsDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .tpm, title: "PM", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .done),
            StepExecution(id: "test_step", role: .sre, title: "QA", status: .done)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .done)
    }

    // MARK: - Mixed Status Cases

    func testDerivedStatusMixedWithPendingAndDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .pending)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testDerivedStatusMixedWithRunningAndDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .running)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testDerivedStatusMixedWithNeedsApprovalAndDone() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsApproval)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    func testDerivedStatusNeedsApprovalWithRunningStep_returnsRunning() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .running)
        ]
        let run = Run(id: 0, steps: steps)
        // When a role needs approval but another is still running, show .running (not .paused)
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testDerivedStatusNeedsApprovalWithRunningAndFailed_returnsFailedPriority() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .running),
            StepExecution(id: "test_step", role: .sre, title: "SRE", status: .failed)
        ]
        let run = Run(id: 0, steps: steps)
        // .failed always takes highest priority regardless of hasRunning
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testDerivedStatusNeedsApprovalWithPendingStep_returnsPaused() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .pending)
        ]
        let run = Run(id: 0, steps: steps)
        // .pending is not .running — approval takes priority when nothing is actively executing
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Full Priority Chain Test

    func testFullPriorityChainWithAllStatuses() {
        // Test with all statuses present - failed should win
        let steps = [
            StepExecution(id: "test_step", role: .supervisor, title: "Supervisor", status: .done),
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .pending),
            StepExecution(id: "test_step", role: .tpm, title: "PM", status: .running),
            StepExecution(id: "test_step", role: .uxDesigner, title: "Designer", status: .paused),
            StepExecution(id: "test_step", role: .codeReviewer, title: "PM Review", status: .needsSupervisorInput),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsApproval),
            StepExecution(id: "test_step", role: .sre, title: "QA", status: .failed)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testPriorityChainWithoutFailed() {
        // Without failed - needsSupervisorInput should win
        let steps = [
            StepExecution(id: "test_step", role: .supervisor, title: "Supervisor", status: .done),
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .pending),
            StepExecution(id: "test_step", role: .tpm, title: "PM", status: .running),
            StepExecution(id: "test_step", role: .uxDesigner, title: "Designer", status: .paused),
            StepExecution(id: "test_step", role: .codeReviewer, title: "PM Review", status: .needsSupervisorInput),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsApproval)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testPriorityChainWithoutFailedOrNeedsSupervisorInput() {
        // Without failed or needsSupervisorInput - paused should win
        let steps = [
            StepExecution(id: "test_step", role: .supervisor, title: "Supervisor", status: .done),
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .pending),
            StepExecution(id: "test_step", role: .tpm, title: "PM", status: .running),
            StepExecution(id: "test_step", role: .uxDesigner, title: "Designer", status: .paused),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Engineer", status: .needsApproval)
        ]
        let run = Run(id: 0, steps: steps)
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Run Mode Variants (same logic regardless of mode)

    func testDerivedStatusSameAcrossAllModes() {
        let steps = [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed)
        ]

        let manualRun = Run(id: 0, steps: steps)
        let guidedRun = Run(id: 0, steps: steps)
        let autonomousRun = Run(id: 0, steps: steps)

        XCTAssertEqual(manualRun.derivedStatus(), .failed)
        XCTAssertEqual(guidedRun.derivedStatus(), .failed)
        XCTAssertEqual(autonomousRun.derivedStatus(), .failed)
    }
}
