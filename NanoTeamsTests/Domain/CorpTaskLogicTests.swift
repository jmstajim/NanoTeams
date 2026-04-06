import XCTest
@testable import NanoTeams

/// Tests for NTMSTask business logic (derivedStatus, toSummary)
final class NTMSTaskLogicTests: XCTestCase {

    // MARK: - derivedStatusFromActiveRun Tests

    func testDerivedStatusWithNoRuns() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .paused)

        // With no runs, should return the stored status
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithEmptySteps() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .done)
        task.runs = [Run(id: 0, steps: [])]

        // With empty steps, should return .running (the fallback)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithAllDoneSteps() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ])
        ]

        // Without closedAt, all done → .needsSupervisorAcceptance
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)

        // With closedAt, all done → .done
        task.closedAt = Date()
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .done)
    }

    func testDerivedStatusWithFailedStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .failed),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Failed takes highest priority
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusWithNeedsSupervisorInputStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorInput)
    }

    func testDerivedStatusWithPausedStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithRunningStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .running),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Running and pending steps should result in .running overall
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusPriority_FailedOverNeedsSupervisor() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Failed has highest priority
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusPriority_NeedsSupervisorOverPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .needsSupervisorInput),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // needsSupervisorInput has priority over paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorInput)
    }

    func testDerivedStatusUsesLastRun() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            // First run - all done
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ]),
            // Second (last) run - has failure
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed)
            ])
        ]

        // Should use the last run's status
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testDerivedStatusWithNeedsApprovalAndRunningStep() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ])
        ]

        // When a role needs approval but another is still running, task should show .running
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusWithNeedsApprovalAndRunningStep_recoveredTask() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsApproval),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .running)
            ])
        ]

        // .running base (has running steps) — recovery status doesn't override derivation
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    // MARK: - derivedStatus + roleStatuses Tests

    func testDerivedStatus_allStepsDone_rolesNotComplete_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .working   // Still working — task should NOT be needsSupervisorAcceptance
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatus_allStepsDone_rolesNeedAcceptance_returnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .needsAcceptance   // Waiting for Supervisor — task should show Review, not Working
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testDerivedStatus_allStepsDone_mixedAcceptanceAndWorking_returnsRunning() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "pm": .needsAcceptance,
                "eng": .working   // Still working — task should be running
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatus_allStepsDone_allRolesComplete_returnsNeedsSupervisorAcceptance() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
            ], roleStatuses: [
                "supervisor": .done,
                "pm": .done,
                "eng": .done
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    func testDerivedStatus_emptyRoleStatuses_fallsThrough() {
        // Legacy runs have empty roleStatuses — should still work
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done)
            ])
        ]

        XCTAssertEqual(task.derivedStatusFromActiveRun(), .needsSupervisorAcceptance)
    }

    // MARK: - toSummary Tests

    func testToSummary() {
        let taskID = 0
        let updatedAt = Date()
        var task = NTMSTask(
            id: taskID,
            title: "Implement Login",
            supervisorTask: "Add login feature",
            status: .running,
            updatedAt: updatedAt
        )
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .done)
            ])
        ]

        let summary = task.toSummary()

        XCTAssertEqual(summary.id, taskID)
        XCTAssertEqual(summary.title, "Implement Login")
        XCTAssertEqual(summary.status, .needsSupervisorAcceptance) // Uses derived status (closedAt is nil)
        XCTAssertEqual(summary.updatedAt, updatedAt)
    }

    func testToSummaryWithFailedRun() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal", status: .running)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
            ])
        ]

        let summary = task.toSummary()

        // Summary should reflect derived failed status
        XCTAssertEqual(summary.status, .failed)
    }

    // MARK: - Run derivedStatus Tests

    func testRunDerivedStatusWithNoSteps() {
        let run = Run(id: 0, steps: [])
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testRunDerivedStatusAllDone() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .done)
        ])
        XCTAssertEqual(run.derivedStatus(), .done)
    }

    func testRunDerivedStatusWithFailed() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .failed)
        ])
        XCTAssertEqual(run.derivedStatus(), .failed)
    }

    func testRunDerivedStatusWithNeedsSupervisorInput() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .needsSupervisorInput)
        ])
        XCTAssertEqual(run.derivedStatus(), .needsSupervisorInput)
    }

    func testRunDerivedStatusWithPaused() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused)
        ])
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    func testRunDerivedStatusWithMixedPendingAndDone() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
        ])
        // Not all done, no failure/needsSupervisor/paused -> running
        XCTAssertEqual(run.derivedStatus(), .running)
    }

    func testRunDerivedStatusWithNeedsApproval() {
        let run = Run(id: 0, steps: [
            StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
            StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .needsApproval)
        ])
        // needsApproval means waiting for Supervisor — maps to .paused at task level
        XCTAssertEqual(run.derivedStatus(), .paused)
    }

    // MARK: - Recovery Status Tests

    func testDerivedStatusReturnsPausedAfterRecovery() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // Paused steps → .paused (recovery and explicit pause produce same result)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusReturnsPausedWhenExplicitlyPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .running  // Normal running state (not recovered)
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused),
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .pending)
            ])
        ]

        // With .running status and paused steps → .paused (explicit pause)
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatusWithNoPausedStepsAndPendingWork() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Recovered — no steps actually running
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .done),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .pending)
            ])
        ]

        // Base is .running (pending work) but no steps are actually running + task.status is .paused → .paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
    }

    func testDerivedStatus_emptySteps_ignoredStoredPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused  // Set by recovery, but run has no steps yet
        task.runs = [Run(id: 0, steps: [])]

        // Empty steps → always .running, stored .paused is ignored
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .running)
    }

    func testDerivedStatusFailedOverridesPaused() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .failed),
                StepExecution(id: "test_step", role: .tpm, title: "PM", status: .paused)
            ])
        ]

        // .failed still takes priority over .paused
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .failed)
    }

    func testToSummaryReflectsPausedStatus() {
        var task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        task.status = .paused
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .productManager, title: "PO", status: .paused)
            ])
        ]

        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
    }

    func testDerivedStatus_chatMode_recoveredTask_returnsPaused() {
        var task = NTMSTask(id: 0, title: "Chat", supervisorTask: "Goal", isChatMode: true)
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Chat-mode recovered task derives .paused — display layer shows "Chat"
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
        XCTAssertTrue(summary.isChatMode)
        XCTAssertEqual(summary.status.displayLabel(isChatMode: summary.isChatMode), "Chat")
    }

    func testDerivedStatus_nonChatMode_recoveredTask_returnsPaused() {
        var task = NTMSTask(id: 0, title: "Task", supervisorTask: "Goal", isChatMode: false)
        task.status = .paused  // Set by StatusRecoveryService
        task.runs = [
            Run(id: 0, steps: [
                StepExecution(id: "test_step", role: .softwareEngineer, title: "Eng", status: .paused)
            ])
        ]

        // Non-chat recovered task derives .paused — display layer shows "Paused"
        XCTAssertEqual(task.derivedStatusFromActiveRun(), .paused)
        let summary = task.toSummary()
        XCTAssertEqual(summary.status, .paused)
        XCTAssertFalse(summary.isChatMode)
        XCTAssertEqual(summary.status.displayLabel(isChatMode: summary.isChatMode), "Paused")
    }

    // MARK: - TaskSummary Tests

    func testTaskSummaryIdentifiable() {
        let id = 42
        let summary = TaskSummary(id: id, title: "Test", status: .running)
        XCTAssertEqual(summary.id, id)
    }

    func testTaskSummaryHashable() {
        let summary1 = TaskSummary(id: 0, title: "Test 1", status: .running)
        let summary2 = TaskSummary(id: 0, title: "Test 2", status: .done)

        var set = Set<TaskSummary>()
        set.insert(summary1)
        set.insert(summary2)
        set.insert(summary1) // duplicate

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - TasksIndex Tests

    func testTasksIndexDefaults() {
        let index = TasksIndex()
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertTrue(index.tasks.isEmpty)
    }

    func testTasksIndexWithTasks() {
        let tasks = [
            TaskSummary(id: 0, title: "Task 1", status: .running),
            TaskSummary(id: 0, title: "Task 2", status: .done)
        ]
        let index = TasksIndex(schemaVersion: 2, tasks: tasks)

        XCTAssertEqual(index.schemaVersion, 2)
        XCTAssertEqual(index.tasks.count, 2)
    }

    // MARK: - Initial Input

    func testHasInitialInput_falseWhenAllInputsEmpty() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "")

        XCTAssertFalse(task.hasInitialInput)
    }

    func testHasInitialInput_goalOnly() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Ship the feature")

        XCTAssertTrue(task.hasInitialInput)
    }

    func testHasInitialInput_clippedTextOnly() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "", clippedTexts: ["Copied selection"])

        XCTAssertTrue(task.hasInitialInput)
    }

    func testHasInitialInput_attachmentOnly() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "",
            attachmentPaths: [".nanoteams/tasks/123/attachments/spec.pdf"]
        )

        XCTAssertTrue(task.hasInitialInput)
    }

    func testEffectiveSupervisorBrief_combinesGoalClipAndAttachments() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Implement import flow",
            clippedTexts: ["Use the selected API response shape"],
            attachmentPaths: [
                ".nanoteams/tasks/123/attachments/spec.pdf",
                ".nanoteams/tasks/123/attachments/mock.png"
            ]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            """
            Implement import flow

            --- Clipped Text ---
            Use the selected API response shape

            --- Attached Files ---
            - .nanoteams/tasks/123/attachments/spec.pdf
            - .nanoteams/tasks/123/attachments/mock.png
            """
        )
    }

    func testEffectiveSupervisorBrief_emptyGoalWithClippedTextOnly() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "",
            clippedTexts: ["Selected text from app"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "--- Clipped Text ---\nSelected text from app"
        )
    }

    func testEffectiveSupervisorBrief_emptyWhenAllInputsEmpty() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "")
        XCTAssertTrue(task.effectiveSupervisorBrief.isEmpty)
    }

    func testHasInitialInput_falseWithWhitespaceOnlyGoal() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "   \n\t")
        XCTAssertFalse(task.hasInitialInput)
    }

    func testHasInitialInput_trueWithAllInputs() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Goal",
            clippedTexts: ["clip"],
            attachmentPaths: ["file.txt"]
        )
        XCTAssertTrue(task.hasInitialInput)
    }

    func testEffectiveSupervisorBrief_attachmentsOnly() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "",
            attachmentPaths: [".nanoteams/tasks/1/attachments/spec.pdf"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "--- Attached Files ---\n- .nanoteams/tasks/1/attachments/spec.pdf"
        )
    }

    func testEffectiveSupervisorBrief_goalAndAttachments_noClip() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Build feature",
            attachmentPaths: ["file.pdf"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            "Build feature\n\n--- Attached Files ---\n- file.pdf"
        )
    }

    func testEffectiveSupervisorBrief_whitespaceClippedText_ignored() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Goal",
            clippedTexts: ["   \n\t"]
        )

        XCTAssertEqual(task.effectiveSupervisorBrief, "Goal")
    }

    func testDecodingMissingQuickCaptureFields_defaultsCleanly() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertTrue(task.clippedTexts.isEmpty)
        XCTAssertTrue(task.attachmentPaths.isEmpty)
    }

    func testDecodingLegacyClippedText_migratesCorrectly() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal",
          "clippedText": "legacy clip value"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertEqual(task.clippedTexts, ["legacy clip value"])
    }

    func testDecodingLegacyClippedTextNull_migratesEmpty() throws {
        let json = """
        {
          "id": 0,
          "title": "Test",
          "supervisorTask": "Goal",
          "clippedText": null
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(NTMSTask.self, from: json)

        XCTAssertTrue(task.clippedTexts.isEmpty)
    }

    func testEffectiveSupervisorBrief_multipleClips() {
        let task = NTMSTask(id: 0, title: "Test",
            supervisorTask: "Goal",
            clippedTexts: ["First clip", "Second clip"]
        )

        XCTAssertEqual(
            task.effectiveSupervisorBrief,
            """
            Goal

            --- Clipped Text (1 of 2) ---
            First clip

            --- Clipped Text (2 of 2) ---
            Second clip
            """
        )
    }

    // MARK: - TaskStatus Display Labels

    func testTaskStatusDisplayLabels() {
        XCTAssertEqual(TaskStatus.running.displayLabel, "Working")
        XCTAssertEqual(TaskStatus.done.displayLabel, "Done")
        XCTAssertEqual(TaskStatus.paused.displayLabel, "Paused")
        XCTAssertEqual(TaskStatus.waiting.displayLabel, "Waiting")
        XCTAssertEqual(TaskStatus.needsSupervisorInput.displayLabel, "Needs Supervisor")
        XCTAssertEqual(TaskStatus.needsSupervisorAcceptance.displayLabel, "Review")
        XCTAssertEqual(TaskStatus.failed.displayLabel, "Failed")
    }
}
