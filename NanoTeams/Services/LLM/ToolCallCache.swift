import Foundation

/// Tracks tool calls made during a step execution to cache read-only results
/// and prevent redundant network/filesystem calls.
final class ToolCallCache {

    private typealias TN = ToolNames

    struct TrackedCall {
        let toolName: String
        let argumentsSummary: String
        let resultSummary: String
        let resultJSON: String
        let timestamp: Date
        let wasSuccessful: Bool
    }

    // MARK: - Cacheable tool sets (delegated to ToolHandlerRegistry)

    static var cacheableTools: Set<String> { ToolHandlerRegistry.cacheableTools }

    // MARK: - State

    private(set) var calls: [TrackedCall] = []
    private let maxTrackedCalls: Int = LLMConstants.maxTrackedToolCalls
    private var callCounts: [String: Int] = [:]
    private var lastScratchpadContentHash: Int?

    /// Canonicalize at every ingress point so cache, invalidation, and the
    /// loop-detector fingerprints treat `repo_browser.read_file`,
    /// `functions.read_file`, and `read_file` as one and the same call.
    private func canonical(_ toolName: String) -> String {
        ToolRegistry.resolveToolName(toolName)
    }

    // MARK: - Recording

    func record(toolName: String, argumentsJSON: String, resultJSON: String, isError: Bool) {
        let toolName = canonical(toolName)
        if toolName == ToolNames.updateScratchpad, !isError {
            if let dict = ToolCallDataUtils.parseJSON(argumentsJSON),
               let content = resolveContentString(dict) {
                let contentHash = content.hashValue
                if contentHash == lastScratchpadContentHash { return }
                lastScratchpadContentHash = contentHash
            }
        }

        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        let resultSummary = ToolCallSummarizer.summarizeResult(toolName: toolName, json: resultJSON)

        calls.append(TrackedCall(
            toolName: toolName,
            argumentsSummary: argSummary,
            resultSummary: resultSummary,
            resultJSON: resultJSON,
            timestamp: MonotonicClock.shared.now(),
            wasSuccessful: !isError
        ))

        let callKey = "\(toolName):\(argSummary)"
        callCounts[callKey, default: 0] += 1

        if !isError {
            let affectedPath = ToolCallDataUtils.extractPath(from: argumentsJSON)
            invalidateCacheAfterWrite(toolName: toolName, affectedPath: affectedPath)
        }

        if calls.count > maxTrackedCalls {
            calls.removeFirst(calls.count - maxTrackedCalls)
        }
    }

    // MARK: - Cache Invalidation

    func invalidateCacheAfterWrite(toolName: String, affectedPath: String? = nil) {
        let toolName = canonical(toolName)
        let fileReadTools = ToolHandlerRegistry.fileReadTools
        let fileWriteTools = ToolHandlerRegistry.fileWriteTools
        let gitReadTools = ToolHandlerRegistry.gitReadTools
        let gitWriteTools = ToolHandlerRegistry.gitWriteTools

        if fileWriteTools.contains(toolName) {
            if let path = affectedPath {
                calls.removeAll { fileReadTools.contains($0.toolName) && $0.argumentsSummary.contains(path) }
                let parent = (path as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    calls.removeAll {
                        $0.toolName == TN.listFiles &&
                        ($0.argumentsSummary == parent ||
                         $0.argumentsSummary.contains(parent) ||
                         parent.hasPrefix($0.argumentsSummary))
                    }
                }
            } else {
                calls.removeAll { fileReadTools.contains($0.toolName) }
            }
            calls.removeAll { gitReadTools.contains($0.toolName) }
            removeCallCounts(for: gitReadTools)
        }

        if gitWriteTools.contains(toolName) {
            calls.removeAll { gitReadTools.contains($0.toolName) }
            removeCallCounts(for: gitReadTools)
        }
    }

    // MARK: - Cache Lookup

    func recentCalls(limit: Int) -> [TrackedCall] {
        Array(calls.suffix(limit))
    }

    func wasAlreadyCalled(toolName: String, argumentsJSON: String) -> TrackedCall? {
        let toolName = canonical(toolName)
        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        return calls.first { $0.toolName == toolName && $0.argumentsSummary == argSummary && $0.wasSuccessful }
    }

    func getCachedResultIfRedundant(toolName: String, argumentsJSON: String) -> String? {
        let toolName = canonical(toolName)
        guard Self.cacheableTools.contains(toolName) else { return nil }
        guard let cached = wasAlreadyCalled(toolName: toolName, argumentsJSON: argumentsJSON) else { return nil }

        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        let callKey = "\(toolName):\(argSummary)"
        let count = callCounts[callKey, default: 0]

        if var dict = ToolCallDataUtils.parseJSON(cached.resultJSON) {
            dict["_cached"] = true
            dict["_cache_hint"] = count >= 3
                ? "CACHED (call #\(count + 1)). You've checked this \(count) times already. The data has not changed. Move forward with your task."
                : "Cached response. Data unchanged since previous call."

            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        return cached.resultJSON
    }

    func getCallCount(toolName: String, argumentsJSON: String) -> Int {
        let argSummary = ToolCallSummarizer.summarizeArguments(toolName: toolName, json: argumentsJSON)
        return callCounts["\(toolName):\(argSummary)", default: 0]
    }

    // MARK: - Private

    private func removeCallCounts(for toolNames: Set<String>) {
        for key in callCounts.keys where toolNames.contains(key.split(separator: ":").first.map(String.init) ?? "") {
            callCounts.removeValue(forKey: key)
        }
    }
    nonisolated deinit {}
}
