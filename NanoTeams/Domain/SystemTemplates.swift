//
//  SystemTemplates.swift
//  NanoTeams
//
//  System-level templates for roles and artifacts used when creating new teams.
//

import Foundation

// MARK: - Role Template

/// Template for creating a TeamRoleDefinition from a system role
nonisolated struct SystemRoleTemplate {
    var id: String  // e.g., "supervisor", "productManager"
    var name: String  // Display name
    var icon: String  // SF Symbol name
    var prompt: String  // System prompt for LLM
    /// What the role reads as `{roleGuidance}` inside a MEETING turn. `nil` ⇒ `prompt`.
    /// Authored only for roles whose step guidance names a tool meetings strip
    /// (`create_artifact`, `ask_supervisor`, `request_changes`, `request_team_meeting`…):
    /// a speaker told "route fixes through request_changes" in a turn whose schema has no
    /// such tool either hallucinates the call or ignores a standing instruction.
    var meetingGuidance: String?
    var toolIDs: [String]  // Available tools
    var usePlanningPhase: Bool  // Two-phase execution
    var dependencies: RoleDependencies  // Required/produced artifacts

    /// The meeting guidance a turn renders — the meeting body when one is authored and
    /// not blank, else the step prompt. Same rule as `TeamRoleDefinition.resolvedMeetingGuidance`.
    var resolvedMeetingGuidance: String {
        SystemTemplates.resolveMeetingGuidance(meetingGuidance, fallback: prompt)
    }
}

// MARK: - Artifact Template

/// Template for creating a TeamArtifact from a system artifact
nonisolated struct SystemArtifactTemplate {
    var name: String  // Display name (e.g., "Product Requirements")
    var icon: String  // SF Symbol name
    var mimeType: String  // e.g., "text/markdown"
    var description: String  // Human-readable description
}

// MARK: - System Templates

/// Central registry of built-in role and artifact templates
nonisolated enum SystemTemplates {

    /// The artifact name that only Supervisor can produce.
    static let supervisorTaskArtifactName = "Supervisor Task"

    /// One rule for both carriers of a meeting body (`SystemRoleTemplate`,
    /// `TeamRoleDefinition`): blank means "not authored", so an editor that saved an
    /// empty field or an imported JSON carrying `""` falls back exactly like `nil`.
    static func resolveMeetingGuidance(_ meetingGuidance: String?, fallback prompt: String) -> String {
        guard let body = meetingGuidance,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return meetingStance(derivedFrom: prompt) }
        return body
    }

    /// The meeting body of a role that has none authored — every LLM-generated role, and
    /// a custom role until its editor's Prompt tab is filled in.
    ///
    /// The opening of the step prompt — its first paragraph, at most two sentences, stopped
    /// at the first `#` heading — plus one sentence that names what a meeting turn is. Until
    /// 2026-09-07 the fallback was the WHOLE step prompt: a FAANG Software Engineer spoke in
    /// a meeting under "Implement the change end-to-end… stage and commit… submit
    /// Engineering Notes" — eleven imperatives about work no meeting turn can do
    /// (playbook R3.1.1 / R4.1.1, audit 2026-09-07).
    static func meetingStance(derivedFrom prompt: String) -> String {
        let closing = "In this meeting, speak from that responsibility in your own words; "
            + "the meeting's outcome is the group's decision, not a deliverable of yours."
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Up to the first blank line, or the whole text when it has none.
        let firstParagraph = trimmed.range(of: "\n\n").map { String(trimmed[..<$0.lowerBound]) } ?? trimmed
        let paragraph = firstParagraph
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        let stance = firstSentences(of: paragraph, count: 2)
        return stance.isEmpty ? closing : stance + " " + closing
    }

    /// The first `count` sentences of `text`, sentence-final punctuation kept.
    private static func firstSentences(of text: String, count: Int) -> String {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            current.append(character)
            if character == " ", let previous, ".!?".contains(previous) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
                if sentences.count == count { return sentences.joined(separator: " ") }
            }
            previous = character
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.prefix(count).joined(separator: " ")
    }

    // MARK: - Step ending

    /// The `{stepEnding}` chip: the ONE sentence of `## Final reminder` that names how the
    /// step ends, resolved per role at prompt-build time. A template serving both
    /// completion types (`questPartyTemplate`, `genericTemplate`) used to carry a literal
    /// or an `if`-clause the model re-judged every turn (R4.4.1); a producing role ends
    /// on `create_artifact`, an advisory role on its `ask_supervisor` reply, and an
    /// advisory role in a team whose Ask Supervisor mode is Off has no tool to end on
    /// at all — three sentences, one chip.
    static let producingStepEnding =
        "Submit each deliverable exactly once — that is how the step ends."
    static let advisoryStepEnding =
        "Reply by calling `ask_supervisor` with your full response in its `question` field — plain text outside tool calls is invisible."
    static let plainReplyStepEnding =
        "Reply in plain text — the Supervisor reads your replies in the feed and ends the step."

    static func stepEnding(producing: Bool, canAskSupervisor: Bool) -> String {
        if producing { return producingStepEnding }
        return canAskSupervisor ? advisoryStepEnding : plainReplyStepEnding
    }

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
        ("stepEnding", "Step Ending", "artifacts"),
        ("conversationMechanics", "Conversation Mechanics", "context"),
        ("globalContext", "Global Context", "context"),
        ("roleSkills", "Role Skills", "context"),
        ("toolCalling", "Tool Calling", "tools"),
    ]

    /// All available placeholder keys for the consultation prompt template.
    static let consultationPlaceholders: [(key: String, label: String, category: String)] = [
        ("consultedRoleName", "Consulted Role", "role"),
        ("requestingRoleName", "Requesting Role", "role"),
        ("roleGuidance", "Role Guidance", "context"),
        ("teamDescription", "Team Description", "role"),
        ("globalContext", "Global Context", "context"),
    ]

    /// All available placeholder keys for the meeting prompt template.
    static let meetingPlaceholders: [(key: String, label: String, category: String)] = [
        ("speakerName", "Speaker Name", "role"),
        ("roleGuidance", "Role Guidance", "context"),
        ("meetingTopic", "Meeting Topic", "context"),
        ("turnNumber", "Turn Number", "context"),
        ("coordinatorHint", "Coordinator Hint", "context"),
        ("teamDescription", "Team Description", "role"),
        ("globalContext", "Global Context", "context"),
        ("toolCalling", "Tool Calling", "tools"),
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
        "codingAgent":   TeamTemplateConfig(system: codingAssistantTemplate, consultation: genericConsultationTemplate,   meeting: genericMeetingTemplate),
        "generated":     TeamTemplateConfig(system: genericTemplate,       consultation: genericConsultationTemplate,       meeting: genericMeetingTemplate),
        "autovisor": TeamTemplateConfig(system: autovisorTemplate,     consultation: genericConsultationTemplate,       meeting: genericMeetingTemplate),
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
            meetingGuidance: template.meetingGuidance,
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
