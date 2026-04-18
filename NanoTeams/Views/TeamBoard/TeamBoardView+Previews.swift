import SwiftUI

// MARK: - Preview Helpers

// periphery:ignore - used in #Preview macros across TeamBoard view files
private enum TeamBoardPreviewData {
    static let team = TeamTemplateFactory.faang()
    static let workFolder = WorkFolderProjection(
        state: WorkFolderState(name: "Preview", activeTeamID: team.id),
        settings: .defaults,
        teams: [team]
    )
    /// Stable task ID shared across preview setup.
    static let taskID = 0

    /// Sequential timestamps for deterministic timeline ordering in previews.
    static func ts(_ offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 1000 + offset)
    }

    static func roleID(_ systemRoleID: String) -> String {
        team.roles.first { $0.systemRoleID == systemRoleID }?.id ?? ""
    }

    static func statuses(
        _ base: RoleExecutionStatus = .idle,
        overrides: [String: RoleExecutionStatus] = [:]
    ) -> [String: RoleExecutionStatus] {
        var result: [String: RoleExecutionStatus] = [:]
        for role in team.roles { result[role.id] = base }
        for (key, value) in overrides { result[roleID(key)] = value }
        return result
    }

    static func step(
        _ systemRoleID: String,
        status: StepStatus,
        artifacts: [Artifact] = [],
        messages: [StepMessage] = [],
        toolCalls: [StepToolCall] = [],
        llmConversation: [LLMMessage] = [],
        consultations: [TeammateConsultation] = [],
        scratchpad: String? = nil,
        supervisorQuestion: String? = nil,
        supervisorAnswer: String? = nil
    ) -> StepExecution {
        let roleDef = team.roles.first { $0.systemRoleID == systemRoleID }!
        var s = StepExecution.make(for: roleDef)
        s.status = status
        s.artifacts = artifacts
        s.messages = messages
        s.toolCalls = toolCalls
        s.llmConversation = llmConversation
        s.consultations = consultations
        s.scratchpad = scratchpad
        if let q = supervisorQuestion {
            s.needsSupervisorInput = true
            s.supervisorQuestion = q
        }
        if let a = supervisorAnswer {
            s.supervisorAnswer = a
            s.needsSupervisorInput = false
        }
        return s
    }

    static func task(
        title: String = "Implement dark mode",
        supervisorTask: String = "Add a dark mode toggle to the settings page.",
        status: TaskStatus = .running,
        createdAt: Date? = nil,
        roleStatuses: [String: RoleExecutionStatus],
        steps: [StepExecution] = [],
        meetings: [TeamMeeting] = [],
        changeRequests: [ChangeRequest] = [],
        closedAt: Date? = nil,
        isChatMode: Bool = false
    ) -> NTMSTask {
        let run = Run(id: 0, steps: steps, meetings: meetings, changeRequests: changeRequests, roleStatuses: roleStatuses, teamID: team.id)
        var task = NTMSTask(
            id: taskID,
            title: title,
            supervisorTask: supervisorTask,
            status: status,
            runs: [run],
            closedAt: closedAt,
            preferredTeamID: team.id,
            isChatMode: isChatMode
        )
        if let createdAt { task.createdAt = createdAt }
        return task
    }

    static func configuredStore(task: NTMSTask) -> NTMSOrchestrator {
        let store = NTMSOrchestrator(repository: NTMSRepository())
        store.snapshot = WorkFolderContext(
            projection: workFolder,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: task.id,
            activeTask: task
        )
        store.activeTask = task
        return store
    }
}

// MARK: - Previews

#Preview("No Task") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    TeamBoardView(workFolder: nil as WorkFolderProjection?)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Running") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            createdAt: TeamBoardPreviewData.ts(0),
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxResearcher": .working,
                "uxDesigner": .idle,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements", createdAt: TeamBoardPreviewData.ts(2))
                ], llmConversation: [
                    LLMMessage(
                        createdAt: TeamBoardPreviewData.ts(1),
                        role: .assistant,
                        content: "I've analyzed the project requirements and prepared a comprehensive product specification for the dark mode feature. The document covers user stories, acceptance criteria, and rollout strategy.",
                        thinking: "The supervisor wants dark mode. I need to consider:\n1. User preferences persistence\n2. System appearance detection\n3. Manual override toggle\n4. Color palette definition for both themes\n5. Migration strategy for existing UI components"
                    )
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, toolCalls: [
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(4), name: "read_file", argumentsJSON: "{\"path\": \"src/theme.swift\"}", resultJSON: "{\"content\": \"struct AppTheme { ... }\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(5), name: "list_files", argumentsJSON: "{\"path\": \"src/components\"}", resultJSON: "{\"files\": [\"Button.swift\", \"Card.swift\", \"Header.swift\"]}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(6), name: "read_file", argumentsJSON: "{\"path\": \"src/components/Button.swift\"}", resultJSON: "{\"content\": \"struct StyledButton: View { ... }\"}")
                ], llmConversation: [
                    LLMMessage(
                        createdAt: TeamBoardPreviewData.ts(3),
                        role: .assistant,
                        content: "Let me review the existing theme infrastructure and component architecture to design the implementation plan.",
                        thinking: "I need to understand the current theme system before proposing changes. Let me check:\n- How colors are currently defined\n- Whether there's an existing AppTheme or similar abstraction\n- How components consume style values\n- The view hierarchy depth to determine the best propagation approach"
                    ),
                    LLMMessage(
                        createdAt: TeamBoardPreviewData.ts(7),
                        role: .assistant,
                        content: "Based on the codebase review, I recommend a centralized ThemeManager with environment-based propagation. The existing AppTheme struct provides a good foundation — we'll extend it with dark variants and add an @Environment key for reactive switching.",
                        thinking: "The codebase has a basic AppTheme struct but no dark mode support. Components use hardcoded colors in some places. I should propose:\n1. Extend AppTheme with a ColorScheme-aware palette\n2. Create a ThemeManager as an @Observable class\n3. Inject via .environment() at the app root\n4. Migrate components incrementally"
                    )
                ]),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Paused") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            status: .paused,
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .done,
                "softwareEngineer": .working,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .done, artifacts: [
                    Artifact(name: "Implementation Plan")
                ]),
                TeamBoardPreviewData.step("softwareEngineer", status: .paused, messages: [
                    StepMessage(role: .softwareEngineer, content: "Started implementing ThemeManager class...")
                ]),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .paused

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Needs Acceptance") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .needsAcceptance,
                "uxResearcher": .done,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .needsApproval, artifacts: [
                    Artifact(name: "Implementation Plan")
                ], messages: [
                    StepMessage(role: .techLead, content: "I've completed the implementation plan for the dark mode feature. The plan covers theme infrastructure, component updates, and persistence strategy.")
                ]),
                TeamBoardPreviewData.step("uxResearcher", status: .done, artifacts: [
                    Artifact(name: "Research Report")
                ]),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Supervisor Input") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            status: .needsSupervisorInput,
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "softwareEngineer": .working,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step(
                    "softwareEngineer",
                    status: .needsSupervisorInput,
                    messages: [
                        StepMessage(role: .softwareEngineer, content: "I need clarification on the design approach.")
                    ],
                    supervisorQuestion: "Should the dark mode toggle use system appearance detection or a manual toggle in Settings?"
                ),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .needsSupervisorInput

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Failed Role") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            status: .failed,
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .done,
                "softwareEngineer": .failed,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .done, artifacts: [
                    Artifact(name: "Implementation Plan")
                ]),
                TeamBoardPreviewData.step("softwareEngineer", status: .failed, messages: [
                    StepMessage(role: .softwareEngineer, content: "Build failed with 3 errors in ThemeManager.swift. Unable to resolve type conflicts between NSAppearance and custom theme enum.")
                ]),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .failed

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("All Done — Review") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            status: .needsSupervisorAcceptance,
            roleStatuses: TeamBoardPreviewData.statuses(.done),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .done, artifacts: [
                    Artifact(name: "Implementation Plan")
                ]),
                TeamBoardPreviewData.step("uxDesigner", status: .done, artifacts: [
                    Artifact(name: "Design Spec")
                ]),
                TeamBoardPreviewData.step("softwareEngineer", status: .done, artifacts: [
                    Artifact(name: "Engineering Notes")
                ]),
                TeamBoardPreviewData.step("codeReviewer", status: .done, artifacts: [
                    Artifact(name: "Code Review")
                ]),
                TeamBoardPreviewData.step("sre", status: .done, artifacts: [
                    Artifact(name: "Production Readiness")
                ]),
                TeamBoardPreviewData.step("tpm", status: .done, artifacts: [
                    Artifact(name: "Release Notes")
                ]),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .done

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — Pending") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .idle,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, messages: [
                    StepMessage(role: .techLead, content: "Requesting a meeting to discuss the rollout strategy...")
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Dark mode rollout strategy",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner, .productManager],
                    context: "Need to align on incremental vs big-bang migration before writing the implementation plan.",
                    status: .pending
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — In Progress") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .working,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, messages: [
                    StepMessage(role: .techLead, content: "In a meeting discussing component architecture...")
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Component architecture for dark mode",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner, .productManager],
                    context: "Need to decide on token-based vs hardcoded color approach.",
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.1), role: .techLead,
                                    content: "I've checked the codebase - only 3 files reference colors directly, so migration scope is small. I see two options: token-based semantic palette or extending hardcoded colors. Thoughts?",
                                    messageType: .question,
                                    thinking: "Let me check the actual scope before proposing anything. Need to list components, read the theme file, and verify the build state.",
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "list_files", arguments: "{\"path\": \"src/components\"}", result: "{\"files\": [\"Button.swift\", \"Card.swift\", \"Header.swift\", \"Toggle.swift\", \"Sidebar.swift\"]}"),
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"src/theme.swift\"}", result: "{\"content\": \"struct AppTheme {\\n    static let primary: Color = .blue\\n    ...\"}"),
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"src/tokens.json\"}", result: "{\"error\": \"File not found: src/tokens.json\"}", isError: true),
                                    ]),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.2), role: .uxDesigner,
                                    content: "I'd strongly recommend the token-based approach. Hardcoded colors will become unmaintainable as we add more themes. I suggest we define surface-primary, surface-secondary, text-primary, and text-secondary as the core tokens.",
                                    messageType: .proposal),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.3), role: .productManager,
                                    content: "I agree with the token approach. From a product perspective, we may want to support custom themes later, and tokens make that trivial. Let me check the current feature config...",
                                    messageType: .agreement,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"config/features.json\"}", result: "{\"content\": \"{\\\"darkMode\\\": false, \\\"customThemes\\\": false}\"}"),
                                    ]),
                    ],
                    status: .inProgress
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = {
        engineState[TeamBoardPreviewData.taskID] = .running
        engineState.setMeetingParticipants([
            TeamBoardPreviewData.roleID("techLead"),
            TeamBoardPreviewData.roleID("uxDesigner"),
            TeamBoardPreviewData.roleID("productManager"),
        ], for: TeamBoardPreviewData.taskID)
    }()

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — Completed") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .idle,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, messages: [
                    StepMessage(role: .techLead, content: "Meeting concluded. Proceeding with token-based architecture...")
                ], llmConversation: [
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(12), role: .user,
                               content: "Meeting concluded: Agreed on token-based semantic palette with incremental migration. Core tokens: surface-primary, surface-secondary, text-primary, text-secondary. Feature flag for gradual rollout.",
                               sourceRole: .techLead, sourceContext: .meeting),
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Dark mode rollout strategy",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner, .productManager],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.1), role: .techLead,
                                    content: "I'd like to discuss the rollout strategy. Should we migrate all components at once or take an incremental approach?",
                                    messageType: .question,
                                    thinking: "A big-bang migration is risky — better to propose incremental rollout with a feature flag."),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.2), role: .uxDesigner,
                                    content: "I suggest an incremental approach. Core components (navigation, backgrounds, text) first, then secondary elements. This lets us validate the palette before full rollout.",
                                    messageType: .proposal),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.3), role: .productManager,
                                    content: "I agree with the incremental approach. Let's add a feature flag so we can enable it gradually. We should also plan a beta testing phase with a subset of users.",
                                    messageType: .agreement,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"config/features.json\"}", result: "{\"content\": \"{\\\"darkMode\\\": false}\"}"),
                                    ]),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.4), role: .techLead,
                                    content: "In summary: we'll take an incremental rollout with core components first, behind a feature flag. Beta phase before general availability.",
                                    messageType: .conclusion),
                    ],
                    decisions: [
                        TeamDecision(summary: "Incremental rollout with feature flag", proposedBy: .techLead, agreedBy: [.uxDesigner, .productManager]),
                        TeamDecision(summary: "Core tokens: surface-primary, surface-secondary, text-primary, text-secondary", proposedBy: .uxDesigner, agreedBy: [.techLead, .productManager]),
                    ],
                    status: .completed
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — Escalated") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            status: .needsSupervisorInput,
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .working,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .needsSupervisorInput, messages: [
                    StepMessage(role: .techLead, content: "Meeting escalated — team could not reach consensus on migration scope.")
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Migration scope for dark mode",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner, .softwareEngineer],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.1), role: .techLead,
                                    content: "Should we migrate just the core shell or all 40+ components? I'm leaning towards core-only for the first release.",
                                    messageType: .question),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.2), role: .uxDesigner,
                                    content: "I'm worried about a partial migration — users will see inconsistent theming. We should migrate everything or nothing.",
                                    messageType: .objection,
                                    thinking: "A half-dark, half-light UI would be worse than no dark mode at all. This is a UX dealbreaker."),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.3), role: .softwareEngineer,
                                    content: "Migrating all 40 components at once is unrealistic given our timeline. The risk of regressions is too high. I side with the incremental approach.",
                                    messageType: .objection,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "list_files", arguments: "{\"path\": \"src/components\"}", result: "{\"files\": [\"Button.swift\", \"Card.swift\", ... 38 more]}"),
                                    ]),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.4), role: .techLead,
                                    content: "We're deadlocked — UX wants full migration, Engineering wants incremental. Escalating to Supervisor for a final decision.",
                                    messageType: .conclusion),
                    ],
                    status: .escalatedToSupervisor
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .needsSupervisorInput

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — Cancelled") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, messages: [
                    StepMessage(role: .techLead, content: "Meeting was cancelled — found the answer in the docs instead.")
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Color token naming conventions",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.1), role: .techLead,
                                    content: "Before we start — I just found Apple's HIG has a definitive section on semantic color naming. Let me read it first.",
                                    messageType: .discussion,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"docs/hig-colors.md\"}", result: "{\"content\": \"Use system-defined semantic colors: label, secondaryLabel, systemBackground...\"}"),
                                    ]),
                    ],
                    status: .cancelled
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Meeting — Multiple Meetings") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxDesigner": .done,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, messages: [
                    StepMessage(role: .techLead, content: "Two meetings completed. Finalizing the implementation plan with all decisions applied.")
                ], llmConversation: [
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(12), role: .user,
                               content: "Meeting concluded: Token-based palette confirmed. Core tokens agreed.",
                               sourceRole: .techLead, sourceContext: .meeting),
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(16), role: .user,
                               content: "Meeting concluded: Rollout will use feature flags with 3-phase plan.",
                               sourceRole: .techLead, sourceContext: .meeting),
                ]),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(10),
                    topic: "Color palette design",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.1), role: .techLead,
                                    content: "What color tokens should we define for the dark palette?",
                                    messageType: .question),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.2), role: .uxDesigner,
                                    content: "I suggest four core tokens: surface-primary (#121212), surface-secondary (#1E1E1E), text-primary (#FFFFFF), text-secondary (#B0B0B0). These follow WCAG AA contrast ratios.",
                                    messageType: .proposal,
                                    thinking: "Need to ensure 4.5:1 contrast for body text and 3:1 for large text. These values pass both thresholds."),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(10.3), role: .techLead,
                                    content: "Sounds good. Let's go with those four as the core set and add accent tokens later.",
                                    messageType: .agreement),
                    ],
                    decisions: [
                        TeamDecision(summary: "Four core dark tokens defined", proposedBy: .uxDesigner, agreedBy: [.techLead]),
                    ],
                    status: .completed
                ),
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(14),
                    topic: "Rollout plan and feature flags",
                    initiatedBy: .techLead,
                    participants: [.techLead, .productManager],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(14.1), role: .techLead,
                                    content: "How about a 3-phase rollout? Phase 1: core shell. Phase 2: all components. Phase 3: custom themes.",
                                    messageType: .proposal),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(14.2), role: .productManager,
                                    content: "I'd recommend adding feature flag integration from phase 1. We need the ability to roll back without a code deploy.",
                                    messageType: .proposal,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"config/feature_flags.json\"}", result: "{\"content\": \"{\\\"flags\\\": {\\\"darkMode\\\": {\\\"enabled\\\": false, \\\"rollout\\\": 0}}}\"}"),
                                    ]),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(14.3), role: .techLead,
                                    content: "In summary: 3-phase rollout with feature flags from day one. Phase 1 targets core shell, flag-gated.",
                                    messageType: .conclusion),
                    ],
                    decisions: [
                        TeamDecision(summary: "3-phase rollout with feature flags from phase 1", proposedBy: .techLead, agreedBy: [.productManager]),
                    ],
                    status: .completed
                ),
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}

#Preview("Role Selected") {
    @Previewable @State var store = TeamBoardPreviewData.configuredStore(
        task: TeamBoardPreviewData.task(
            createdAt: TeamBoardPreviewData.ts(0),
            roleStatuses: TeamBoardPreviewData.statuses(overrides: [
                "supervisor": .done,
                "productManager": .done,
                "techLead": .working,
                "uxResearcher": .working,
                "uxDesigner": .idle,
                "softwareEngineer": .idle,
            ]),
            steps: [
                TeamBoardPreviewData.step("productManager", status: .done, artifacts: [
                    Artifact(name: "Product Requirements", createdAt: TeamBoardPreviewData.ts(2))
                ], llmConversation: [
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(1), role: .assistant,
                               content: "I've prepared the product specification for dark mode.",
                               thinking: "Supervisor wants dark mode. Key areas:\n1. User preference persistence\n2. System appearance detection\n3. Color palette for both themes")
                ]),
                TeamBoardPreviewData.step("techLead", status: .running, artifacts: [
                    Artifact(name: "Implementation Plan", createdAt: TeamBoardPreviewData.ts(18))
                ], toolCalls: [
                    // Tool calls: read files, consult teammate, ask supervisor
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(4), name: "read_file",
                                 argumentsJSON: "{\"path\": \"src/theme.swift\"}",
                                 resultJSON: "{\"content\": \"struct AppTheme { ... }\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(5), name: "list_files",
                                 argumentsJSON: "{\"path\": \"src/components\"}",
                                 resultJSON: "{\"files\": [\"Button.swift\", \"Card.swift\", \"Header.swift\"]}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(6), name: "read_file",
                                 argumentsJSON: "{\"path\": \"src/components/Button.swift\"}",
                                 resultJSON: "{\"content\": \"struct StyledButton: View { ... }\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(8), name: "ask_teammate",
                                 argumentsJSON: "{\"teammate\": \"uxDesigner\", \"question\": \"What color tokens should we use for the dark palette?\"}",
                                 resultJSON: "{\"response\": \"Use semantic tokens: surface-primary, surface-secondary, text-primary, text-secondary. Avoid hardcoded hex values.\"}"),
                    StepToolCall(id: UUID(uuidString: "00000000-0000-0000-0000-A00000000001")!, createdAt: TeamBoardPreviewData.ts(12),
                                 name: "ask_supervisor",
                                 argumentsJSON: "{\"question\": \"Should we support automatic switching based on system appearance, or manual toggle only?\"}",
                                 resultJSON: "{\"answer\": \"Support both — auto-detect system appearance by default, with a manual override in Settings.\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(15), name: "edit_file",
                                 argumentsJSON: "{\"path\": \"src/theme.swift\", \"old_text\": \"struct AppTheme {\", \"new_text\": \"struct AppTheme {\\n    enum Mode { case light, dark, system }\"}",
                                 resultJSON: "{\"success\": true, \"path\": \"src/theme.swift\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(16), name: "write_file",
                                 argumentsJSON: "{\"path\": \"src/ThemeManager.swift\", \"content\": \"import SwiftUI\\n\\n@Observable final class ThemeManager {\\n    var mode: AppTheme.Mode = .system\\n    ...\\n}\"}",
                                 resultJSON: "{\"success\": true, \"path\": \"src/ThemeManager.swift\"}"),
                    StepToolCall(createdAt: TeamBoardPreviewData.ts(17), name: "run_xcodebuild",
                                 argumentsJSON: "{\"action\": \"build\"}",
                                 resultJSON: "{\"success\": true, \"warnings\": 2, \"errors\": 0}"),
                ], llmConversation: [
                    // 1. Initial thinking + message
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(3), role: .assistant,
                               content: "Let me review the existing theme infrastructure to design the implementation plan.",
                               thinking: "I need to understand the current theme system before proposing changes. Let me check:\n- How colors are currently defined\n- Whether there's an existing AppTheme or similar abstraction\n- How components consume style values\n- The view hierarchy depth for propagation approach"),
                    // 2. After tool calls — consultation response injected
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(9), role: .user,
                               content: "Use semantic tokens: surface-primary, surface-secondary, text-primary, text-secondary. Avoid hardcoded hex values.",
                               sourceRole: .uxDesigner, sourceContext: .consultation),
                    // 3. Message after consultation
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(10), role: .assistant,
                               content: "Good — UX Designer confirms semantic tokens. I'll structure the palette around surface/text token pairs with ColorScheme-aware resolution.",
                               thinking: "The UX Designer recommends semantic tokens rather than raw colors. This aligns well with SwiftUI's adaptive color system. I'll create a token-based palette that resolves differently per ColorScheme."),
                    // 4. Supervisor answer injected
                    LLMMessage(id: UUID(uuidString: "00000000-0000-0000-0000-A00000000002")!, createdAt: TeamBoardPreviewData.ts(13), role: .user,
                               content: "Supervisor answer: Support both — auto-detect system appearance by default, with a manual override in Settings.",
                               sourceContext: .supervisorAnswer),
                    // 5. Message after supervisor answer
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(14), role: .assistant,
                               content: "The Supervisor wants both automatic and manual modes. I'll implement a ThemeManager with a three-way toggle: Light / Dark / System. The system mode will use `@Environment(\\.colorScheme)` for reactive switching.",
                               thinking: "With both auto and manual modes, I need:\n1. A ThemeManager @Observable with Mode enum (.light, .dark, .system)\n2. UserDefaults persistence for the user's choice\n3. Environment injection at the app root\n4. The system mode should react to OS appearance changes"),
                    // 6. Meeting result injected
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(12.5), role: .user,
                               content: "Meeting concluded: Agreed on incremental rollout — migrate core components first, then secondary views. Use feature flag for gradual activation.",
                               sourceRole: .techLead, sourceContext: .meeting),
                    // 7. Final summary message
                    LLMMessage(createdAt: TeamBoardPreviewData.ts(19), role: .assistant,
                               content: "Implementation plan is ready. I've created the ThemeManager class, updated AppTheme with mode support, and verified the build succeeds. The plan covers:\n\n1. **Token-based palette** — semantic color tokens (surface-primary, text-primary, etc.)\n2. **Three-way toggle** — Light / Dark / System with UserDefaults persistence\n3. **Incremental rollout** — core components first, behind a feature flag\n4. **Environment propagation** — `@Observable` ThemeManager injected at app root",
                               thinking: "Everything is in place. The build passes, the architecture is clean. Let me create the Implementation Plan artifact summarizing the approach.")
                ], consultations: [
                    TeammateConsultation(
                        requestingRole: .techLead, consultedRole: .uxDesigner,
                        question: "What color tokens should we use for the dark palette?",
                        response: "Use semantic tokens: surface-primary, surface-secondary, text-primary, text-secondary. Avoid hardcoded hex values.",
                        status: .completed),
                    TeammateConsultation(
                        requestingRole: .techLead, consultedRole: .productManager,
                        question: "Are there accessibility requirements for contrast ratios in dark mode?",
                        response: "Yes — WCAG AA minimum (4.5:1 for text, 3:1 for large text). We also need to support Increased Contrast accessibility setting.",
                        status: .completed)
                ], scratchpad: "## Dark Mode Implementation Plan\n- [x] Review existing theme infrastructure\n- [x] Consult UX Designer on color tokens\n- [x] Clarify auto vs manual toggle with Supervisor\n- [x] Design ThemeManager architecture\n- [ ] Migrate core components\n- [ ] Add feature flag integration",
                   supervisorQuestion: "{\"question\": \"Should we support automatic switching based on system appearance, or manual toggle only?\"}",
                   supervisorAnswer: "Support both — auto-detect system appearance by default, with a manual override in Settings."),
            ],
            meetings: [
                TeamMeeting(
                    createdAt: TeamBoardPreviewData.ts(11),
                    topic: "Dark mode rollout strategy",
                    initiatedBy: .techLead,
                    participants: [.techLead, .uxDesigner, .productManager],
                    messages: [
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(11.1), role: .techLead,
                                    content: "I'd like to discuss the rollout strategy. Should we migrate all components at once or take an incremental approach?",
                                    messageType: .question,
                                    thinking: "A big-bang migration is risky — better to propose incremental rollout with a feature flag."),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(11.2), role: .uxDesigner,
                                    content: "I suggest an incremental approach. Core components (navigation, backgrounds, text) first, then secondary elements. This lets us validate the palette before full rollout.",
                                    messageType: .proposal),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(11.3), role: .productManager,
                                    content: "I agree with the incremental approach. Let's add a feature flag so we can enable it gradually. We should also plan a beta testing phase with a subset of users.",
                                    messageType: .agreement,
                                    toolSummaries: [
                                        MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"config/features.json\"}", result: "{\"content\": \"{\\\"darkMode\\\": false}\"}")
                                    ]),
                        TeamMessage(createdAt: TeamBoardPreviewData.ts(11.4), role: .techLead,
                                    content: "In summary: we'll take an incremental rollout with core components first, behind a feature flag. Beta phase before general availability.",
                                    messageType: .conclusion)
                    ],
                    decisions: [
                        TeamDecision(summary: "Incremental rollout with feature flag", proposedBy: .techLead, agreedBy: [.uxDesigner, .productManager])
                    ]
                )
            ]
        )
    )
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    let _ = store.pendingRoleSelection = TeamBoardPreviewData.roleID("techLead")

    TeamBoardView(workFolder: TeamBoardPreviewData.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 900, height: 700)
}

#Preview("Chat Mode") {
    @Previewable @State var store: NTMSOrchestrator = {
        let chatTeam = TeamTemplateFactory.assistant()
        let chatWF = WorkFolderProjection(
            state: WorkFolderState(name: "Chat Project", activeTeamID: chatTeam.id),
            settings: .defaults,
            teams: [chatTeam]
        )
        let assistantRole = chatTeam.roles.first { !$0.isSupervisor }!
        var roleStatuses: [String: RoleExecutionStatus] = [:]
        for role in chatTeam.roles {
            roleStatuses[role.id] = role.isSupervisor ? .done : .working
        }
        var step = StepExecution.make(for: assistantRole)
        step.status = .running
        step.messages = [StepMessage(role: .custom(id: assistantRole.id), content: "How can I help you today?")]
        let run = Run(id: 0, steps: [step], roleStatuses: roleStatuses, teamID: chatTeam.id)
        let task = NTMSTask(
            id: TeamBoardPreviewData.taskID,
            title: "Quick question",
            supervisorTask: "Help me understand SwiftUI layout priorities.",
            status: .running,
            runs: [run],
            preferredTeamID: chatTeam.id,
            isChatMode: true
        )
        let s = NTMSOrchestrator(repository: NTMSRepository())
        s.snapshot = WorkFolderContext(projection: chatWF, tasksIndex: TasksIndex(), toolDefinitions: [], activeTaskID: task.id, activeTask: task)
        s.activeTask = task
        return s
    }()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()

    let _ = engineState[TeamBoardPreviewData.taskID] = .running

    TeamBoardView(workFolder: store.workFolder)
        .environment(store)
        .environment(engineState)
        .environment(config)
        .environment(streaming)
        .frame(width: 800, height: 600)
}
