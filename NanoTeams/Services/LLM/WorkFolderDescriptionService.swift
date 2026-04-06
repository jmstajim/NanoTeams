import Foundation

/// Service for generating project descriptions using LLM.
final class WorkFolderDescriptionService {

    private let client: any LLMClient

    init(client: any LLMClient = LLMClientRouter()) {
        self.client = client
    }

    /// Generates a project description by analyzing the codebase and using an LLM.
    /// - Parameters:
    ///   - workFolderRoot: The project root URL.
    ///   - config: The LLM configuration.
    /// - Returns: A generated description, or nil if generation fails.
    /// - Throws: An error if the LLM request fails.
    func generate(
        workFolderRoot: URL,
        config: LLMConfig,
        customPrompt: String? = nil
    ) async throws -> String? {
        let input = await Task.detached {
            WorkFolderDescriptionBuilder.buildInput(workFolderRoot: workFolderRoot)
        }.value

        let trimmedCustom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let system = trimmedCustom.isEmpty
            ? AppDefaults.workFolderDescriptionPrompt
            : trimmedCustom

        var userLines: [String] = []
        userLines.append("Work folder name: \(input.rootName)")

        if !input.fileTypeCounts.isEmpty {
            let sorted = input.fileTypeCounts.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            let top = sorted.prefix(8).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            if !top.isEmpty {
                userLines.append("File types: \(top)")
            }
        }

        let snapshotFiles = input.fileList.prefix(80)
        if !snapshotFiles.isEmpty {
            userLines.append("File snapshot:")
            for path in snapshotFiles {
                userLines.append("- \(path)")
            }
        }

        if !input.excerpts.isEmpty {
            userLines.append("")
            userLines.append("Excerpts:")
            for excerpt in input.excerpts {
                userLines.append("File: \(excerpt.path)")
                userLines.append("```")
                userLines.append(excerpt.content)
                userLines.append("```")
            }
        }

        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: userLines.joined(separator: "\n")),
        ]

        var collected = ""
        for try await event in client.streamChat(
            config: config,
            messages: messages,
            tools: [],
            session: nil,
            logger: nil,
            stepID: nil
        ) {
            if !event.contentDelta.isEmpty {
                collected += event.contentDelta
            }
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
