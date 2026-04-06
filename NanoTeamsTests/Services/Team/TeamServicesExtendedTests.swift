import XCTest

@testable import NanoTeams

// MARK: - Extended Acceptance Service Tests

final class AcceptanceServiceExtendedTests: XCTestCase {

    // MARK: - Complex Workflow Tests

    func testWorkflow_MultiRoleAcceptance() {
        var roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .needsAcceptance,
            Role.builtInID(.tpm): .working,
            Role.builtInID(.uxDesigner): .idle,
            Role.builtInID(.softwareEngineer): .idle,
        ]

        // Accept PO
        roleStatuses[Role.builtInID(.productManager)] = AcceptanceService.statusAfterAcceptance(
            decision: .accepted)

        XCTAssertEqual(roleStatuses[Role.builtInID(.productManager)], .accepted)
        XCTAssertEqual(roleStatuses[Role.builtInID(.tpm)], .working)
    }

    func testWorkflow_RevisionCycle() {
        var roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.uxDesigner): .needsAcceptance
        ]

        // Request revision
        roleStatuses[Role.builtInID(.uxDesigner)] = AcceptanceService.statusAfterAcceptance(
            decision: .revisionRequested)
        XCTAssertEqual(roleStatuses[Role.builtInID(.uxDesigner)], .revisionRequested)

        // Simulate revision work
        roleStatuses[Role.builtInID(.uxDesigner)] = .working
        XCTAssertEqual(roleStatuses[Role.builtInID(.uxDesigner)], .working)

        // Complete revision
        roleStatuses[Role.builtInID(.uxDesigner)] = .needsAcceptance

        // Accept after revision
        roleStatuses[Role.builtInID(.uxDesigner)] = AcceptanceService.statusAfterAcceptance(
            decision: .accepted)
        XCTAssertEqual(roleStatuses[Role.builtInID(.uxDesigner)], .accepted)
    }

    func testWorkflow_ParallelRoleAcceptance() {
        // Multiple roles completing at same time
        var roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.uxDesigner): .needsAcceptance,
            Role.builtInID(.codeReviewer): .needsAcceptance,
        ]

        let pending = AcceptanceService.getPendingAcceptances(roleStatuses: roleStatuses)
        XCTAssertEqual(pending.count, 2)

        // Accept both
        roleStatuses[Role.builtInID(.uxDesigner)] = .accepted
        roleStatuses[Role.builtInID(.codeReviewer)] = .accepted

        XCTAssertTrue(
            AcceptanceService.allRolesAccepted(
                roleStatuses: roleStatuses,
                requiredRoleIDs: Set([Role.builtInID(.uxDesigner), Role.builtInID(.codeReviewer)])
            ))
    }

    // MARK: - Mode Transition Tests

    func testModeTransition_FromAfterEachRoleToFinalOnly() {
        // First check with afterEachRole
        XCTAssertTrue(
            AcceptanceService.shouldRequestAcceptance(
                roleID: Role.builtInID(.productManager),
                mode: .afterEachRole,
                checkpoints: [],
                isLastRole: false
            ))

        // Then with finalOnly - same role should not require acceptance if not last
        XCTAssertFalse(
            AcceptanceService.shouldRequestAcceptance(
                roleID: Role.builtInID(.productManager),
                mode: .finalOnly,
                checkpoints: [],
                isLastRole: false
            ))
    }

    func testModeTransition_CustomCheckpointsEmpty() {
        // Empty checkpoints, not last role
        XCTAssertFalse(
            AcceptanceService.shouldRequestAcceptance(
                roleID: Role.builtInID(.uxDesigner),
                mode: .customCheckpoints,
                checkpoints: [],
                isLastRole: false
            ))

        // Empty checkpoints, last role - should still require
        XCTAssertTrue(
            AcceptanceService.shouldRequestAcceptance(
                roleID: Role.builtInID(.sre),
                mode: .customCheckpoints,
                checkpoints: [],
                isLastRole: true
            ))
    }

    // MARK: - Edge Cases

    func testEffectiveMode_ChainOfOverrides() {
        let teamSettings = TeamSettings(defaultAcceptanceMode: .afterEachRole)

        // Task without override uses team default
        let task1 = NTMSTask(id: 0, title: "Task 1", supervisorTask: "Goal")
        XCTAssertEqual(
            AcceptanceService.effectiveAcceptanceMode(for: task1, teamSettings: teamSettings),
            .afterEachRole
        )

        // Task with override uses task setting
        let task2 = NTMSTask(id: 0, title: "Task 2",
            supervisorTask: "Goal",
            acceptanceMode: .finalOnly
        )
        XCTAssertEqual(
            AcceptanceService.effectiveAcceptanceMode(for: task2, teamSettings: teamSettings),
            .finalOnly
        )
    }

    func testValidateAcceptance_AllStatusTypes() {
        let statuses: [(RoleExecutionStatus, Bool)] = [
            (.idle, false),
            (.ready, false),
            (.working, false),
            (.needsAcceptance, true),  // Only valid one
            (.accepted, false),
            (.revisionRequested, false),
            (.done, false),
            (.failed, false),
            (.skipped, false),
        ]

        for (status, shouldBeValid) in statuses {
            let roleStatuses = [Role.builtInID(.uxDesigner): status]
            let result = AcceptanceService.validateAcceptance(
                roleID: Role.builtInID(.uxDesigner),
                roleStatuses: roleStatuses
            )

            if shouldBeValid {
                XCTAssertNil(result, "Status \(status) should be valid for acceptance")
            } else {
                XCTAssertNotNil(result, "Status \(status) should not be valid for acceptance")
            }
        }
    }

    // MARK: - Artifact Acceptance Tests

    func testArtifactAcceptance_AllModes() {
        let artifacts: [String] = [
            "Product Requirements", "Implementation Plan", "Design Spec", "Engineering Notes",
            "Test Plan",
        ]

        // Only afterEachArtifact mode should return true (artifact name is irrelevant)
        XCTAssertTrue(
            AcceptanceService.shouldRequestAcceptanceForArtifact(
                mode: .afterEachArtifact
            ))

        XCTAssertFalse(
            AcceptanceService.shouldRequestAcceptanceForArtifact(
                mode: .afterEachRole
            ))

        XCTAssertFalse(
            AcceptanceService.shouldRequestAcceptanceForArtifact(
                mode: .finalOnly
            ))

        XCTAssertFalse(
            AcceptanceService.shouldRequestAcceptanceForArtifact(
                mode: .customCheckpoints
            ))
    }
}

// MARK: - Extended Notification Service Tests

@MainActor
final class NotificationServiceExtendedTests: XCTestCase {

    var service: NotificationService!

    override func setUp() {
        super.setUp()
        service = NotificationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Long Message Truncation Tests

    func testSupervisorQuestion_TruncatesLongQuestion() {
        let longQuestion = String(repeating: "A", count: 200)
        service.notifySupervisorQuestion(role: .uxDesigner, question: longQuestion, stepID: "test_step")

        let notification = service.notifications.first!
        XCTAssertTrue(notification.message.contains("..."))
        XCTAssertLessThan(notification.message.count, 200)
    }

    func testRoleFailed_TruncatesLongError() {
        let longError = String(repeating: "Error ", count: 50)
        service.notifyRoleFailed(role: .softwareEngineer, error: longError, stepID: "test_step")

        let notification = service.notifications.first!
        XCTAssertTrue(notification.message.contains("..."))
    }

    func testTaskFailed_TruncatesLongError() {
        let longError = String(repeating: "Build ", count: 50)
        service.notifyTaskFailed(taskTitle: "Test", error: longError, taskID: Int())

        let notification = service.notifications.first!
        XCTAssertTrue(notification.message.contains("..."))
    }

    // MARK: - Batch Operations Tests

    func testBatchMarkAsRead() {
        for _ in 0..<5 {
            service.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        }

        XCTAssertEqual(service.unreadCount, 5)

        service.markAllAsRead()

        XCTAssertEqual(service.unreadCount, 0)
    }

    func testBatchDismiss() {
        for _ in 0..<5 {
            service.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")
        }

        let idsToRemove = service.notifications.prefix(3).map { $0.id }

        for id in idsToRemove {
            service.dismiss(id)
        }

        XCTAssertEqual(service.notifications.count, 2)
    }

    // MARK: - Priority Sorting Tests

    func testSortedByPriority_ComplexScenario() {
        service.notifyTaskCompleted(taskTitle: "Done", taskID: Int())  // Priority 20
        service.notifyRoleCompleted(role: .uxDesigner, stepID: "test_step")  // Priority 30
        service.notifyMeetingInvitation(initiatedBy: .tpm, topic: "Sprint", meetingID: UUID())  // Priority 70
        service.notifyTaskFailed(taskTitle: "Failed", error: "Error", taskID: Int())  // Priority 80
        service.notifyRoleFailed(role: .sre, error: "Test failed", stepID: "test_step")  // Priority 85
        service.notifySupervisorQuestion(role: .uxDesigner, question: "Color?", stepID: "test_step")  // Priority 90
        service.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")  // Priority 100

        let sorted = service.sortedByPriority()

        XCTAssertEqual(sorted[0].type, .acceptanceRequired)
        XCTAssertEqual(sorted[1].type, .supervisorQuestionAsked)
        XCTAssertEqual(sorted[2].type, .roleFailed)
        XCTAssertEqual(sorted[3].type, .taskFailed)
        XCTAssertEqual(sorted[4].type, .meetingInvitation)
        XCTAssertEqual(sorted[5].type, .roleCompleted)
        XCTAssertEqual(sorted[6].type, .taskCompleted)
    }

    // MARK: - Role Display Tests

    func testNotificationMessage_IncludesRoleDisplayName() {
        let roles: [Role] = [.productManager, .tpm, .uxDesigner, .softwareEngineer, .sre]

        for role in roles {
            service.clearAll()
            service.notifyRoleCompleted(role: role, stepID: "test_step")

            let notification = service.notifications.first!
            XCTAssertTrue(
                notification.message.contains(role.displayName),
                "Message should contain '\(role.displayName)'"
            )
        }
    }

    // MARK: - Context ID Tests

    func testContextID_PreservedAcrossNotificationTypes() {
        let stepID = "test_step"
        let meetingID = UUID()
        let taskID = 0

        service.notifyAcceptanceRequired(role: .uxDesigner, stepID: stepID)
        service.notifyMeetingInvitation(initiatedBy: .tpm, topic: "Test", meetingID: meetingID)
        service.notifyTaskCompleted(taskTitle: "Task", taskID: taskID)

        XCTAssertEqual(service.notifications[2].contextID, stepID)
        XCTAssertEqual(service.notifications[1].contextID, meetingID.uuidString)
        XCTAssertEqual(service.notifications[0].contextID, String(taskID))
    }

    // MARK: - Notification Lifecycle Tests

    func testNotificationLifecycle_CreateReadDismiss() {
        service.notifyAcceptanceRequired(role: .softwareEngineer, stepID: "test_step")
        let notificationID = service.notifications.first!.id

        XCTAssertFalse(service.notifications.first!.isRead)
        XCTAssertEqual(service.actionableNotifications.count, 1)

        service.markAsRead(notificationID)

        XCTAssertTrue(service.notifications.first!.isRead)
        XCTAssertEqual(service.actionableNotifications.count, 0)

        service.dismiss(notificationID)

        XCTAssertTrue(service.notifications.isEmpty)
    }
}

// MARK: - Extended Error Recovery Service Tests

final class ErrorRecoveryServiceExtendedTests: XCTestCase {

    // MARK: - Error Classification Edge Cases

    func testClassifyError_MixedKeywords() {
        // Build failure takes precedence over network
        let buildWithNetwork = "Network issue during build failed"
        XCTAssertEqual(ErrorRecoveryService.classifyError(buildWithNetwork), .buildFailure)

        // First matching keyword wins for same priority
        let timeoutAndConnection = "Connection timeout"
        XCTAssertEqual(ErrorRecoveryService.classifyError(timeoutAndConnection), .transient)
    }

    func testClassifyError_EmptyString() {
        let result = ErrorRecoveryService.classifyError("")
        XCTAssertEqual(result, .unknown)
    }

    func testClassifyError_SpecialCharacters() {
        let result = ErrorRecoveryService.classifyError("Error: [timeout] occurred!")
        XCTAssertEqual(result, .transient)
    }

    // MARK: - Retry Delay Edge Cases

    func testRetryDelay_VeryHighRetryCount() {
        // Even with high retry count, should cap at 30 seconds
        let delay = ErrorRecoveryService.retryDelay(retryCount: 100)
        XCTAssertEqual(delay, 30.0)
    }

    func testRetryDelay_NegativeRetryCount() {
        // Should handle gracefully (though shouldn't happen)
        let delay = ErrorRecoveryService.retryDelay(retryCount: -1)
        XCTAssertGreaterThan(delay, 0)
    }

    // MARK: - Recovery Options Scenarios

    func testRecoveryOptions_TransientError_RetryRecommended() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Network timeout",
            errorType: .transient,
            retryCount: 0,
            maxRetries: 3
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        XCTAssertEqual(options.count, 3)  // retry, skip, fail
        let retryOption = options.first { $0.strategy == .retry }!
        XCTAssertTrue(retryOption.isRecommended)
    }

    func testRecoveryOptions_BuildFailure_NoRetryRecommended() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Build failed",
            errorType: .buildFailure,
            retryCount: 0,
            maxRetries: 3
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        let retryOption = options.first { $0.strategy == .retry }!
        XCTAssertFalse(retryOption.isRecommended)
    }

    func testRecoveryOptions_ZeroMaxRetries() {
        let error = RoleError(
            role: .softwareEngineer,
            errorMessage: "Error",
            retryCount: 0,
            maxRetries: 0
        )

        let options = ErrorRecoveryService.recoveryOptions(for: error)

        // No retry option since maxRetries is 0
        XCTAssertFalse(options.contains { $0.strategy == .retry })
    }

    // MARK: - Error History Tests

    func testErrorHistory_RecordResolvedDoesNotIncrementCounters() {
        var history = ErrorHistory()

        let error = RoleError(role: .uxDesigner, errorMessage: "Test")
        history.record(error, outcome: .resolved)

        XCTAssertEqual(history.errors.count, 1)
        XCTAssertEqual(history.totalRetries, 0)
        XCTAssertEqual(history.totalSkipped, 0)
        XCTAssertEqual(history.totalFailed, 0)
    }

    func testErrorHistory_MixedOutcomes() {
        var history = ErrorHistory()

        for _ in 0..<3 {
            history.record(RoleError(role: .uxDesigner, errorMessage: "Retry"), outcome: .retried)
        }
        for _ in 0..<2 {
            history.record(RoleError(role: .sre, errorMessage: "Skip"), outcome: .skipped)
        }
        history.record(RoleError(role: .softwareEngineer, errorMessage: "Fail"), outcome: .failed)
        history.record(RoleError(role: .productManager, errorMessage: "Ok"), outcome: .resolved)

        XCTAssertEqual(history.errors.count, 7)
        XCTAssertEqual(history.totalRetries, 3)
        XCTAssertEqual(history.totalSkipped, 2)
        XCTAssertEqual(history.totalFailed, 1)
    }

    // MARK: - RoleError Tests

    func testRoleError_Identifiable() {
        let error1 = RoleError(role: .uxDesigner, errorMessage: "Error 1")
        let error2 = RoleError(role: .uxDesigner, errorMessage: "Error 1")

        // Different IDs even with same content
        XCTAssertNotEqual(error1.id, error2.id)
    }

    func testRoleError_Hashable() {
        let error = RoleError(role: .uxDesigner, errorMessage: "Error")

        var set = Set<RoleError>()
        set.insert(error)
        set.insert(error)  // Same error

        XCTAssertEqual(set.count, 1)
    }
}

// MARK: - Team Hierarchy Tests

final class TeamHierarchyTests: XCTestCase {

    var hierarchy: TeamHierarchy!

    override func setUp() {
        super.setUp()
        // Build a FAANG-like hierarchy using string IDs
        hierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "uxr": "pm",
            "uxd": "pm",
            "tl": "pm",
            "swe": "tl",
            "cr": "tl",
            "sre": "tl",
            "tpm": "tl",
        ])
    }

    override func tearDown() {
        hierarchy = nil
        super.tearDown()
    }

    // MARK: - Supervisor Tests

    func testSupervisorID() {
        XCTAssertEqual(hierarchy.supervisorID(for: "pm"), "supervisor")
        XCTAssertEqual(hierarchy.supervisorID(for: "uxr"), "pm")
        XCTAssertEqual(hierarchy.supervisorID(for: "uxd"), "pm")
        XCTAssertEqual(hierarchy.supervisorID(for: "tl"), "pm")
        XCTAssertEqual(hierarchy.supervisorID(for: "swe"), "tl")
        XCTAssertEqual(hierarchy.supervisorID(for: "cr"), "tl")
        XCTAssertEqual(hierarchy.supervisorID(for: "sre"), "tl")
        XCTAssertEqual(hierarchy.supervisorID(for: "tpm"), "tl")
    }

    func testSupervisorID_SupervisorHasNoSupervisor() {
        XCTAssertNil(hierarchy.supervisorID(for: "supervisor"))
    }

    func testSupervisorID_UnknownRole() {
        XCTAssertNil(hierarchy.supervisorID(for: "unknownRole"))
    }

    // MARK: - Subordinates Tests

    func testSubordinateIDs_Supervisor() {
        let subordinates = hierarchy.subordinateIDs(of: "supervisor")
        XCTAssertEqual(subordinates.count, 1)
        XCTAssertTrue(subordinates.contains("pm"))
    }

    func testSubordinateIDs_PM() {
        let subordinates = Set(hierarchy.subordinateIDs(of: "pm"))
        XCTAssertTrue(subordinates.contains("uxr"))
        XCTAssertTrue(subordinates.contains("uxd"))
        XCTAssertTrue(subordinates.contains("tl"))
    }

    func testSubordinateIDs_LeafRole() {
        let subordinates = hierarchy.subordinateIDs(of: "swe")
        XCTAssertTrue(subordinates.isEmpty)
    }

    // MARK: - Reports To Chain Tests

    func testDoesReport_Direct() {
        XCTAssertTrue(hierarchy.doesReport("pm", to: "supervisor"))
        XCTAssertTrue(hierarchy.doesReport("uxr", to: "pm"))
        XCTAssertTrue(hierarchy.doesReport("tl", to: "pm"))
        XCTAssertTrue(hierarchy.doesReport("swe", to: "tl"))
    }

    func testDoesReport_Indirect() {
        XCTAssertTrue(hierarchy.doesReport("tpm", to: "supervisor"))
        XCTAssertTrue(hierarchy.doesReport("uxd", to: "supervisor"))
        XCTAssertTrue(hierarchy.doesReport("swe", to: "pm"))
        XCTAssertTrue(hierarchy.doesReport("swe", to: "supervisor"))
    }

    func testDoesReport_SameRole() {
        XCTAssertFalse(hierarchy.doesReport("uxd", to: "uxd"))
    }

    func testDoesReport_NoRelation() {
        XCTAssertFalse(hierarchy.doesReport("uxd", to: "swe"))
        XCTAssertFalse(hierarchy.doesReport("supervisor", to: "pm"))
    }

    func testDoesReport_ReverseRelation() {
        XCTAssertFalse(hierarchy.doesReport("pm", to: "tpm"))
    }

    // MARK: - Custom Hierarchy Tests

    func testFlatStructure() {
        let flatHierarchy = TeamHierarchy(reportsTo: [
            "pm": "supervisor",
            "tpm": "supervisor",
            "uxd": "supervisor",
            "swe": "supervisor",
            "sre": "supervisor",
        ])

        let supervisorSubordinates = flatHierarchy.subordinateIDs(of: "supervisor")
        XCTAssertEqual(supervisorSubordinates.count, 5)
    }

    func testDeepChain() {
        let deepHierarchy = TeamHierarchy(reportsTo: [
            "level1": "supervisor",
            "level2": "level1",
            "level3": "level2",
            "level4": "level3",
        ])

        XCTAssertTrue(deepHierarchy.doesReport("level4", to: "level2"))
        XCTAssertTrue(deepHierarchy.doesReport("level4", to: "supervisor"))
    }

    func testCycleDetection() {
        let cyclicHierarchy = TeamHierarchy(reportsTo: [
            "role1": "role2",
            "role2": "role3",
            "role3": "role1",
        ])

        XCTAssertFalse(cyclicHierarchy.doesReport("role1", to: "nonexistent"))
    }

    // MARK: - Codable Tests

    func testTeamHierarchy_Codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(hierarchy)
        let decoded = try decoder.decode(TeamHierarchy.self, from: data)

        XCTAssertEqual(decoded.reportsTo.count, hierarchy.reportsTo.count)
    }
}

// MARK: - Team Limits Tests

final class TeamLimitsTests: XCTestCase {

    func testDefaultLimits() {
        let limits = TeamLimits.default

        XCTAssertEqual(limits.maxConsultationsPerStep, 5)
        XCTAssertEqual(limits.maxMeetingsPerRun, 3)
        XCTAssertEqual(limits.maxMeetingTurns, 10)
        XCTAssertEqual(limits.maxSameTeammateAsks, 2)
    }

    func testCustomLimits() {
        let limits = TeamLimits(
            maxConsultationsPerStep: 10,
            maxMeetingsPerRun: 5,
            maxMeetingTurns: 20,
            maxSameTeammateAsks: 3
        )

        XCTAssertEqual(limits.maxConsultationsPerStep, 10)
        XCTAssertEqual(limits.maxMeetingsPerRun, 5)
        XCTAssertEqual(limits.maxMeetingTurns, 20)
        XCTAssertEqual(limits.maxSameTeammateAsks, 3)
    }

    func testCodable_WithDefaults() throws {
        let decoder = JSONDecoder()

        // Empty JSON should decode with defaults
        let emptyJSON = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(TeamLimits.self, from: emptyJSON)

        XCTAssertEqual(decoded.maxConsultationsPerStep, 5)
        XCTAssertEqual(decoded.maxMeetingsPerRun, 3)
    }

    func testCodable_RoundTrip() throws {
        let original = TeamLimits(
            maxConsultationsPerStep: 8,
            maxMeetingsPerRun: 6,
            maxMeetingTurns: 15,
            maxSameTeammateAsks: 4
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TeamLimits.self, from: data)

        XCTAssertEqual(decoded.maxConsultationsPerStep, original.maxConsultationsPerStep)
        XCTAssertEqual(decoded.maxMeetingsPerRun, original.maxMeetingsPerRun)
        XCTAssertEqual(decoded.maxMeetingTurns, original.maxMeetingTurns)
        XCTAssertEqual(decoded.maxSameTeammateAsks, original.maxSameTeammateAsks)
    }

    func testHashable() {
        let limits1 = TeamLimits.default
        let limits2 = TeamLimits.default
        let limits3 = TeamLimits(maxConsultationsPerStep: 10)

        XCTAssertEqual(limits1, limits2)
        XCTAssertNotEqual(limits1, limits3)
    }
}

// MARK: - Acceptance Mode Tests

final class AcceptanceModeTests: XCTestCase {

    func testDisplayName() {
        XCTAssertEqual(AcceptanceMode.afterEachArtifact.displayName, "After Each Artifact")
        XCTAssertEqual(AcceptanceMode.afterEachRole.displayName, "After Each Role")
        XCTAssertEqual(AcceptanceMode.finalOnly.displayName, "Final Result Only")
        XCTAssertEqual(AcceptanceMode.customCheckpoints.displayName, "Custom Checkpoints")
    }

    func testDescription() {
        XCTAssertTrue(AcceptanceMode.afterEachArtifact.description.contains("artifact"))
        XCTAssertTrue(AcceptanceMode.afterEachRole.description.contains("role"))
        XCTAssertTrue(AcceptanceMode.finalOnly.description.contains("all roles"))
        XCTAssertTrue(AcceptanceMode.customCheckpoints.description.contains("selects"))
    }

    func testCaseIterable() {
        XCTAssertEqual(AcceptanceMode.allCases.count, 4)
        XCTAssertTrue(AcceptanceMode.allCases.contains(.afterEachArtifact))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.afterEachRole))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.finalOnly))
        XCTAssertTrue(AcceptanceMode.allCases.contains(.customCheckpoints))
    }

    func testCodable() throws {
        for mode in AcceptanceMode.allCases {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(AcceptanceMode.self, from: data)

            XCTAssertEqual(decoded, mode)
        }
    }

    func testRawValue() {
        XCTAssertEqual(AcceptanceMode.afterEachArtifact.rawValue, "afterEachArtifact")
        XCTAssertEqual(AcceptanceMode.afterEachRole.rawValue, "afterEachRole")
        XCTAssertEqual(AcceptanceMode.finalOnly.rawValue, "finalOnly")
        XCTAssertEqual(AcceptanceMode.customCheckpoints.rawValue, "customCheckpoints")
    }
}

// MARK: - Team Graph Transform Tests

final class TeamGraphTransformTests: XCTestCase {

    func testIdentity() {
        let identity = TeamGraphTransform.identity

        XCTAssertEqual(identity.offsetX, 0)
        XCTAssertEqual(identity.offsetY, 0)
        XCTAssertEqual(identity.scale, 1.0)
    }

    func testReset() {
        var transform = TeamGraphTransform(offsetX: 100, offsetY: 200, scale: 2.5)

        transform.reset()

        XCTAssertEqual(transform.offsetX, 0)
        XCTAssertEqual(transform.offsetY, 0)
        XCTAssertEqual(transform.scale, 1.0)
    }

    func testClampScale_TooSmall() {
        var transform = TeamGraphTransform(scale: 0.2)

        transform.clampScale()

        XCTAssertEqual(transform.scale, 0.5)
    }

    func testClampScale_TooLarge() {
        var transform = TeamGraphTransform(scale: 3.0)

        transform.clampScale()

        XCTAssertEqual(transform.scale, 2.0)
    }

    func testClampScale_InRange() {
        var transform = TeamGraphTransform(scale: 1.5)

        transform.clampScale()

        XCTAssertEqual(transform.scale, 1.5)
    }

    func testCodable_RoundTrip() throws {
        let original = TeamGraphTransform(offsetX: 50, offsetY: -30, scale: 1.75)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TeamGraphTransform.self, from: data)

        XCTAssertEqual(decoded.offsetX, original.offsetX)
        XCTAssertEqual(decoded.offsetY, original.offsetY)
        XCTAssertEqual(decoded.scale, original.scale)
    }

    func testCodable_WithDefaults() throws {
        let decoder = JSONDecoder()

        let emptyJSON = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(TeamGraphTransform.self, from: emptyJSON)

        XCTAssertEqual(decoded.offsetX, 0)
        XCTAssertEqual(decoded.offsetY, 0)
        XCTAssertEqual(decoded.scale, 1.0)
    }
}

// MARK: - Team Graph Layout Tests

final class TeamGraphLayoutTests: XCTestCase {

    func testDefaultLayout_HasPositionsForBuiltInRoles() {
        let layout = TeamGraphLayout.default

        XCTAssertNotNil(layout.position(for: Role.builtInID(.supervisor)))
        XCTAssertNotNil(layout.position(for: Role.builtInID(.productManager)))
        XCTAssertNotNil(layout.position(for: Role.builtInID(.tpm)))
        XCTAssertNotNil(layout.position(for: Role.builtInID(.uxDesigner)))
        XCTAssertNotNil(layout.position(for: Role.builtInID(.softwareEngineer)))
        XCTAssertNotNil(layout.position(for: Role.builtInID(.sre)))
    }

    func testPosition_UnknownRole() {
        let layout = TeamGraphLayout.default

        XCTAssertNil(layout.position(for: "unknownRole"))
    }

    func testSetPosition_NewRole() {
        var layout = TeamGraphLayout.default

        layout.setPosition(for: "customRole", x: 100, y: 200)

        let position = layout.position(for: "customRole")
        XCTAssertEqual(position?.x, 100)
        XCTAssertEqual(position?.y, 200)
    }

    func testSetPosition_UpdateExisting() {
        var layout = TeamGraphLayout.default

        let originalPosition = layout.position(for: Role.builtInID(.uxDesigner))
        XCTAssertNotNil(originalPosition)

        layout.setPosition(for: Role.builtInID(.uxDesigner), x: 999, y: 888)

        let newPosition = layout.position(for: Role.builtInID(.uxDesigner))
        XCTAssertEqual(newPosition?.x, 999)
        XCTAssertEqual(newPosition?.y, 888)
    }

    func testResetTransform() {
        var layout = TeamGraphLayout.default
        layout.transform = TeamGraphTransform(offsetX: 100, offsetY: 200, scale: 2.0)

        layout.resetTransform()

        XCTAssertEqual(layout.transform, .identity)
    }

    func testCodable_RoundTrip() throws {
        let original = TeamGraphLayout.default

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TeamGraphLayout.self, from: data)

        XCTAssertEqual(decoded.nodePositions.count, original.nodePositions.count)
    }
}

// MARK: - Role Dependencies Tests

final class RoleDependenciesTests: XCTestCase {

    func testSystemTemplateDependencies_Supervisor() {
        let deps = SystemTemplates.roles["supervisor"]!.dependencies

        XCTAssertTrue(deps.requiredArtifacts.isEmpty)
        XCTAssertEqual(deps.producesArtifacts, [SystemTemplates.supervisorTaskArtifactName])
    }

    func testSystemTemplateDependencies_PM() {
        let deps = SystemTemplates.roles["productManager"]!.dependencies

        XCTAssertEqual(deps.requiredArtifacts, [SystemTemplates.supervisorTaskArtifactName])
        XCTAssertEqual(deps.producesArtifacts, ["Product Requirements"])
    }

    func testSystemTemplateDependencies_TPM() {
        let deps = SystemTemplates.roles["tpm"]!.dependencies

        XCTAssertEqual(Set(deps.requiredArtifacts), Set(["Code Review Summary", "Production Readiness Summary"]))
        XCTAssertEqual(deps.producesArtifacts, ["Release Notes"])
    }

    func testSystemTemplateDependencies_UXDesigner() {
        let deps = SystemTemplates.roles["uxDesigner"]!.dependencies

        XCTAssertEqual(
            Set(deps.requiredArtifacts), Set(["Product Requirements", "Research Report"]))
        XCTAssertEqual(deps.producesArtifacts, ["Design Spec"])
    }

    func testSystemTemplateDependencies_Engineer() {
        let deps = SystemTemplates.roles["softwareEngineer"]!.dependencies

        XCTAssertEqual(Set(deps.requiredArtifacts), Set(["Implementation Plan", "Design Spec"]))
        XCTAssertEqual(deps.producesArtifacts, ["Engineering Notes", "Build Diagnostics"])
    }

    func testSystemTemplateDependencies_SRE() {
        let deps = SystemTemplates.roles["sre"]!.dependencies

        XCTAssertEqual(deps.requiredArtifacts, ["Engineering Notes"])
        XCTAssertEqual(Set(deps.producesArtifacts), Set(["Production Readiness", "Production Readiness Summary"]))
    }

    func testSystemTemplateDependencies_CodeReviewer() {
        let deps = SystemTemplates.roles["codeReviewer"]!.dependencies

        XCTAssertEqual(
            Set(deps.requiredArtifacts), Set(["Implementation Plan", "Engineering Notes"]))
        XCTAssertEqual(Set(deps.producesArtifacts), Set(["Code Review", "Code Review Summary"]))
    }

    func testSystemTemplateDependencies_CustomRoleNotInTemplates() {
        XCTAssertNil(SystemTemplates.roles["customRole"])
    }

    func testCodable_RoundTrip() throws {
        let original = RoleDependencies(
            requiredArtifacts: ["Product Requirements", "Implementation Plan"],
            producesArtifacts: ["Design Spec", "Architecture"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RoleDependencies.self, from: data)

        XCTAssertEqual(decoded.requiredArtifacts, original.requiredArtifacts)
        XCTAssertEqual(decoded.producesArtifacts, original.producesArtifacts)
    }
}
