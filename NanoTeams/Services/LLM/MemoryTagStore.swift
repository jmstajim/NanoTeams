import Foundation

// MARK: - MemoryTagStore

/// Stamps every supported tool result with a unique tag (e.g., `<§R1§>`, `<§E3§>`,
/// `<§B2§>`). The tag is a compact reference handle for the MODEL: the system
/// prompt's legend teaches it to reference a tag in its reasoning instead of
/// re-quoting the result. Tags live ONLY on the wire (`conversationMessages`,
/// and therefore `network_log.json`) — the persisted feed entry and
/// `tool_calls.jsonl` both carry the raw untagged envelope, an asymmetry pinned
/// by `RegularToolResultDispatchTests` ("tags must not leak into the persisted
/// feed entry").
///
/// Deliberately STATELESS across actions (simplified 2026-08-11): every result is
/// rendered in full with a fresh tag — there is no unchanged-detection, no
/// baseline comparison, no OUTDATED/REPLACED bookkeeping, and nothing to reset at
/// the planning boundary. The only cross-call state is the per-type counter that
/// keeps tags unique within the conversation the model sees.
///
/// Split across extension files:
/// - `MemoryTagStore+FileProcessing.swift` — read/edit/write envelopes
/// - `MemoryTagStore+BuildProcessing.swift` — build/test summary envelopes
/// - `MemoryTagStore+GitProcessing.swift` — git status/diff envelopes
/// - `MemoryTagStore+BashProcessing.swift` — bash output envelopes
/// - `MemoryTagStore+SummaryExtraction.swift` — build/test summary extraction
/// - `MemoryTagStore+JSONHelpers.swift` — JSON parsing utilities
nonisolated final class MemoryTagStore {

    // MARK: - Tag Types

    enum TagType: String {
        case read = "R"      // read_file, read_lines
        case edit = "E"      // edit_file (successful only)
        case write = "W"     // write_file
        case build = "B"     // run_xcodebuild, run_xcodetests
        case git = "G"       // git_status, git_diff
        case shell = "S"     // bash
    }

    // MARK: - Processors (DIP)

    let processors: [ToolResultProcessor]

    /// Work folder root used to canonicalize tool-arg paths into one repo-relative
    /// spelling, so the `path` rendered into a tagged envelope is stable across
    /// the model's spelling variations (`src/x`, `Foo/src/x`, `./src/x`, or an
    /// absolute path). `nil` disables canonicalization (raw path as-is) — for
    /// stores built without a work-folder context. The sole production
    /// constructor (LLMExecutionService+StepLifecycle) always supplies a root.
    let workFolderRoot: URL?

    nonisolated(unsafe) static let defaultProcessors: [any ToolResultProcessor] = [
        FileToolProcessor(),
        BuildGitToolProcessor(),
        BashToolProcessor(),
    ]

    /// The tools whose SUCCESS results actually get a tag — the prompt's tag
    /// legend is gated and worded from this set, so a role that can produce a
    /// tagged envelope always gets the legend explaining it. Narrower than the
    /// processors' `supportedTools` union: `delete_file`/`list_files`/`search`
    /// are CLAIMED but pass through untagged. Pinned by
    /// `MemoryTagStoreTests.testTagProducingTools_matchesActualTaggingBehavior`.
    static let tagProducingTools: Set<String> = [
        ToolNames.readFile, ToolNames.readLines,
        ToolNames.editFile, ToolNames.writeFile,
        ToolNames.runXcodebuild, ToolNames.runXcodetests,
        ToolNames.gitStatus, ToolNames.gitDiff,
        ToolNames.bash,
    ]

    init(
        workFolderRoot: URL? = nil,
        processors: [ToolResultProcessor] = MemoryTagStore.defaultProcessors
    ) {
        self.workFolderRoot = workFolderRoot
        self.processors = processors
    }

    nonisolated deinit {}

    // MARK: - Tag Generation

    /// Per-type monotonic counter — the store's ONLY cross-call state.
    ///
    /// The counter alone guarantees uniqueness only WITHIN one store's life, and
    /// the store is built per `runStep` ENTRY — but a resumed step replays
    /// `step.wireTranscript`, which still carries the previous entry's tags. That
    /// is why `runStep` calls `seedTagCounters(replaying:)` on the assembled
    /// conversation before the loop starts: without it a fresh store would mint
    /// `<§R1§>` again next to a replayed `<§R1§>` holding a different payload.
    private var nextID: [TagType: Int] = [:]

    func nextTag(_ type: TagType) -> String {
        let id = (nextID[type] ?? 0) + 1
        nextID[type] = id
        return "<§\(type.rawValue)\(id)§>"
    }

    /// Advances the per-type counters past every tag already visible in
    /// `messages`, so a store built for a step RE-ENTRY (which replays the
    /// persisted wire transcript, tags included) can never re-mint a handle the
    /// conversation already carries.
    ///
    /// SYSTEM messages are skipped, and that exclusion is load-bearing rather than
    /// tidy. The system prompt carries the tag LEGEND — `<§R1§> read, <§E1§> edit,
    /// …` (`PromptBuilder`) — which is an illustration, not a live handle. Scanning
    /// it seeded every counter to 1 on EVERY step, so the first tag actually minted
    /// for any type was `#2`: the prompt taught the model `<§R1§>` and the model
    /// could never receive it. (This is why the 2026-08-13 gemma run's first
    /// successful edit came back `<§E2§>`.) The old doc claimed "a fresh
    /// conversation has no tags, so the scan is a cheap no-op there" — false on
    /// every step, since the legend always ships.
    func seedTagCounters(replaying messages: [ChatMessage]) {
        let pattern = #/<§([A-Z])(\d+)§>/#
        for message in messages where message.role != .system {
            guard let content = message.content, content.contains("<§") else { continue }
            for match in content.matches(of: pattern) {
                guard let type = TagType(rawValue: String(match.output.1)),
                      let number = Int(match.output.2) else { continue }
                nextID[type] = max(nextID[type] ?? 0, number)
            }
        }
    }
}

// MARK: - Processing Results

nonisolated enum TagProcessingResult {
    case passthrough                          // use original result as-is
    // `tag` is the minted handle. Production's sole consumer reads only
    // `content` (the tag is already rendered into it); the separate payload
    // exists so tests can assert tag identity without re-parsing the envelope.
    case tagged(content: String, tag: String)
}

// MARK: - Tool Result Processor Protocol (OCP)

/// Implement to add a new tool category to the tag system.
nonisolated protocol ToolResultProcessor {
    var supportedTools: Set<String> { get }
    func process(_ result: ToolExecutionResult, store: MemoryTagStore) -> TagProcessingResult
}

/// Processes file tools: read_file, read_lines, edit_file, write_file.
/// `supportedTools` is `allFileTools`, so this processor CLAIMS `delete_file`,
/// `list_files` and `search` too — all three deliberately fall to the `default:`
/// passthrough (minimal envelopes, nothing references them afterwards). Claimed-
/// but-untagged matters: `processToolResult`'s first-match loop means a later
/// processor can never pick these tools up; a future listing tag has to be added
/// HERE, not as a new processor.
nonisolated struct FileToolProcessor: ToolResultProcessor {
    let supportedTools: Set<String> = ToolHandlerRegistry.allFileTools

    private typealias TN = ToolNames

    func process(_ result: ToolExecutionResult, store: MemoryTagStore) -> TagProcessingResult {
        switch result.toolName {
        case TN.readFile, TN.readLines: return store.processRangedRead(result)
        case TN.editFile: return store.processEdit(result)
        case TN.writeFile: return store.processWrite(result)
        default: return .passthrough
        }
    }
}

/// Processes build and git tools: run_xcodebuild, run_xcodetests, git_status, git_diff.
nonisolated struct BuildGitToolProcessor: ToolResultProcessor {
    private typealias TN = ToolNames

    let supportedTools: Set<String> = ToolHandlerRegistry.xcodeTools.union([TN.gitStatus, TN.gitDiff])

    func process(_ result: ToolExecutionResult, store: MemoryTagStore) -> TagProcessingResult {
        switch result.toolName {
        case TN.runXcodebuild: return store.processBuild(result)
        case TN.runXcodetests: return store.processTests(result)
        case TN.gitStatus, TN.gitDiff: return store.processGit(result)
        default: return .passthrough
        }
    }
}

/// Processes the `bash` tool. `bash_output` (incremental background reads) is
/// intentionally NOT tagged — its envelope is a rolling delta, not a result.
nonisolated struct BashToolProcessor: ToolResultProcessor {
    let supportedTools: Set<String> = [ToolNames.bash]

    func process(_ result: ToolExecutionResult, store: MemoryTagStore) -> TagProcessingResult {
        store.processBash(result)
    }
}

nonisolated extension MemoryTagStore {

    /// Process tool result. Returns tagged/passthrough.
    func processToolResult(_ result: ToolExecutionResult) -> TagProcessingResult {
        for processor in processors where processor.supportedTools.contains(result.toolName) {
            return processor.process(result, store: self)
        }
        return .passthrough
    }
}
