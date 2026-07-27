import SwiftUI

/// Settings for the Autovisor — the per-folder automated Supervisor.
/// Power toggle + goal, standing memory, activation (schedule + event triggers),
/// and an optional dedicated LLM model.
struct AutovisorSettingsView: View {
    @Environment(NTMSOrchestrator.self) var store
    @Environment(ModelCatalog.self) private var modelCatalog

    @State private var goalDraft = ""
    @State private var memoryDraft = ""
    @State private var activation = AutovisorActivation.default
    @State private var tuning = AutovisorTuning.default
    @State private var intervalMinutes = Int(AutovisorConstants.defaultScheduleIntervalSeconds / 60)
    /// Per-server bearer token for the manager's LLM override. `LLMTokenField`
    /// (inside `LLMEndpointEditor`) owns the load/save lifecycle keyed by the URL.
    @State private var managerApiToken = ""

    @State private var goalSaveTask: Task<Void, Never>?
    @State private var memorySaveTask: Task<Void, Never>?
    @State private var tuningSaveTask: Task<Void, Never>?
    /// Mirrored from `AutovisorGoalComposer`'s improve stream — suspends this card's
    /// debounced goal autosave while the rewrite streams.
    @State private var isImprovingGoal = false
    @State private var isAutoOffRowHovered = false
    /// Goal-preset disclosure in `goalCard` — collapsed by default.
    @State private var showPresets = false

    var body: some View {
        if store.hasRealWorkFolder {
            content
        } else {
            SettingsEmptyState(
                title: "No Work Folder",
                systemImage: "folder.badge.questionmark",
                description: "Open a work folder to configure its Autovisor.",
                actionTitle: nil,
                action: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isEnabled: Bool { store.workFolder?.settings.autovisorEnabled ?? false }
    private var isRunning: Bool {
        guard let id = store.autovisorTaskID else { return false }
        return store.taskEngineStates[id] == .running
    }

    private var content: some View {
        ScrollView {
            // All settings stay visible whether the manager is on or off — you can
            // set the goal/memory/schedule/model up front, then flip the toggle.
            VStack(spacing: Spacing.xl) {
                powerCard
                goalCard
                memoryCard
                activationCard
                limitsCard
                stuckCard
                modelCard
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Colors.surfacePrimary)
        .onAppear(perform: seed)
        .onChange(of: store.workFolder?.id) { _, _ in seed() }
        .onChange(of: store.workFolder?.settings.autovisorMemory) { _, new in
            if let new { memoryDraft = new }   // manager writes memory too — keep editor fresh
        }
        // Persist the tuning struct (both the Limits and Stuck cards mutate it).
        // Debounced like the goal/memory editors so a burst of stepper taps (or
        // press-and-hold auto-repeat) collapses to ONE write. The debounce also keeps
        // the re-sync below loop-safe: a single coalesced persist means no stale
        // in-flight write can echo an older value back over a newer edit.
        .onChange(of: tuning) { _, new in
            tuningSaveTask?.cancel()
            tuningSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await store.updateAutovisorTuning(new)
            }
        }
        // Adopt EXTERNAL changes to the persisted tuning (e.g. a future manager tool
        // editing its own caps). `new != tuning` makes the echo of our own debounced
        // write an inert no-op — and there is no external writer today, so this is
        // future-proofing, NOT (unlike the memory re-sync) a live-writer mirror.
        .onChange(of: store.workFolder?.settings.autovisorTuning) { _, new in
            if let new, new != tuning { tuning = new }
        }
        // Persist the activation struct. Lives on `content` (not a card) because TWO
        // cards edit it — the power card (its auto-off rows) and Activation.
        // Immediate (no debounce):
        // `mutateWorkFolder` skips no-op writes (settings are structurally diffed),
        // and each genuine auto-off change re-arming the countdown from "now" is
        // exactly the sleep-timer contract.
        .onChange(of: activation) { _, new in
            Task { await store.updateAutovisorActivation(new) }
        }
    }

    // MARK: - Power + Auto-off

    private var powerCard: some View {
        SettingsCard(
            header: "Autovisor",
            systemImage: "folder.badge.person.crop"
        ) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.standard) {
                    AutovisorPowerToggle(isOn: isEnabled, isRunning: isRunning) {
                        let next = !isEnabled
                        Task { await store.setAutovisorEnabled(next) }
                    }
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            StatusGlyph(
                                glyph: isEnabled ? (isRunning ? TerminalGlyph.working : TerminalGlyph.ready) : TerminalGlyph.skipped,
                                color: isEnabled ? Colors.success : Colors.textSecondary,
                                animatesWork: isRunning,
                                font: Typography.subheadlineSemibold
                            )
                            Text(isEnabled ? (isRunning ? "Working…" : "On") : "Off")
                                .font(Typography.subheadlineSemibold)
                                .foregroundStyle(isEnabled ? Colors.success : Colors.textSecondary)
                        }
                        Text(isEnabled ? "Tap to disable" : "Tap to enable")
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    }
                    Spacer()
                    if isEnabled, store.autovisorTaskID != nil {
                        SettingsPillButton(title: "Run now", icon: "play") {
                            if let id = store.autovisorTaskID {
                                // Same contract as the TeamBoard TopBar's Run now:
                                // `force: true` supersedes ANY state, including a
                                // live `.running` pass. Two controls, one label —
                                // they must not mean different things.
                                Task { await store.startAutovisorPass(taskID: id, force: true) }
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)

                rowCaption("An autonomous supervisor for this folder: it watches all tasks, creates/runs/stops them, answers their questions, and keeps the goal, memory, and shared context current.", indented: false)

                SettingsToggleRow(
                    title: "Turn off automatically",
                    icon: "moon.zzz",
                    isOn: $activation.autoDisableEnabled
                )
                rowCaption("Sleep timer: Autovisor switches itself off after a set time once turned on. Editing the duration restarts the countdown, and relaunching the app restarts it too.")

                if activation.autoDisableEnabled {
                    autoOffDurationRow
                    if isEnabled, let at = store.autovisorAutoDisableAt {
                        rowCaption("Autovisor will turn off around \(at.formatted(date: .omitted, time: .shortened)).")
                    } else {
                        rowCaption("The countdown starts when you turn Autovisor on.")
                    }
                }
            }
        }
    }

    // MARK: - Goal

    private var goalCard: some View {
        SettingsCard(
            header: "Goal",
            systemImage: "target",
            // Rides the `┤ GOAL ├` chip via the slot TerminalPane already owns.
            // `AnyView` is re-wrapped per keystroke, but the wrapped type never
            // changes, so the tip's `@State` identity survives.
            headerTrailing: AnyView(
                AutovisorGoalLintTip(goal: goalDraft, font: Typography.term2xs)
            )
        ) {
            VStack(spacing: 0) {
                // Quick Capture-style composer minus the send button. Attachments
                // + skill/clip cards persist to the folder goal store; the goal
                // text keeps this card's debounced autosave (`scheduleGoalSave`).
                AutovisorGoalComposer(
                    text: $goalDraft,
                    isImproving: $isImprovingGoal
                )

                rowCaption("What you want Autovisor to pursue in this folder — injected into its system prompt.", indented: false)

                SettingsDisclosureRow(
                    title: "Start from a preset",
                    icon: "sparkles",
                    isExpanded: $showPresets
                ) {
                    // Applying a preset mutates goalDraft → the same debounced
                    // autosave as typing (`.onChange` below). Disabled while the
                    // improve stream owns the draft.
                    AutovisorGoalPresetPicker(goalText: $goalDraft, isDisabled: isImprovingGoal)
                        .padding(.top, Spacing.xs)
                }
                .padding(.top, Spacing.s)
            }
            .onChange(of: goalDraft) { _, newValue in
                // Suppress debounced autosave while the improve stream mutates
                // goalDraft — a stall > 500ms would otherwise persist a half-improved
                // goal into the manager's live brief. The trailing save fires once
                // on stream end (onChange below).
                guard !isImprovingGoal else { return }
                scheduleGoalSave(newValue)
            }
            .onChange(of: isImprovingGoal) { _, improving in
                if improving {
                    goalSaveTask?.cancel()
                } else {
                    // Persist the final rewrite (or the restored original) in
                    // one save now that the stream is done.
                    scheduleGoalSave(goalDraft)
                }
            }
        }
    }

    /// Debounced write-through to `settings.autovisorGoal`. Extracted so the
    /// editor's onChange and the improve-stream end both funnel here.
    private func scheduleGoalSave(_ newValue: String) {
        goalSaveTask?.cancel()
        goalSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if store.workFolder?.settings.autovisorGoal != newValue {
                await store.updateAutovisorGoal(newValue)
            }
        }
    }

    /// "Turn off after [X h] [Y m]" — mirrors `SettingsStepperRow` (icon tile +
    /// title + hover shell) but hosts TWO compact stepper cells; the shared row
    /// hosts a single wide value cell, whose `stepperValueMinWidth` reserve would
    /// also open a large gap between the hour and minute cells.
    private var autoOffDurationRow: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(Colors.surfaceElevated)
                .frame(width: SettingsLayout.toggleIconSize, height: SettingsLayout.toggleIconSize)
                .overlay(
                    Image(systemName: "timer")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                )
            Text("Turn off after")
                .font(Typography.subheadline)
            Spacer()
            compactStepperCell(value: autoOffHoursBinding, range: 0...999, unit: "h")
            compactStepperCell(value: autoOffMinutesBinding, range: 0...59, unit: "m")
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isAutoOffRowHovered ? Colors.surfaceHover : .clear)
        )
        .trackHover($isAutoOffRowHovered)
        .animation(Animations.quick, value: isAutoOffRowHovered)
    }

    /// Value + stepper + unit packed tight (no `stepperValueMinWidth` reserve).
    private func compactStepperCell(value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .foregroundStyle(Colors.textSecondary)
            TerminalStepperButtons(value: value, range: range)
            Text(unit)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
    }

    /// Duration edited as hours + minutes; stored as `TimeInterval` seconds.
    private var autoOffHoursBinding: Binding<Int> {
        Binding(
            get: { Int(activation.autoDisableAfterSeconds) / 3600 },
            set: { setAutoOffDuration(hours: $0, minutes: (Int(activation.autoDisableAfterSeconds) % 3600) / 60) }
        )
    }

    private var autoOffMinutesBinding: Binding<Int> {
        Binding(
            get: { (Int(activation.autoDisableAfterSeconds) % 3600) / 60 },
            set: { setAutoOffDuration(hours: Int(activation.autoDisableAfterSeconds) / 3600, minutes: $0) }
        )
    }

    /// 0h 0m snaps to the 1-minute floor — mirrors the domain clamp
    /// (`clampAutoDisable`) so the shown value always equals what persists.
    private func setAutoOffDuration(hours: Int, minutes: Int) {
        let seconds = max(Int(AutovisorConstants.minAutoDisableSeconds), hours * 3600 + minutes * 60)
        activation.autoDisableAfterSeconds = TimeInterval(seconds)
    }

    // MARK: - Memory

    private var memoryCard: some View {
        SettingsCard(
            header: "Memory",
            systemImage: "brain"
        ) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    PromptMarker()
                    editor($memoryDraft, minHeight: 140) { newValue in
                        memorySaveTask?.cancel()
                        memorySaveTask = Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !Task.isCancelled else { return }
                            if store.workFolder?.settings.autovisorMemory != newValue {
                                await store.updateAutovisorMemory(newValue)
                            }
                        }
                    }
                }

                rowCaption("Autovisor's standing notes, carried across reviews. It writes here itself; you can edit too.", indented: false)
            }
        }
    }

    // MARK: - Activation

    private var activationCard: some View {
        SettingsCard(
            header: "Activation",
            systemImage: "clock.arrow.circlepath"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Review interval (min)",
                    icon: "clock.arrow.circlepath",
                    value: $intervalMinutes,
                    range: 1...1440,
                    zeroLabel: nil
                )
                rowCaption("How often Autovisor wakes on a timer to run a review pass.")

                SettingsToggleRow(title: "Wake when a task needs supervisor input", icon: "questionmark.bubble", isOn: $activation.onTaskNeedsSupervisor)
                rowCaption("Lets Autovisor answer folder tasks as their Supervisor. Off restores each task's normal supervisor handling — auto-answer or human wait.")

                SettingsToggleRow(title: "Wake when a task fails", icon: "xmark.octagon", isOn: $activation.onTaskFailed)
                rowCaption("Wake to triage or restart a failed task.")

                SettingsToggleRow(title: "Wake when a task completes", icon: "checkmark.circle", isOn: $activation.onTaskCompleted)
                rowCaption("Wake to review results, close, or decide what's next.")

                SettingsToggleRow(title: "Wake when a new task is created", icon: "plus.circle", isOn: $activation.onTaskCreated)
                rowCaption("Wake when a human adds a top-level task Autovisor hasn't seen yet.")

                SettingsToggleRow(title: "Wake when a task is stuck or looping", icon: "arrow.triangle.2.circlepath", isOn: $activation.onTaskStuck)
                rowCaption("Wake when a running role hangs or loops — thresholds set under Stuck detection.")
            }
        }
        .onChange(of: intervalMinutes) { _, minutes in
            guard let id = store.autovisorTaskID else { return }
            let rule = RecurrenceRule.interval(seconds: TimeInterval(minutes * 60))
            Task { await store.setTaskRecurrence(taskID: id, recurrence: TaskRecurrence(rule: rule, isEnabled: true)) }
        }
        // NOTE: `.onChange(of: activation)` lives on `content` — the power card's
        // auto-off rows edit the same struct.
    }

    // MARK: - Limits

    private var limitsCard: some View {
        SettingsCard(
            header: "Limits",
            systemImage: "gauge.with.dots.needle.bottom.50percent"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Max tasks running at once",
                    icon: "square.stack.3d.up",
                    value: $tuning.maxConcurrentManagedTasks,
                    range: 1...50,
                    zeroLabel: nil
                )
                rowCaption("Cap on how many Autovisor-created tasks run concurrently. Each is its own LLM-call stream.")

                SettingsStepperRow(
                    title: "Max new tasks per review",
                    icon: "plus.square.on.square",
                    value: $tuning.maxManagedTasksPerReview,
                    range: 1...20,
                    zeroLabel: nil
                )
                rowCaption("Cap on tasks Autovisor may create in a single review pass.")

                SettingsToggleRow(
                    title: "Let Autovisor generate new teams",
                    icon: "wand.and.stars",
                    isOn: allowTeamGenerationBinding
                )
                rowCaption("On: Autovisor may run team generation. Off: existing teams only.")
            }
        }
    }

    /// Persists immediately (no debounced draft — it's a plain flag) via the
    /// orchestrator setter, mirroring the Model card's `baseURLBinding` pattern.
    private var allowTeamGenerationBinding: Binding<Bool> {
        Binding(
            get: { store.workFolder?.settings.autovisorAllowTeamGeneration ?? true },
            set: { newValue in Task { await store.setAutovisorAllowTeamGeneration(newValue) } }
        )
    }

    // MARK: - Stuck detection

    private var stuckCard: some View {
        SettingsCard(
            header: "Stuck detection",
            systemImage: "exclamationmark.triangle"
        ) {
            VStack(spacing: 0) {
                SettingsStepperRow(
                    title: "Flag hung after (min)",
                    icon: "clock.badge.exclamationmark",
                    value: hangMinutesBinding,
                    range: 1...30,
                    zeroLabel: nil
                )
                rowCaption("Silence (no tokens) on a running role for this long flags it hung. Raise it for slow local models that legitimately think for minutes.")

                SettingsStepperRow(
                    title: "Loop signal window (min)",
                    icon: "arrow.triangle.2.circlepath",
                    value: loopRecencyMinutesBinding,
                    range: 1...10,
                    zeroLabel: nil
                )
                rowCaption("A loop signal counts only if it occurred within this recent window.")
            }
        }
    }

    /// Hang timeout edited in whole minutes; stored as seconds. Floored at 1 min
    /// (≥ the struct's 30s clamp).
    private var hangMinutesBinding: Binding<Int> {
        Binding(
            get: { max(1, Int((tuning.stuckHangSeconds / 60).rounded())) },
            set: { tuning.stuckHangSeconds = TimeInterval($0 * 60) }
        )
    }

    /// Loop-recency window edited in whole minutes; stored as seconds. Floored at
    /// 1 min (≥ the struct's 30s clamp).
    private var loopRecencyMinutesBinding: Binding<Int> {
        Binding(
            get: { max(1, Int((tuning.stuckLoopRecencySeconds / 60).rounded())) },
            set: { tuning.stuckLoopRecencySeconds = TimeInterval($0 * 60) }
        )
    }

    // MARK: - Model

    /// Same endpoint editor the Vision / Generate-Team cards use — URL + inherited
    /// token + model picker with Refresh. Empty fields fall back to the global LLM
    /// (placeholders surface the live defaults). Backed by the Manager role's
    /// `llmOverride` rather than a `StoreConfiguration` field.
    private var modelCard: some View {
        SettingsCard(
            header: "Model",
            systemImage: "cpu"
        ) {
            // The manager's model can live on a different provider than the
            // global chat LLM — pin its wire format here (`nil` = inherit).
            LLMProviderOverridePicker(selection: managerProviderBinding)

            LLMEndpointEditor(
                baseURL: baseURLBinding,
                modelName: modelNameBinding,
                apiToken: $managerApiToken,
                urlPrompt: inheritedURLPrompt,
                emptyModelLabel: emptyModelLabel,
                onTokenSaveError: { store.lastErrorMessage = $0.localizedDescription },
                onTokenLoadError: { store.lastErrorMessage = $0.localizedDescription },
                onURLCommit: {
                    Task { await modelCatalog.loadIfNeeded(url: effectiveFetchURL, provider: effectiveFetchProvider) }
                },
                availableModels: modelCatalog.models(for: effectiveFetchURL, provider: effectiveFetchProvider),
                isFetchingModels: modelCatalog.isFetching(effectiveFetchURL, provider: effectiveFetchProvider),
                status: EndpointStatus.resolve(
                    fetchError: modelCatalog.error(for: effectiveFetchURL, provider: effectiveFetchProvider),
                    isFetching: modelCatalog.isFetching(effectiveFetchURL, provider: effectiveFetchProvider)
                ),
                onRefreshModels: {
                    Task { await modelCatalog.refresh(url: effectiveFetchURL, provider: effectiveFetchProvider) }
                }
            )
        }
        .task {
            // First-appear populate. URL edits re-fetch via onURLCommit / Refresh.
            await modelCatalog.loadIfNeeded(url: effectiveFetchURL, provider: effectiveFetchProvider)
        }
    }

    // MARK: - LLM override helpers (mirror GenerateTeamLLMOverrideCard)

    private var managerOverride: LLMOverride? { store.autovisorRole?.llmOverride }

    private var globalURL: String {
        store.configuration.llmBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inheritedURLPrompt: String {
        globalURL.isEmpty ? effectiveFetchProvider.defaultBaseURL : globalURL
    }

    private var emptyModelLabel: String {
        let g = store.configuration.llmModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? "Use global model" : "Use global: \(g)"
    }

    /// URL the picker reads from — override URL when typed, else the global LLM URL.
    private var effectiveFetchURL: String {
        let custom = (managerOverride?.baseURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? globalURL : custom
    }

    /// Provider for the model-list fetch — the override's provider when set
    /// (matches `buildEffectiveConfig` resolution), else the global one.
    private var effectiveFetchProvider: LLMProvider {
        managerOverride?.provider ?? store.configuration.llmProvider
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { managerOverride?.baseURLString ?? "" },
            set: { newURL in
                let model = managerOverride?.modelName
                let provider = managerOverride?.provider
                Task { await store.setAutovisorLLMOverride(baseURL: newURL, model: model, provider: provider) }
            }
        )
    }

    private var managerProviderBinding: Binding<LLMProvider?> {
        Binding(
            get: { managerOverride?.provider },
            set: { newProvider in
                let url = managerOverride?.baseURLString
                let model = managerOverride?.modelName
                Task { await store.setAutovisorLLMOverride(baseURL: url, model: model, provider: newProvider) }
            }
        )
    }

    private var modelNameBinding: Binding<String> {
        Binding(
            get: { managerOverride?.modelName ?? "" },
            set: { newModel in
                let url = managerOverride?.baseURLString
                let provider = managerOverride?.provider
                Task { await store.setAutovisorLLMOverride(baseURL: url, model: newModel, provider: provider) }
            }
        )
    }

    // MARK: - Helpers

    /// Per-row caption beneath a settings row — the Tool Behavior pattern
    /// (`ToolBehaviorSettingsView`): tertiary `caption` text. `indented: true` aligns it
    /// under a row's title (past the leading icon) and hugs the row tightly. `indented: false`
    /// (full-width controls like the editors) gives a small `Spacing.s` leading inset that
    /// lines up with the editor's text, plus a small top gap so the caption doesn't sit
    /// flush against the editor above it.
    @ViewBuilder
    private func rowCaption(_ text: String, indented: Bool = true) -> some View {
        Text(LocalizedStringKey(text))
            .font(Typography.caption)
            .foregroundStyle(Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indented ? SettingsLayout.toggleIconSize + Spacing.m : Spacing.s)
            .padding(.top, indented ? 0 : Spacing.xs)
            .padding(.bottom, Spacing.s)
    }

    // Multi-line editor matching the Work Folder Context field (CLAUDE.md #32):
    // `TextEditor` gives native newline-on-Enter, caret tracking, and internal
    // scroll. The `TextField(axis: .vertical)` it replaces treated Enter as
    // "end editing", which made multi-line goal/memory editing feel broken.
    // Visual style is shared with the Watchtower Autovisor card via
    // `borderedTextEditorStyle(minHeight:)`.
    @ViewBuilder
    private func editor(_ text: Binding<String>, minHeight: CGFloat, onChange: @escaping (String) -> Void) -> some View {
        TextEditor(text: text)
            .font(Typography.termBase)
            .borderedTextEditorStyle(minHeight: minHeight)
            .onChange(of: text.wrappedValue) { _, newValue in onChange(newValue) }
    }

    private func seed() {
        guard let settings = store.workFolder?.settings else { return }
        // Show the default goal/memory when nothing is set yet, so both fields are
        // populated even while the manager is OFF (the in-engine `ensureAutovisorTask`
        // seed only runs once the manager is enabled). The editor's onChange persists
        // the shown value; when the user later enables, the goal is already in place.
        goalDraft = settings.autovisorGoal.isEmpty
            ? AutovisorConstants.defaultGoal : settings.autovisorGoal
        memoryDraft = settings.autovisorMemory.isEmpty
            ? AutovisorConstants.defaultMemory : settings.autovisorMemory
        activation = settings.autovisorActivation
        tuning = settings.autovisorTuning
        // Seed the interval stepper from the manager task's actual recurrence so the
        // displayed value reflects reality (e.g. one the manager set via schedule_task)
        // instead of a hardcoded default.
        if let id = store.autovisorTaskID,
           case .interval(let seconds)? = store.loadedTask(id)?.recurrence?.rule {
            intervalMinutes = max(1, Int(seconds / 60))
        }
        // The Model card binds directly to the Manager role's `llmOverride` — no draft to seed.
    }
}
