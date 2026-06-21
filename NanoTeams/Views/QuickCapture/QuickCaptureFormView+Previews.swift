import SwiftUI


#if DEBUG
private enum QuickCaptureFormPreviewData {
    static let team = Team.default
    static let taskID = 42

    static var workFolder: WorkFolderProjection {
        WorkFolderProjection(
            state: WorkFolderState(name: "Preview", activeTeamID: team.id),
            settings: .defaults,
            teams: [team]
        )
    }

    static var roleDefinition: TeamRoleDefinition? {
        team.roles.first { $0.systemRoleID == Role.techLead.baseID }
    }

    static var answerPayload: SupervisorAnswerPayload {
        SupervisorAnswerPayload(
            stepID: roleDefinition?.id ?? Role.techLead.baseID,
            taskID: taskID,
            role: .techLead,
            roleDefinition: roleDefinition,
            question: "Should we keep the first version focused on the menu bar capture flow, or include the full settings migration in the same task?",
            messageContent: "I found two viable implementation paths and need a product call before continuing.",
            thinking: "The smaller scope ships sooner, but settings migration reduces future churn.",
            isChatMode: false
        )
    }

    static func runningTask(isChatMode: Bool) -> NTMSTask {
        let step = StepExecution(
            id: roleDefinition?.id ?? Role.techLead.baseID,
            role: .techLead,
            title: "Implementation Plan",
            expectedArtifacts: ["Implementation Plan"],
            status: .running
        )
        let run = Run(
            id: 0,
            steps: [step],
            roleStatuses: [step.id: .working],
            teamID: team.id
        )
        return NTMSTask(
            id: taskID,
            title: "Preview Task",
            supervisorTask: "Plan the quick capture improvements.",
            status: .running,
            runs: [run],
            preferredTeamID: team.id,
            isChatMode: isChatMode
        )
    }

    @MainActor
    static func configure(_ store: NTMSOrchestrator, activeTask: NTMSTask? = nil) {
        store.snapshot = WorkFolderContext(
            projection: workFolder,
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: activeTask?.id,
            activeTask: activeTask
        )
        store.activeTask = activeTask
        store._setActiveTaskID(activeTask?.id)
    }
}

#Preview("Quick Capture - New Task") {
    @Previewable @State var formState = QuickCaptureFormState()
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var dictation = DictationService()

    let _ = QuickCaptureFormPreviewData.configure(store)
    let _ = formState.supervisorTask = "Draft a launch checklist for the new macOS menu bar workflow."

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(dictation)
    .frame(width: 300, height: 260)
}

#Preview("Quick Capture - Supervisor Answer") {
    @Previewable @State var formState = QuickCaptureFormState()
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var dictation = DictationService()

    let _ = QuickCaptureFormPreviewData.configure(store)
    let _ = formState.supervisorTask = "Keep v1 focused on quick capture. Move settings migration into a follow-up task."

    QuickCaptureFormView(
        mode: .supervisorAnswer(payload: QuickCaptureFormPreviewData.answerPayload),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(dictation)
    .frame(width: 300, height: 360)
}

#Preview("Quick Capture - Working") {
    @Previewable @State var formState = QuickCaptureFormState()
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var dictation = DictationService()

    let _ = QuickCaptureFormPreviewData.configure(
        store,
        activeTask: QuickCaptureFormPreviewData.runningTask(isChatMode: false)
    )

    QuickCaptureFormView(
        mode: .taskWorking(roleName: "Tech Lead", isChatMode: false),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(dictation)
    .frame(width: 300, height: 260)
}

#Preview("Quick Capture - Chat Working") {
    @Previewable @State var formState = QuickCaptureFormState()
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var streaming = StreamingPreviewManager()
    @Previewable @State var dictation = DictationService()

    let _ = QuickCaptureFormPreviewData.configure(
        store,
        activeTask: QuickCaptureFormPreviewData.runningTask(isChatMode: true)
    )
    let _ = {
        formState.supervisorTask = "Queue this note for the next supervisor check-in."
        if let queued = QuickCaptureFormState.QueuedChatMessage(
            text: "Ask whether the launch checklist should include QA sign-off.",
            attachments: [],
            clippedTexts: []
        ) {
            formState.appendQueuedMessage(queued, for: QuickCaptureFormPreviewData.taskID)
        }
    }()

    QuickCaptureFormView(
        mode: .taskWorking(roleName: "Tech Lead", isChatMode: true),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(config)
    .environment(streaming)
    .environment(dictation)
    .frame(width: 300, height: 360)
}
#endif

