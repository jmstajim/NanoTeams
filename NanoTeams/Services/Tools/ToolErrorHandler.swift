import Foundation

/// Helper type for executing tool implementations with standardized error handling.
nonisolated enum ToolErrorHandler {

    /// Executes a tool implementation with standardized error handling.
    /// Catches common error types and converts them to appropriate error results.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool being executed
    ///   - args: The tool arguments dictionary
    ///   - implementation: The tool implementation closure that may throw. `async` because
    ///     `ToolHandler.handle` is — `search` fans its per-file scan out across a task group,
    ///     and a sync sibling overload would be a second home for the same catch ladder.
    /// - Returns: The tool result, either from successful execution or error handling
    static func execute(
        toolName: String,
        args: [String: Any],
        implementation: () async throws -> ToolExecutionResult
    ) async -> ToolExecutionResult {
        do {
            return try await implementation()
        } catch let error as ToolArgumentError {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .invalidArgs, message: error.localizedDescription
            )
        } catch SandboxPathError.restrictedPath {
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .fileNotFound, message: "File not found."
            )
        } catch let error as SandboxPathError {
            // An argument fault, not a decision: every remaining case is a path SHAPE the
            // resolver refuses (absolute, `..`, outside the folder), and each message
            // carries the one-token repair. It shipped as `PERMISSION_DENIED` until
            // 2026-09-07 — a `_DENIED` code, which `ToolErrorNotePolicy` answers with
            // "Do not retry this call" on top of a message that says how to retry it
            // (playbook R1.8.1 / R3.5.3).
            return makeErrorResult(
                toolName: toolName, args: args,
                code: .invalidArgs, message: error.localizedDescription
            )
        } catch ProcessRunnerError.cancelled {
            // SIGTERMed `xcodebuild` / `git`. Route through the unified cancel
            // envelope so MemoryTagStore and downstream classifiers see one
            // wire shape regardless of which layer cancelled.
            return makeCancelledResult(
                toolName: toolName,
                argumentsJSON: encodeArgsToJSON(args)
            )
        } catch let error as ProcessRunnerError {
            let (code, message) = classify(processRunnerError: error)
            return makeErrorResult(
                toolName: toolName, args: args, code: code, message: message
            )
        } catch {
            let (code, message) = classify(error)
            return makeErrorResult(
                toolName: toolName, args: args, code: code, message: message
            )
        }
    }

    // MARK: - Classification

    /// The three `ProcessRunnerError` cases that are not `.cancelled`, each under the
    /// code its own recovery needs.
    ///
    /// All three used to reach the generic arm as `COMMAND_FAILED`, which
    /// `ToolErrorNotePolicy.direction` steers with "if the message indicates bad
    /// arguments, fix them" — true for exactly one of the three. The messages
    /// themselves are `ProcessRunnerError`'s own: app-authored, English, and already
    /// written for this reader (`.launchFailed` even names `working_directory` as the
    /// thing to check), so nothing is paraphrased here.
    static func classify(
        processRunnerError error: ProcessRunnerError
    ) -> (code: ToolErrorCode, message: String) {
        let message = error.errorDescription ?? "The command could not be run."
        switch error {
        case .timeout:
            return (.commandTimedOut, message)
        case .launchFailed:
            // The overwhelmingly common cause is an argument — a `working_directory`
            // that does not exist or cannot be searched (see the case's own doc).
            // `INVALID_ARGS` is what makes the policy print the tool's required list.
            return (.invalidArgs, message)
        case .executableNotFound:
            return (.commandFailed, message)
        case .cancelled:
            // Handled by its own arm above; kept exhaustive so a new case cannot
            // silently inherit a wrong code.
            return (.cancelled, message)
        }
    }

    /// Classifies everything else ~50 tools can throw — `FileManager`,
    /// `Data(contentsOf:)`, `JSONDecoder`, `Process` — into a typed code and a
    /// STABLE English sentence.
    ///
    /// What this replaced was `error.localizedDescription`, unconditionally, under
    /// `COMMAND_FAILED`. Three harms, and the third is what made it a defect rather
    /// than a style complaint:
    ///
    /// 1. **It is localized.** Cocoa's file errors come back in the user's system
    ///    language, so on a non-English Mac the model is handed a Russian or Japanese
    ///    sentence mid-conversation — and, because nudges are never retired, that
    ///    sentence then rides the prefix of every later request of the step.
    /// 2. **It names absolute paths** (`/Users/<name>/…`), which is precisely what
    ///    `SandboxPathError.restrictedPath` is careful not to leak one arm above.
    /// 3. **It teaches nothing, because the code is always the same.** "no such file"
    ///    and "you don't have permission" arrived under one code, so the policy steered
    ///    both with the generic arm. Classifying restores the distinction the OS
    ///    already made.
    ///
    /// App-authored `LocalizedError`s pass through verbatim: they are English,
    /// sandbox-relative, and written for this reader. Only the system's are rewritten.
    static func classify(_ error: Error) -> (code: ToolErrorCode, message: String) {
        if let decoding = error as? DecodingError {
            return (.commandFailed, describe(decoding))
        }
        if let localized = error as? LocalizedError,
           let text = localized.errorDescription, !text.isEmpty {
            return (.commandFailed, text)
        }

        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, 4), (NSCocoaErrorDomain, 260), (NSPOSIXErrorDomain, 2):
            return (.fileNotFound, "File not found.")
        case (NSCocoaErrorDomain, 257), (NSCocoaErrorDomain, 513), (NSPOSIXErrorDomain, 13):
            return (.permissionDenied, "Permission denied.")
        case (NSCocoaErrorDomain, 512):
            return (.invalidArgs, "The path is not a valid file name.")
        case (NSCocoaErrorDomain, 516):
            return (.conflict, "A file already exists at that path.")
        case (NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28):
            return (.commandFailed, "No space left on the volume.")
        case (NSPOSIXErrorDomain, 21):
            return (.notAFile, "That path is a directory.")
        case (NSCocoaErrorDomain, 3840):
            return (.commandFailed, "The file's contents are not valid JSON.")
        case (NSCocoaErrorDomain, 261):
            return (.commandFailed,
                    "The file could not be decoded with the requested text encoding.")
        // Transport errors reach the wire from the vision, meeting, consultation and judge
        // paths — `URLError`'s own text is localized like Cocoa's ("The request timed out."
        // arrives in the system language), so the four the model can act on get stable
        // English here, and the rest the domain-and-code handle below.
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return (.commandFailed, "The request timed out.")
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost), (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return (.commandFailed, "The server could not be reached.")
        default:
            // Not localized and not path-bearing, but still a handle: the domain and
            // code are the only things anyone — model or Supervisor reading the card —
            // can look up about an error nobody anticipated.
            return (.commandFailed,
                    "The tool failed with an unclassified system error "
                        + "(\(nsError.domain) \(nsError.code)).")
        }
    }

    /// `DecodingError` in the model's terms: which key or type, not Foundation's
    /// localized "The data couldn't be read because it isn't in the correct format."
    ///
    /// `codingPath` is included because it is the only part that says WHERE, and it is
    /// derived from the document being decoded rather than from the filesystem — so
    /// unlike `localizedDescription` it cannot carry a path outside the sandbox.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Malformed JSON: required key '\(key.stringValue)' is missing at \(path(context))."
        case .typeMismatch(let type, let context):
            return "Malformed JSON: expected \(type) at \(path(context))."
        case .valueNotFound(let type, let context):
            return "Malformed JSON: found null where \(type) was required at \(path(context))."
        case .dataCorrupted(let context):
            return "Malformed JSON at \(path(context))."
        @unknown default:
            return "Malformed JSON."
        }
    }
}
