import Foundation

/// Generates compact human-readable summaries of tool arguments and results.
/// Used by ToolCallCache for tracked call display and dedup keys.
/// OCP: dictionary-based dispatch — add new tools by adding entries, not modifying switches.
enum ToolCallSummarizer {

    private typealias TN = ToolNames

    // MARK: - Argument Summarization

    private static let argumentSummarizers: [String: ([String: Any]) -> String] = {
        let pathExtractor: ([String: Any]) -> String = { ($0["path"] as? String) ?? "?" }
        let schemeExtractor: ([String: Any]) -> String = { dict in
            if let scheme = dict["scheme"] as? String { return "scheme: \(scheme)" }
            return ""
        }
        return [
            TN.readFile: pathExtractor,
            TN.writeFile: pathExtractor,
            TN.readLines: { dict in
                let path = (dict["path"] as? String) ?? "?"
                let start = dict["start_line"] as? Int
                let end = dict["end_line"] as? Int
                if let s = start, let e = end { return "\(path) \(s):\(e)" }
                if let s = start { return "\(path) \(s):" }
                if let e = end { return "\(path) :\(e)" }
                return path
            },
            TN.deleteFile: pathExtractor,
            TN.editFile: pathExtractor,
            TN.listFiles: { dict in
                let raw = (dict["path"] as? String) ?? "."
                let path = raw.isEmpty ? "." : raw
                if let depth = dict["depth"] as? Int { return "\(path) depth:\(depth)" }
                return path
            },
            TN.search: { dict in
                let query = (dict["query"] as? String) ?? "?"
                if let paths = dict["paths"] as? [String], !paths.isEmpty {
                    return "\"\(query)\" in \(paths.count) paths"
                }
                return "\"\(query)\""
            },
            TN.gitCheckout: { ($0["branch"] as? String) ?? "?" },
            TN.gitAdd: { dict in
                if let paths = dict["paths"] as? [String], !paths.isEmpty {
                    return paths.count == 1 ? paths[0] : "\(paths.count) files"
                }
                return "files"
            },
            TN.gitBranch: { ($0["name"] as? String) ?? "?" },
            TN.gitCommit: { dict in
                let msg = (dict["message"] as? String) ?? ""
                return msg.count > 30 ? String(msg.prefix(30)) + "..." : msg
            },
            TN.runXcodebuild: schemeExtractor,
            TN.runXcodetests: schemeExtractor,
            TN.updateScratchpad: { dict in
                let content = resolveContentString(dict) ?? ""
                return content.count > 40 ? String(content.prefix(40)) + "..." : content
            },
            TN.createArtifact: { _ in "" },
            TN.analyzeImage: pathExtractor,
            TN.askTeammate: { dict in
                guard let id = dict["teammate"] as? String else { return "" }
                return Role.builtInRole(for: id)?.displayName ?? id
            },
            TN.requestChanges: { dict in
                guard let id = dict["target_role"] as? String else { return "" }
                return Role.builtInRole(for: id)?.displayName ?? id
            },
            TN.requestTeamMeeting: { dict in
                let topic = (dict["topic"] as? String) ?? ""
                let count = (dict["participants"] as? [String])?.count ?? 0
                if topic.isEmpty { return count > 0 ? "\(count) participants" : "" }
                let trimmed = topic.count > 40 ? String(topic.prefix(40)) + "..." : topic
                return count > 0 ? "\(trimmed) · \(count)" : trimmed
            },
            TN.createTeam: { dict in
                if let config = dict["team_config"] as? [String: Any],
                   let name = config["name"] as? String {
                    return name
                }
                return ""
            },
        ]
    }()

    static func summarizeArguments(toolName: String, json: String, resolveRoleName: ((String) -> String)? = nil) -> String {
        guard let dict = ToolCallDataUtils.parseJSON(json) else { return "?" }

        // Role-aware summarizers (prefer resolved names when available)
        if let resolve = resolveRoleName {
            switch toolName {
            case TN.askTeammate:
                if let id = dict["teammate"] as? String { return resolve(id) }
            case TN.requestChanges:
                if let id = dict["target_role"] as? String { return resolve(id) }
            default: break
            }
        }

        return argumentSummarizers[toolName]?(dict) ?? ""
    }

    // MARK: - Result Summarization

    private static let resultSummarizers: [String: ([String: Any]) -> String] = [
        TN.gitStatus: { dict in
            if let data = dict["data"] as? [String: Any] {
                let branch = (data["branch"] as? String) ?? "?"
                let clean = (data["clean"] as? Bool) ?? false
                return clean ? "clean on \(branch)" : "dirty on \(branch)"
            }
            return "ok"
        },
        TN.gitBranchList: { _ in "ok" },
        TN.runXcodebuild: { dict in
            if let data = dict["data"] as? [String: Any] {
                let success = (data["success"] as? Bool) ?? false
                let errors = (data["error_count"] as? Int) ?? 0
                return success ? "success" : "failed (\(errors) errors)"
            }
            return "ok"
        },
        TN.gitCommit: { _ in "committed" },
        TN.gitMerge: { _ in "merged" },
        TN.readFile: { dict in
            if let data = dict["data"] as? [String: Any] {
                let size = (data["size"] as? Int) ?? 0
                return "\(size) bytes"
            }
            return "ok"
        },
    ]

    static func summarizeResult(toolName: String, json: String) -> String {
        guard let dict = ToolCallDataUtils.parseJSON(json) else { return "parse error" }

        if let error = dict["error"] as? [String: Any], let message = error["message"] as? String {
            return "error: \(message.prefix(50))"
        }

        if let summarizer = resultSummarizers[toolName] {
            return summarizer(dict)
        }

        if let ok = dict["ok"] as? Bool { return ok ? "ok" : "failed" }
        return "ok"
    }
}
