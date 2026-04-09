import AppKit
import SwiftUI

// MARK: - Quick Capture Panel

/// A floating NSPanel that hosts the Quick Capture SwiftUI form.
/// Stays on top of all windows (including other apps), supports text input,
/// and does not activate the main application window.
final class QuickCapturePanel: NSPanel {
    var onPanelHidden: (() -> Void)?
    private var hideGeneration = 0

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 250, height: 540)) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configure()
    }

    // MARK: - Configuration

    private func configure() {
        // Floating behavior
        isFloatingPanel = true
        level = .floating
        collectionBehavior.insert(.fullScreenAuxiliary)

        // Titlebar
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true

        // Persistence
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Appearance
        backgroundColor = NSColor(Colors.surfacePrimary)
        isOpaque = false
        hasShadow = true
        animationBehavior = .none

        minSize = NSSize(width: 250, height: 300)
        setFrameAutosaveName(UserDefaultsKeys.quickCapturePanelFrame)

        // Hide standard window buttons
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - SwiftUI Content

    /// Sets the SwiftUI content view for this panel.
    func setContent<Content: View>(_ view: Content) {
        let hostingView = NSHostingView(rootView: view.ignoresSafeArea())
        contentView = hostingView
    }

    // MARK: - Focus

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Dismiss on Esc

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onPanelHidden?()
    }

    // MARK: - Show with Animation

    /// Shows the panel with a fast fade-in. Uses saved position if available,
    /// otherwise centers on the screen under the mouse cursor.
    func showWithAnimation() {
        hideGeneration += 1
        let restored = setFrameUsingName(frameAutosaveName)
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            centerOnMouseScreen()
        }
        alphaValue = 0
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hides the panel with a fast fade-out. Does NOT release or clear content.
    func hideWithAnimation() {
        let gen = hideGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.orderOut(nil)
            self.alphaValue = 1
        }
    }

    // MARK: - Positioning

    private func centerOnMouseScreen() {
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screen = mouseScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = frame
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    nonisolated deinit {}
}

// MARK: - Previews

@MainActor
private enum QuickCapturePanelPreview {
    static func makeStore() -> NTMSOrchestrator {
        let store = NTMSOrchestrator(repository: NTMSRepository())
        store.snapshot = WorkFolderContext(
            projection: WorkFolderProjection(
                state: WorkFolderState(name: "Preview"),
                settings: .defaults,
                teams: Team.defaultTeams
            ),
            tasksIndex: TasksIndex(),
            toolDefinitions: [],
            activeTaskID: nil
        )
        return store
    }

    static func makeFormState(
        supervisorTask: String = "",
        attachments: [StagedAttachment] = [],
        clippedTexts: [String] = []
    ) -> QuickCaptureFormState {
        let state = QuickCaptureFormState()
        state.supervisorTask = supervisorTask
        state.attachments = attachments
        state.clippedTexts = clippedTexts
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
}

#Preview("Quick Capture Panel — Empty") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    QuickCaptureFormView(
        mode: .overlay,
        formState: formState,
        onSubmit: {},
        onCancel: {}
    )
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Task") {
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Clips") {
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Files") {
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 360)
}

#Preview("Quick Capture Panel — Mixed") {
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 420)
}

#Preview("Supervisor Answer") {
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 420)
}

#Preview("Supervisor Answer — Chat Mode") {
    @Previewable @State var store = QuickCapturePanelPreview.makeStore()
    @Previewable @State var formState = QuickCapturePanelPreview.makeFormState()

    let payload = SupervisorAnswerPayload(
        stepID: "preview",
        taskID: Int(),
        role: .custom(id: "assistant"),
        roleDefinition: TeamRoleDefinition(
            id: "assistant", name: "Assistant", icon: "bubble.left.and.bubble.right.fill",
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
    .environment(store)
    .environment(store.configuration)
    .frame(width: 250, height: 540)
}
