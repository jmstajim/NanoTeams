import XCTest
@testable import NanoTeams

final class AcceptanceServiceTests: XCTestCase {

    // MARK: - shouldRequestAcceptance Tests

    func testShouldRequestAcceptance_AfterEachArtifact_AlwaysTrue() {
        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.softwareEngineer),
            mode: .afterEachArtifact,
            checkpoints: [],
            isLastRole: false
        )

        XCTAssertTrue(result)
    }

    func testShouldRequestAcceptance_AfterEachRole_AlwaysTrue() {
        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.uxDesigner),
            mode: .afterEachRole,
            checkpoints: [],
            isLastRole: false
        )

        XCTAssertTrue(result)
    }

    func testShouldRequestAcceptance_FinalOnly_FalseWhenNotLast() {
        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.productManager),
            mode: .finalOnly,
            checkpoints: [],
            isLastRole: false
        )

        XCTAssertFalse(result)
    }

    func testShouldRequestAcceptance_FinalOnly_TrueWhenLast() {
        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.sre),
            mode: .finalOnly,
            checkpoints: [],
            isLastRole: true
        )

        XCTAssertTrue(result)
    }

    func testShouldRequestAcceptance_CustomCheckpoints_TrueWhenInCheckpoints() {
        let checkpoints: Set<String> = [
            Role.builtInID(.tpm),
            Role.builtInID(.softwareEngineer)
        ]

        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.softwareEngineer),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        )

        XCTAssertTrue(result)
    }

    func testShouldRequestAcceptance_CustomCheckpoints_FalseWhenNotInCheckpoints() {
        let checkpoints: Set<String> = [
            Role.builtInID(.tpm)
        ]

        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.uxDesigner),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        )

        XCTAssertFalse(result)
    }

    func testShouldRequestAcceptance_CustomCheckpoints_TrueWhenLastRole() {
        // Even if not in checkpoints, last role always requires acceptance
        let checkpoints: Set<String> = [Role.builtInID(.tpm)]

        let result = AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.sre),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: true
        )

        XCTAssertTrue(result)
    }

    // MARK: - shouldRequestAcceptanceForArtifact Tests

    func testShouldRequestAcceptanceForArtifact_AfterEachArtifact_True() {
        let result = AcceptanceService.shouldRequestAcceptanceForArtifact(
            mode: .afterEachArtifact
        )

        XCTAssertTrue(result)
    }

    func testShouldRequestAcceptanceForArtifact_AfterEachRole_False() {
        let result = AcceptanceService.shouldRequestAcceptanceForArtifact(
            mode: .afterEachRole
        )

        XCTAssertFalse(result)
    }

    func testShouldRequestAcceptanceForArtifact_FinalOnly_False() {
        let result = AcceptanceService.shouldRequestAcceptanceForArtifact(
            mode: .finalOnly
        )

        XCTAssertFalse(result)
    }

    func testShouldRequestAcceptanceForArtifact_CustomCheckpoints_False() {
        let result = AcceptanceService.shouldRequestAcceptanceForArtifact(
            mode: .customCheckpoints
        )

        XCTAssertFalse(result)
    }

    // MARK: - effectiveAcceptanceMode Tests

    func testEffectiveAcceptanceMode_TaskOverridePresent() {
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            acceptanceMode: .finalOnly
        )
        let teamSettings = TeamSettings(defaultAcceptanceMode: .afterEachRole)

        let result = AcceptanceService.effectiveAcceptanceMode(
            for: task,
            teamSettings: teamSettings
        )

        XCTAssertEqual(result, .finalOnly)
    }

    func testEffectiveAcceptanceMode_NoTaskOverride() {
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            acceptanceMode: nil
        )
        let teamSettings = TeamSettings(defaultAcceptanceMode: .afterEachArtifact)

        let result = AcceptanceService.effectiveAcceptanceMode(
            for: task,
            teamSettings: teamSettings
        )

        XCTAssertEqual(result, .afterEachArtifact)
    }

    func testEffectiveAcceptanceMode_UsesDefaultSettings() {
        let task = NTMSTask(id: 0, title: "Test", supervisorTask: "Goal")
        let teamSettings = TeamSettings.default

        let result = AcceptanceService.effectiveAcceptanceMode(
            for: task,
            teamSettings: teamSettings
        )

        XCTAssertEqual(result, .afterEachRole)
    }

    // MARK: - effectiveCheckpoints Tests

    func testEffectiveCheckpoints_TaskOverridePresent() {
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            acceptanceCheckpoints: [Role.builtInID(.softwareEngineer)]
        )
        let teamSettings = TeamSettings(
            acceptanceCheckpoints: [Role.builtInID(.uxDesigner)]
        )

        let result = AcceptanceService.effectiveCheckpoints(
            for: task,
            teamSettings: teamSettings
        )

        XCTAssertEqual(result, [Role.builtInID(.softwareEngineer)])
    }

    func testEffectiveCheckpoints_NoTaskOverride() {
        let task = NTMSTask(id: 0, title: "Test Task",
            supervisorTask: "Test goal",
            acceptanceCheckpoints: nil
        )
        let teamSettings = TeamSettings(
            acceptanceCheckpoints: [
                Role.builtInID(.tpm),
                Role.builtInID(.sre)
            ]
        )

        let result = AcceptanceService.effectiveCheckpoints(
            for: task,
            teamSettings: teamSettings
        )

        XCTAssertEqual(result, [Role.builtInID(.tpm), Role.builtInID(.sre)])
    }

    // MARK: - statusAfterAcceptance Tests

    func testStatusAfterAcceptance_Accepted() {
        let result = AcceptanceService.statusAfterAcceptance(decision: .accepted)

        XCTAssertEqual(result, .accepted)
    }

    func testStatusAfterAcceptance_RevisionRequested() {
        let result = AcceptanceService.statusAfterAcceptance(decision: .revisionRequested)

        XCTAssertEqual(result, .revisionRequested)
    }

    // MARK: - allRolesAccepted Tests

    func testAllRolesAccepted_AllAccepted() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .accepted,
            Role.builtInID(.tpm): .accepted,
            Role.builtInID(.uxDesigner): .done
        ]
        let requiredRoleIDs: Set<String> = [
            Role.builtInID(.productManager),
            Role.builtInID(.tpm),
            Role.builtInID(.uxDesigner)
        ]

        let result = AcceptanceService.allRolesAccepted(
            roleStatuses: roleStatuses,
            requiredRoleIDs: requiredRoleIDs
        )

        XCTAssertTrue(result)
    }

    func testAllRolesAccepted_SomeNotAccepted() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .accepted,
            Role.builtInID(.tpm): .working,
            Role.builtInID(.uxDesigner): .done
        ]
        let requiredRoleIDs: Set<String> = [
            Role.builtInID(.productManager),
            Role.builtInID(.tpm),
            Role.builtInID(.uxDesigner)
        ]

        let result = AcceptanceService.allRolesAccepted(
            roleStatuses: roleStatuses,
            requiredRoleIDs: requiredRoleIDs
        )

        XCTAssertFalse(result)
    }

    func testAllRolesAccepted_MissingRole() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .accepted
        ]
        let requiredRoleIDs: Set<String> = [
            Role.builtInID(.productManager),
            Role.builtInID(.tpm)
        ]

        let result = AcceptanceService.allRolesAccepted(
            roleStatuses: roleStatuses,
            requiredRoleIDs: requiredRoleIDs
        )

        XCTAssertFalse(result)
    }

    func testAllRolesAccepted_EmptyRequired() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .working
        ]

        let result = AcceptanceService.allRolesAccepted(
            roleStatuses: roleStatuses,
            requiredRoleIDs: []
        )

        XCTAssertTrue(result)
    }

    func testAllRolesAccepted_DoneCountsAsAccepted() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .done,
            Role.builtInID(.tpm): .done
        ]
        let requiredRoleIDs: Set<String> = [
            Role.builtInID(.productManager),
            Role.builtInID(.tpm)
        ]

        let result = AcceptanceService.allRolesAccepted(
            roleStatuses: roleStatuses,
            requiredRoleIDs: requiredRoleIDs
        )

        XCTAssertTrue(result)
    }

    // MARK: - getPendingAcceptances Tests

    func testGetPendingAcceptances_NoPending() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .done,
            Role.builtInID(.tpm): .working
        ]

        let result = AcceptanceService.getPendingAcceptances(roleStatuses: roleStatuses)

        XCTAssertTrue(result.isEmpty)
    }

    func testGetPendingAcceptances_OnePending() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .needsAcceptance,
            Role.builtInID(.tpm): .working
        ]

        let result = AcceptanceService.getPendingAcceptances(roleStatuses: roleStatuses)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.contains(Role.builtInID(.productManager)))
    }

    func testGetPendingAcceptances_MultiplePending() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .needsAcceptance,
            Role.builtInID(.tpm): .needsAcceptance,
            Role.builtInID(.uxDesigner): .done
        ]

        let result = AcceptanceService.getPendingAcceptances(roleStatuses: roleStatuses)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(Role.builtInID(.productManager)))
        XCTAssertTrue(result.contains(Role.builtInID(.tpm)))
    }

    func testGetPendingAcceptances_EmptyStatuses() {
        let result = AcceptanceService.getPendingAcceptances(roleStatuses: [:])

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - validateAcceptance Tests

    func testValidateAcceptance_ValidNeedsAcceptance() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .needsAcceptance
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNil(result)
    }

    func testValidateAcceptance_RoleNotFound() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .needsAcceptance
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: "unknownRole",
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not found"))
    }

    func testValidateAcceptance_AlreadyAccepted() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .accepted
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("already accepted"))
    }

    func testValidateAcceptance_AlreadyDone() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .done
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("already completed"))
    }

    func testValidateAcceptance_StillWorking() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .working
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("still working"))
    }

    func testValidateAcceptance_Idle() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .idle
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not started"))
    }

    func testValidateAcceptance_Ready() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .ready
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("not started"))
    }

    func testValidateAcceptance_RevisionRequested() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .revisionRequested
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("already in revision"))
    }

    func testValidateAcceptance_Failed() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .failed
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("failed"))
    }

    func testValidateAcceptance_Skipped() {
        let roleStatuses: [String: RoleExecutionStatus] = [
            Role.builtInID(.productManager): .skipped
        ]

        let result = AcceptanceService.validateAcceptance(
            roleID: Role.builtInID(.productManager),
            roleStatuses: roleStatuses
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("skipped"))
    }

    // MARK: - SupervisorFeedback Tests

    func testSupervisorFeedback_Initialization() {
        let feedback = AcceptanceService.SupervisorFeedback(
            roleID: Role.builtInID(.softwareEngineer),
            decision: .accepted,
            comment: "Great work!"
        )

        XCTAssertEqual(feedback.roleID, Role.builtInID(.softwareEngineer))
        XCTAssertEqual(feedback.decision, .accepted)
        XCTAssertEqual(feedback.comment, "Great work!")
        XCTAssertNotNil(feedback.id)
        XCTAssertNotNil(feedback.createdAt)
    }

    func testSupervisorFeedback_InitializationWithoutComment() {
        let feedback = AcceptanceService.SupervisorFeedback(
            roleID: Role.builtInID(.uxDesigner),
            decision: .revisionRequested
        )

        XCTAssertNil(feedback.comment)
    }

    func testSupervisorFeedback_Codable() throws {
        let feedback = AcceptanceService.SupervisorFeedback(
            id: UUID(),
            createdAt: Date(),
            roleID: Role.builtInID(.softwareEngineer),
            decision: .accepted,
            comment: "Test comment"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(feedback)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AcceptanceService.SupervisorFeedback.self, from: data)

        XCTAssertEqual(decoded.id, feedback.id)
        XCTAssertEqual(decoded.roleID, feedback.roleID)
        XCTAssertEqual(decoded.decision, feedback.decision)
        XCTAssertEqual(decoded.comment, feedback.comment)
    }

    func testSupervisorFeedback_Hashable() {
        let feedback1 = AcceptanceService.SupervisorFeedback(
            id: UUID(),
            roleID: "role1",
            decision: .accepted
        )
        let feedback2 = AcceptanceService.SupervisorFeedback(
            id: feedback1.id,
            roleID: "role1",
            decision: .accepted
        )

        XCTAssertEqual(feedback1, feedback2)
    }

    // MARK: - AcceptanceDecision Tests

    func testAcceptanceDecision_Codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let acceptedData = try encoder.encode(AcceptanceService.AcceptanceDecision.accepted)
        let decodedAccepted = try decoder.decode(
            AcceptanceService.AcceptanceDecision.self,
            from: acceptedData
        )
        XCTAssertEqual(decodedAccepted, .accepted)

        let revisionData = try encoder.encode(AcceptanceService.AcceptanceDecision.revisionRequested)
        let decodedRevision = try decoder.decode(
            AcceptanceService.AcceptanceDecision.self,
            from: revisionData
        )
        XCTAssertEqual(decodedRevision, .revisionRequested)
    }

    // MARK: - Integration Scenarios

    func testScenario_FullWorkflowAfterEachRole() {
        // Simulate a workflow with afterEachRole mode

        // Step 1: PO completes, should need acceptance
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.productManager),
            mode: .afterEachRole,
            checkpoints: [],
            isLastRole: false
        ))

        // Step 2: Supervisor accepts PO
        let statusAfterAccept = AcceptanceService.statusAfterAcceptance(decision: .accepted)
        XCTAssertEqual(statusAfterAccept, .accepted)

        // Step 3: PM completes, should need acceptance
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.tpm),
            mode: .afterEachRole,
            checkpoints: [],
            isLastRole: false
        ))

        // Step 4: Supervisor requests revision
        let statusAfterRevision = AcceptanceService.statusAfterAcceptance(decision: .revisionRequested)
        XCTAssertEqual(statusAfterRevision, .revisionRequested)
    }

    func testScenario_FinalOnlyWorkflow() {
        // Only last role should need acceptance

        // Early roles should not need acceptance
        XCTAssertFalse(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.productManager),
            mode: .finalOnly,
            checkpoints: [],
            isLastRole: false
        ))

        XCTAssertFalse(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.softwareEngineer),
            mode: .finalOnly,
            checkpoints: [],
            isLastRole: false
        ))

        // Last role (QA) should need acceptance
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.sre),
            mode: .finalOnly,
            checkpoints: [],
            isLastRole: true
        ))
    }

    func testScenario_CustomCheckpointsWorkflow() {
        let checkpoints: Set<String> = [
            Role.builtInID(.tpm),
            Role.builtInID(.softwareEngineer)
        ]

        // PO not in checkpoints, not last
        XCTAssertFalse(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.productManager),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        ))

        // PM in checkpoints
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.tpm),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        ))

        // Designer not in checkpoints
        XCTAssertFalse(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.uxDesigner),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        ))

        // Engineer in checkpoints
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.softwareEngineer),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: false
        ))

        // QA not in checkpoints but is last role
        XCTAssertTrue(AcceptanceService.shouldRequestAcceptance(
            roleID: Role.builtInID(.sre),
            mode: .customCheckpoints,
            checkpoints: checkpoints,
            isLastRole: true
        ))
    }
}
