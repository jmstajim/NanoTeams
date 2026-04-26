import Foundation

/// Service for generating work-folder context using LLM.
final class WorkFolderContextService {

    private let client: any LLMClient

    init(client: any LLMClient = LLMClientRouter()) {
        self.client = client
    }

    /// Generates work-folder context by analyzing the folder contents via an LLM.
    /// - Parameters:
    ///   - workFolderRoot: The work folder root URL.
    ///   - config: The LLM configuration.
    ///   - customPrompt: Optional override for `AppDefaults.workFolderContextPrompt`.
    /// - Returns: The trimmed generated context, or `nil` when the LLM produced
    ///   only whitespace. Callers must distinguish "nil from empty content" from
    ///   "nil from cancellation" via `Task.isCancelled` at the call site.
    /// - Throws: Transport / decoding errors from `client.streamChat` and
    ///   `CancellationError` if the surrounding `Task` is cancelled mid-stream.
    func generate(
        workFolderRoot: URL,
        config: LLMConfig,
        customPrompt: String? = nil
    ) async throws -> String? {
        let input = await Task.detached {
            WorkFolderContextBuilder.buildInput(workFolderRoot: workFolderRoot)
        }.value

        let trimmedCustom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let system = trimmedCustom.isEmpty
            ? AppDefaults.workFolderContextPrompt
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

        if !input.fileList.isEmpty {
            userLines.append("File snapshot:")
            for path in input.fileList {
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
    nonisolated deinit {}
}
