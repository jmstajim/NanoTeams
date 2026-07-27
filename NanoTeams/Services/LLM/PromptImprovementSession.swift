import Foundation

/// Lifecycle state machine for the non-blocking "improve prompt" flow: streams
/// the LLM rewrite live into a host-owned text field (Writing Tools style),
/// restores the original on stop/error, and drives the post-completion
/// Revert affordance. Owned as `@State` by `ImprovePromptButton`; no SwiftUI
/// imports so the whole machine is testable without rendering.
///
/// Field access goes through injected `read`/`write` closures (captured from
/// the host's `Binding` — routed through `@State` storage, so they stay live
/// for the session's whole lifetime).
///
/// Two guards make concurrent field ownership safe:
/// 1. **CAS baseline** — the session remembers the exact string it last wrote
///    (`lastWritten`, seeded from `streamBaseline`). Every write and every
///    restore first checks the field still holds that value; on mismatch the
///    session silently self-cancels WITHOUT restoring — an external owner
///    (draft swap, programmatic clear, task switch) has taken the field and
///    must win. Same principle as `EditableMessageTextView.Coordinator`'s
///    `lastAppliedText`.
/// 2. **Generation counter** (CLAUDE.md #38) — `start`/`stop`/terminal
///    transitions bump `generation`; reducer calls carrying a stale
///    generation are dropped, so events from a cancelled pump can never
///    clobber a restored field or interleave with a newer stream.
@MainActor
@Observable
final class PromptImprovementSession {

    enum Phase: Equatable {
        case idle
        /// Task running, no visible content yet — the field keeps showing the
        /// ORIGINAL text while a reasoning model thinks.
        case waitingForFirstDelta
        /// Deltas arriving — the field shows the accumulated rewrite.
        case streaming
        case failed(message: String)
    }

    // MARK: - Observable surface

    /// Only phase transitions and the revert baseline are observable;
    /// per-delta internals are `@ObservationIgnored` so a delta burst doesn't
    /// re-evaluate host bodies that read session state.
    private(set) var phase: Phase = .idle
    /// Non-nil → the Revert chip is visible; holds the text Revert restores.
    private(set) var revertText: String?

    var isImproving: Bool { phase == .waitingForFirstDelta || phase == .streaming }
    var canRevert: Bool { revertText != nil }
    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    // MARK: - Wiring

    typealias StreamProvider = @MainActor (_ prompt: String, _ config: LLMConfig)
        -> AsyncThrowingStream<String, Error>

    @ObservationIgnored private let streamProvider: StreamProvider
    @ObservationIgnored private var read: (@MainActor () -> String)?
    @ObservationIgnored private var write: (@MainActor (String) -> Void)?

    // MARK: - Stream state (all @ObservationIgnored)

    /// Field content when the current stream started — the restore target for
    /// stop/error and the CAS expectation before the first write.
    @ObservationIgnored private var streamBaseline = ""
    /// The last user-authored text (v0). Kept across chained improves so
    /// Revert always restores the user's own words, never a prior AI pass.
    @ObservationIgnored private var revertTarget = ""
    /// Exact string of this stream's last field write; nil until the first
    /// write. CAS baseline for subsequent writes and for the restore.
    @ObservationIgnored private var lastWritten: String?
    /// Final improved text of the last successful run — the Revert chip stays
    /// while the field still equals this value.
    @ObservationIgnored private var finalText: String?
    @ObservationIgnored private var accumulated = ""
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(streamProvider: @escaping StreamProvider = { prompt, config in
        PromptImprovementService.improveStream(prompt: prompt, config: config)
    }) {
        self.streamProvider = streamProvider
    }

    // MARK: - Controls

    /// Begins an improve run over the field's current text. No-op while a run
    /// is active or when the field is blank. The field is NOT touched until
    /// the first visible delta arrives.
    /// `recordPrefixCall` registers this request with the prompt-prefix ledger. A closure rather
    /// than the ledger itself: this session is owned by a SwiftUI view and has no service handle,
    /// while the host can reach one from the environment. Optional because a host without the
    /// orchestrator in scope legitimately cannot supply it — see the marker at the `streamChat`
    /// call site.
    func start(
        config: LLMConfig,
        read: @escaping @MainActor () -> String,
        write: @escaping @MainActor (String) -> Void,
        recordPrefixCall: (@MainActor (LLMConfig) async -> Void)? = nil
    ) {
        guard !isImproving else { return }
        let current = read()
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Chained improve (field still holds this session's last final):
        // keep v0 as the revert target — "Revert" means the user's own text.
        if !(revertText != nil && current == finalText) {
            revertTarget = current
        }
        self.read = read
        self.write = write
        streamBaseline = current
        accumulated = ""
        lastWritten = nil
        finalText = nil
        revertText = nil
        phase = .waitingForFirstDelta
        generation += 1
        let gen = generation
        // Build the stream synchronously so the underlying request starts now
        // (and, in tests, the provider records its invocation before start()
        // returns). The Task only consumes.
        let stream = streamProvider(current, config)
        task = Task { [weak self] in
            // Registered as a suspect: this runs on the global model, and the button lives in
            // `MessageComposer` — i.e. in the activity feed, where a role step may well be
            // streaming on that same model right now.
            await recordPrefixCall?(config)
            do {
                for try await delta in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.ingest(delta: delta, generation: gen)
                }
                self?.finishStream(generation: gen)
            } catch {
                guard !(error is CancellationError) else { return }
                self?.failStream(message: error.localizedDescription, generation: gen)
            }
        }
    }

    /// User stop: cancel the stream and restore the original (CAS-guarded).
    func stop() {
        guard isImproving else { return }
        cancelPump()
        restoreBaselineIfStillOwned()
        phase = .idle
    }

    /// View teardown mid-stream ≡ stop. The CAS guard makes the restore safe
    /// even when teardown races a host that already re-seeded the field.
    func handleDisappear() {
        guard isImproving else { return }
        stop()
    }

    /// Revert chip: restore the user's original text (CAS-guarded — if the
    /// field no longer holds the improved text, just retire the chip).
    func revert() {
        guard let target = revertText else { return }
        if let read, let write, read() == finalText {
            write(target)
        }
        revertText = nil
        finalText = nil
    }

    /// Host signal from `.onChange(of: text)`. Comparisons run against the
    /// LIVE field value (`read()`), not the delivered onChange payload, so
    /// coalesced/stale SwiftUI deliveries can't trigger a false cancel.
    func noteFieldTextChanged(_ newText: String) {
        guard let read else { return }
        switch phase {
        case .waitingForFirstDelta, .streaming:
            let expected = lastWritten ?? streamBaseline
            if read() != expected {
                // External owner took the field mid-stream (draft swap,
                // programmatic clear, user typing past the lock) — cancel
                // WITHOUT restore; their write wins.
                cancelPump()
                phase = .idle
            }
        case .idle:
            if revertText != nil, read() != finalText {
                revertText = nil
                finalText = nil
            }
        case .failed:
            // The error was surfaced against the restored original; any real
            // edit means the user moved on — clear the stale error.
            if read() != streamBaseline {
                phase = .idle
            }
        }
    }

    // MARK: - Reducers (internal so tests drive transitions deterministically)

    func ingest(delta: String, generation gen: Int) {
        guard gen == generation, isImproving else { return }
        accumulated += delta
        let display = Self.displayText(accumulated)
        // Nothing visible yet (delta was pure model tokens / an opening
        // fence) — keep the original on screen.
        if lastWritten == nil && display.isEmpty { return }
        guard casWrite(display) else {
            cancelPump()
            phase = .idle
            return
        }
        phase = .streaming
    }

    func finishStream(generation gen: Int) {
        guard gen == generation, isImproving else { return }
        let final = PromptImprovementService.postProcess(accumulated)
        if final.isEmpty {
            restoreBaselineIfStillOwned()
            phase = .failed(message: "The model returned an empty prompt. Try again.")
            retirePump()
            return
        }
        guard casWrite(final) else {
            cancelPump()
            phase = .idle
            return
        }
        finalText = final
        revertText = revertTarget
        phase = .idle
        retirePump()
    }

    func failStream(message: String, generation gen: Int) {
        guard gen == generation, isImproving else { return }
        restoreBaselineIfStillOwned()
        phase = .failed(message: message)
        retirePump()
    }

    // MARK: - Display transform

    /// Per-delta display text: strip `<|…|>` model tokens and hide an opening
    /// code-fence line so mid-stream output reads clean. The full pipeline
    /// (trim + closing-fence strip) runs once at end of stream via
    /// `PromptImprovementService.postProcess`.
    static func displayText(_ accumulated: String) -> String {
        let stripped = ModelTokenCleaner.stripTokens(accumulated)
        var lines = stripped.components(separatedBy: "\n")
        var index = 0
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count,
              lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        else { return stripped }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    /// CAS write: lands `text` only when the field still holds this stream's
    /// last write (or the untouched baseline before the first write).
    private func casWrite(_ text: String) -> Bool {
        guard let read, let write else { return false }
        guard read() == (lastWritten ?? streamBaseline) else { return false }
        write(text)
        lastWritten = text
        return true
    }

    /// Restore the pre-stream original — only when the session wrote at all
    /// AND the field still holds the session's text.
    private func restoreBaselineIfStillOwned() {
        defer { lastWritten = nil }
        guard let sessionText = lastWritten, let read, let write else { return }
        guard read() == sessionText else { return }
        write(streamBaseline)
    }

    /// Invalidate in-flight pump events and cancel the task.
    private func cancelPump() {
        generation += 1
        task?.cancel()
        task = nil
    }

    /// Terminal transition housekeeping: the stream ended on its own — no
    /// cancel needed, but stale stragglers must still be invalidated.
    private func retirePump() {
        generation += 1
        task = nil
    }
}
