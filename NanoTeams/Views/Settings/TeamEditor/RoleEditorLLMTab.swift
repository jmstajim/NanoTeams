import SwiftUI

// MARK: - LLM Tab

struct RoleEditorLLMTab: View {
    @Binding var editorState: RoleEditorState
    let llmProvider: LLMProvider
    var client: any LLMClient = LLMClientRouter()

    var body: some View {
        Form {
            Section {
                Toggle("Custom LLM Configuration", isOn: $editorState.llmOverrideEnabled)
                    .onChange(of: editorState.llmOverrideEnabled) { _, enabled in
                        if enabled {
                            if editorState.llmModelName.isEmpty {
                                editorState.llmModelName = llmProvider.defaultModel
                            }
                            if editorState.llmBaseURL.isEmpty {
                                editorState.llmBaseURL = llmProvider.defaultBaseURL
                            }
                            Task { await fetchOverrideModels() }
                        }
                    }

                if editorState.llmOverrideEnabled {
                    TextField("Base URL", text: $editorState.llmBaseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await fetchOverrideModels() }
                        }

                    Picker("Model", selection: $editorState.llmModelName) {
                        if !editorState.llmModelName.isEmpty && !editorState.availableModels.contains(editorState.llmModelName) {
                            Text(editorState.llmModelName).tag(editorState.llmModelName)
                        }
                        ForEach(editorState.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            } header: {
                Text("LLM Override")
            } footer: {
                Text("Override the global LLM settings for this specific role.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if editorState.llmOverrideEnabled && editorState.availableModels.isEmpty {
                Task { await fetchOverrideModels() }
            }
        }
    }

    private func fetchOverrideModels() async {
        let fetchConfig = LLMConfig(
            provider: .lmStudio,
            baseURLString: editorState.llmBaseURL.isEmpty ? nil : editorState.llmBaseURL
        )
        do {
            editorState.availableModels = try await client.fetchModels(config: fetchConfig, visionOnly: false)
        } catch {
            // Keep existing list if fetch fails
        }
    }
}

#Preview("LLM Override") {
    @Previewable @State var editorState: RoleEditorState = {
        var s = RoleEditorState()
        s.llmOverrideEnabled = true
        s.llmBaseURL = "http://127.0.0.1:1234"
        s.llmModelName = "qwen2.5-coder-32b"
        s.availableModels = ["qwen2.5-coder-32b", "deepseek-r1-14b", "llama-3.3-70b"]
        return s
    }()

    RoleEditorLLMTab(
        editorState: $editorState,
        llmProvider: .lmStudio
    )
    .frame(width: 500)
    .fixedSize(horizontal: false, vertical: true)
    .background(Colors.surfacePrimary)
}
