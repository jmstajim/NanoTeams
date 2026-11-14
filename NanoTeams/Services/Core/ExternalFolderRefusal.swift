import Foundation

/// Why an external call's `folder_id` was refused — and, by case, the refusal's error code, its
/// message and the call to make next. One type picks all three, so no caller reads them back out
/// of a string.
///
/// Until 2026-11-08 `validateActiveFolderID` returned a bare message and its callers chose the code
/// with `message.hasPrefix("Missing required")`. A missing `folder_id` came back with no next call
/// at all, and every other refusal borrowed `DeferredCallReplies.folderChanged` — "The work folder
/// changed while this action was running…" — so an id from another project, or a call made while
/// no folder was open, reported a race that had not happened, as `COMMAND_FAILED`.
///
/// `classify` is the decision, over facts the orchestrator gathers; this type holds no state.
nonisolated enum ExternalFolderRefusal: Error, Hashable, Sendable, CaseIterable {
    /// The tool requires `folder_id` and the call carried none.
    case missingFolderID
    /// The call's `folder_id` is not the folder NanoTeams has open: an id from a folder opened
    /// earlier, or another project's.
    case notTheOpenFolder
    /// A work-folder transition is in progress, so there is no folder to act in yet.
    case folderTransitionInProgress
    /// The folder is open in another NanoTeams process, so this one has nothing loaded to act in.
    case folderInUse
    /// No project work folder is open.
    case noWorkFolder
    /// The folder changed while this call ran: the lifecycle the call began in has ended and the
    /// next folder has committed. The one refusal the race wording describes.
    case changedDuringCall

    /// The refusal for these facts, or `nil` when the call may go on in the open folder.
    ///
    /// The order is the argument. An argument error is one whatever state the folder is in. A
    /// transition in progress is asked before the lifecycle because a call that begins during one
    /// captures a lifecycle that is already over — it arrived in that state, it did not see a
    /// change. Only then does an ended lifecycle mean the folder changed while the call ran.
    static func classify(
        providedFolderID: String?,
        required: Bool,
        isFolderTransitionInProgress: Bool,
        isLifecycleCurrent: Bool,
        isFolderInUseByAnotherProcess: Bool,
        hasRealWorkFolder: Bool,
        openFolderID: String?
    ) -> ExternalFolderRefusal? {
        let provided = providedFolderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if required && provided.isEmpty { return .missingFolderID }
        if isFolderTransitionInProgress { return .folderTransitionInProgress }
        if !isLifecycleCurrent { return .changedDuringCall }
        if isFolderInUseByAnotherProcess { return .folderInUse }
        guard hasRealWorkFolder, let openFolderID else { return .noWorkFolder }
        if !provided.isEmpty, provided.caseInsensitiveCompare(openFolderID) != .orderedSame {
            return .notTheOpenFolder
        }
        return nil
    }

    var code: ToolErrorCode {
        switch self {
        case .missingFolderID, .notTheOpenFolder:
            return .invalidArgs
        case .folderTransitionInProgress, .folderInUse, .noWorkFolder:
            return .commandFailed
        case .changedDuringCall:
            return .folderChanged
        }
    }

    /// runtime-prompt
    ///
    /// The two the agent fixes itself say where a `folder_id` comes from. The folder states say
    /// what a write is told in the same state (`ExternalAutovisorReadiness.Refusal`, a `String`
    /// per refusing state), so a read and a write cannot describe one state two ways.
    var message: String {
        switch self {
        case .missingFolderID:
            return "Missing required parameter: folder_id. " + Self.folderIDSource
        case .notTheOpenFolder:
            return "This folder_id is not the work folder open in NanoTeams now, so nothing was done. "
                + Self.folderIDSource
        case .folderTransitionInProgress:
            return ExternalAutovisorReadiness.Refusal.folderTransition.message
        case .folderInUse:
            return ExternalAutovisorReadiness.Refusal.folderInUse.message
        case .noWorkFolder:
            return ExternalAutovisorReadiness.Refusal.noWorkFolder.message
        case .changedDuringCall:
            return DeferredCallReplies.folderChanged
        }
    }

    /// runtime-prompt
    ///
    /// `folder_status` for every case: for the two the agent fixes itself it returns the id; for
    /// the folder states it is the call that says when they are over; after a change, the folder
    /// open now. Until 2026-11-12 the folder states and the change named no next call (F6 L1), on
    /// the reasoning that an immediate `folder_status` would only repeat them — but the
    /// instructions promise one on every refusal, and it is the call that ends the wait.
    var next: NextHint {
        switch self {
        case .missingFolderID, .notTheOpenFolder:
            ExternalNextCall.folderID.hint()
        case .folderTransitionInProgress, .folderInUse, .noWorkFolder:
            ExternalNextCall.folderNotReady.hint()
        case .changedDuringCall:
            ExternalNextCall.folderChanged.hint()
        }
    }

    /// The tool error envelope for this refusal.
    func errorResult(toolName: String, args: [String: Any]) -> ToolExecutionResult {
        makeErrorResult(toolName: toolName, args: args, code: code, message: message, next: next)
    }

    private static let folderIDSource =
        "folder_id is the id folder_status returns for the work folder NanoTeams has open; check that its path is your project."
}
