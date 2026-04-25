import SwiftUI

// MARK: - Previews

#Preview("Empty Feed") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    TeamActivityFeedView(
        run: nil,
        roleDefinitions: Team.default.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: [],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — LLM Thinking + Consultation") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let tlRole = team.roles.first(where: { $0.name == "Tech Lead" })!
    let step = StepExecution(
        id: "preview",
        role: .techLead,
        title: "Tech Lead",
        expectedArtifacts: ["Implementation Plan"],
        status: .done,
        messages: [
            StepMessage(role: .techLead, content: "Designing the architecture for the notification system.")
        ],
        artifacts: [Artifact(name: "Implementation Plan", icon: "list.bullet.rectangle", description: "Architecture plan")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"Sources/Models/User.swift\"}", resultJSON: "{\"content\": \"struct User { ... }\"}", isError: false)
        ],
        consultations: [
            TeammateConsultation(
                requestingRole: .techLead,
                consultedRole: .productManager,
                question: "What's the expected notification throughput? Do we need to support more than 10k messages/sec?",
                response: "Initial target is 1k messages/sec with horizontal scaling to 10k. Use message queues for buffering.",
                status: .completed
            ),
            TeammateConsultation(
                requestingRole: .techLead,
                consultedRole: .softwareEngineer,
                question: "Can you confirm Redis is available in the current infrastructure?",
                response: "Yes, Redis 7.2 is available on the staging cluster. Production deployment is scheduled for next week.",
                status: .completed
            )
        ],
        llmConversation: [
            LLMMessage(role: .assistant, content: "I need to design a scalable notification architecture. Let me review the existing codebase and consult with the team.", thinking: "The user wants a WebSocket-based notification system. I should first understand the existing User model and then design the architecture. Key considerations:\n1. Message delivery guarantees\n2. Horizontal scaling\n3. Connection management\n4. Fallback mechanisms for offline users"),
            LLMMessage(role: .user, content: "Initial target is 1k messages/sec with horizontal scaling to 10k. Use message queues for buffering.", sourceRole: .productManager, sourceContext: .consultation)
        ]
    )
    TeamActivityFeedView(
        run: Run(id: 0, steps: [step], roleStatuses: [tlRole.id: .done]),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Implementation Plan"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Meeting Messages") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let step = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        toolCalls: [
            StepToolCall(name: "request_team_meeting", argumentsJSON: "{\"topic\": \"Database schema design\", \"participants\": [\"Tech Lead\", \"Product Manager\"]}", resultJSON: "{\"meetingID\": \"abc\"}", isError: false)
        ]
    )
    let meeting = TeamMeeting(
        topic: "Database schema design",
        initiatedBy: .softwareEngineer,
        participants: [.softwareEngineer, .techLead, .productManager],
        messages: [
            TeamMessage(role: .techLead, content: "I suggest we use a normalized schema with separate tables for notifications, channels, and subscriptions. This gives us flexibility for future channel types.", messageType: .proposal, thinking: "Considering the throughput requirements of 1k msg/sec, a normalized schema will be more efficient for writes."),
            TeamMessage(role: .productManager, content: "Agreed on normalized schema. We should also add a `priority` field — critical alerts need to bypass batching.", messageType: .agreement),
            TeamMessage(
                role: .softwareEngineer,
                content: "I'll implement the normalized schema. After reviewing the codebase, the existing User model already has a notification preferences field we can leverage.",
                messageType: .conclusion,
                toolSummaries: [
                    MeetingToolSummary(toolName: "read_file", arguments: "{\"path\": \"Sources/Models/User.swift\"}", result: "{\"content\": \"struct User { var notificationPrefs... }\"}", isError: false),
                    MeetingToolSummary(toolName: "list_files", arguments: "{\"path\": \"Sources/Models/\"}", result: "{\"entries\": [\"User.swift\", \"Notification.swift\"]}", isError: false)
                ]
            )
        ],
        status: .completed
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [step],
            meetings: [meeting],
            roleStatuses: [sweRole.id: .working]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Implementation Plan"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Change Requests") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let crRole = team.roles.first(where: { $0.name == "Code Reviewer" })!
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let crStep = StepExecution(
        id: "preview",
        role: .codeReviewer,
        title: "Code Reviewer",
        expectedArtifacts: ["Code Review"],
        status: .done,
        artifacts: [Artifact(name: "Code Review", icon: "checkmark.shield.fill", description: "Review completed")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"Sources/NotificationService.swift\"}", resultJSON: "{\"content\": \"class NotificationService { ... }\"}", isError: false),
            StepToolCall(name: "request_changes", argumentsJSON: "{\"target_role\": \"Software Engineer\", \"changes\": \"Missing error handling in WebSocket reconnection logic\"}", resultJSON: "{\"status\": \"approved\"}", isError: false)
        ]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [crStep],
            changeRequests: [
                ChangeRequest(
                    requestingRoleID: "codeReviewer",
                    targetRoleID: "softwareEngineer",
                    changes: "Missing error handling in WebSocket reconnection logic. The connection drops silently without retry.",
                    reasoning: "Production reliability requires graceful reconnection with exponential backoff.",
                    status: .approved
                ),
                ChangeRequest(
                    requestingRoleID: "sre",
                    targetRoleID: "softwareEngineer",
                    changes: "Add health check endpoint for the notification service",
                    reasoning: "Required for Kubernetes liveness probes and monitoring.",
                    status: .rejected
                )
            ],
            roleStatuses: [crRole.id: .done, sweRole.id: .revisionRequested]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Code Review"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Answered Supervisor Question") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let askCallID = UUID()
    let step = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        toolCalls: [
            StepToolCall(id: askCallID, name: "ask_supervisor", argumentsJSON: "{\"question\": \"Should we support both WebSocket and Server-Sent Events, or just WebSocket?\"}", resultJSON: "{\"answer\": \"WebSocket only for now. We can add SSE later if needed.\"}", isError: false),
            StepToolCall(name: "write_file", argumentsJSON: "{\"path\": \"Sources/WebSocketHandler.swift\"}", resultJSON: "{\"success\": true}", isError: false)
        ],
        supervisorAnswer: "WebSocket only for now. We can add SSE later if needed.",
        llmConversation: [
            LLMMessage(role: .assistant, content: "I need to decide on the transport protocol.", thinking: "The requirements mention real-time delivery. WebSocket provides full-duplex communication while SSE is simpler but one-directional. Let me ask the Supervisor for their preference."),
            LLMMessage(role: .user, content: "Supervisor answer: WebSocket only for now. We can add SSE later if needed.", sourceContext: .supervisorAnswer)
        ]
    )
    TeamActivityFeedView(
        run: Run(id: 0, steps: [step], roleStatuses: [sweRole.id: .working]),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Final Review Stage") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let tpmRole = team.roles.first(where: { $0.name == "TPM" })!
    let step = StepExecution(
        id: "preview",
        role: .tpm,
        title: "TPM",
        expectedArtifacts: ["Release Notes"],
        status: .done,
        artifacts: [Artifact(name: "Release Notes", icon: "doc.text.fill", description: "v1.0 release notes")]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [step],
            roleStatuses: team.roles.reduce(into: [:]) { $0[$1.id] = .done }
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: ["Release Notes", "Engineering Notes", "Build Diagnostics"],
        producedArtifacts: ["Release Notes", "Engineering Notes"],
        isFinalReviewStage: true
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Needs Acceptance") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let pmStep = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD v2")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"README.md\"}", resultJSON: "{\"content\": \"# Project\"}", isError: false)
        ]
    )
    let sweStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .needsApproval,
        artifacts: [Artifact(name: "Engineering Notes", icon: "hammer.fill", description: "Implementation complete")],
        toolCalls: [
            StepToolCall(name: "write_file", argumentsJSON: "{\"path\": \"Sources/NotificationService.swift\"}", resultJSON: "{\"success\": true}", isError: false),
            StepToolCall(name: "run_xcodebuild", argumentsJSON: "{\"action\": \"build\"}", resultJSON: "{\"success\": true, \"warnings\": 2}", isError: false)
        ]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [pmStep, sweStep],
            roleStatuses: [pmRole.id: .done, sweRole.id: .needsAcceptance]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Engineering Notes"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Filtered Single Role") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let pmStep = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"README.md\"}", resultJSON: "{\"content\": \"# Project\"}", isError: false)
        ]
    )
    let sweStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        toolCalls: [
            StepToolCall(name: "write_file", argumentsJSON: "{\"path\": \"Sources/App.swift\"}", resultJSON: "{\"success\": true}", isError: false)
        ]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [pmStep, sweStep],
            roleStatuses: [pmRole.id: .done, sweRole.id: .working]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        isFinalReviewStage: false,
        filterRoleID: sweRole.id
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed with Steps") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let step = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        messages: [
            StepMessage(role: .productManager, content: "I'll analyze the requirements and create a comprehensive PRD.")
        ],
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"README.md\"}", resultJSON: "{\"content\": \"# Project\"}", isError: false)
        ]
    )
    TeamActivityFeedView(
        run: Run(id: 0, steps: [step], roleStatuses: [pmRole.id: .done]),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Multi-Role Pipeline") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let tlRole = team.roles.first(where: { $0.name == "Tech Lead" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let pmStep = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        messages: [
            StepMessage(role: .productManager, content: "Analyzing requirements for the notification system.")
        ],
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"README.md\"}", resultJSON: "{\"content\": \"# Project\"}", isError: false)
        ]
    )
    let tlStep = StepExecution(
        id: "preview",
        role: .techLead,
        title: "Tech Lead",
        expectedArtifacts: ["Implementation Plan"],
        status: .done,
        messages: [
            StepMessage(role: .techLead, content: "Creating implementation plan based on the PRD.")
        ],
        artifacts: [Artifact(name: "Implementation Plan", icon: "list.bullet.rectangle", description: "Architecture plan")],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"Package.swift\"}", resultJSON: "{\"content\": \"// swift-tools-version: 5.9\"}", isError: false),
            StepToolCall(name: "list_files", argumentsJSON: "{\"path\": \"Sources/\"}", resultJSON: "{\"entries\": [\"App/\", \"Models/\"]}", isError: false)
        ],
        consultations: [
            TeammateConsultation(
                requestingRole: .techLead,
                consultedRole: .productManager,
                question: "Are there any latency requirements for the notification system?",
                response: "Notifications should be delivered within 500ms of the triggering event.",
                status: .completed
            )
        ]
    )
    let sweStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        messages: [
            StepMessage(role: .softwareEngineer, content: "Implementing WebSocket-based notification delivery.")
        ],
        toolCalls: [
            StepToolCall(name: "read_file", argumentsJSON: "{\"path\": \"Sources/App/App.swift\"}", resultJSON: "{\"content\": \"import Vapor\"}", isError: false),
            StepToolCall(name: "write_file", argumentsJSON: "{\"path\": \"Sources/App/NotificationService.swift\"}", resultJSON: "{\"success\": true}", isError: false),
            StepToolCall(name: "run_xcodebuild", argumentsJSON: "{\"action\": \"build\"}", resultJSON: "{\"error\": \"Build failed: 2 errors\"}", isError: true)
        ]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [pmStep, tlStep, sweStep],
            roleStatuses: [pmRole.id: .done, tlRole.id: .done, sweRole.id: .working]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task", "Product Requirements", "Implementation Plan"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Supervisor Question") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let autoAnsweredCallID = UUID()
    let autoAnsweredStep = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .running,
        toolCalls: [
            StepToolCall(
                id: autoAnsweredCallID,
                name: "ask_supervisor",
                argumentsJSON: "{\"question\": \"Should we target iOS 16+ or iOS 17+ as the minimum deployment version?\"}",
                resultJSON: "{\"answer\": \"Target iOS 17+. We want to use the latest SwiftUI features and our analytics show 90% of users are on iOS 17.\"}",
                isError: false
            )
        ],
        supervisorAnswer: "Target iOS 17+. We want to use the latest SwiftUI features and our analytics show 90% of users are on iOS 17.",
        llmConversation: [
            LLMMessage(role: .assistant, content: "I need to determine the minimum iOS version for the project.", thinking: "The deployment target affects which APIs we can use. SwiftUI has major improvements in iOS 17. Let me ask the Supervisor."),
            LLMMessage(role: .user, content: "Supervisor answer: Target iOS 17+. We want to use the latest SwiftUI features and our analytics show 90% of users are on iOS 17.", sourceRole: .supervisor, sourceContext: .supervisorAnswer)
        ]
    )
    let unansweredStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .needsSupervisorInput,
        messages: [
            StepMessage(role: .softwareEngineer, content: "I need clarification on the database schema.")
        ],
        toolCalls: [
            StepToolCall(
                name: "ask_supervisor",
                argumentsJSON: "{\"question\": \"Should I use PostgreSQL or SQLite for the local database? PostgreSQL offers better concurrency but SQLite is simpler to deploy.\"}",
                resultJSON: "",
                isError: false
            )
        ]
    )
    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [autoAnsweredStep, unansweredStep],
            roleStatuses: [pmRole.id: .working, sweRole.id: .working]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}

#Preview("Feed — Failed Step") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!
    let step = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .failed,
        messages: [
            StepMessage(role: .softwareEngineer, content: "Attempting to build the project."),
            StepMessage(role: .softwareEngineer, content: "Build failed after 3 retry attempts. The authentication module has circular dependencies.")
        ],
        toolCalls: [
            StepToolCall(name: "run_xcodebuild", argumentsJSON: "{\"action\": \"build\"}", resultJSON: "{\"error\": \"Build failed: circular dependency in AuthModule\"}", isError: true),
            StepToolCall(name: "run_xcodebuild", argumentsJSON: "{\"action\": \"build\"}", resultJSON: "{\"error\": \"Build failed: circular dependency in AuthModule\"}", isError: true)
        ]
    )
    TeamActivityFeedView(
        run: Run(id: 0, steps: [step], roleStatuses: [sweRole.id: .failed]),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}
// MARK: - Loaders & Activity Indicators Preview

#Preview("Loaders & Activity Indicators") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var engineState = OrchestratorEngineState()
    @Previewable @State var dictation = DictationService()
    let team = Team.default
    let pmRole = team.roles.first(where: { $0.name == "Product Manager" })!
    let tlRole = team.roles.first(where: { $0.name == "Tech Lead" })!
    let sweRole = team.roles.first(where: { $0.name == "Software Engineer" })!

    // 1. Streaming — processing progress (loader + "Processing 42%")
    let processingStepID = UUID().uuidString
    let processingMsgID = UUID()
    let processingStep = StepExecution(
        id: processingStepID,
        role: .techLead,
        title: "Tech Lead",
        expectedArtifacts: ["Implementation Plan"],
        status: .running,
        llmConversation: [
            LLMMessage(id: processingMsgID, createdAt: MonotonicClock.shared.now(), role: .assistant, content: "")
        ]
    )

    // 2. Streaming — empty (loader, waiting for first token)
    let emptyStreamStepID = UUID().uuidString
    let emptyStreamMsgID = UUID()
    let emptyStreamStep = StepExecution(
        id: emptyStreamStepID,
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .running,
        llmConversation: [
            LLMMessage(id: emptyStreamMsgID, createdAt: MonotonicClock.shared.now(), role: .assistant, content: "")
        ]
    )

    // 3. Streaming — thinking only (loader in thinking header)
    let thinkingStreamStepID = UUID().uuidString
    let thinkingStreamMsgID = UUID()
    let thinkingStreamStep = StepExecution(
        id: thinkingStreamStepID,
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        llmConversation: [
            LLMMessage(id: thinkingStreamMsgID, createdAt: MonotonicClock.shared.now(), role: .assistant, content: "")
        ]
    )

    // 4. Streaming — content arriving (loader in header row)
    let contentStreamStepID = UUID().uuidString
    let contentStreamMsgID = UUID()
    let contentStreamStep = StepExecution(
        id: contentStreamStepID,
        role: .techLead,
        title: "Tech Lead",
        expectedArtifacts: ["Implementation Plan"],
        status: .running,
        llmConversation: [
            LLMMessage(id: contentStreamMsgID, createdAt: MonotonicClock.shared.now(), role: .assistant, content: "")
        ]
    )

    // 5. In-progress tool call (loader instead of status icon)
    let toolInProgressStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .running,
        toolCalls: [
            StepToolCall(name: "run_xcodebuild", argumentsJSON: "{\"action\": \"build\"}", resultJSON: nil, isError: false)
        ]
    )

    // 6. Artifact expanded with nil content (loader + "Loading content...")
    let artifactLoadingStep = StepExecution(
        id: "preview",
        role: .productManager,
        title: "Product Manager",
        expectedArtifacts: ["Product Requirements"],
        status: .done,
        artifacts: [Artifact(name: "Product Requirements", icon: "doc.text.fill", description: "PRD v2")]
    )

    // 7. Supervisor auto-answering (loader + "Supervisor auto-answering...")
    let autoAnswerStep = StepExecution(
        id: "preview",
        role: .softwareEngineer,
        title: "Software Engineer",
        expectedArtifacts: ["Engineering Notes"],
        status: .needsSupervisorInput,
        toolCalls: [
            StepToolCall(
                name: "ask_supervisor",
                argumentsJSON: "{\"question\": \"Should we use PostgreSQL or SQLite?\"}",
                resultJSON: "",
                isError: false
            )
        ],
        needsSupervisorInput: true
    )

    // Configure streaming states
    let _ = {
        // 1. Processing progress
        streaming.beginStreaming(stepID: processingStepID, messageID: processingMsgID, role: .techLead)
        streaming.updateProcessingProgress(stepID: processingStepID, progress: 0.42)

        // 2. Empty streaming (no content, no thinking, no progress)
        streaming.beginStreaming(stepID: emptyStreamStepID, messageID: emptyStreamMsgID, role: .productManager)

        // 3. Thinking only (no content yet)
        streaming.beginStreaming(stepID: thinkingStreamStepID, messageID: thinkingStreamMsgID, role: .softwareEngineer)
        streaming.appendThinking(stepID: thinkingStreamStepID, content: "I need to analyze the project structure and understand the existing codebase before writing any code...")

        // 4. Content arriving
        streaming.beginStreaming(stepID: contentStreamStepID, messageID: contentStreamMsgID, role: .techLead)
        streaming.append(stepID: contentStreamStepID, messageID: contentStreamMsgID, role: .techLead, content: "Based on the requirements, I propose the following architecture for the notification system...")
    }()

    TeamActivityFeedView(
        run: Run(
            id: 0,
            steps: [
                processingStep, emptyStreamStep, thinkingStreamStep,
                contentStreamStep, toolInProgressStep, artifactLoadingStep,
                autoAnswerStep
            ],
            roleStatuses: [
                pmRole.id: .working,
                tlRole.id: .working,
                sweRole.id: .working
            ]
        ),
        roleDefinitions: team.roles,
        supervisorReviewArtifacts: [],
        producedArtifacts: ["Supervisor Task"],
        isFinalReviewStage: false
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(engineState)
    .environment(dictation)
    .frame(width: 400, height: 700)
    .background(Colors.surfacePrimary)
}
