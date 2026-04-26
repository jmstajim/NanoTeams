//
//  SystemTemplates.swift
//  NanoTeams
//
//  System-level templates for roles and artifacts used when creating new teams.
//

import Foundation

// MARK: - Role Template

/// Template for creating a TeamRoleDefinition from a system role
struct SystemRoleTemplate {
    var id: String  // e.g., "supervisor", "productManager"
    var name: String  // Display name
    var icon: String  // SF Symbol name
    var prompt: String  // System prompt for LLM
    var toolIDs: [String]  // Available tools
    var usePlanningPhase: Bool  // Two-phase execution
    var dependencies: RoleDependencies  // Required/produced artifacts
}

// MARK: - Artifact Template

/// Template for creating a TeamArtifact from a system artifact
struct SystemArtifactTemplate {
    var name: String  // Display name (e.g., "Product Requirements")
    var icon: String  // SF Symbol name
    var mimeType: String  // e.g., "text/markdown"
    var description: String  // Human-readable description
}

// MARK: - System Templates

/// Central registry of built-in role and artifact templates
enum SystemTemplates {

    /// The artifact name that only Supervisor can produce.
    static let supervisorTaskArtifactName = "Supervisor Task"

    /// Get available system role templates for a team template (roles not yet in the team)
    static func availableRoles(
        forTemplateID templateID: String?, existingSystemRoleIDs: Set<String>
    ) -> [(id: String, template: SystemRoleTemplate)] {
        guard let templateID, let roleIDs = teamRoleIDs[templateID] else { return [] }

        return
            roleIDs
            .filter { !existingSystemRoleIDs.contains($0) }
            .compactMap { id in
                guard let template = roles[id] else { return nil }
                return (id: id, template: template)
            }
    }

    // MARK: - Prompt Templates

    /// Resolves a template string by replacing `{key}` placeholders with values from the dictionary.
    /// Delegates to `TemplateResolver.resolve()` in the service layer.
    static func resolveTemplate(_ template: String, placeholders: [String: String]) -> String {
        TemplateResolver.resolve(template, placeholders: placeholders)
    }

    /// All available placeholder keys for the system prompt template.
    static let systemPromptPlaceholders: [(key: String, label: String, category: String)] = [
        ("roleName", "Role Name", "role"),
        ("teamName", "Team Name", "role"),
        ("teamDescription", "Team Description", "role"),
        ("teamRoles", "Team Roles", "role"),
        ("stepInfo", "Step Info", "context"),
        ("positionContext", "Position Context", "context"),
        ("workFolderContext", "Work Folder Context", "context"),
        ("roleGuidance", "Role Guidance", "context"),
        ("toolList", "Tool List", "tools"),
        ("expectedArtifacts", "Expected Artifacts", "artifacts"),
        ("artifactInstructions", "Artifact Instructions", "artifacts"),
        ("contextAwareness", "Context Awareness", "context"),
    ]

    /// All available placeholder keys for the consultation prompt template.
    static let consultationPlaceholders: [(key: String, label: String, category: String)] = [
        ("consultedRoleName", "Consulted Role", "role"),
        ("requestingRoleName", "Requesting Role", "role"),
        ("roleGuidance", "Role Guidance", "context"),
        ("teamDescription", "Team Description", "role"),
    ]

    /// All available placeholder keys for the meeting prompt template.
    static let meetingPlaceholders: [(key: String, label: String, category: String)] = [
        ("speakerName", "Speaker Name", "role"),
        ("roleGuidance", "Role Guidance", "context"),
        ("meetingTopic", "Meeting Topic", "context"),
        ("turnNumber", "Turn Number", "context"),
        ("coordinatorHint", "Coordinator Hint", "context"),
        ("teamDescription", "Team Description", "role"),
    ]


    // MARK: - Template Config

    /// Per-template bundle of system, consultation, and meeting prompt templates.
    /// Single source of truth — add a new template ID here once, not in 3 separate switches.
    struct TeamTemplateConfig {
        let system: String
        let consultation: String
        let meeting: String
    }

    static let templateConfigs: [String: TeamTemplateConfig] = [
        "faang":         TeamTemplateConfig(system: softwareTemplate,      consultation: softwareConsultationTemplate,      meeting: softwareMeetingTemplate),
        "engineering":   TeamTemplateConfig(system: softwareTemplate,      consultation: softwareConsultationTemplate,      meeting: softwareMeetingTemplate),
        "startup":       TeamTemplateConfig(system: softwareTemplate,      consultation: softwareConsultationTemplate,      meeting: softwareMeetingTemplate),
        "questParty":    TeamTemplateConfig(system: questPartyTemplate,    consultation: questPartyConsultationTemplate,    meeting: questPartyMeetingTemplate),
        "discussionClub":TeamTemplateConfig(system: discussionTemplate,    consultation: discussionConsultationTemplate,    meeting: discussionMeetingTemplate),
        "assistant":     TeamTemplateConfig(system: assistantTemplate,     consultation: genericConsultationTemplate,       meeting: genericMeetingTemplate),
        "codingAssistant": TeamTemplateConfig(system: codingAssistantTemplate, consultation: genericConsultationTemplate,   meeting: genericMeetingTemplate),
        "generated":     TeamTemplateConfig(system: genericTemplate,       consultation: genericConsultationTemplate,       meeting: genericMeetingTemplate),
    ]

    /// Returns the default system prompt template for a given team template ID.
    static func defaultSystemTemplate(for templateID: String?) -> String {
        guard let id = templateID else { return genericTemplate }
        return templateConfigs[id]?.system ?? genericTemplate
    }

    /// Returns the default consultation prompt template for a given team template ID.
    static func defaultConsultationTemplate(for templateID: String?) -> String {
        guard let id = templateID else { return genericConsultationTemplate }
        return templateConfigs[id]?.consultation ?? genericConsultationTemplate
    }

    /// Returns the default meeting prompt template for a given team template ID.
    static func defaultMeetingTemplate(for templateID: String?) -> String {
        guard let id = templateID else { return genericMeetingTemplate }
        return templateConfigs[id]?.meeting ?? genericMeetingTemplate
    }

    // MARK: - Helper Methods

    /// Create a TeamRoleDefinition from a system template.
    /// - Parameter teamSeed: Team NTMSID for deterministic role ID. Nil → random UUID (custom roles via UI).
    static func createRole(from template: SystemRoleTemplate, teamSeed: String? = nil) -> TeamRoleDefinition {
        let roleID: String
        if let seed = teamSeed {
            roleID = NTMSID.from(name: "\(seed):\(template.name)")
        } else {
            roleID = UUID().uuidString
        }
        return TeamRoleDefinition(
            id: roleID,
            name: template.name,
            icon: template.icon,
            prompt: template.prompt,
            toolIDs: template.toolIDs,
            usePlanningPhase: template.usePlanningPhase,
            dependencies: template.dependencies,
            llmOverride: nil,
            isSystemRole: true,
            systemRoleID: template.id,
            iconColor: "#FFFFFF",
            iconBackground: RoleColorDefaults.defaultBackgroundHex(for: template.id),
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )
    }

    /// Create a TeamArtifact from a system template.
    /// - Parameter teamSeed: Team NTMSID for deterministic artifact ID. Nil → random UUID (custom artifacts via UI).
    static func createArtifact(from template: SystemArtifactTemplate, teamSeed: String? = nil) -> TeamArtifact {
        let artifactID: String
        if let seed = teamSeed {
            artifactID = NTMSID.from(name: "\(seed):artifact:\(template.name)")
        } else {
            artifactID = UUID().uuidString
        }
        return TeamArtifact(
            id: artifactID,
            name: template.name,
            icon: template.icon,
            mimeType: template.mimeType,
            description: template.description,
            isSystemArtifact: true,
            systemArtifactName: template.name,
            createdAt: MonotonicClock.shared.now(),
            updatedAt: MonotonicClock.shared.now()
        )
    }
}
