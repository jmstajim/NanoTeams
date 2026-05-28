import XCTest

@testable import NanoTeams

/// Regression tests for the `## Deliverables` section elision contract:
/// when a role has empty `expectedArtifacts`, the section must disappear
/// entirely (via `TemplateResolver.stripOrphanHeaders`). The prior bug
/// was a literal `.` hardcoded after `{expectedArtifacts}` in the four
/// producing-role templates — it survived placeholder resolution as
/// non-whitespace body and defeated the orphan-stripper, leaving
/// `## Deliverables\n.\n` in the rendered prompt.
///
/// See `docs/prompt-engineering-sources.md` §6 (no filler bytes) and §98
/// (omit empty list sections) for the principle, and the chip-format
/// contract docstring at the top of
/// `Domain/SystemTemplates+PromptLibrary.swift`.
@MainActor
final class DeliverablesElisionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    override func tearDown() {
        MonotonicClock.shared.reset()
        super.tearDown()
    }

    // MARK: - Literal-pin: no producing-role template ships `{expectedArtifacts}.`

    /// Walks the 4 producing-role templates and asserts none of them
    /// reintroduce the trailing literal period after `{expectedArtifacts}`.
    /// Cheap drift guard — fires the moment anyone edits a template back
    /// into the pre-fix shape, independent of the runtime resolution path.
    func testProducingTemplates_haveNoLiteralPeriodAfterExpectedArtifactsChip() {
        let producingTemplates: [(name: String, body: String)] = [
            ("softwareTemplate", SystemTemplates.softwareTemplate),
            ("questPartyTemplate", SystemTemplates.questPartyTemplate),
            ("discussionTemplate", SystemTemplates.discussionTemplate),
            ("genericTemplate", SystemTemplates.genericTemplate),
        ]
        for (name, body) in producingTemplates {
            XCTAssertFalse(
                body.contains("{expectedArtifacts}."),
                "\(name) must not have a literal `.` after `{expectedArtifacts}` — "
                + "that defeats stripOrphanHeaders for empty-deliverables roles."
            )
            XCTAssertTrue(
                body.contains("{expectedArtifacts}"),
                "\(name) must still carry the {expectedArtifacts} chip itself."
            )
        }
    }

    // MARK: - End-to-end via PromptBuilder.buildChatMessages

    /// Empty `expectedArtifacts` ⇒ no `## Deliverables` heading in the
    /// resolved system prompt and no orphan `.` line anywhere.
    func testBuildChatMessages_emptyExpectedArtifacts_elidesDeliverablesSection() {
        let systemContent = renderSystemPromptForAdvisoryRole()

        XCTAssertFalse(
            systemContent.contains("## Deliverables"),
            "Empty expectedArtifacts must elide the entire `## Deliverables` section. Got:\n\(systemContent)"
        )
        // No lone `.` line — that was the visible symptom of the bug.
        let lines = systemContent.components(separatedBy: "\n")
        XCTAssertFalse(
            lines.contains("."),
            "Resolved prompt must not contain a lone `.` line. Got:\n\(systemContent)"
        )
    }

    /// Non-empty `expectedArtifacts` ⇒ `## Deliverables` present, artifact
    /// names listed, and crucially **no trailing period** on the artifact
    /// list (the period was the cosmetic decoration we removed). Scoped
    /// to the `## Deliverables` section body — `Engineering Notes.` still
    /// appears elsewhere (e.g. `Your position: Produces: Engineering Notes.`
    /// — that period is correct, it's a label-prefixed sentence).
    func testBuildChatMessages_nonEmptyExpectedArtifacts_rendersWithoutTrailingPeriod() {
        let systemContent = renderSystemPromptForProducingRole()

        XCTAssertTrue(
            systemContent.contains("## Deliverables"),
            "Producing role must keep the `## Deliverables` heading. Got:\n\(systemContent)"
        )

        let deliverablesBody = extractDeliverablesBody(from: systemContent)
        XCTAssertNotNil(deliverablesBody, "Could not isolate `## Deliverables` body. Got:\n\(systemContent)")
        guard let body = deliverablesBody else { return }

        // First non-empty line of the section IS the artifact-list line.
        let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        XCTAssertEqual(
            firstLine,
            "Engineering Notes",
            "`## Deliverables` body's first line must be the bare artifact list with NO trailing period — that was the byte removed."
        )
    }

    /// Returns the body of the `## Deliverables` section (text between the
    /// heading and the next `##` heading or end-of-string), or `nil` if
    /// the heading isn't present.
    private func extractDeliverablesBody(from prompt: String) -> String? {
        guard let headerRange = prompt.range(of: "## Deliverables\n") else { return nil }
        let afterHeader = prompt[headerRange.upperBound...]
        if let nextHeaderRange = afterHeader.range(of: "\n## ") {
            return String(afterHeader[..<nextHeaderRange.lowerBound])
        }
        return String(afterHeader)
    }

    // MARK: - Fixtures

    /// Builds a 1-role team using the production `softwareTemplate` with an
    /// advisory role (no `producesArtifacts`, no `requiredArtifacts`) and
    /// renders the first chat message's system content.
    private func renderSystemPromptForAdvisoryRole() -> String {
        let advisoryRole = TeamRoleDefinition(
            id: "advisor",
            name: "Advisor",
            prompt: "You advise.",
            toolIDs: ["ask_supervisor"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: []
            ),
            isSystemRole: false
        )
        let team = Team(
            name: "Advisory Team",
            templateID: "faang",
            systemPromptTemplate: SystemTemplates.softwareTemplate,
            roles: [advisoryRole],
            artifacts: [],
            settings: .default,
            graphLayout: .default
        )
        let step = StepExecution(
            id: "advisor",
            role: .custom(id: "advisor"),
            title: "Advise",
            expectedArtifacts: [],
            status: .pending
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Task", supervisorTask: "Help out", runs: [run])
        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: advisoryRole
        )
        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        XCTAssertEqual(messages.first?.role, MessageRole.system, "First message must be system prompt")
        return messages.first?.content ?? ""
    }

    /// Builds a 1-role team using the production `softwareTemplate` with a
    /// producing role (`producesArtifacts: ["Engineering Notes"]`).
    private func renderSystemPromptForProducingRole() -> String {
        let producingRole = TeamRoleDefinition(
            id: "engineer",
            name: "Software Engineer",
            prompt: "You write code.",
            toolIDs: ["read_file", "create_artifact"],
            usePlanningPhase: false,
            dependencies: RoleDependencies(
                requiredArtifacts: [],
                producesArtifacts: ["Engineering Notes"]
            ),
            isSystemRole: false
        )
        let team = Team(
            name: "Producing Team",
            templateID: "faang",
            systemPromptTemplate: SystemTemplates.softwareTemplate,
            roles: [producingRole],
            artifacts: [
                TeamArtifact(
                    id: "engineering-notes",
                    name: "Engineering Notes",
                    icon: "doc.text",
                    mimeType: "text/markdown",
                    description: "Notes from engineering work"
                )
            ],
            settings: .default,
            graphLayout: .default
        )
        let step = StepExecution(
            id: "engineer",
            role: .custom(id: "engineer"),
            title: "Engineer",
            expectedArtifacts: ["Engineering Notes"],
            status: .pending
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Task", supervisorTask: "Ship a feature", runs: [run])
        let context = PromptBuilder.Context(
            task: task,
            step: step,
            stepIndex: 0,
            run: run,
            workFolder: nil,
            artifactReader: { _ in nil },
            activeTeam: team,
            roleDefinition: producingRole
        )
        let messages = PromptBuilder.buildChatMessages(context: context, tools: [])
        XCTAssertEqual(messages.first?.role, MessageRole.system, "First message must be system prompt")
        return messages.first?.content ?? ""
    }
}
