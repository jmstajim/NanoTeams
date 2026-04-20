//
//  SystemTemplatesTests.swift
//  NanoTeamsTests
//
//  Tests for SystemTemplates: role/artifact templates, placeholder resolution, and team template lookups.
//

import XCTest
@testable import NanoTeams

final class SystemTemplatesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    // MARK: - resolveTemplate

    func testResolveTemplate_replacesPlaceholders() {
        let template = "Hello {name}, welcome to {team}!"
        let result = SystemTemplates.resolveTemplate(template, placeholders: [
            "name": "Alice",
            "team": "Engineering",
        ])
        XCTAssertEqual(result, "Hello Alice, welcome to Engineering!")
    }

    func testResolveTemplate_unknownPlaceholders_stayAsIs() {
        let template = "Hello {name}, your role is {role}."
        let result = SystemTemplates.resolveTemplate(template, placeholders: [
            "name": "Bob",
        ])
        XCTAssertEqual(result, "Hello Bob, your role is {role}.")
    }

    func testResolveTemplate_emptyPlaceholders_noChange() {
        let template = "You are {roleName} in a team with {teamRoles}."
        let result = SystemTemplates.resolveTemplate(template, placeholders: [:])
        XCTAssertEqual(result, template)
    }

    func testResolveTemplate_multipleSamePlaceholder_allReplaced() {
        let template = "{name} said hello. Then {name} said goodbye. Finally {name} left."
        let result = SystemTemplates.resolveTemplate(template, placeholders: [
            "name": "Charlie",
        ])
        XCTAssertEqual(result, "Charlie said hello. Then Charlie said goodbye. Finally Charlie left.")
    }

    // MARK: - Role Template Invariants

    func testAllRoleTemplates_haveNonEmptyName() {
        for (id, template) in SystemTemplates.roles {
            XCTAssertFalse(
                template.name.isEmpty,
                "Role template '\(id)' should have a non-empty name"
            )
        }
    }

    func testAllRoleTemplates_supervisorHasEmptyPrompt() {
        guard let sup = SystemTemplates.roles["supervisor"] else {
            XCTFail("Supervisor role template must exist")
            return
        }
        XCTAssertTrue(
            sup.prompt.isEmpty,
            "Supervisor prompt should be empty because Supervisor is the user, not an LLM role"
        )
    }

    func testAllRoleTemplates_nonSupervisorHaveNonEmptyPrompt() {
        for (id, template) in SystemTemplates.roles where id != "supervisor" {
            XCTAssertFalse(
                template.prompt.isEmpty,
                "Non-Supervisor role template '\(id)' should have a non-empty prompt"
            )
        }
    }

    func testAllRoleTemplates_softwareEngineerHasWriteTools() {
        guard let swe = SystemTemplates.roles["softwareEngineer"] else {
            XCTFail("softwareEngineer role template must exist")
            return
        }
        let writeTools = ["write_file", "edit_file"]
        for tool in writeTools {
            XCTAssertTrue(
                swe.toolIDs.contains(tool),
                "Software Engineer should have write tool '\(tool)'"
            )
        }
    }

    // MARK: - Artifact Template Invariants

    func testAllArtifactTemplates_haveNonEmptyDescription() {
        for (name, template) in SystemTemplates.artifacts {
            XCTAssertFalse(
                template.description.isEmpty,
                "Artifact template '\(name)' should have a non-empty description"
            )
        }
    }

    func testAllArtifactTemplates_haveNonEmptyIcon() {
        for (name, template) in SystemTemplates.artifacts {
            XCTAssertFalse(
                template.icon.isEmpty,
                "Artifact template '\(name)' should have a non-empty icon"
            )
        }
    }

    // MARK: - Team Role IDs

    func testFaangTeamRoleIDs_contains8Roles() {
        guard let faangIDs = SystemTemplates.teamRoleIDs["faang"] else {
            XCTFail("faang team role IDs must exist")
            return
        }
        XCTAssertEqual(faangIDs.count, 8, "FAANG team should have 8 roles (excluding Supervisor)")
        XCTAssertTrue(faangIDs.contains("productManager"))
        XCTAssertTrue(faangIDs.contains("uxResearcher"))
        XCTAssertTrue(faangIDs.contains("uxDesigner"))
        XCTAssertTrue(faangIDs.contains("techLead"))
        XCTAssertTrue(faangIDs.contains("softwareEngineer"))
        XCTAssertTrue(faangIDs.contains("codeReviewer"))
        XCTAssertTrue(faangIDs.contains("sre"))
        XCTAssertTrue(faangIDs.contains("tpm"))
    }

    func testQuestPartyTeamRoleIDs_contains5Roles() {
        guard let questIDs = SystemTemplates.teamRoleIDs["questParty"] else {
            XCTFail("questParty team role IDs must exist")
            return
        }
        XCTAssertEqual(questIDs.count, 5, "Quest Party team should have 5 roles (excluding Supervisor)")
        XCTAssertTrue(questIDs.contains("loreMaster"))
        XCTAssertTrue(questIDs.contains("npcCreator"))
        XCTAssertTrue(questIDs.contains("encounterArchitect"))
        XCTAssertTrue(questIDs.contains("rulesArbiter"))
        XCTAssertTrue(questIDs.contains("questMaster"))
    }

    func testDiscussionClubTeamRoleIDs_contains5Roles() {
        guard let discIDs = SystemTemplates.teamRoleIDs["discussionClub"] else {
            XCTFail("discussionClub team role IDs must exist")
            return
        }
        XCTAssertEqual(discIDs.count, 5, "Discussion Club team should have 5 roles (excluding Supervisor)")
        XCTAssertTrue(discIDs.contains("theAgreeable"))
        XCTAssertTrue(discIDs.contains("theOpen"))
        XCTAssertTrue(discIDs.contains("theConscientious"))
        XCTAssertTrue(discIDs.contains("theExtrovert"))
        XCTAssertTrue(discIDs.contains("theNeurotic"))
    }

    func testStartupTeamRoleIDs_containsSWEOnly() {
        guard let startupIDs = SystemTemplates.teamRoleIDs["startup"] else {
            XCTFail("startup team role IDs must exist")
            return
        }
        XCTAssertEqual(startupIDs.count, 1, "Startup team should have only 1 role (excluding Supervisor)")
        XCTAssertEqual(startupIDs.first, "softwareEngineer")
    }

    // MARK: - Default System Template

    func testDefaultSystemTemplate_faang_returnsSoftwareTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: "faang")
        XCTAssertEqual(result, SystemTemplates.softwareTemplate)
    }

    func testDefaultSystemTemplate_startup_returnsSoftwareTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: "startup")
        XCTAssertEqual(result, SystemTemplates.softwareTemplate)
    }

    func testDefaultSystemTemplate_questParty_returnsQuestPartyTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: "questParty")
        XCTAssertEqual(result, SystemTemplates.questPartyTemplate)
    }

    func testDefaultSystemTemplate_discussionClub_returnsDiscussionTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: "discussionClub")
        XCTAssertEqual(result, SystemTemplates.discussionTemplate)
    }

    func testDefaultSystemTemplate_nil_returnsGenericTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: nil)
        XCTAssertEqual(result, SystemTemplates.genericTemplate)
    }

    func testDefaultSystemTemplate_unknownID_returnsGenericTemplate() {
        let result = SystemTemplates.defaultSystemTemplate(for: "unknownTeamType")
        XCTAssertEqual(result, SystemTemplates.genericTemplate)
    }

    // MARK: - Default Consultation Template

    func testDefaultConsultationTemplate_matchesTeamType() {
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: "faang"),
            SystemTemplates.softwareConsultationTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: "startup"),
            SystemTemplates.softwareConsultationTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: "questParty"),
            SystemTemplates.questPartyConsultationTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: "discussionClub"),
            SystemTemplates.discussionConsultationTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: nil),
            SystemTemplates.genericConsultationTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultConsultationTemplate(for: "unknownTeamType"),
            SystemTemplates.genericConsultationTemplate
        )
    }

    // MARK: - Default Meeting Template

    func testDefaultMeetingTemplate_matchesTeamType() {
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: "faang"),
            SystemTemplates.softwareMeetingTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: "startup"),
            SystemTemplates.softwareMeetingTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: "questParty"),
            SystemTemplates.questPartyMeetingTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: "discussionClub"),
            SystemTemplates.discussionMeetingTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: nil),
            SystemTemplates.genericMeetingTemplate
        )
        XCTAssertEqual(
            SystemTemplates.defaultMeetingTemplate(for: "unknownTeamType"),
            SystemTemplates.genericMeetingTemplate
        )
    }

    // MARK: - availableRoles

    func testAvailableRoles_filtersExistingIDs() {
        // Start with all FAANG roles present except SRE and TPM
        let existingIDs: Set<String> = [
            "supervisor", "productManager", "uxResearcher", "uxDesigner",
            "techLead", "softwareEngineer", "codeReviewer",
        ]

        let available = SystemTemplates.availableRoles(
            forTemplateID: "faang",
            existingSystemRoleIDs: existingIDs
        )

        let availableIDs = Set(available.map { $0.id })
        XCTAssertEqual(availableIDs, Set(["sre", "tpm"]))
        XCTAssertEqual(available.count, 2)

        // Verify the returned templates match the registry
        for (id, template) in available {
            XCTAssertEqual(template.name, SystemTemplates.roles[id]?.name)
        }
    }

    func testAvailableRoles_allExisting_returnsEmpty() {
        let allFaangIDs: Set<String> = Set(SystemTemplates.teamRoleIDs["faang"] ?? [])
        let available = SystemTemplates.availableRoles(
            forTemplateID: "faang",
            existingSystemRoleIDs: allFaangIDs
        )
        XCTAssertTrue(available.isEmpty, "Should return no roles when all are already present")
    }

    func testAvailableRoles_noneExisting_returnsAll() {
        let available = SystemTemplates.availableRoles(
            forTemplateID: "faang",
            existingSystemRoleIDs: []
        )
        XCTAssertEqual(available.count, 8, "Should return all 8 FAANG roles when none are present")
    }

    func testAvailableRoles_unknownTemplateID_returnsEmpty() {
        let available = SystemTemplates.availableRoles(
            forTemplateID: "nonExistentTemplate",
            existingSystemRoleIDs: []
        )
        XCTAssertTrue(
            available.isEmpty,
            "Unknown template ID should return empty available roles"
        )
    }

    func testAvailableRoles_nilTemplateID_returnsEmpty() {
        let available = SystemTemplates.availableRoles(
            forTemplateID: nil,
            existingSystemRoleIDs: []
        )
        XCTAssertTrue(
            available.isEmpty,
            "Nil template ID should return empty available roles"
        )
    }

    // MARK: - createRole

    func testCreateRole_fromTemplate_setsSystemRoleTrue() {
        guard let pmTemplate = SystemTemplates.roles["productManager"] else {
            XCTFail("productManager template must exist")
            return
        }

        let role = SystemTemplates.createRole(from: pmTemplate)

        XCTAssertTrue(role.isSystemRole, "Created role should have isSystemRole = true")
        XCTAssertEqual(role.systemRoleID, "productManager")
        XCTAssertEqual(role.name, "Product Manager")
        XCTAssertEqual(role.icon, pmTemplate.icon)
        XCTAssertEqual(role.prompt, pmTemplate.prompt)
        XCTAssertEqual(role.toolIDs, pmTemplate.toolIDs)
        XCTAssertEqual(role.usePlanningPhase, pmTemplate.usePlanningPhase)
        XCTAssertEqual(role.dependencies, pmTemplate.dependencies)
        XCTAssertNil(role.llmOverride)
        XCTAssertFalse(role.id.isEmpty, "Created role should have a non-empty UUID-based ID")
    }

    func testCreateRole_fromTemplate_generatesUniqueIDs() {
        guard let template = SystemTemplates.roles["softwareEngineer"] else {
            XCTFail("softwareEngineer template must exist")
            return
        }

        let role1 = SystemTemplates.createRole(from: template)
        let role2 = SystemTemplates.createRole(from: template)

        XCTAssertNotEqual(role1.id, role2.id, "Each created role should have a unique ID")
    }

    // MARK: - createArtifact

    func testCreateArtifact_fromTemplate_setsSystemArtifactTrue() {
        guard let prTemplate = SystemTemplates.artifacts["Product Requirements"] else {
            XCTFail("Product Requirements artifact template must exist")
            return
        }

        let artifact = SystemTemplates.createArtifact(from: prTemplate)

        XCTAssertTrue(artifact.isSystemArtifact, "Created artifact should have isSystemArtifact = true")
        XCTAssertEqual(artifact.systemArtifactName, "Product Requirements")
        XCTAssertEqual(artifact.name, "Product Requirements")
        XCTAssertEqual(artifact.icon, prTemplate.icon)
        XCTAssertEqual(artifact.mimeType, prTemplate.mimeType)
        XCTAssertEqual(artifact.description, prTemplate.description)
        XCTAssertFalse(artifact.id.isEmpty, "Created artifact should have a non-empty UUID-based ID")
    }

    func testCreateArtifact_fromTemplate_generatesUniqueIDs() {
        guard let template = SystemTemplates.artifacts["Design Spec"] else {
            XCTFail("Design Spec artifact template must exist")
            return
        }

        let artifact1 = SystemTemplates.createArtifact(from: template)
        let artifact2 = SystemTemplates.createArtifact(from: template)

        XCTAssertNotEqual(artifact1.id, artifact2.id, "Each created artifact should have a unique ID")
    }

    // MARK: - Supervisor Task Consistency

    func testSupervisorTaskArtifactName_isConsistent() {
        // Verify the constant matches what the Supervisor role template produces
        guard let sup = SystemTemplates.roles["supervisor"] else {
            XCTFail("Supervisor role template must exist")
            return
        }
        XCTAssertTrue(
            sup.dependencies.producesArtifacts.contains(SystemTemplates.supervisorTaskArtifactName),
            "Supervisor role template must produce the supervisorTaskArtifactName artifact"
        )

        // Verify the artifact template exists for this name
        XCTAssertNotNil(
            SystemTemplates.artifacts[SystemTemplates.supervisorTaskArtifactName],
            "An artifact template must exist for supervisorTaskArtifactName"
        )

        // Verify roles that depend on Supervisor Task reference the same constant
        let rolesRequiringSupervisorTask = SystemTemplates.roles.filter {
            $0.value.dependencies.requiredArtifacts.contains(SystemTemplates.supervisorTaskArtifactName)
        }
        XCTAssertFalse(
            rolesRequiringSupervisorTask.isEmpty,
            "At least one role should require the Supervisor Task artifact"
        )

        // Verify the productManager requires Supervisor Task (FAANG pipeline entry)
        guard let pm = SystemTemplates.roles["productManager"] else {
            XCTFail("productManager template must exist")
            return
        }
        XCTAssertTrue(
            pm.dependencies.requiredArtifacts.contains(SystemTemplates.supervisorTaskArtifactName),
            "Product Manager should require the Supervisor Task artifact"
        )
    }

    // MARK: - Placeholder Metadata

    func testSystemPromptPlaceholders_containsExpectedKeys() {
        let keys = Set(SystemTemplates.systemPromptPlaceholders.map { $0.key })
        let expectedKeys: Set<String> = [
            "roleName", "teamName", "teamDescription", "teamRoles",
            "stepInfo", "positionContext", "workFolderContext", "roleGuidance",
            "toolList",
            "expectedArtifacts", "artifactInstructions",
            "contextAwareness",
        ]
        XCTAssertEqual(keys, expectedKeys)
    }

    func testConsultationPlaceholders_containsExpectedKeys() {
        let keys = Set(SystemTemplates.consultationPlaceholders.map { $0.key })
        let expectedKeys: Set<String> = [
            "consultedRoleName", "requestingRoleName", "roleGuidance", "teamDescription",
        ]
        XCTAssertEqual(keys, expectedKeys)
    }

    func testMeetingPlaceholders_containsExpectedKeys() {
        let keys = Set(SystemTemplates.meetingPlaceholders.map { $0.key })
        let expectedKeys: Set<String> = [
            "speakerName", "roleGuidance", "meetingTopic",
            "turnNumber", "coordinatorHint", "teamDescription",
        ]
        XCTAssertEqual(keys, expectedKeys)
    }

    // MARK: - Template Content Sanity

    func testSoftwareTemplate_containsExpectedPlaceholders() {
        let template = SystemTemplates.softwareTemplate
        XCTAssertTrue(template.contains("{roleName}"))
        XCTAssertTrue(template.contains("{teamRoles}"))
        XCTAssertTrue(template.contains("{roleGuidance}"))
        XCTAssertTrue(template.contains("{toolList}"))
        XCTAssertTrue(template.contains("{expectedArtifacts}"))
    }

    func testQuestPartyTemplate_containsExpectedPlaceholders() {
        let template = SystemTemplates.questPartyTemplate
        XCTAssertTrue(template.contains("{roleName}"))
        XCTAssertTrue(template.contains("{teamRoles}"))
        XCTAssertTrue(template.contains("{roleGuidance}"))
        XCTAssertTrue(template.contains("{expectedArtifacts}"))
    }

    func testDiscussionTemplate_containsExpectedPlaceholders() {
        let template = SystemTemplates.discussionTemplate
        XCTAssertTrue(template.contains("{roleName}"))
        XCTAssertTrue(template.contains("{teamRoles}"))
        XCTAssertTrue(template.contains("{roleGuidance}"))
        XCTAssertTrue(template.contains("{expectedArtifacts}"))
    }

    func testGenericTemplate_containsExpectedPlaceholders() {
        let template = SystemTemplates.genericTemplate
        XCTAssertTrue(template.contains("{roleName}"))
        XCTAssertTrue(template.contains("{teamRoles}"))
        XCTAssertTrue(template.contains("{roleGuidance}"))
        XCTAssertTrue(template.contains("{expectedArtifacts}"))
    }

    // MARK: - Role Template Count

    func testRoleTemplatesCount() {
        XCTAssertEqual(
            SystemTemplates.roles.count, 20,
            "Should have 20 built-in role templates"
        )
    }

    // MARK: - Artifact Template Count

    func testArtifactTemplatesCount() {
        XCTAssertEqual(
            SystemTemplates.artifacts.count, 17,
            "Should have 17 built-in artifact templates"
        )
    }

}
