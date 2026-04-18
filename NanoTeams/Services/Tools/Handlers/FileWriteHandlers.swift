import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - write_file

struct WriteFileTool: ToolHandler {
    static let name = TN.writeFile
    static let schema = ToolSchema(
        name: TN.writeFile,
        description: "Write content to a file. Creates parent directories if needed. Replaces the ENTIRE file — always include the complete file content (imports, class declaration, ALL methods). Never write a partial file. Prefer edit_file for targeted changes.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "content": JS.string("Content to write"),
            ],
            required: ["path", "content"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let content = try requiredString(args, "content")
            let createDirs = optionalBool(args, "create_dirs", default: true)

            let fileURL = try resolver.resolveFileURL(relativePath: path)
            let parentDir = fileURL.deletingLastPathComponent()

            var isDir: ObjCBool = false
            let parentExists = fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)

            if !parentExists {
                if createDirs {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                } else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .notADirectory, message: "Parent directory does not exist: \(parentDir.path)"
                    )
                }
            } else if !isDir.boolValue {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notADirectory, message: "Parent path is not a directory"
                )
            }

            let fileExisted = fileManager.fileExists(atPath: fileURL.path)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            struct WriteFileData: Codable {
                var path: String
                var size: Int
                var created: Bool
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: WriteFileData(
                    path: path,
                    size: content.utf8.count,
                    created: !fileExisted
                )
            )
        }
    }
}

// MARK: - edit_file

struct EditFileTool: ToolHandler {
    static let name = TN.editFile
    static let schema = ToolSchema(
        name: TN.editFile,
        description: "Edit a file by replacing exact text matches. The old_text must match exactly including whitespace and indentation. If it fails with ANCHOR_NOT_FOUND, re-read the file with read_lines before retrying — the file content changed since your last read. For complex multi-step changes, prefer write_file instead.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "old_text": JS.string("Exact text to find in the file (must match exactly including whitespace and indentation)"),
                "new_text": JS.string("Text to replace old_text with"),
                "replace_all": JS.boolean("Replace all occurrences (default: first only)"),
            ],
            required: ["path", "old_text", "new_text"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let oldText = try requiredString(args, "old_text")
            let newText = try requiredString(args, "new_text")
            let replaceAll = optionalBool(args, "replace_all", default: false)

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .fileNotFound, message: "File not found: \(path)"
                )
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)

            let effectiveOldText: String
            if content.contains(oldText) {
                effectiveOldText = oldText
            } else {
                let stripped = Self.stripLineNumberPrefixes(oldText)
                let unescaped = Self.unescapeJSONSequences(oldText)

                if !stripped.isEmpty && stripped != oldText && content.contains(stripped) {
                    effectiveOldText = stripped
                } else if unescaped != oldText && content.contains(unescaped) {
                    effectiveOldText = unescaped
                } else {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .anchorNotFound,
                        message: "old_text not found in file. Make sure it matches exactly including whitespace and indentation. Do not include line numbers from read_lines output."
                    )
                }
            }

            let newContent: String
            let count: Int
            if replaceAll {
                count = content.components(separatedBy: effectiveOldText).count - 1
                newContent = content.replacingOccurrences(of: effectiveOldText, with: newText)
            } else {
                count = 1
                if let range = content.range(of: effectiveOldText) {
                    newContent = content.replacingCharacters(in: range, with: newText)
                } else {
                    newContent = content
                }
            }

            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)

            struct EditFileData: Codable {
                var path: String
                var replacements_made: Int
            }

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: EditFileData(path: path, replacements_made: count)
            )
        }
    }

    /// Strips line-number prefixes from each line of text.
    /// Handles formats: `6\t`, `6   │ `, `6  | ` (from read_lines output).
    /// Only strips if ALL non-empty lines match the prefix pattern to avoid false positives.
    private static func stripLineNumberPrefixes(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let prefixPattern = try? NSRegularExpression(
            pattern: #"^\d+(\t|\s*[\x{2502}|]\s?)"#
        ) else {
            return text
        }

        let nonEmptyLines = lines.filter { !$0.isEmpty }
        guard !nonEmptyLines.isEmpty else { return text }

        let allMatch = nonEmptyLines.allSatisfy { line in
            let range = NSRange(line.startIndex..., in: line)
            return prefixPattern.firstMatch(in: line, range: range) != nil
        }

        guard allMatch else { return text }

        let stripped = lines.map { line in
            guard !line.isEmpty else { return line }
            let range = NSRange(line.startIndex..., in: line)
            if let match = prefixPattern.firstMatch(in: line, range: range) {
                let matchRange = Range(match.range, in: line)!
                return String(line[matchRange.upperBound...])
            }
            return line
        }

        return stripped.joined(separator: "\n")
    }

    /// Unescapes common JSON escape sequences that LLMs copy from read_file output.
    private static func unescapeJSONSequences(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }
}

// MARK: - delete_file

struct DeleteFileTool: ToolHandler {
    static let name = TN.deleteFile
    static let schema = ToolSchema(
        name: TN.deleteFile,
        description: "Delete a file.",
        parameters: JS.object(
            properties: [
                "path": JS.string("Relative path to file"),
                "must_exist": JS.boolean("Fail if file does not exist"),
            ],
            required: ["path"]
        )
    )
    static let category: ToolCategory = .fileWrite
    static let blockedInDefaultStorage = true

    let resolver: SandboxPathResolver
    let fileManager: FileManager

    
    static func makeInstance(dependencies: ToolHandlerDependencies) -> Self {
        Self(resolver: dependencies.resolver, fileManager: dependencies.fileManager)
    }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let path = try requiredString(args, "path")
            let mustExist = optionalBool(args, "must_exist", default: true)

            let fileURL = try resolver.resolveFileURL(relativePath: path)

            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir)

            struct DeleteData: Codable {
                var path: String
                var deleted: Bool
            }

            if !exists {
                if mustExist {
                    return makeErrorResult(
                        toolName: Self.name, args: args,
                        code: .fileNotFound, message: "File not found: \(path)"
                    )
                } else {
                    return makeSuccessResult(
                        toolName: Self.name, args: args,
                        data: DeleteData(path: path, deleted: false)
                    )
                }
            }

            if isDir.boolValue {
                return makeErrorResult(
                    toolName: Self.name, args: args,
                    code: .notAFile, message: "Path is a directory: \(path)"
                )
            }

            try fileManager.removeItem(at: fileURL)

            return makeSuccessResult(
                toolName: Self.name, args: args,
                data: DeleteData(path: path, deleted: true)
            )
        }
    }
}
