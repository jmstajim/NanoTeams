import SwiftUI

// MARK: - Final Review Item

/// Shared model for review items across FinalReview sub-views.
struct FinalReviewItem: Identifiable {
    let name: String
    let produced: Run.ProducedArtifactRecord?
    let isReady: Bool

    var id: String { name }
}

// MARK: - Supervisor Final Review View

/// Final review screen for Supervisor before accepting a completed task.
/// Shows required artifacts on the left and detailed artifact content on the right.
struct SupervisorFinalReviewView: View {
    let task: NTMSTask
    let run: Run?
    let roleDefinitions: [TeamRoleDefinition]
    let requiredArtifactNames: [String]
    let workFolderURL: URL?
    let onAcceptTask: () async -> Bool
    let onClose: () -> Void

    @State private var selectedArtifactName: String?
    @State private var contentCache: [String: String] = [:]
    @State private var isAcceptingTask = false

    private var reviewItems: [FinalReviewItem] {
        let produced = producedByName
        return normalizedRequiredArtifactNames.map { name in
            if name == SystemTemplates.supervisorTaskArtifactName {
                let hasSupervisorTask = task.hasInitialInput
                return FinalReviewItem(name: name, produced: nil, isReady: hasSupervisorTask)
            }

            if let record = produced[name] {
                return FinalReviewItem(name: name, produced: record, isReady: true)
            }

            return FinalReviewItem(name: name, produced: nil, isReady: false)
        }
    }

    private var additionalItems: [FinalReviewItem] {
        let requiredSet = Set(normalizedRequiredArtifactNames)
        return producedByName
            .filter { !requiredSet.contains($0.key) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { FinalReviewItem(name: $0.key, produced: $0.value, isReady: true) }
    }

    private var allItems: [FinalReviewItem] {
        reviewItems + additionalItems
    }

    private var selectedItem: FinalReviewItem? {
        guard let selectedArtifactName else { return allItems.first }
        return allItems.first { $0.name == selectedArtifactName } ?? allItems.first
    }

    private var progress: (ready: Int, total: Int, missing: Int) {
        let total = reviewItems.count
        let ready = reviewItems.filter(\.isReady).count
        return (ready: ready, total: total, missing: total - ready)
    }

    var body: some View {
        VStack(spacing: 0) {
            FinalReviewHeader(
                taskTitle: task.title,
                progress: progress,
                isAcceptingTask: $isAcceptingTask,
                onAcceptTask: onAcceptTask,
                onClose: onClose
            )

            Divider()

            HSplitView {
                FinalReviewArtifactsPane(
                    reviewItems: reviewItems,
                    additionalItems: additionalItems,
                    selectedArtifactName: $selectedArtifactName,
                    roleDefinitions: roleDefinitions
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

                FinalReviewDetailPane(
                    selectedItem: selectedItem,
                    selectedArtifactName: selectedArtifactName,
                    contentCache: contentCache,
                    supervisorTask: task.effectiveSupervisorBrief,
                    roleDefinitions: roleDefinitions
                )
                .frame(minWidth: 540)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            if selectedArtifactName == nil {
                selectedArtifactName = allItems.first?.name
            }
            if let item = selectedItem {
                loadContentIfNeeded(for: item)
            }
        }
        .onChange(of: allItems.count) { _, _ in
            if selectedArtifactName == nil || !allItems.contains(where: { $0.name == selectedArtifactName }) {
                selectedArtifactName = allItems.first?.name
            }
        }
        .onChange(of: selectedArtifactName) { _, _ in
            if let item = selectedItem {
                loadContentIfNeeded(for: item)
            }
        }
    }

    // MARK: - Data Helpers

    private var normalizedRequiredArtifactNames: [String] {
        requiredArtifactNames.normalizedUnique()
    }

    private var producedByName: [String: Run.ProducedArtifactRecord] {
        run?.producedArtifactsByName() ?? [:]
    }

    private func loadContentIfNeeded(for item: FinalReviewItem) {
        guard item.isReady else { return }
        guard item.name != SystemTemplates.supervisorTaskArtifactName else { return }
        guard contentCache[item.name] == nil else { return }
        guard let produced = item.produced else { return }
        guard let workFolderURL else { return }

        if let content = ArtifactService.readContent(artifact: produced.artifact, workFolderRoot: workFolderURL) {
            contentCache[item.name] = content
        } else if !produced.artifact.description.isEmpty {
            contentCache[item.name] = produced.artifact.description
        } else {
            contentCache[item.name] = "(Content not available)"
        }
    }
}

// MARK: - Previews

#Preview("Final Review — Missing Artifacts") {
    let team = Team.default
    let task = NTMSTask(id: 0, title: "Build notification system", supervisorTask: "Create a real-time notification system with WebSocket support.")
    SupervisorFinalReviewView(
        task: task,
        run: Run(id: 0, roleStatuses: team.roles.reduce(into: [:]) { $0[$1.id] = .done }),
        roleDefinitions: team.roles,
        requiredArtifactNames: ["Supervisor Task", "Release Notes"],
        workFolderURL: nil,
        onAcceptTask: { true },
        onClose: {}
    )
}

#Preview("Final Review — All Ready") {
    let team = Team.default
    let supervisorTask = Artifact(name: "Supervisor Task", icon: "star.fill", description: "User task")
    let releaseNotes = Artifact(name: "Release Notes", icon: "doc.text.fill", description: "v1.0 release notes")
    let tpmRole = team.roles.first(where: { $0.name == "TPM" })!
    let step = StepExecution(
        id: "preview",
        role: .tpm,
        title: "TPM",
        expectedArtifacts: ["Release Notes"],
        status: .done,
        artifacts: [releaseNotes]
    )
    let supervisorRole = team.roles.first(where: { $0.isSupervisor })!
    let supervisorStep = StepExecution(
        id: "preview",
        role: .supervisor,
        title: "Supervisor",
        expectedArtifacts: [],
        status: .done,
        artifacts: [supervisorTask]
    )
    SupervisorFinalReviewView(
        task: NTMSTask(id: 0, title: "Build notification system", supervisorTask: "WebSocket-based real-time alerts"),
        run: Run(id: 0,
            steps: [supervisorStep, step],
            roleStatuses: team.roles.reduce(into: [:]) { $0[$1.id] = .done }
        ),
        roleDefinitions: team.roles,
        requiredArtifactNames: ["Supervisor Task", "Release Notes"],
        workFolderURL: nil,
        onAcceptTask: { true },
        onClose: {}
    )
}

#Preview("Final Review — Single Artifact") {
    let team = Team.default
    let tpmRole = team.roles.first(where: { $0.name == "TPM" })!
    let step = StepExecution(
        id: "preview",
        role: .tpm,
        title: "TPM",
        expectedArtifacts: ["Release Notes"],
        status: .done,
        artifacts: [Artifact(name: "Release Notes", icon: "doc.text.fill", description: "v1.0 release notes with all changes documented")]
    )
    SupervisorFinalReviewView(
        task: NTMSTask(id: 0, title: "Full pipeline task", supervisorTask: "Complete product development"),
        run: Run(id: 0, steps: [step], roleStatuses: [tpmRole.id: .done]),
        roleDefinitions: team.roles,
        requiredArtifactNames: ["Release Notes"],
        workFolderURL: nil,
        onAcceptTask: { true },
        onClose: {}
    )
}
