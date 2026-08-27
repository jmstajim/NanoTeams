import AppKit
import SwiftUI

// Preview support for `QuickCapturePanel`, split out of the panel file.
//
// Not a style choice — a coverage-metric one. The project's tracked metric is line
// coverage of everything OUTSIDE `NanoTeams/Views/`, and `#Preview` MACRO bodies
// contribute zero executable lines to xccov (measured: a 761-line file of nothing
// but `#Preview` blocks is absent from the report entirely). Preview SUPPORT code is
// different — it is ordinary, never-executed, instrumented code, and
// `QuickCapturePanelPreview` alone was 175 executable lines at 0% inside a Services
// file. Living under `Views/` puts it where the rest of the app's preview scaffolding
// already lives (`TeamBoardView+Previews.swift` and siblings) and out of the metric.
//
// Enforced by `PreviewLocationPinTests`.

// MARK: - Previews

#if DEBUG

// periphery:ignore - used in #Preview macros below
@MainActor
private enum QuickCapturePanelPreview {
    /// Panel width matches the AppKit floor (`QuickCapturePanel.panelMinSize.width`)
    /// — single source of truth so DS-aligned previews can never drift from the
    /// real resize floor.
    static let panelWidth: CGFloat = QuickCapturePanel.panelMinSize.width
    /// Three semantic heights covering the panel's actual content states.
    /// Compact = empty / short task; medium = task + clip-or-file rail;
    /// tall = supervisor-answer mode with thinking disclosure expanded.
    static let heightCompact: CGFloat = 360
    static let heightMedium: CGFloat = 420
    static let heightTall: CGFloat = 540

    /// Task id used by the `.taskWorking` previews. Any stable value works — it
    /// only has to match between the seeded task and `store.activeTaskID`.
    static let workingTaskID = 42

    /// `activeTask` is what separates the two `.taskWorking` previews: the chat
    /// variant renders `chatWorkingBody` ONLY when `store.activeTaskID != nil`
    /// (`QuickCaptureFormView.body`), so seeding it is not cosmetic — without it
    /// the chat preview silently falls through to the non-chat body and shows a
    /// plausible-but-wrong screen.
    static func makeStore(activeTask: NTMSTask? = nil) -> NTMSOrchestrator {
        let store = PreviewStore.make()
        store.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "Preview"),
                settings: .defaults,
                teams: Team.defaultTeams
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: activeTask?.id,
            activeTask: activeTask
        )
        store.activeTask = activeTask
        store._setActiveTaskID(activeTask?.id)
        return store
    }

    /// A task with one `.running` Tech Lead step — the state the `.taskWorking`
    /// mode renders while a role is mid-turn.
    static func runningTask(isChatMode: Bool) -> NTMSTask {
        let team = Team.default
        let roleID = team.roles.first { $0.systemRoleID == Role.techLead.baseID }?.id
            ?? Role.techLead.baseID
        let step = StepExecution(
            id: roleID,
            role: .techLead,
            title: "Implementation Plan",
            expectedArtifacts: ["Implementation Plan"],
            status: .running
        )
        return NTMSTask(
            id: workingTaskID,
            title: "Preview Task",
            supervisorTask: "Plan the quick capture improvements.",
            status: .running,
            runs: [Run(id: 0, steps: [step], roleStatuses: [step.id: .working], teamID: team.id)],
            preferredTeamID: team.id,
            isChatMode: isChatMode
        )
    }

    /// `supervisorTask` seeds the NEW-TASK composer; `answerText` seeds the answer / chat-working
    /// one. They are separate fields for the reason recorded on `QuickCaptureFormState`, and a
    /// preview helper that could only seed one of them would make the other's samples silently
    /// render empty.
    static func makeFormState(
        supervisorTask: String = "",
        answerText: String = "",
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = []
    ) -> QuickCaptureFormState {
        let state = QuickCaptureFormState()
        state.supervisorTask = supervisorTask
        state.answerText = answerText
        state.attachments = attachments
        state.clippedTexts = [Clip].minting(clippedTexts)
        return state
    }

    static func makeAttachment(
        fileName: String,
        stagedRelativePath: String
    ) -> StagedAttachment {
        // Preview helper — create a temp file so StagedAttachment.init succeeds.
        let url = URL(fileURLWithPath: "/tmp/\(fileName)")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        // swiftlint:disable:next force_try
        return try! StagedAttachment(url: url, stagedRelativePath: stagedRelativePath)
    }

    /// One row in the Showcase preview. `id` keys `ForEach` and is stable for
    /// the lifetime of the sample list (held as `@Previewable @State`).
    struct Sample: Identifiable {
        let id = UUID()
        let label: String
        let mode: QuickCaptureMode
        let formState: QuickCaptureFormState
        let height: CGFloat
    }

    /// Every state surfaced in the per-state previews, in the same order so
    /// the Showcase reads like a visual table of contents.
    static func makeShowcaseSamples() -> [Sample] {
        let standardPayload = SupervisorAnswerPayload(
            stepID: "showcase-standard",
            taskID: Int(),
            role: .softwareEngineer,
            roleDefinition: nil,
            question: "Async/await or completion handlers for the network layer?",
            messageContent: "Two possible approaches surfaced in the audit. Picking one to standardize on.",
            thinking: "Codebase currently mixes both patterns.",
            isChatMode: false
        )
        let chatPayload = SupervisorAnswerPayload(
            stepID: "showcase-chat",
            taskID: Int(),
            role: .custom(id: "assistant"),
            roleDefinition: TeamRoleDefinition(
                id: "assistant", name: "Assistant", icon: "bubble.left.and.bubble.right",
                prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
                iconBackground: RoleColorDefaults.defaultHex
            ),
            question: "What should I focus on next?",
            messageContent: "Hi! I'm ready to help. What do you need?",
            thinking: "User just started a chat session.",
            isChatMode: true
        )
        return [
            Sample(
                label: "Empty",
                mode: .overlay,
                formState: makeFormState(),
                height: heightCompact
            ),
            Sample(
                label: "Task",
                mode: .overlay,
                formState: makeFormState(
                    supervisorTask: "Review the first-run experience, identify friction points, and propose a simpler setup path."
                ),
                height: heightCompact
            ),
            Sample(
                label: "Clips",
                mode: .overlay,
                formState: makeFormState(
                    supervisorTask: "Summarize the pasted research and extract the main risks.",
                    clippedTexts: [
                        "Interview notes mention a slow setup flow and unclear permissions prompts.",
                        "Support tickets mention users abandoning onboarding before the first successful action."
                    ]
                ),
                height: heightCompact
            ),
            Sample(
                label: "Files",
                mode: .overlay,
                formState: makeFormState(
                    attachments: [
                        makeAttachment(fileName: "LaunchPlan.md", stagedRelativePath: "drafts/launch-plan.md"),
                        makeAttachment(fileName: "Metrics.csv", stagedRelativePath: "drafts/metrics.csv")
                    ]
                ),
                height: heightCompact
            ),
            Sample(
                label: "Mixed",
                mode: .overlay,
                formState: makeFormState(
                    supervisorTask: "Combine the attached documents with the clipped evidence and propose a retention experiment plan.",
                    attachments: [
                        makeAttachment(fileName: "RetentionBrief.pdf", stagedRelativePath: "drafts/retention-brief.pdf")
                    ],
                    clippedTexts: [
                        "Customer interviews highlight that teams do not understand what happens after they create the first task."
                    ]
                ),
                height: heightMedium
            ),
            Sample(
                label: "Answer · Standard",
                mode: .supervisorAnswer(payload: standardPayload),
                formState: makeFormState(),
                height: heightMedium
            ),
            Sample(
                label: "Answer · Chat",
                mode: .supervisorAnswer(payload: chatPayload),
                formState: makeFormState(),
                height: heightTall
            ),
            Sample(
                label: "Working · Task",
                mode: .taskWorking(roleName: "Tech Lead", isChatMode: false),
                formState: makeFormState(),
                height: heightCompact
            ),
            Sample(
                label: "Working · Chat",
                mode: .taskWorking(roleName: "Tech Lead", isChatMode: true),
                formState: makeFormState(),
                height: heightMedium
            )
        ]
    }
}

// periphery:ignore - used in #Preview macros below
extension View {
    /// Injects every `@Environment(...)` `QuickCaptureFormView` and its subtree
    /// read — single source of truth so a new env-dependency can't silently
    /// break only some of the previews (the way `DictationService` did).
    fileprivate func quickCapturePreviewEnvironment(
        store: NTMSOrchestrator
    ) -> some View {
        self
            .environment(store)
            .environment(store.configuration)
            .environment(StreamingPreviewManager())
            .environment(DictationService())
    }

    /// Renders the panel preview as it appears floating over the desktop:
    /// panel-shaped frame, the same 4pt chrome curvature the panel's rounded
    /// SwiftUI background fill paints at runtime (see `setContent`), an elevated
    /// shadow, and a `surfaceBackground` backdrop (Level 0) so the panel's
    /// `surfacePrimary` fill (Level 1) reads with the same contrast as in production.
    fileprivate func quickCapturePreviewChrome(height: CGFloat) -> some View {
        self
            .frame(width: QuickCapturePanelPreview.panelWidth, height: height)
            .clipShape(RoundedRectangle.squircle(CornerRadius.large))
            .shadow(.elevated)
            .padding(Spacing.l)
            .background(Colors.surfaceBackground)
    }
}

#Preview("Quick Capture / Empty") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightCompact)
}

#Preview("Quick Capture / Task") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Review the first-run experience, identify friction points, and propose a simpler setup path."
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightCompact)
}

#Preview("Quick Capture / Clips") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Summarize the pasted research and extract the main risks.",
        clippedTexts: [
            "Interview notes mention a slow setup flow and unclear permissions prompts.",
            "Support tickets mention users abandoning onboarding before the first successful action."
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightCompact)
}

#Preview("Quick Capture / Files") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        attachments: [
            QuickCapturePanelPreview.makeAttachment(fileName: "LaunchPlan.md", stagedRelativePath: "drafts/launch-plan.md"),
            QuickCapturePanelPreview.makeAttachment(fileName: "Metrics.csv", stagedRelativePath: "drafts/metrics.csv")
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightCompact)
}

#Preview("Quick Capture / Mixed") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState(
        supervisorTask: "Combine the attached documents with the clipped evidence and propose a retention experiment plan.",
        attachments: [
            QuickCapturePanelPreview.makeAttachment(fileName: "RetentionBrief.pdf", stagedRelativePath: "drafts/retention-brief.pdf")
        ],
        clippedTexts: [
            "Customer interviews highlight that teams do not understand what happens after they create the first task."
        ]
    )

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightMedium)
}

#Preview("Supervisor Answer / Standard") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    let payload = SupervisorAnswerPayload(
        stepID: "preview",
        taskID: Int(),
        role: .softwareEngineer,
        roleDefinition: nil,
        question: "Should I use async/await or completion handlers for the network layer?",
        messageContent: "I've analyzed the existing codebase and found two possible approaches for the network layer. I need your guidance on which direction to take.",
        thinking: "The codebase currently mixes both patterns. I should ask which one to standardize on.",
        isChatMode: false
    )

    QuickCaptureFormView(
        mode: .supervisorAnswer(payload: payload),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightMedium)
}

#Preview("Supervisor Answer / Chat") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    let payload = SupervisorAnswerPayload(
        stepID: "preview",
        taskID: Int(),
        role: .custom(id: "assistant"),
        roleDefinition: TeamRoleDefinition(
            id: "assistant", name: "Assistant", icon: "bubble.left.and.bubble.right",
            prompt: "", toolIDs: [], usePlanningPhase: false, dependencies: RoleDependencies(),
            iconBackground: RoleColorDefaults.defaultHex
        ),
        question: "What should I focus on next?",
        messageContent: "Hi! I'm ready to help. What do you need?\n\nOptions:\n1. Describe a specific task\n2. Upload files to work with\n3. Ask something about the project",
        thinking: "The user started a chat session. I should ask what they need help with.",
        isChatMode: true
    )

    QuickCaptureFormView(
        mode: .supervisorAnswer(payload: payload),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightTall)
}

#Preview("Working / Task") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore(
        activeTask: QuickCapturePanelPreview.runningTask(isChatMode: false))
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    QuickCaptureFormView(
        mode: .taskWorking(roleName: "Tech Lead", isChatMode: false),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightCompact)
}

/// The chat variant renders a DIFFERENT branch (`chatWorkingBody`), reachable
/// only while `store.activeTaskID` is set — hence the seeded active task above.
#Preview("Working / Chat") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore(
        activeTask: QuickCapturePanelPreview.runningTask(isChatMode: true))
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    QuickCaptureFormView(
        mode: .taskWorking(roleName: "Tech Lead", isChatMode: true),
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .quickCapturePreviewEnvironment(store: store)
    .quickCapturePreviewChrome(height: QuickCapturePanelPreview.heightMedium)
}

/// Single-canvas gamut of every panel state — at-a-glance visual audit for
/// designers / reviewers. Adaptive 2-column grid so the canvas re-flows as
/// the preview window is resized.
#Preview("Quick Capture / Showcase") {
    // Seeded with a chat-mode active task so the two "Working" rows render their
    // real branches — `chatWorkingBody` is gated on `store.activeTaskID`. The
    // overlay / answer rows ignore it.
    @Previewable @State var store = QuickCapturePanelPreview.makeStore(
        activeTask: QuickCapturePanelPreview.runningTask(isChatMode: true))
    @Previewable @State var samples = QuickCapturePanelPreview.makeShowcaseSamples()

    let cellWidth = QuickCapturePanelPreview.panelWidth + Spacing.l * 2

    ScrollView {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: cellWidth), spacing: Spacing.xl)],
            spacing: Spacing.xl
        ) {
            ForEach(samples) { sample in
                VStack(spacing: Spacing.m) {
                    QuickCaptureFormView(
                        mode: sample.mode,
                        formState: sample.formState,
                        onSubmit: {},
                        onCancel: {}
                    )
                    .frame(
                        width: QuickCapturePanelPreview.panelWidth,
                        height: sample.height
                    )
                    .clipShape(RoundedRectangle.squircle(CornerRadius.large))
                    .shadow(.elevated)

                    Text(sample.label)
                        .font(Typography.caption)
                        .tracking(Typography.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Colors.textSecondary)
                }
            }
        }
        .padding(Spacing.xl)
    }
    .quickCapturePreviewEnvironment(store: store)
    .background(Colors.surfaceBackground)
    // Explicit canvas size — without it Xcode opens the showcase at the
    // ScrollView's zero intrinsic size and collapses every tile. Width fits
    // two `cellWidth` cells with `Spacing.xl` inter-column gap; height lets
    // the longest two rows (tall + medium) breathe.
    .frame(minWidth: cellWidth * 2 + Spacing.xl * 3, minHeight: 1200)
}

#endif
