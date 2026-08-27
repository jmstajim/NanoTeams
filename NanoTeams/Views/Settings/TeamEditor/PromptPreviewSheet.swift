import AppKit
import SwiftUI

// MARK: - Prompt Preview Sheet

/// Read-only preview of the step-execution wire system_prompt. Built via
/// `PromptBuilder.buildWirePromptPreview(kind: .stepExecution, …)`.
/// Includes the full Harmony `## Tool Calling` block + global-context footer.
///
/// Body never reads `store.*` directly — env reads happen only inside `.task`
/// closures so orchestrator emissions during a running task don't fire body
/// re-evals here.
struct PromptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(StoreConfiguration.self) private var config
    @Environment(NTMSOrchestrator.self) private var store
    let roleDefinition: TeamRoleDefinition
    let team: Team?
    let workFolder: WorkFolderProjection?

    @State private var rendered: WirePreviewRender = .notRendered

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MonoLabel(text: "Full Prompt Preview", marker: true)

                Spacer()

                Button {
                    if let plain = rendered.plain {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plain, forType: .string)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(Typography.caption)
                }
                .buttonStyle(.terminalSecondary)
                .controlSize(.small)
                .disabled(rendered.plain == nil)

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.terminalSecondary)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.m)

            TerminalDivider()

            switch rendered {
            case .notRendered:
                Color.clear
            case .success(_, let attributed):
                ResolvedPromptView(attributed: attributed)
            case .failure(let error):
                WirePreviewUnavailableView(error: error)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // `.task` closure runs outside body-tracking — env reads here do NOT
        // register observation. Refreshes only on sheet appear and on
        // role-identity flips (the only fields that can change while the sheet
        // is open via the Role Editor's currentRoleDefinition pass-through).
        // globalContext / snapshot / workFolderURL changes during the sheet's
        // lifetime are intentionally NOT live — user must reopen the preview
        // to pick up settings changes. Trade-off: zero observation overhead
        // during runs.
        .task(id: roleDefinition.id) {
            // Rescan agent instruction files first — the wire rescans at every
            // startRun, so a preview rendered from a stale snapshot would be
            // byte-identical to the PREVIOUS wire, not the upcoming one.
            await store.refreshAgentInstructions()
            // Same reason for role-attached skills: their bodies are read at
            // scan time, so a stale snapshot would preview the previous wire.
            await store.refreshAgentSkills()
            rendered = renderFromEnv()
        }
    }

    /// Reads env (`store`, `config`, `workFolder`) inside a `.task` closure so
    /// the reads happen outside SwiftUI's observation-tracking context — they
    /// don't register the body as an observer of `snapshot` / `workFolderURL`
    /// / `visionLLMConfig` / `globalContext`. Without this isolation, every
    /// orchestrator emission during a running task fires a body re-eval here.
    private func renderFromEnv() -> WirePreviewRender {
        let inputs = PromptBuilder.WirePreviewInputs(
            role: roleDefinition,
            team: team,
            allTeams: store.snapshot?.projection.teams ?? [],
            workFolder: workFolder,
            workFolderState: PromptBuilder.WireWorkFolder.from(orchestratorURL: store.workFolderURL),
            selectedScheme: workFolder?.settings.selectedScheme,
            isVisionConfigured: store.visionLLMConfig != nil,
            isComputerUseEnabled: config.isComputerUseEnabled,
            globalContext: config.globalContext,
            agentInstructions: store.agentInstructions,
            attachedSkills: store.roleSkills?.resolve(roleDefinition.attachedSkillIDs) ?? []
        )
        return renderWirePreview(kind: .stepExecution, inputs: inputs)
    }
}

// MARK: - Shared rendering helpers

/// Three-state cached render result. Sum-type encoding makes "error XOR
/// content" structurally exclusive — a `.success` carries both encodings
/// (plain + attributed), a `.failure` carries only the error, and
/// `.notRendered` is the pre-task `@State` sentinel that's distinct from
/// "successful render of empty content".
///
/// The previous 3-`var` struct + `.empty` sentinel allowed invalid combinations
/// (e.g. `error != nil` together with non-empty `plain` / `attributed`) and
/// couldn't distinguish "not rendered yet" from "rendered empty".
enum WirePreviewRender {
    case notRendered
    case success(plain: String, attributed: NSAttributedString)
    case failure(PromptBuilder.WirePreviewError)

    /// Convenience for the Copy button — returns the plain payload, or `nil`
    /// when there's nothing to copy.
    var plain: String? {
        if case .success(let plain, _) = self { return plain }
        return nil
    }

}

/// Drives both renderers (plain + attributed) and packages the result. Used
/// by both `PromptPreviewSheet` and `TemplatePreviewSheet`. Both renderers
/// use Swift 6 typed throws (`throws(WirePreviewError)`), so the catch is
/// exhaustive over the declared error type — no generic catch, no silent
/// misclassification of unrelated future errors.
func renderWirePreview(
    kind: WirePromptKind,
    inputs: PromptBuilder.WirePreviewInputs
) -> WirePreviewRender {
    do {
        let plain = try PromptBuilder.buildWirePromptPreview(kind: kind, inputs: inputs)
        let attributed = try PromptBuilder.buildWirePromptPreviewAttributed(kind: kind, inputs: inputs)
        return .success(plain: plain, attributed: attributed)
    } catch {
        return .failure(error)
    }
}

/// Shared explanatory pane for `WirePreviewError` (currently only Generated
/// Team can't be rendered offline). Used by both sheets.
struct WirePreviewUnavailableView: View {
    let error: PromptBuilder.WirePreviewError

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "wand.and.stars")
                .font(Typography.term3xl)
                .foregroundStyle(Colors.textSecondary)
            Text("Preview unavailable")
                .font(Typography.termLg)
                .foregroundStyle(Colors.textPrimary)
            Text(error.description)
                .font(Typography.termBase)
                .foregroundStyle(Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Prompt Preview") {
    @Previewable @State var previewStore = PreviewStore.make()
    let team = Team.default
    let role = team.nonSupervisorRoles.first!
    PromptPreviewSheet(
        roleDefinition: role,
        team: team,
        workFolder: nil
    )
    .environment(StoreConfiguration())
    .environment(previewStore)
    .frame(width: 700, height: 1100)
}
