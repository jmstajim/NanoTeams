import Foundation

// MARK: - Artifact Templates

nonisolated extension SystemTemplates {

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
        "Code Review Summary": SystemArtifactTemplate(
            name: "Code Review Summary",
            icon: "checkmark",
            mimeType: "text/markdown",
            description: "Concise code review summary (3-5 bullet points) for downstream roles: (1) overall status (approve/request changes), (2) critical issues if any with file:line citations from the diff, (3) scope compliance flagged (if out-of-scope features were added, note as enhancement), (4) key recommendations (no more than 2-3 items). Used by TPM for quick handoff."
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
        // Ultra Team artifacts
        "Change Brief": SystemArtifactTemplate(
            name: "Change Brief",
            icon: "list.clipboard",
            mimeType: "text/markdown",
            description: "The change specified well enough to build from: (1) the KIND of work — defect, new behaviour, refactor, question about the code, or one-file edit — stated first, because everything downstream sizes itself to it, (2) observable behaviour, stated so a test could check it, (3) acceptance criteria, concrete and countable, each with the command, test or file that would settle it, (4) what is out of scope, (5) the files and modules the change touches, by path, (6) the Supervisor's answers recorded verbatim, and any assumption made where an answer is missing."
        ),
        "Brief Critique": SystemArtifactTemplate(
            name: "Brief Critique",
            icon: "text.magnifyingglass",
            mimeType: "text/markdown",
            description: "The brief itself judged, before any design exists: (1) one entry per acceptance criterion with the command, test or file that would settle it — or the criterion marked unsettleable, (2) every claim the brief makes about the state of the build, the tests or the timing, each paired with the tool call that established it or marked unsupported, (3) requirements that are ambiguous enough to be built two ways, (4) what the brief leaves out that the work cannot proceed without."
        ),
        "Diff Review": SystemArtifactTemplate(
            name: "Diff Review",
            icon: "arrow.triangle.branch",
            mimeType: "text/markdown",
            description: "The diff read as the only record of what the repository actually received: (1) every changed file with what changed in it, (2) each change matched to the claim in the implementation notes that covers it, (3) changes no claim covers, (4) claims no change supports, (5) leftovers that belong to nobody — stray files, commented-out code, debug output."
        ),
        "Approach A": SystemArtifactTemplate(
            name: "Approach A",
            icon: "square.stack.3d.up",
            mimeType: "text/markdown",
            description: "The thorough design: (1) the design in prose with the seam and the ownership named, (2) every file to add or change, by path, (3) the invariants preserved and where they are enforced, (4) the tests that prove it, (5) the strongest argument against it. A design record with paths, not the code itself."
        ),
        "Approach B": SystemArtifactTemplate(
            name: "Approach B",
            icon: "scissors",
            mimeType: "text/markdown",
            description: "The minimal design: (1) the design in prose, naming what was deliberately not built, (2) every file to change, by path, (3) the behaviour put at risk by the short path, (4) the tests that prove it, (5) the point at which this approach stops being adequate. A design record with paths, not the code itself."
        ),
        "Spec Critique": SystemArtifactTemplate(
            name: "Spec Critique",
            icon: "checklist",
            mimeType: "text/markdown",
            description: "Both approaches judged against the brief: (1) one entry per acceptance criterion with a verdict for each approach — met, not met, or not established — and the evidence read, (2) requirements neither approach covers, (3) a recommendation naming one approach and the criterion that decided it."
        ),
        "Regression Critique": SystemArtifactTemplate(
            name: "Regression Critique",
            icon: "exclamationmark.triangle",
            mimeType: "text/markdown",
            description: "What each approach breaks: (1) each risk with the file and line that carries it and the sequence that triggers it, (2) the blast radius of each approach, (3) migration or compatibility work implied, (4) a recommendation naming one approach, the risk that decided it, and the conditions to respect while implementing."
        ),
        "Implementation Notes": SystemArtifactTemplate(
            name: "Implementation Notes",
            icon: "hammer.fill",
            mimeType: "text/markdown",
            description: "What was actually built: (1) every file changed, by path, and what changed in each, (2) deviations from the recommended approach with what forced each, (3) the exact commands run and what each returned, (4) anything left unfinished, stated plainly."
        ),
        "Verification Report": SystemArtifactTemplate(
            name: "Verification Report",
            icon: "checkmark.seal",
            mimeType: "text/markdown",
            description: "What the build and the tests established: (1) the exact commands run and the outcome of each, (2) test counts exactly as the output reported them, (3) one entry per acceptance criterion from the brief — met, not met, or not established — with what settled it, (4) each claim from the implementation notes, quoted from its source, with the check that settled it, (5) changes in the diff that no claim covers, (6) claims that could not be checked and why, (7) a closing verdict covering what works, what does not, and what was not established."
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
        "codingAssistant": ["codingAssistant"],
        "codingAgent": ["codingAgent"],
        "ultra": [
            "changePlanner", "briefCritic", "solutionArchitect", "pragmaticArchitect",
            "specCritic", "regressionCritic",
            "changeEngineer", "diffReviewer", "changeVerifier",
        ],
    ]
}
