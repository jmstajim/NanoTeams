import Foundation

// MARK: - Artifact Templates

extension SystemTemplates {

    /// All available system artifact templates
    static let artifacts: [String: SystemArtifactTemplate] = [
        // FAANG artifacts
        supervisorTaskArtifactName: SystemArtifactTemplate(
            name: supervisorTaskArtifactName,
            icon: "target",
            mimeType: "text/plain",
            description: "The original task brief — objectives, requirements, and context provided by the Supervisor. Starting point for all downstream work."
        ),
        "Product Requirements": SystemArtifactTemplate(
            name: "Product Requirements",
            icon: "doc.text",
            mimeType: "text/markdown",
            description: "PRD covering: (1) problem statement and target users, (2) key user stories and pain points, (3) acceptance criteria — concrete and testable, (4) scope: in/out of scope, (5) success metrics. Focus on the 'what' and 'why', not the 'how'. Proportional to task complexity — 1-2 paragraphs for small tasks, full PRD for large features."
        ),
        "Research Report": SystemArtifactTemplate(
            name: "Research Report",
            icon: "chart.bar.doc.horizontal",
            mimeType: "text/markdown",
            description: "User research covering: (1) 2-3 user personas with goals and pain points, (2) current vs ideal user journey, (3) competitive analysis, (4) key insights, (5) actionable recommendations for the designer. If the task is API/backend-only with no user-facing changes, briefly note that and summarize key technical user needs instead."
        ),
        "Design Spec": SystemArtifactTemplate(
            name: "Design Spec",
            icon: "paintbrush",
            mimeType: "text/markdown",
            description: "Design specification covering: (1) user flows and navigation paths, (2) UI component states (normal, empty, error, loading), (3) layout structure and visual hierarchy, (4) edge cases and error states, (5) developer-facing interface notes if no visible UI. Describe in text; reference existing patterns. Skip sections that don't apply to the task."
        ),
        "Implementation Plan": SystemArtifactTemplate(
            name: "Implementation Plan",
            icon: "list.bullet.clipboard",
            mimeType: "text/markdown",
            description: "Technical implementation plan covering: (1) architecture overview and key design decisions, (2) step-by-step implementation tasks in priority order, (3) files/modules to create or modify, (4) data models and API interfaces, (5) risk areas and mitigations, (6) testing strategy. Proportional to task complexity — 3-5 bullets for simple tasks, full plan for large features."
        ),
        "Engineering Notes": SystemArtifactTemplate(
            name: "Engineering Notes",
            icon: "hammer",
            mimeType: "text/markdown",
            description: "Engineering implementation record covering: (1) what was built and key decisions made, (2) files created or modified with brief explanations, (3) code patterns and conventions used, (4) known limitations or tech debt, (5) testing done. Written as a factual record of what was actually implemented, not a plan."
        ),
        "Build Diagnostics": SystemArtifactTemplate(
            name: "Build Diagnostics",
            icon: "wrench.and.screwdriver",
            mimeType: "application/json",
            description: "Build diagnostics report summarizing: (1) overall build/test outcome (pass/fail), (2) compiler errors or warnings with file locations, (3) test failures with test names and error messages, (4) performance or dependency issues if relevant. Structured as JSON for machine readability."
        ),
        "Code Review": SystemArtifactTemplate(
            name: "Code Review",
            icon: "checklist",
            mimeType: "text/markdown",
            description: "Code review report covering: (1) overall assessment (approve/request changes), (2) critical issues — bugs, security vulnerabilities, or correctness problems, (3) scope compliance — flag if implementation includes features marked 'out of scope' in the PRD (call these out as enhancements, not silent additions), (4) style and maintainability feedback, (5) specific actionable suggestions with file and line references where possible, (6) positive observations. Focus on what matters most — skip trivial nitpicks."
        ),
        "Code Review Summary": SystemArtifactTemplate(
            name: "Code Review Summary",
            icon: "checkmark",
            mimeType: "text/markdown",
            description: "Concise code review summary (3-5 bullet points) for downstream roles: (1) overall status (approve/request changes), (2) critical issues if any, (3) scope compliance flagged (if out-of-scope features were added, note as enhancement), (4) key recommendations (no more than 2-3 items). Used by TPM for quick handoff instead of full review. CR produces both full and summary versions."
        ),
        "Production Readiness": SystemArtifactTemplate(
            name: "Production Readiness",
            icon: "checkmark.shield",
            mimeType: "text/markdown",
            description: "Production readiness assessment covering: (1) reliability — error handling, edge cases, retry logic, (2) observability — logging and monitoring hooks, (3) security — input validation, auth, data exposure, (4) performance — resource usage, bottlenecks, (5) deployment — config, rollback plan, dependencies. Rate each area and summarize overall readiness."
        ),
        "Production Readiness Summary": SystemArtifactTemplate(
            name: "Production Readiness Summary",
            icon: "shield",
            mimeType: "text/markdown",
            description: "Concise production readiness summary (5 ratings with 1-2 line findings each): (1) Reliability, (2) Observability, (3) Security, (4) Performance, (5) Deployment. Used by TPM for quick handoff instead of full assessment. SRE produces both full and summary versions."
        ),
        "Release Notes": SystemArtifactTemplate(
            name: "Release Notes",
            icon: "doc.plaintext",
            mimeType: "text/markdown",
            description: "Release notes for end users and stakeholders covering: (1) what changed and why — written for a non-technical audience, (2) new features with brief descriptions, (3) bug fixes and improvements, (4) known limitations or caveats, (5) upgrade instructions if applicable. Written in plain language, not engineering jargon."
        ),
        // Quest Party artifacts
        "World Compendium": SystemArtifactTemplate(
            name: "World Compendium",
            icon: "globe",
            mimeType: "text/markdown",
            description: "World lore for a single-player adventure covering: (1) setting overview — geography, era, tone, and the player's starting location, (2) factions and their attitude toward the player, (3) history and events relevant to the player's journey, (4) magic/technology the player can use or face, (5) a central tension the player walks into. Should give the Quest Master everything needed to immerse one hero in a living world."
        ),
        "NPC Compendium": SystemArtifactTemplate(
            name: "NPC Compendium",
            icon: "person.3",
            mimeType: "text/markdown",
            description: "NPC reference for a single-player adventure. For each character: (1) name, role, and appearance, (2) personality and motivations, (3) attitude toward the player and why, (4) first-encounter hook — what they're doing when the player meets them, (5) in-character dialogue lines and a secret the player can discover. Designed for face-to-face interactions with a solo hero."
        ),
        "Encounter Guide": SystemArtifactTemplate(
            name: "Encounter Guide",
            icon: "flag",
            mimeType: "text/markdown",
            description: "Encounter design for a single-player adventure (no party — one hero). Covering: (1) encounters forming a narrative arc with location and sensory details, (2) type — combat, social, exploration, or hybrid, (3) branching outcomes with meaningful player choice, (4) solo balance — environmental advantages, escape routes, cleverness over force, (5) narrative connection to the overall story. Designed for a lone protagonist."
        ),
        "Balance Review": SystemArtifactTemplate(
            name: "Balance Review",
            icon: "scale.3d",
            mimeType: "text/markdown",
            description: "Single-player viability assessment covering: (1) solo survivability — can one person handle each encounter? (2) power curve — does difficulty escalate naturally? (3) player agency — does every encounter offer meaningful choice? (4) NPC consistency across documents, (5) branch integrity — do all outcome paths lead somewhere? Focused on fun, fair solo play."
        ),
        // Discussion Club artifacts
        "Discussion Summary": SystemArtifactTemplate(
            name: "Discussion Summary",
            icon: "bubble.left.and.bubble.right",
            mimeType: "text/markdown",
            description: "Discussion synthesis covering: (1) topic and key question discussed, (2) main perspectives and arguments from each participant, (3) areas of agreement and disagreement, (4) key insights or conclusions reached, (5) open questions and next steps. Written as a balanced synthesis, not just a transcript — highlight what was learned or decided."
        ),
    ]

    // MARK: - Team Role ID Sets

    /// Defines which system role IDs belong to each team template (excluding "supervisor" — always included)
    static let teamRoleIDs: [String: [String]] = [
        "faang": [
            "productManager", "uxResearcher", "uxDesigner", "techLead",
            "softwareEngineer", "codeReviewer", "sre", "tpm",
        ],
        "startup": ["softwareEngineer"],
        "questParty": [
            "loreMaster", "npcCreator", "encounterArchitect", "rulesArbiter", "questMaster",
        ],
        "discussionClub": ["theAgreeable", "theOpen", "theConscientious", "theExtrovert", "theNeurotic"],
        "engineering": ["techLead", "softwareEngineer", "codeReviewer", "tpm"],
        "assistant": ["assistant"],
    ]
}
