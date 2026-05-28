import AppKit
import SwiftUI

// MARK: - Template Preview Sheet

/// Sheet showing the wire system_prompt for the selected role and template
/// kind. Built by `PromptBuilder.buildWirePromptPreview` — only the
/// step-execution kind is byte-identity tested against the production wire
/// build; consultation and meeting share the same `TemplateResolver.resolveSystemPrompt`
/// pipeline as their runtime, so byte parity is structural for the body, plus
/// the meeting Harmony block is appended verbatim from the same
/// `NativeLMStudioClient.buildToolSchemaSection` the runtime uses.
///
/// Runtime-only slots (`requestingRoleName`, `meetingTopic`) get deterministic
/// preview values so the body matches wire shape. Generated Team placeholder
/// surfaces an explanatory error pane — its real team is built by an LLM call
/// at run time.
///
/// Body never reads `store.*` directly — env reads only inside `.task`
/// closures so orchestrator emissions during a running task don't fire body
/// re-evals here.
struct TemplatePreviewSheet: View {
    @Environment(StoreConfiguration.self) private var config
    @Environment(NTMSOrchestrator.self) private var store
    let team: Team
    let templateType: TemplateType
    let workFolder: WorkFolderProjection?
    @State private var selectedRoleID: String?
    @State private var rendered: WirePreviewRender = .notRendered
    /// Meeting kind only — toggle between non-coordinator (default) and
    /// coordinator views. The runtime emits a different `coordinatorHint`
    /// for each; without this toggle the meeting preview was locked to the
    /// non-coordinator branch and silently diverged from the actual wire
    /// payload for coordinator roles.
    @State private var previewAsCoordinator: Bool = false

    enum TemplateType {
        case system
        case consultation
        case meeting

        fileprivate var kind: WirePromptKind {
            switch self {
            case .system: return .stepExecution
            case .consultation: return .consultation
            case .meeting: return .meeting
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Template Preview")
                    .font(.headline)
                Spacer()
                if templateType == .meeting {
                    Toggle("As Coordinator", isOn: $previewAsCoordinator)
                        .toggleStyle(.checkbox)
                        .help("Preview the prompt the meeting coordinator role receives. Runtime emits a different coordinator hint than non-coordinator participants.")
                }
                Picker("Role", selection: $selectedRoleID) {
                    ForEach(nonSupervisorRoles) { role in
                        Text(role.name).tag(Optional(role.id))
                    }
                }
                .frame(width: 200)
            }
            .padding()

            Divider()

            if selectedRoleID == nil {
                Text("(select a role)")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch rendered {
                case .notRendered:
                    Color.clear
                case .success(_, let attributed):
                    ResolvedPromptView(attributed: attributed)
                case .failure(let error):
                    WirePreviewUnavailableView(error: error)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            if selectedRoleID == nil {
                selectedRoleID = nonSupervisorRoles.first?.id
            }
        }
        // `.task` closures run outside the body-tracking context — env reads
        // inside don't register observation, so orchestrator emissions during
        // a running task no longer fire body re-evals here. Refreshes on
        // role selection or coordinator-toggle change.
        .task(id: TaskFingerprint(selectedRoleID: selectedRoleID, isCoordinator: previewAsCoordinator)) {
            rendered = renderFromEnv()
        }
    }

    /// Combined identity for `.task(id:)` — re-runs the renderer when either
    /// the selected role or the coordinator toggle changes.
    private struct TaskFingerprint: Hashable {
        let selectedRoleID: String?
        let isCoordinator: Bool
    }

    private var nonSupervisorRoles: [TeamRoleDefinition] {
        team.nonSupervisorRoles
    }

    /// Reads env (`store`, `config`, `workFolder`) inside a `.task` closure so
    /// the reads happen outside SwiftUI's observation-tracking context.
    /// Without this isolation, every orchestrator emission during a running
    /// task would fire a body re-eval here.
    private func renderFromEnv() -> WirePreviewRender {
        // Nothing selected yet — the sheet displays a "(select a role)" hint
        // separately. Return `.notRendered` (no error) so the UI doesn't show
        // the error pane during the brief pre-selection moment.
        guard let id = selectedRoleID else { return .notRendered }

        // Role id is set but no longer in the team — stale selection (role
        // got deleted from another surface while the sheet is open). Surface
        // an explanatory error instead of a blank pane.
        guard let role = team.roles.first(where: { $0.id == id }) else {
            return .failure(.roleNotFoundInTeam(roleID: id, teamName: team.name))
        }
        let inputs = PromptBuilder.WirePreviewInputs(
            role: role,
            team: team,
            allTeams: store.snapshot?.projection.teams ?? [],
            workFolder: workFolder,
            workFolderState: PromptBuilder.WireWorkFolder.from(orchestratorURL: store.workFolderURL),
            selectedScheme: workFolder?.settings.selectedScheme,
            isVisionConfigured: store.visionLLMConfig != nil,
            globalContext: config.globalContext,
            isCoordinator: previewAsCoordinator
        )
        return renderWirePreview(kind: templateType.kind, inputs: inputs)
    }
}

// MARK: - Previews

#Preview("System Template") {
    TemplatePreviewSheet(
        team: Team.default,
        templateType: .system,
        workFolder: nil
    )
    .environment(StoreConfiguration())
    .environment(NTMSOrchestrator(repository: NTMSRepository()))
    .frame(width: 700, height: 1000)
}

#Preview("Consultation Template") {
    TemplatePreviewSheet(
        team: Team.default,
        templateType: .consultation,
        workFolder: nil
    )
    .environment(StoreConfiguration())
    .environment(NTMSOrchestrator(repository: NTMSRepository()))
    .frame(width: 700, height: 1000)
}

#Preview("Meeting Template") {
    TemplatePreviewSheet(
        team: Team.default,
        templateType: .meeting,
        workFolder: nil
    )
    .environment(StoreConfiguration())
    .environment(NTMSOrchestrator(repository: NTMSRepository()))
    .frame(width: 700, height: 1000)
}
