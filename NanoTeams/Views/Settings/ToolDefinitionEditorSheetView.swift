import SwiftUI

// MARK: - Tool Definition Editor View

/// Tool definition editor with split view layout
struct ToolDefinitionEditorView: View {
    @Environment(NTMSOrchestrator.self) private var store

    @State private var tools: [ToolDefinitionRecord] = []
    @State private var selectedToolID: String?
    @State private var nameDraft: String = ""
    @State private var promptDraft: String = ""
    @State private var parametersDraft: String = ""
    @State private var parametersError: String?
    @State private var isShowingRestoreConfirmation = false

    var body: some View {
        SettingsMasterDetailView(
            hasSelection: selectedToolBinding != nil,
            master: {
                List(selection: $selectedToolID) {
                    ForEach(categorizedTools, id: \.category.id) { group in
                        Section(group.category.name) {
                            ForEach(group.tools) { tool in
                                toolRow(tool)
                                    .tag(tool.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            },
            detail: {
                if selectedToolBinding != nil {
                    ToolDetailEditor(
                        nameDraft: $nameDraft,
                        promptDraft: $promptDraft,
                        parametersDraft: $parametersDraft,
                        parametersError: parametersError,
                        isBuiltIn: selectedToolBinding?.wrappedValue.isBuiltIn ?? false,
                        onNameChange: { updateNameDraft($0) },
                        onPromptChange: { updatePromptDraft($0) },
                        onParametersChange: { updateParametersDraft($0) }
                    )
                }
            },
            emptyDetail: {
                SettingsEmptyState(
                    title: "No Tool Selected",
                    systemImage: "wrench.and.screwdriver",
                    description: "Select a tool from the list to view its configuration"
                )
            }
        )
        .onAppear {
            reloadFromStore()
        }
        .onChange(of: store.toolDefinitions) { _, _ in
            reloadFromStore()
        }
        .onChange(of: selectedToolID) { _, _ in
            syncDraftsFromSelection()
        }
        .onChange(of: tools) { _, _ in
            Task { await save() }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingRestoreConfirmation = true
                } label: {
                    Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .confirmationDialog(
            "Restore Default Tools?",
            isPresented: $isShowingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                tools = ToolDefinitionRecord.defaultDefinitions()
                selectedToolID = tools.first?.id
                syncDraftsFromSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all custom tools and reset built-in tools to their default configuration. This action cannot be undone.")
        }
    }

    private var categorizedTools: [ToolCategoryGroup] {
        let categories = ToolConstants.displayCategories
        let toolsByID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        var usedIDs = Set<String>()
        var groups: [ToolCategoryGroup] = []

        for category in categories {
            let matched = category.tools.compactMap { toolsByID[$0] }
            if !matched.isEmpty {
                groups.append(ToolCategoryGroup(category: category, tools: matched))
                matched.forEach { usedIDs.insert($0.id) }
            }
        }

        let uncategorized = tools.filter { !usedIDs.contains($0.id) }
        if !uncategorized.isEmpty {
            let otherCategory = ToolConstants.ToolCategoryDisplay(
                id: "other", name: "Other", icon: "ellipsis.circle.fill", tools: []
            )
            groups.append(ToolCategoryGroup(category: otherCategory, tools: uncategorized))
        }

        return groups
    }

    private func toolRow(_ tool: ToolDefinitionRecord) -> some View {
        Text(tool.name)
            .font(.system(.callout, design: .monospaced))
    }

    private var selectedToolBinding: Binding<ToolDefinitionRecord>? {
        guard let id = selectedToolID else { return nil }
        guard let idx = tools.firstIndex(where: { $0.id == id }) else { return nil }
        return $tools[idx]
    }

    private func reloadFromStore() {
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: store.toolDefinitions)
        tools = merged
        if selectedToolID == nil || !tools.contains(where: { $0.id == selectedToolID }) {
            selectedToolID = tools.first?.id
        }
        syncDraftsFromSelection()
    }

    private func syncDraftsFromSelection() {
        guard let tool = selectedToolBinding?.wrappedValue else {
            nameDraft = ""
            promptDraft = ""
            parametersDraft = ""
            parametersError = nil
            return
        }
        nameDraft = tool.name
        promptDraft = tool.prompt
        parametersDraft = encodeParameters(tool.parameters)
        parametersError = nil
    }

    private func updateNameDraft(_ newValue: String) {
        guard let binding = selectedToolBinding else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nameDraft = newValue
        guard !trimmed.isEmpty else { return }
        if tools.contains(where: { $0.id == trimmed && $0.id != binding.wrappedValue.id }) {
            return
        }
        let oldID = binding.wrappedValue.id
        updateTool(id: oldID) { tool in
            tool.id = trimmed
            tool.name = trimmed
        }
        selectedToolID = trimmed
    }

    private func updatePromptDraft(_ newValue: String) {
        promptDraft = newValue
        guard let id = selectedToolID else { return }
        updateTool(id: id) { tool in
            tool.prompt = newValue
        }
    }

    private func updateParametersDraft(_ newValue: String) {
        parametersDraft = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parametersError = nil
            guard let id = selectedToolID else { return }
            updateTool(id: id) { tool in
                tool.parameters = JSONSchema(type: "object", properties: [:])
            }
            return
        }

        do {
            let schema = try decodeParameters(trimmed)
            parametersError = nil
            guard let id = selectedToolID else { return }
            updateTool(id: id) { tool in
                tool.parameters = schema
            }
        } catch {
            parametersError = "Invalid JSON schema."
        }
    }

    private func updateTool(id: String, mutate: (inout ToolDefinitionRecord) -> Void) {
        guard let idx = tools.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tools[idx])
        tools[idx].updatedAt = MonotonicClock.shared.now()
    }

    private func save() async {
        if parametersError != nil {
            await store.setLastErrorMessageForUI("Fix the parameters JSON before saving.")
            return
        }
        let merged = ToolDefinitionRecord.mergeWithDefaults(existing: tools)
        await store.saveToolDefinitions(merged)
        tools = merged
    }

    private func encodeParameters(_ schema: JSONSchema) -> String {
        let encoder = JSONCoderFactory.makeDisplayEncoder()
        if let data = try? encoder.encode(schema),
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return "{\n  \"type\": \"object\",\n  \"properties\": {},\n  \"required\": []\n}"
    }

    private func decodeParameters(_ text: String) throws -> JSONSchema {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode(JSONSchema.self, from: data)
    }
}

struct ToolDetailEditor: View {
    @Binding var nameDraft: String
    @Binding var promptDraft: String
    @Binding var parametersDraft: String
    let parametersError: String?
    let isBuiltIn: Bool
    let onNameChange: (String) -> Void
    let onPromptChange: (String) -> Void
    let onParametersChange: (String) -> Void

    var body: some View {
        Form {
            Section("Identity") {
                if isBuiltIn {
                    LabeledContent("Name", value: nameDraft)
                } else {
                    TextField("Name", text: Binding(get: { nameDraft }, set: onNameChange))
                }
            }

            Section("Description") {
                if isBuiltIn {
                    Text(promptDraft)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextEditor(text: Binding(get: { promptDraft }, set: onPromptChange))
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80)
                }
            }

            Section("Parameters (JSON Schema)") {
                if isBuiltIn {
                    Text(parametersDraft)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextEditor(text: Binding(get: { parametersDraft }, set: onParametersChange))
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                }

                if let parametersError {
                    Label(parametersError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Colors.error)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Tool Category Group

private struct ToolCategoryGroup {
    let category: ToolConstants.ToolCategoryDisplay
    let tools: [ToolDefinitionRecord]
}

#Preview {
    ToolDefinitionEditorView()
        .environment(NTMSOrchestrator(repository: NTMSRepository()))
}
