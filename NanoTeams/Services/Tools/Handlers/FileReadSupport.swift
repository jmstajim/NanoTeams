import Foundation

/// Shared resolve-and-extract logic for the file-READING tools (`read_file` /
/// `read_lines`). Both tools open with the same sequence — sandbox path
/// resolution, existence check, RTFD-bundle-as-file handling, directory
/// rejection, then document-format-or-UTF-8 content extraction — which had
/// drifted into two near-identical copies. Centralizing it removes the
/// copy-paste drift hazard (a fix to one previously had to be mirrored by hand).
///
/// Deliberately does NOT own the line-range math: `read_file` *rejects* an
/// over-cap file while `read_lines` *truncates and paginates*. Those are
/// genuinely different policies, so the cap arithmetic stays inline in each
/// handler (forcing them into one computer would add a worse branch than the
/// duplication it removes).
nonisolated enum FileReadSupport {

    /// Result of resolving a path: either a readable file/bundle URL or a
    /// ready-to-return error envelope. A plain enum (not `Result`) because
    /// `ToolExecutionResult` is not an `Error`.
    enum ResolveOutcome {
        case file(URL)
        case rejected(ToolExecutionResult)
    }

    /// Result of content extraction: either decoded text (+ the encoding label
    /// `read_file` reports) or a ready-to-return error envelope.
    enum ContentOutcome {
        case text(content: String, encoding: String)
        case failure(ToolExecutionResult)
    }

    /// Resolves `path` to a readable regular-file (or RTFD bundle) URL, or
    /// returns the error envelope the caller should surface.
    ///
    /// `throws` only via `resolver.resolveFileURL` — a sandbox/restricted-path
    /// error propagates so the caller's `ToolErrorHandler.execute` maps it
    /// (e.g. restricted internal path → `fileNotFound`), exactly as before.
    /// Validated-but-rejected cases (missing file, plain directory) come back
    /// as `.failure(envelope)`.
    ///
    /// `notFoundNext` is caller-supplied because the not-found hint differs:
    /// `read_file` points at the parent directory's `list_files`, `read_lines`
    /// omits the hint. The directory-rejection hint is identical for both and
    /// is built here.
    static func resolveReadableFile(
        toolName: String,
        args: [String: Any],
        path: String,
        resolver: SandboxPathResolver,
        fileManager: FileManager,
        notFoundNext: NextHint?
    ) throws -> ResolveOutcome {
        let fileURL = try resolver.resolveFileURL(relativePath: path)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            return .rejected(makeErrorResult(
                toolName: toolName, args: args,
                code: .fileNotFound, message: "File not found: \(path)",
                next: notFoundNext
            ))
        }

        // RTFD is a file-bundle directory — treat as a single document.
        let isRTFDBundle = isDir.boolValue && fileURL.pathExtension.lowercased() == "rtfd"
        guard !isDir.boolValue || isRTFDBundle else {
            return .rejected(makeErrorResult(
                toolName: toolName, args: args,
                code: .notAFile, message: "Path is a directory: \(path)",
                next: NextHint(
                    suggested_cmd: ToolNames.listFiles,
                    suggested_args: ["path": path],
                    reason: "List directory contents"
                )
            ))
        }

        return .file(fileURL)
    }

    /// Extracts file content: PDF/DOCX/RTF/etc. via `DocumentTextExtractor`,
    /// otherwise raw UTF-8. A document-extraction failure message and a
    /// non-UTF-8/binary file both surface as `.commandFailed` envelopes — never
    /// empty content (which the LLM would mistake for a genuinely empty file).
    static func extractContent(
        toolName: String,
        args: [String: Any],
        path: String,
        fileURL: URL
    ) -> ContentOutcome {
        if let outcome = DocumentTextExtractor.extract(from: fileURL) {
            guard case .text(let extracted, _) = outcome else {
                // `.empty` and `.failure` both mean "no content to return". They read the
                // same here on purpose: the caller asked for this file's text, and either
                // way there is none — the reason says which.
                return .failure(makeErrorResult(
                    toolName: toolName, args: args,
                    code: .commandFailed,
                    message: outcome.message(for: fileURL) ?? "no extractable text"
                ))
            }
            return .text(content: extracted, encoding: "extracted_text")
        }
        guard let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .failure(makeErrorResult(
                toolName: toolName, args: args,
                code: .commandFailed,
                message: "File is not valid UTF-8 — appears to be binary or in another encoding: \(path)"
            ))
        }
        return .text(content: utf8, encoding: "utf-8")
    }
}
