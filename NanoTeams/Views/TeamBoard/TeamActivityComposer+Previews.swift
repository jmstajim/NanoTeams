import SwiftUI

// MARK: - Preview

#Preview("Composer — no pending question (chat)") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    TeamActivityComposer(
        roleDefinitions: Team.default.roles,
        isChatMode: true,
        taskID: 0,
        workingRoleIDs: Set(Team.default.roles.map(\.id)),
        failedRoleIDs: [],
        allowsRoleFallback: true,
        activeQuestions: [],
        maxHeight: .infinity
    )
    .environment(store)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Composer — queued messages") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let sweID = roles.first(where: { $0.name == "Software Engineer" })?.id
    let taskID = 42
    TeamActivityComposer(
        roleDefinitions: roles,
        isChatMode: false,
        taskID: taskID,
        workingRoleIDs: Set(roles.map(\.id)),
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [],
        maxHeight: .infinity
    )
    .environment(store)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
    .onAppear {
        let fs = QuickCaptureController.shared.formState
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Focus on the login flow first, skip the admin panel",
            attachments: [], clippedTexts: []
        ) { fs.appendQueuedMessage(m, for: taskID) }
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Use the existing auth service, don't build a new one",
            attachments: [], clippedTexts: [], targetRoleID: sweID
        ) { fs.appendQueuedMessage(m, for: taskID) }
        if let m = QuickCaptureFormState.QueuedChatMessage(
            text: "Remember to check the error handling edge cases",
            attachments: [], clippedTexts: []
        ) { fs.appendQueuedMessage(m, for: taskID) }
    }
}

