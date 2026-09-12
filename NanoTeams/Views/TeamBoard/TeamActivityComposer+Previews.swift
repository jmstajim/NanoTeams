import SwiftUI

// MARK: - Preview

#Preview("Composer — no pending question (chat)") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    TeamActivityComposer(
        roleDefinitions: Team.default.roles,
        taskID: 0,
        workingRoleIDs: Set(Team.default.roles.map(\.id)),
        failedRoleIDs: [],
        allowsRoleFallback: true,
        activeQuestions: [],
        maxHeight: .infinity
    )
    .environment(store)
    .environment(store.contextFill)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Composer — queued messages") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let sweID = roles.first(where: { $0.name == "Software Engineer" })?.id
    let taskID = 42
    TeamActivityComposer(
        roleDefinitions: roles,
        taskID: taskID,
        workingRoleIDs: Set(roles.map(\.id)),
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [],
        maxHeight: .infinity
    )
    .environment(store)
    .environment(store.contextFill)
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


/// Long enough to overflow both caps below — the state the question card's fade exists for,
/// and which no preview covered while the fade was a fraction of the frame.
private let previewLongQuestion = """
I've wired both widgets into the main app target as `WidgetBundle` scenes and the build is \
green, but before I go further I want to confirm the scope with you.

| File | Change |
|---|---|
| `MeditationApp.swift` | Added `MeditationWidgetBundle()` in `#if os(iOS)` |
| `StreaksWidget.swift` | Wrapped entire file in `#if os(iOS)` |
| `QuickStartWidget.swift` | Wrapped entire file in `#if os(iOS)` |

On iOS, when adding a widget to the Home Screen, the user sees two widgets:

1. **"Meditation Streaks"** (systemSmall + systemMedium) — shows the user's current streak in \
days, sourced from `StreakCounter().currentStreak`.
2. **"Quick Start"** (systemSmall) — shows the title and duration of the user's most recent \
completed session, or a "Tap to begin your first session" prompt when no history exists.

Both refresh every hour.

Deliberately left out: no changes to `ContentView`, `SessionLibrary` or `SessionHistoryStore`; \
no App Intents or deep-link tap-to-open wiring; and no widget extension target — the widgets \
live in the main app target, which keeps the project single-target.

Should I keep the single-target approach, or split the widgets into their own extension?
"""

/// Same question, two pane heights. The whole point of the fixed-length fade is that the band
/// looks identical in both: a fraction of the frame gave ~58pt here and ~24pt below, so the
/// tall pane dimmed three and a half lines of text the reader was still trying to read.
#Preview("Composer — long question, tall pane") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let asking = roles.first(where: { $0.name == "Software Engineer" }) ?? roles[0]
    TeamActivityComposer(
        roleDefinitions: roles,
        taskID: 7,
        workingRoleIDs: [],
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [
            TeamActivityActiveQuestion(
                stepID: asking.id,
                role: .softwareEngineer,
                question: previewLongQuestion,
                askCallID: UUID()
            )
        ],
        maxHeight: 600
    )
    .environment(store)
    .environment(store.contextFill)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Composer — long question, short pane") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let asking = roles.first(where: { $0.name == "Software Engineer" }) ?? roles[0]
    TeamActivityComposer(
        roleDefinitions: roles,
        taskID: 7,
        workingRoleIDs: [],
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [
            TeamActivityActiveQuestion(
                stepID: asking.id,
                role: .softwareEngineer,
                question: previewLongQuestion,
                askCallID: UUID()
            )
        ],
        maxHeight: 300
    )
    .environment(store)
    .environment(store.contextFill)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

/// The questionnaire in the composer: three questions with a recommendation each, in a pane
/// tall enough to show that a form claims more room than a paragraph would
/// (`MessageComposerLayout.inquiryPreviewMaxHeight` vs `questionPreviewMaxHeight`) — and still
/// leaves the message field, which is where the prose beside the form is typed.
#Preview("Composer — questionnaire") {
    @Previewable @State var store = PreviewStore.make()
    @Previewable @State var config = StoreConfiguration()
    @Previewable @State var dictation = DictationService()
    let roles = Team.default.roles
    let asking = roles.first(where: { $0.name == "Software Engineer" }) ?? roles[0]
    TeamActivityComposer(
        roleDefinitions: roles,
        taskID: 7,
        workingRoleIDs: [],
        failedRoleIDs: [],
        allowsRoleFallback: false,
        activeQuestions: [
            TeamActivityActiveQuestion(
                stepID: asking.id,
                role: .softwareEngineer,
                question: "A few decisions before I start on the exporter.",
                inquiry: previewInquiry,
                askCallID: UUID()
            )
        ],
        maxHeight: 700
    )
    .environment(store)
    .environment(store.contextFill)
    .environment(config)
    .environment(dictation)
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

/// Shared questionnaire fixture for the previews above.
private let previewInquiry = SupervisorInquiry(
    headline: "A few decisions before I start on the exporter.",
    questions: [
        SupervisorInquiryQuestion(
            id: "scheme",
            prompt: "Which scheme should I build against?",
            detail: "The integration tests only run under one of them.",
            kind: .singleChoice,
            options: [
                SupervisorInquiryOption(id: "debug", label: "NanoTeams (Debug)",
                                        detail: "what CI uses"),
                SupervisorInquiryOption(id: "release", label: "NanoTeams (Release)"),
            ]),
        SupervisorInquiryQuestion(
            id: "suites",
            prompt: "Which suites should I run before I report back?",
            kind: .multiChoice,
            options: [
                SupervisorInquiryOption(id: "unit", label: "Unit tests"),
                SupervisorInquiryOption(id: "ui", label: "UI tests", detail: "slow, and flaky on CI"),
                SupervisorInquiryOption(id: "perf", label: "Performance tests"),
            ]),
        SupervisorInquiryQuestion(
            id: "notes",
            prompt: "Anything else I should know before I start?",
            kind: .freeText),
    ])
