import Foundation

/// The task-persistence stream split (2026-08-22): a step's four stream
/// collections — `llmConversation`, `wireTranscript`, `toolCalls`, `messages`,
/// 98.4% of a task's bytes — live in per-step `step_log.jsonl` files;
/// `task.json` carries metadata plus a `logCommit` stamp per split step. This
/// file owns both directions: strip-and-flush on write, hydration on read.
///
/// Strip-on-WRITE is what makes raw `store.read` → `store.write` round-trips
/// of a split task lossless by construction: the blob on disk simply does not
/// contain the arrays, so a sweep that decodes, patches one metadata field and
/// writes the whole value back (the placeholder-chat heal) cannot erase
/// conversations — there is nothing there to erase. No separate metadata type
/// is needed; the one residual hazard (an unhydrated task's EMPTY arrays
/// reaching the diff and reading as a rollback) is closed by the
/// `streamsHydrated` guard in `updateTaskOnly`.
nonisolated extension NTMSRepository {

    /// Flushes every step's streams to its log and returns the task with the
    /// arrays STRIPPED and `logCommit` stamped — the shape `task.json`
    /// receives. A never-logged step with empty streams stays legacy-shaped
    /// (no file, no stamp); a legacy step with content migrates here on its
    /// first flush (the cold-entry whole-file write). Throws when a log write
    /// fails: refusing the whole task write is what keeps the blob and the log
    /// from ever disagreeing about where the streams live.
    func splittingStreams(
        _ task: NTMSTask, paths: NTMSPaths, ancestors: [Int]
    ) throws -> NTMSTask {
        var stripped = task
        // Resolved ONCE: this walk visits every step of every run on every
        // mutation, and `task.runs` is append-only with no cap, so anything
        // per-step is paid by the whole frozen history. Standardizing here and
        // concatenating below is the same identity as standardizing each step's
        // URL (see `NTMSPaths.stepLogKey`).
        let taskDirPath = paths
            .internalTaskDir(taskID: task.id, ancestors: ancestors)
            .standardizedFileURL.path
        for r in stripped.runs.indices {
            let runID = stripped.runs[r].id
            for s in stripped.runs[r].steps.indices {
                let step = stripped.runs[r].steps[s]
                let streams = TaskStreamStore.StepStreams(
                    conversation: step.llmConversation,
                    wire: step.wireTranscript,
                    toolCalls: step.toolCalls,
                    messages: step.messages)
                if streams.isEmpty && step.logCommit == nil { continue }
                let key = NTMSPaths.stepLogKey(
                    taskDirPath: taskDirPath, runID: runID, roleID: step.id)

                // Frozen history: the four arrays are the very buffers the store
                // last flushed, so there is provably nothing to diff. Answered
                // under one uncontended lock — no queue hop, no URL, no
                // comparison pass. The stamp comes from the store rather than
                // from `step.logCommit`, which is NOT a change signal: this
                // function stamps only the returned copy, `updateTaskOnly` takes
                // the task by value, and nothing writes it back.
                let commit: StepLogCommit
                if let cached = TaskStreamStore.cachedCommitIfUnchanged(streams, forKey: key) {
                    commit = cached
                } else {
                    let url = paths.stepLogJSONL(
                        taskID: task.id, runID: runID, roleID: step.id, ancestors: ancestors)
                    guard let flushed = TaskStreamStore.flush(
                        streams, to: url, fileManager: fileManager,
                        directoryAttributes: Self.internalDirAttributes)
                    else {
                        throw NTMSRepositoryError.stepLogWriteFailed(
                            taskID: task.id, stepID: step.id)
                    }
                    commit = flushed
                }
                // The strip runs on BOTH paths: skipping it would hand `task.json`
                // back the 98.4% of bytes the split exists to remove.
                stripped.runs[r].steps[s].logCommit = commit
                stripped.runs[r].steps[s].llmConversation = []
                stripped.runs[r].steps[s].wireTranscript = []
                stripped.runs[r].steps[s].toolCalls = []
                stripped.runs[r].steps[s].messages = []
            }
        }
        return stripped
    }

    /// Loads every split step's streams back from its log and marks the task
    /// hydrated. Legacy steps (no `logCommit`) keep their embedded arrays —
    /// the reader-fallback that lets a never-again-mutated old task read
    /// correctly forever. A missing log behind a stamp fails OPEN with empty
    /// streams plus a warning, matching the reconcile scans' per-task policy.
    func hydrateStreams(_ task: inout NTMSTask, paths: NTMSPaths, ancestors: [Int]) {
        for r in task.runs.indices {
            let runID = task.runs[r].id
            for s in task.runs[r].steps.indices {
                guard let expected = task.runs[r].steps[s].logCommit else { continue }
                let stepID = task.runs[r].steps[s].id
                let url = paths.stepLogJSONL(
                    taskID: task.id, runID: runID, roleID: stepID, ancestors: ancestors)
                if let result = TaskStreamStore.hydrate(
                    from: url, expected: expected, fileManager: fileManager) {
                    task.runs[r].steps[s].llmConversation = result.streams.conversation
                    task.runs[r].steps[s].wireTranscript = result.streams.wire
                    task.runs[r].steps[s].toolCalls = result.streams.toolCalls
                    task.runs[r].steps[s].messages = result.streams.messages
                    task.runs[r].steps[s].logCommit = result.commit
                } else {
                    print("[NTMSRepository] WARNING: step log missing for task \(task.id) "
                        + "step '\(stepID)' — hydrating empty (fail-open)")
                }
            }
        }
        task.streamsHydrated = true
    }
}
