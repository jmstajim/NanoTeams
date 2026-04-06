import XCTest
@testable import NanoTeams

final class TeamValidationServiceTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a minimal TeamRoleDefinition for testing.
    private func makeRole(
        id: String = UUID().uuidString,
        name: String = "TestRole",
        required: [String] = [],
        produces: [String] = [],
        systemRoleID: String? = nil
    ) -> TeamRoleDefinition {
        TeamRoleDefinition(
            id: id,
            name: name,
            prompt: "Test prompt for \(name)",
            toolIDs: [],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: required,
                producesArtifacts: produces
            ),
            systemRoleID: systemRoleID
        )
    }

    /// Creates a Supervisor role.
    private func makeSupervisorRole(
        id: String = "supervisor-id",
        required: [String] = [],
        produces: [String] = ["Supervisor Task"]
    ) -> TeamRoleDefinition {
        makeRole(
            id: id,
            name: "Supervisor",
            required: required,
            produces: produces,
            systemRoleID: "supervisor"
        )
    }

    // MARK: - validateArtifactUniqueness

    func testValidateArtifactUniqueness_noDuplicates_passes() {
        let roles = [
            makeRole(id: "pm", produces: ["Product Requirements"]),
            makeRole(id: "swe", produces: ["Engineering Notes"]),
            makeRole(id: "tl", produces: ["Implementation Plan"])
        ]

        let errors = TeamValidationService.validateArtifactUniqueness(roleDefinitions: roles)

        XCTAssertTrue(errors.isEmpty, "Expected no errors when each artifact has a single producer")
    }

    func testValidateArtifactUniqueness_twoRolesProduceSameArtifact_fails() {
        let roles = [
            makeRole(id: "role-a", name: "Role A", produces: ["Design Spec"]),
            makeRole(id: "role-b", name: "Role B", produces: ["Design Spec"])
        ]

        let errors = TeamValidationService.validateArtifactUniqueness(roleDefinitions: roles)

        XCTAssertEqual(errors.count, 1)
        guard case let .duplicateProducer(artifact, roleIDs) = errors.first else {
            XCTFail("Expected duplicateProducer error")
            return
        }
        XCTAssertEqual(artifact, "Design Spec")
        XCTAssertTrue(roleIDs.contains("role-a"))
        XCTAssertTrue(roleIDs.contains("role-b"))
        XCTAssertEqual(roleIDs.count, 2)
    }

    // MARK: - validateDependencyChain

    func testValidateDependencyChain_allProducersExist_passes() {
        let roles = [
            makeRole(id: "supervisor", produces: ["Supervisor Task"]),
            makeRole(id: "pm", required: ["Supervisor Task"], produces: ["Product Requirements"]),
            makeRole(id: "swe", required: ["Product Requirements"], produces: ["Engineering Notes"])
        ]

        let errors = TeamValidationService.validateDependencyChain(roleDefinitions: roles)

        XCTAssertTrue(errors.isEmpty, "Expected no errors when all required artifacts have producers")
    }

    func testValidateDependencyChain_missingProducer_fails() {
        let roles = [
            makeRole(id: "pm", produces: ["Product Requirements"]),
            makeRole(id: "swe", required: ["Implementation Plan"], produces: ["Engineering Notes"])
        ]

        let errors = TeamValidationService.validateDependencyChain(roleDefinitions: roles)

        XCTAssertEqual(errors.count, 1)
        guard case let .missingProducer(artifact, requiredBy) = errors.first else {
            XCTFail("Expected missingProducer error")
            return
        }
        XCTAssertEqual(artifact, "Implementation Plan")
        XCTAssertEqual(requiredBy, "swe")
    }

    // MARK: - validateNoCircularDependencies

    func testValidateNoCircularDependencies_linearChain_passes() {
        let roles = [
            makeRole(id: "a", produces: ["Artifact A"]),
            makeRole(id: "b", required: ["Artifact A"], produces: ["Artifact B"]),
            makeRole(id: "c", required: ["Artifact B"], produces: ["Artifact C"])
        ]

        let errors = TeamValidationService.validateNoCircularDependencies(roleDefinitions: roles)

        XCTAssertTrue(errors.isEmpty, "Expected no circular dependency in a linear chain")
    }

    func testValidateNoCircularDependencies_cycle_detected() {
        // A produces X, requires Z
        // B produces Y, requires X
        // C produces Z, requires Y
        // Cycle: A -> C -> B -> A
        let roles = [
            makeRole(id: "a", required: ["Artifact Z"], produces: ["Artifact X"]),
            makeRole(id: "b", required: ["Artifact X"], produces: ["Artifact Y"]),
            makeRole(id: "c", required: ["Artifact Y"], produces: ["Artifact Z"])
        ]

        let errors = TeamValidationService.validateNoCircularDependencies(roleDefinitions: roles)

        XCTAssertEqual(errors.count, 1)
        guard case let .circularDependency(roleIDs) = errors.first else {
            XCTFail("Expected circularDependency error")
            return
        }
        // The cycle should contain all three roles
        XCTAssertTrue(roleIDs.contains("a"), "Cycle should include role 'a'")
        XCTAssertTrue(roleIDs.contains("b"), "Cycle should include role 'b'")
        XCTAssertTrue(roleIDs.contains("c"), "Cycle should include role 'c'")
    }

    func testValidateNoCircularDependencies_supervisorRequirementsExcluded() {
        // Supervisor requires "Release Notes" (review requirement, not execution edge)
        // TPM produces "Release Notes", requires "Engineering Notes"
        // SWE produces "Engineering Notes", requires "Supervisor Task"
        // Supervisor produces "Supervisor Task"
        // Without Supervisor exclusion, Supervisor -> TPM -> SWE -> Supervisor would form a cycle
        let roles = [
            makeSupervisorRole(required: ["Release Notes"], produces: ["Supervisor Task"]),
            makeRole(id: "tpm", required: ["Engineering Notes"], produces: ["Release Notes"]),
            makeRole(id: "swe", required: ["Supervisor Task"], produces: ["Engineering Notes"])
        ]

        let errors = TeamValidationService.validateNoCircularDependencies(roleDefinitions: roles)

        XCTAssertTrue(errors.isEmpty, "Supervisor requiredArtifacts should not create dependency edges, so no cycle should be detected")
    }

    func testValidateNoCircularDependencies_selfDependency_detected() {
        // A role that requires an artifact it also produces
        let roles = [
            makeRole(id: "self-ref", required: ["Ouroboros"], produces: ["Ouroboros"])
        ]

        let errors = TeamValidationService.validateNoCircularDependencies(roleDefinitions: roles)

        XCTAssertEqual(errors.count, 1)
        guard case let .circularDependency(roleIDs) = errors.first else {
            XCTFail("Expected circularDependency error for self-dependency")
            return
        }
        XCTAssertTrue(roleIDs.contains("self-ref"), "Cycle should include the self-referencing role")
    }

    // MARK: - findOrphanArtifacts

    func testFindOrphanArtifacts_allConsumed_noWarnings() {
        let roles = [
            makeRole(id: "a", produces: ["Artifact A"]),
            makeRole(id: "b", required: ["Artifact A"], produces: ["Artifact B"]),
            makeRole(id: "c", required: ["Artifact B"])
        ]

        let warnings = TeamValidationService.findOrphanArtifacts(roleDefinitions: roles)

        XCTAssertTrue(warnings.isEmpty, "Expected no orphan warnings when all produced artifacts are consumed")
    }

    func testFindOrphanArtifacts_producedButNeverRequired_warns() {
        let roles = [
            makeRole(id: "a", produces: ["Artifact A"]),
            makeRole(id: "b", produces: ["Artifact B"]),
            makeRole(id: "c", required: ["Artifact A"])
        ]

        let warnings = TeamValidationService.findOrphanArtifacts(roleDefinitions: roles)

        XCTAssertEqual(warnings.count, 1)
        guard case let .orphanArtifact(artifact, producedBy) = warnings.first else {
            XCTFail("Expected orphanArtifact warning")
            return
        }
        XCTAssertEqual(artifact, "Artifact B")
        XCTAssertEqual(producedBy, "b")
    }

    // MARK: - validate (integration)

    func testValidate_validTeam_isValidTrue() {
        let roles = [
            makeSupervisorRole(produces: ["Supervisor Task"]),
            makeRole(id: "pm", required: ["Supervisor Task"], produces: ["Product Requirements"]),
            makeRole(id: "swe", required: ["Product Requirements"], produces: ["Engineering Notes"]),
            makeSupervisorRole(id: "supervisor-review", required: ["Engineering Notes"], produces: [])
        ]

        let result = TeamValidationService.validate(roleDefinitions: roles)

        XCTAssertTrue(result.isValid, "A valid team configuration should return isValid == true")
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidate_withErrors_isValidFalse() {
        // SWE requires an artifact that nobody produces
        let roles = [
            makeRole(id: "pm", produces: ["Product Requirements"]),
            makeRole(id: "swe", required: ["Implementation Plan"], produces: ["Engineering Notes"])
        ]

        let result = TeamValidationService.validate(roleDefinitions: roles)

        XCTAssertFalse(result.isValid, "A team with missing producers should return isValid == false")
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidate_errorsAndWarnings_separated() {
        // Role B requires "Missing Artifact" (error: no producer)
        // Role A produces "Orphan Artifact" (warning: never consumed)
        let roles = [
            makeRole(id: "a", produces: ["Orphan Artifact"]),
            makeRole(id: "b", required: ["Missing Artifact"], produces: ["Result"])
        ]

        let result = TeamValidationService.validate(roleDefinitions: roles)

        // Errors: missingProducer for "Missing Artifact"
        XCTAssertFalse(result.isValid)
        let errorKinds = result.errors.map { error -> String in
            if case .missingProducer = error { return "missingProducer" }
            return "other"
        }
        XCTAssertTrue(errorKinds.contains("missingProducer"), "Errors should contain missingProducer")

        // Warnings: orphanArtifact for "Orphan Artifact"
        let warningKinds = result.warnings.map { warning -> String in
            if case .orphanArtifact = warning { return "orphanArtifact" }
            return "other"
        }
        XCTAssertTrue(warningKinds.contains("orphanArtifact"), "Warnings should contain orphanArtifact")

        // Verify separation: orphans should NOT be in errors
        let errorsContainOrphan = result.errors.contains { error in
            if case .orphanArtifact = error { return true }
            return false
        }
        XCTAssertFalse(errorsContainOrphan, "Orphan artifacts should only appear in warnings, not errors")

        // Verify separation: missingProducer should NOT be in warnings
        let warningsContainMissing = result.warnings.contains { warning in
            if case .missingProducer = warning { return true }
            return false
        }
        XCTAssertFalse(warningsContainMissing, "Missing producer should only appear in errors, not warnings")
    }

    func testValidate_emptyRoles_isValid() {
        let result = TeamValidationService.validate(roleDefinitions: [])

        XCTAssertTrue(result.isValid, "Empty roles should produce no validation errors")
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - ValidationError.isError

    func testValidationError_isError_trueForErrors() {
        let duplicateProducer = TeamValidationService.ValidationError.duplicateProducer(
            artifact: "X", roleIDs: ["a", "b"]
        )
        let missingProducer = TeamValidationService.ValidationError.missingProducer(
            artifact: "X", requiredBy: "a"
        )
        let circularDependency = TeamValidationService.ValidationError.circularDependency(
            roleIDs: ["a", "b"]
        )

        XCTAssertTrue(duplicateProducer.isError)
        XCTAssertTrue(missingProducer.isError)
        XCTAssertTrue(circularDependency.isError)
    }

    func testValidationError_isError_falseForOrphan() {
        let orphan = TeamValidationService.ValidationError.orphanArtifact(
            artifact: "X", producedBy: "a"
        )

        XCTAssertFalse(orphan.isError, "orphanArtifact should be a warning, not an error")
    }
}
