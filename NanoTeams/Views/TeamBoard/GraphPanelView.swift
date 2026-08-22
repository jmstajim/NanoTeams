import SwiftUI

// MARK: - Graph Panel View

/// Left panel containing team graph and status bar.
///
/// When the active task has any in-flight `delegate_to_team` calls (i.e. any
/// step on the current run carries `activeDelegationChildID != nil`), the
/// panel stacks the parent team graph on top with the delegated child team(s)
/// rendered below — each as its own `TeamGraphView` slice with a header band
/// and the inferred parent → child connector. Layers disappear as soon as
/// the delegation closes (V1 active-only graph, per docs/delegation-feature.md
/// scope decision). Recursion is bounded structurally by `maxDelegationDepth`.
struct GraphPanelView: View {
    let task: NTMSTask
    let workFolder: WorkFolderProjection?
    let roleStatuses: [String: RoleExecutionStatus]
    let roleDefinitions: [TeamRoleDefinition]
    let producedArtifacts: Set<String>
    @Binding var selectedRoleID: String?
    var onRestartRole: ((String) -> Void)? = nil
    var onFinishRole: ((String) -> Void)? = nil
    var onCorrectRole: ((String) -> Void)? = nil
    var onRetryGeneration: (() -> Void)? = nil
    var isChatMode: Bool = false
    var isPaused: Bool = false
    var isEngineRunning: Bool = true
    var meetingParticipants: Set<String> = []
    var isTaskInReview: Bool = false

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(OrchestratorEngineState.self) private var engineState

    /// First-paint hydration gate. Deferring the graph subtree to the next
    /// main-runloop tick splits the cost of TeamBoardView's initial layout:
    /// AppKit's constraint walk and SwiftUI's display-list assembly hit the
    /// chat panel first, then the graph's NSHostingView subtree expands one
    /// tick later. Trace evidence: a 490 ms first-paint hang was dominated
    /// by 8 nested `_updateConstraintsForSubtreeIfNeeded` querying every
    /// NSHostingView for `minSize()`, each triggering a SwiftUI
    /// `_sizeThatFits` over the full tree. Deferring the graph keeps it
    /// out of the first constraint walk; it hydrates on the next pass with
    /// the chat panel's cost already committed.
    ///
    /// `.task` runs after the first layout pass, NOT during it. `.onAppear`
    /// would fire synchronously inside the first layout and defeat the
    /// optimization.
    ///
    /// Task switch resets this `@State` (new view identity), so each task
    /// switch pays one deferred hydration — by design.
    @State private var hasHydrated = false

    private var activeTeam: Team? {
        if let generated = task.generatedTeam {
            return generated
        }
        if let preferredTeamID = task.preferredTeamID,
           let team = workFolder?.teams.first(where: { $0.id == preferredTeamID }) {
            return team
        }
        return workFolder?.activeTeam
    }

    /// True when task uses the "Generated Team" template and no team has been generated yet.
    private var isGenerationPending: Bool {
        guard task.generatedTeam == nil else { return false }
        guard let preferredID = task.preferredTeamID,
              let template = workFolder?.teams.first(where: { $0.id == preferredID })
        else { return false }
        return template.isGeneratedPlaceholder
    }

    /// The most recent create_team tool call across the latest run's steps, if any.
    private var generationToolCall: StepToolCall? {
        guard let run = task.runs.last else { return nil }
        for step in run.steps.reversed() {
            if let call = step.toolCalls.last(where: { $0.name == ToolNames.createTeam }) {
                return call
            }
        }
        return nil
    }

    /// Whether a generation attempt is actually in flight, derived from a LIVENESS
    /// signal rather than from the absence of an error marker.
    ///
    /// `runTeamGeneration` injects a synthetic `team_generation_*` step and drives it
    /// `.running` → `.done` / `.failed`, so the step's own status is the honest source.
    /// A missing step means generation has not started (or its record was destroyed).
    private var generationStep: StepExecution? {
        task.runs.last?.steps.last {
            $0.isTeamGenerationStep
        }
    }

    /// Failure is anything pending but NOT live — see `GeneratedTeamPanelState.failed`,
    /// which owns the rule and its regression history.
    ///
    /// The `isPending` guard is MIRRORED here, ahead of the call, purely so the
    /// arguments are never built for a task that cannot be a Generated Team.
    /// Swift evaluates call arguments eagerly, so `generationToolCall` — which
    /// walks every step's `toolCalls` and can only exit early when a `create_team`
    /// call EXISTS, i.e. never on an ordinary task — used to run before the
    /// callee's own leading `guard isPending else { return false }`. `toolCalls`
    /// has no ceiling (`LLMConstants.maxToolIterations == 0`), and `body` reaches
    /// this on every pass.
    ///
    /// Semantically identical by construction: `GeneratedTeamPanelState.failed`
    /// returns `false` for `isPending == false` unconditionally. The rule stays
    /// there, in one place; the view only stops paying for inputs the rule
    /// discards. Pinned by `GeneratedTeamPanelStateTests`' truth table plus the
    /// mirror test beside it.
    private var generationFailed: Bool {
        guard isGenerationPending else { return false }
        return GeneratedTeamPanelState.failed(
            isPending: isGenerationPending,
            toolCallIsError: generationToolCall?.isError == true,
            stepStatus: generationStep?.status,
            hasRun: task.runs.last != nil,
            isGenerationInFlight: store.isGeneratingTeam(taskID: task.id)
        )
    }

    private var isGeneratingTeam: Bool {
        isGenerationPending && !generationFailed
    }

    private var generationErrorMessage: String? {
        guard generationFailed else { return nil }
        return GeneratedTeamPanelState.failureMessage(
            recorded: generationToolCall?.errorMessage,
            stepStatus: generationStep?.status
        )
    }

    private var activeTeamMembers: Set<String> {
        Set(activeTeam?.roles.map(\.id) ?? Team.default.roles.map(\.id))
    }

    private var nodePositions: [TeamNodePosition] {
        activeTeam?.graphLayout.nodePositions ?? TeamGraphLayout.default.nodePositions
    }

    // MARK: - Delegation layers

    /// One delegated child team rendered below the parent. Resolved from
    /// `step.activeDelegationChildID` markers — completed/failed delegations
    /// drop out of the graph as soon as the marker is cleared. The audit
    /// trail still lives in `step.delegationChildIDs` (and the activity feed
    /// keeps the message history) but the graph stays focused on the live
    /// in-flight chain so it doesn't accumulate clutter on long-lived
    /// parents that delegate many times.
    // parentRoleID / childTask / childRun deliberately not stored (wave 32): the layer
    // renders from the resolved team + statuses; the walk-local values had zero readers.
    private struct DelegationLayer: Identifiable {
        let id: Int                        // child task ID
        let parentRoleName: String
        let childTeam: Team
        let childStatuses: [String: RoleExecutionStatus]
        let producedArtifacts: Set<String>
        let isPaused: Bool
    }

    /// Walks `activeDelegationChildID` markers transitively from the active
    /// task. Bounded by `maxDelegationDepth`. Skips children no longer in
    /// `loadedTasks` (graceful for stale state).
    private func resolveDelegationLayers() -> [DelegationLayer] {
        var layers: [DelegationLayer] = []
        var currentTask: NTMSTask? = task
        var safety = 0
        while let parent = currentTask, safety < DelegationConstants.maxDelegationDepth {
            guard let parentRun = parent.runs.last else { break }
            let delegatingStep = parentRun.steps.first { $0.activeDelegationChildID != nil }
            guard let step = delegatingStep,
                  let childID = step.activeDelegationChildID
            else { break }
            // `loadedTask(_:)` — an O(1) dictionary read — not a linear scan of a
            // freshly materialized `allLoadedTasksIncludingChildren`. That array was built
            // ABOVE the loop, so every render paid it even though the usual render has no
            // delegation and breaks two lines in; and this is the first statement of
            // `var body`, on a view whose `store.snapshot` read makes SwiftUI re-run it on
            // every task mutation. The property's own doc reserves it for "internal
            // lifecycle code … that genuinely needs the full set" (CLAUDE.md #79).
            guard let childTask = store.loadedTask(childID),
                  let childRun = childTask.runs.last
            else { break }

            let parentTeam = store.resolvedTeam(for: parent)
            let parentRoleName = parentTeam.roles.roleName(for: step.id)
            let childTeam = store.resolvedTeam(for: childTask)

            layers.append(DelegationLayer(
                id: childID,
                parentRoleName: parentRoleName,
                childTeam: childTeam,
                childStatuses: childRun.roleStatuses,
                producedArtifacts: Set(childRun.producedArtifactsByName().keys),
                isPaused: engineState.taskEngineStates[childID] == .paused
            ))

            currentTask = childTask
            safety += 1
        }
        return layers
    }

    var body: some View {
        let layers = resolveDelegationLayers()
        ZStack {
            if hasHydrated {
                if layers.isEmpty {
                    singleLayerGraph
                } else {
                    stackedLayersGraph(layers: layers)
                }
            } else {
                // Placeholder for the first layout pass — keeps HSplitView's
                // min-width subview present without expanding the graph
                // subtree into the NSHostingView constraint walk. Hydrates
                // on the next runloop tick via `.task` below.
                Color.clear
            }

            if isGeneratingTeam {
                VStack(spacing: Spacing.m) {
                    NTMSLoader(.large)
                    Text("Generating team…")
                        .font(Typography.captionSemibold)
                        .foregroundStyle(Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Colors.surfaceOverlayStrong)
            } else if generationFailed {
                generationFailureOverlay
            }
        }
        .background {
            // Terminal dot-grid canvas — faint; depth comes from node borders.
            Colors.surfacePrimary
            DotGridBackground()
        }
        .task {
            // Defer to next main-runloop tick. `.task` fires after the
            // first layout pass — different from `.onAppear` which fires
            // synchronously during it. See `hasHydrated` doc above.
            hasHydrated = true
        }
    }

    /// Default single-layer rendering — current behavior preserved when no
    /// active delegations are in flight.
    private var singleLayerGraph: some View {
        TeamGraphView(
            roleStatuses: roleStatuses,
            roleDefinitions: roleDefinitions,
            nodePositions: nodePositions,
            teamMembers: activeTeamMembers,
            selectedRoleID: $selectedRoleID,
            producedArtifacts: producedArtifacts,
            team: activeTeam,
            onRestartRole: onRestartRole,
            onFinishRole: onFinishRole,
            onCorrectRole: onCorrectRole,
            isChatMode: isChatMode,
            isPaused: isPaused,
            isEngineRunning: isEngineRunning,
            meetingParticipants: meetingParticipants,
            isTaskInReview: isTaskInReview
        )
        .clipped()
    }

    /// Stacked layout for delegation: parent on top, each child team below
    /// separated by a labeled boundary band. Active layer keeps the live
    /// engine-state pill; completed history layers render muted with a
    /// terminal-state pill so users see the full audit trail without losing
    /// focus on the in-flight team.
    ///
    /// Each layer auto-fits to its allocated height. Child layers use a
    /// disabled selection binding so a tap on a child role doesn't clobber
    /// the parent's selection (V1 keyboard nav stays on layer 0). Child
    /// nodes show bare role names — the team name already lives in the
    /// boundary band above, so `teamLabelSuffix: nil` keeps node labels
    /// clean (e.g. just `Code Refactorer` instead of
    /// `Code Refactorer.Calculator Code Refactor Team`).
    private func stackedLayersGraph(layers: [DelegationLayer]) -> some View {
        VStack(spacing: 0) {
            singleLayerGraph
                .frame(maxHeight: .infinity)

            ForEach(layers) { layer in
                delegationBandView(for: layer)
                TeamGraphView(
                    roleStatuses: layer.childStatuses,
                    roleDefinitions: layer.childTeam.roles,
                    nodePositions: layer.childTeam.graphLayout.nodePositions,
                    teamMembers: Set(layer.childTeam.roles.map(\.id)),
                    selectedRoleID: .constant(nil),  // child layers are read-only in V1
                    producedArtifacts: layer.producedArtifacts,
                    team: layer.childTeam,
                    isChatMode: layer.childTeam.isChatMode,
                    isPaused: layer.isPaused,
                    isEngineRunning: !layer.isPaused,
                    meetingParticipants: engineState.activeMeetingParticipants[layer.id] ?? [],
                    isTaskInReview: false,
                    teamLabelSuffix: nil
                )
                .frame(maxHeight: .infinity)
                .clipped()
            }
        }
    }

    /// Slim band that announces a layer transition. Matches the activity
    /// feed's `TeamBoundaryBandView` styling so the two surfaces stay
    /// visually consistent when the user looks across the panel split.
    private func delegationBandView(for layer: DelegationLayer) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.turn.down.right")
                .font(Typography.caption)
                .foregroundStyle(Colors.purple)
                .accessibilityHidden(true)
            Text("Delegated to \(layer.childTeam.name)")
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
            Text(verbatim: "by \(layer.parentRoleName)")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
            Spacer()
            statusPill(for: layer)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Colors.purpleTint)
    }

    @ViewBuilder
    private func statusPill(for layer: DelegationLayer) -> some View {
        let (label, foreground, background, glyph) = pillContent(for: layer)
        HStack(spacing: Spacing.xxs) {
            StatusGlyph(
                glyph: glyph,
                color: foreground,
                animatesWork: engineState.taskEngineStates[layer.id] == .running,
                font: Typography.term2xs
            )
            Text(label.uppercased())
                .font(Typography.caption2.weight(.medium))
                .tracking(Typography.labelTracking)
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 2)
        .background(background, in: RoundedRectangle.squircle(CornerRadius.small))
    }

    /// Resolves pill label + foreground + background for the in-flight
    /// delegation layer based on live engine state. Background uses the
    /// matching pre-computed `*Tint` token (CLAUDE.md "Design System Color
    /// Rules" — never `.opacity()` design-system tokens to derive new
    /// colors, always use a named tint). Completed/failed delegations are
    /// filtered out by `resolveDelegationLayers`, so this helper only sees
    /// in-flight layers.
    private func pillContent(for layer: DelegationLayer) -> (String, Color, Color, String) {
        // Single source of truth — `TeamEngineState.display` (StatusDisplayExtensions)
        // shared with the navbar status badge so a delegation child's pill color
        // matches the badge for the same engine state (previously diverged:
        // running=success vs info, input=warning vs gold, done=textSecondary vs success).
        let d = TeamEngineState.display(for: engineState.taskEngineStates[layer.id])
        return (d.label, d.color, d.tint, d.glyph)
    }

    private var generationFailureOverlay: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.term3xl)
                .foregroundStyle(Colors.error)
            Text(GeneratedTeamPanelState.failureTitle(stepStatus: generationStep?.status))
                .font(Typography.subheadlineSemibold)
                .foregroundStyle(Colors.textPrimary)
            if let message = generationErrorMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
            if let onRetryGeneration {
                Button("Retry", action: onRetryGeneration)
                    .buttonStyle(.terminalPrimary)
                    .padding(.top, Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Colors.surfaceOverlayStrong)
    }
}

// MARK: - Previews

#Preview("Graph Panel — Idle") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    let wf = WorkFolderProjection(
        state: WorkFolderState(name: "Preview", activeTeamID: team.id),
        settings: .defaults,
        teams: [team]
    )
    GraphPanelView(
        task: NTMSTask(id: 0, title: "Implement sorting", supervisorTask: "Create sorting algorithms"),
        workFolder: wf,
        roleStatuses: [:],
        roleDefinitions: team.roles,
        producedArtifacts: [],
        selectedRoleID: $selectedRoleID
    )
    .environment(store)
    .environment(store.engineState)
    .frame(width: 500, height: 400)
}

#Preview("Graph Panel — In Progress") {
    @Previewable @State var store = NTMSOrchestrator(repository: NTMSRepository())
    @Previewable @State var selectedRoleID: String? = nil
    let team = Team.default
    let wf = WorkFolderProjection(
        state: WorkFolderState(name: "Preview", activeTeamID: team.id),
        settings: .defaults,
        teams: [team]
    )
    GraphPanelView(
        task: NTMSTask(id: 0, title: "Build notification system", supervisorTask: "Real-time alerts"),
        workFolder: wf,
        roleStatuses: [
            team.roles[0].id: .done,
            team.roles[1].id: .done,
            team.roles[2].id: .working,
            team.roles[3].id: .working,
        ],
        roleDefinitions: team.roles,
        producedArtifacts: ["Supervisor Task", "Product Requirements"],
        selectedRoleID: $selectedRoleID,
        isEngineRunning: true
    )
    .environment(store)
    .environment(store.engineState)
    .frame(width: 500, height: 400)
}
