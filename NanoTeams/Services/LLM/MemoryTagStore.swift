import Foundation

// MARK: - MemoryTagStore

/// Tracks tool result tags for the Memories system. Each tool result gets a unique tag
/// (e.g., `<§R1§>`, `<§E3§>`, `<§B2§>`). Unchanged repeat reads return compact references
/// instead of full content, saving tokens. Memories message provides a compact index of all tags.
///
/// Split across extension files:
/// - `MemoryTagStore+FileProcessing.swift` — read/edit/write/delete file processing
/// - `MemoryTagStore+BuildGitProcessing.swift` — build/test/git processing + summary extraction
/// - `MemoryTagStore+JSONHelpers.swift` — JSON parsing utilities
final class MemoryTagStore {

    // MARK: - Tag Types

    enum TagType: String {
        case read = "R"      // read_file, read_lines
        case edit = "E"      // edit_file (successful only)
        case write = "W"     // write_file (new baseline)
        case build = "B"     // run_xcodebuild, run_xcodetests
        case git = "G"       // git_status, git_diff
        case plan = "P"      // update_scratchpad
    }

    enum TagStatus {
        case current
        case outdated(reason: String)  // "<§E1§>" or "external change"
        case replaced(by: String)      // "<§R3§>"
    }

    struct TagEntry {
        let tag: String              // "<§R1§>"
        let type: TagType
        let resource: String         // file path, "build", "git_diff"
        let iteration: Int
        var status: TagStatus
        var content: String          // full content (internal, NOT sent to LLM)
    }

    // MARK: - Processors (DIP)

    let processors: [ToolResultProcessor]

    static let defaultProcessors: [ToolResultProcessor] = [
        FileToolProcessor(),
        BuildGitToolProcessor(),
    ]

    init(processors: [ToolResultProcessor] = MemoryTagStore.defaultProcessors) {
        self.processors = processors
    }

    nonisolated deinit {}

    // MARK: - State

    var entries: [String: TagEntry] = [:]   // tag -> entry
    private var nextID: [TagType: Int] = [:]         // per-type counter
    var currentIteration: Int = 0

    /// Current tag for each resource (path or composite key -> tag string)
    var currentReadTags: [String: String] = [:]
    /// Whether file was edited since last read (path -> true)
    var editedSinceLastRead: [String: Bool] = [:]
    /// Current plan tag (for update_scratchpad)
    private var currentPlanTag: String?

    // MARK: - Tag Generation

    func nextTag(_ type: TagType) -> String {
        let id = (nextID[type] ?? 0) + 1
        nextID[type] = id
        return "<§\(type.rawValue)\(id)§>"
    }

    // MARK: - Entry Registration

    /// Creates a new tag entry, marking the previous tag in `trackingMap[key]` as replaced.
    /// Returns the newly created tag string.
    @discardableResult
    func registerEntry(
        type: TagType,
        resource: String,
        iteration: Int,
        content: String,
        replacingIn trackingMap: inout [String: String],
        key: String? = nil
    ) -> String {
        let tag = nextTag(type)
        let trackingKey = key ?? resource
        if let oldTag = trackingMap[trackingKey] {
            entries[oldTag]?.status = .replaced(by: tag)
        }
        entries[tag] = TagEntry(tag: tag, type: type, resource: resource,
                                iteration: iteration, status: .current, content: content)
        trackingMap[trackingKey] = tag
        return tag
    }
}

// MARK: - Processing Results

enum TagProcessingResult {
    case passthrough                          // use original result as-is
    case tagged(content: String, tag: String) // full content + tag
    case reference(content: String)           // compact reference (unchanged)
}

// MARK: - Tool Result Processor Protocol (OCP)

/// Implement to add a new tool category to the Memories system.
protocol ToolResultProcessor {
    var supportedTools: Set<String> { get }
    func process(_ result: ToolExecutionResult, iteration: Int, store: MemoryTagStore) -> TagProcessingResult
}

/// Processes file tools: read_file, read_lines, edit_file, write_file, delete_file.
struct FileToolProcessor: ToolResultProcessor {
    let supportedTools: Set<String> = ToolHandlerRegistry.allFileTools

    private typealias TN = ToolNames

    func process(_ result: ToolExecutionResult, iteration: Int, store: MemoryTagStore) -> TagProcessingResult {
        switch result.toolName {
        case TN.readFile: return store.processReadFile(result, iteration: iteration)
        case TN.readLines: return store.processReadLines(result, iteration: iteration)
        case TN.editFile: return store.processEdit(result, iteration: iteration)
        case TN.writeFile: return store.processWrite(result, iteration: iteration)
        case TN.deleteFile: return store.processDelete(result)
        default: return .passthrough
        }
    }
}

/// Processes build and git tools: run_xcodebuild, run_xcodetests, git_status, git_diff.
struct BuildGitToolProcessor: ToolResultProcessor {
    private typealias TN = ToolNames

    let supportedTools: Set<String> = ToolHandlerRegistry.xcodeTools.union([TN.gitStatus, TN.gitDiff])

    func process(_ result: ToolExecutionResult, iteration: Int, store: MemoryTagStore) -> TagProcessingResult {
        switch result.toolName {
        case TN.runXcodebuild: return store.processBuild(result, iteration: iteration)
        case TN.runXcodetests: return store.processTests(result, iteration: iteration)
        case TN.gitStatus: return store.processGitStatus(result, iteration: iteration)
        case TN.gitDiff: return store.processGitDiff(result, iteration: iteration)
        default: return .passthrough
        }
    }
}

extension MemoryTagStore {

    /// Process tool result. Returns tagged/reference/passthrough.
    func processToolResult(_ result: ToolExecutionResult, iteration: Int) -> TagProcessingResult {
        currentIteration = iteration

        for processor in processors {
            if processor.supportedTools.contains(result.toolName) {
                return processor.process(result, iteration: iteration, store: self)
            }
        }
        return .passthrough
    }
}

// MARK: - Plan Registration

extension MemoryTagStore {

    /// Register a plan update from `update_scratchpad`. Creates a tagged entry so the plan
    /// appears in MEMORIES like other resources (compact tag reference when unchanged).
    func registerPlanUpdate(content: String, iteration: Int) {
        // Use a temporary single-key map to leverage registerEntry for plan tags
        var planMap: [String: String] = currentPlanTag.map { ["plan": $0] } ?? [:]
        registerEntry(type: .plan, resource: "plan", iteration: iteration,
                      content: content, replacingIn: &planMap)
        currentPlanTag = planMap["plan"]
    }
}

// MARK: - Memories Generation

extension MemoryTagStore {

    /// Generate Memories index showing all tags and their current statuses.
    /// Returns nil when there are no tracked entries — injecting a bare
    /// header/footer every iteration is pure noise for roles that never
    /// invoked a tag-producing tool.
    func generateMemories(version: Int) -> String? {
        guard !entries.isEmpty else { return nil }

        var lines: [String] = ["=== MEMORIES v\(version) ==="]

        let grouped = Dictionary(grouping: entries.values) { $0.resource }

        for (resource, tags) in grouped.sorted(by: { $0.key < $1.key }) {
            for tag in tags.sorted(by: { $0.iteration < $1.iteration }) {
                let statusStr: String
                switch tag.status {
                case .current:
                    statusStr = "CURRENT"
                case .outdated(let reason):
                    statusStr = "OUTDATED [\(reason)]"
                case .replaced(let by):
                    statusStr = "REPLACED -> \(by)"
                }
                lines.append("\(tag.tag) \(resource) (iter \(tag.iteration)) — \(statusStr)")
            }
        }

        lines.append("=== END MEMORIES ===")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Invalidation Helpers

extension MemoryTagStore {

    func invalidateBuilds(reason: String) {
        for (key, entry) in entries where entry.type == .build && isCurrentStatus(entry.status) {
            entries[key]?.status = .outdated(reason: reason)
        }
    }

    func invalidateGit(reason: String) {
        for (key, entry) in entries where entry.type == .git && isCurrentStatus(entry.status) {
            entries[key]?.status = .outdated(reason: reason)
        }
    }

    func invalidateReadRanges(forPath path: String, reason: String) {
        let rangeKeys = currentReadTags.keys.filter { $0.hasPrefix(path + ":") }
        for key in rangeKeys {
            if let tag = currentReadTags[key] {
                entries[tag]?.status = .outdated(reason: reason)
            }
        }
    }

    func isCurrentStatus(_ status: TagStatus) -> Bool {
        if case .current = status { return true }
        return false
    }

    func currentBuildTag() -> String? {
        entries.values
            .filter { $0.type == .build && $0.resource == "build" && isCurrentStatus($0.status) }
            .first?.tag
    }

    func currentTestTag() -> String? {
        entries.values
            .filter { $0.type == .build && $0.resource == "tests" && isCurrentStatus($0.status) }
            .first?.tag
    }

    func currentGitTag(resource: String) -> String? {
        entries.values
            .filter { $0.type == .git && $0.resource == resource && isCurrentStatus($0.status) }
            .first?.tag
    }
}
