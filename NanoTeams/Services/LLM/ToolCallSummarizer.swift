import Foundation

/// Generates compact human-readable summaries of tool arguments and results.
/// Used by ToolCallTracker for tracked-call display.
/// OCP: dictionary-based dispatch — add new tools by adding entries, not modifying switches.
nonisolated enum ToolCallSummarizer {

    private typealias TN = ToolNames

    // MARK: - Argument Summarization

    nonisolated(unsafe) private static let argumentSummarizers: [String: ([String: Any]) -> String] = {
        let pathExtractor: ([String: Any]) -> String = { ($0["path"] as? String) ?? "?" }
        let schemeExtractor: ([String: Any]) -> String = { dict in
            if let scheme = dict["scheme"] as? String { return "scheme: \(scheme)" }
            return ""
        }
        return [
            TN.readFile: pathExtractor,
            TN.writeFile: pathExtractor,
            // Bounds resolved via `optionalInt` — the SAME coercion the handler
            // uses, so a string-encoded range ({"start_line":"501"}) the handler
            // reads doesn't collapse the summary (and thus the loop-detector
            // identity key) to the bare path, counting successive pages of a
            // paginated read as one repeated call.
            TN.readLines: { dict in
                let path = (dict["path"] as? String) ?? "?"
                let start = optionalInt(dict, "start_line")
                let end = optionalInt(dict, "end_line")
                if let s = start, let e = end { return "\(path) \(s):\(e)" }
                if let s = start { return "\(path) \(s):" }
                if let e = end { return "\(path) :\(e)" }
                return path
            },
            TN.deleteFile: pathExtractor,
            // Same reasoning as `readLines` above, one tool over: the summary IS
            // the loop-detector's identity key, so the bare path made every edit
            // to a given file look like the same call. An honest sequence of
            // different edits to one file — the normal way a role works — read
            // as a repeat and got interrupted. The anchor is what distinguishes
            // them, and it is also the most useful thing to show on the card.
            TN.editFile: { dict in
                let path = (dict["path"] as? String) ?? "?"
                guard let anchor = optionalString(dict, "old_text"),
                      !anchor.isEmpty
                else { return path }
                let squashed = anchor.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !squashed.isEmpty else { return path }
                return "\(path) ‹\(squashed.prefix(32))›"
            },
            TN.listFiles: { dict in
                let raw = (dict["path"] as? String) ?? "."
                let path = raw.isEmpty ? "." : raw
                if let depth = optionalInt(dict, "depth") { return "\(path) depth:\(depth)" }
                return path
            },
            TN.search: { dict in
                let query = (dict["query"] as? String) ?? "?"
                if let paths = optionalStringArray(dict, "paths"), !paths.isEmpty {
                    return "\"\(query)\" in \(paths.count) paths"
                }
                return "\"\(query)\""
            },
            TN.bash: { dict in
                // Resolve via the same single-source helper the gate + handler use,
                // so the card shows exactly the command that runs (honors alias keys).
                guard let command = BashArguments.command(from: dict) else { return "" }
                // Collapse newlines/runs of whitespace so a multi-line command reads
                // as one scannable line; the card middle-truncates the visible portion.
                return command
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            },
            TN.gitCheckout: { ($0["branch"] as? String) ?? "?" },
            TN.gitAdd: { dict in
                if let paths = optionalStringArray(dict, "paths"), !paths.isEmpty {
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
                let count = optionalStringArray(dict, "participants")?.count ?? 0
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
            // Computer-use tools MUST summarize their distinguishing arguments: the summary is
            // also `ToolCallTracker`'s identity key for loop detection. With no entry it
            // collapsed to "" — clicks at DIFFERENT coordinates counted as "identical
            // arguments" and the loop nudge misfired with the wrong advice (observed: 4
            // distinct clicks flagged as a loop after 4 calls).
            TN.screenCapture: { dict in
                let target = (dict["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "screen"
                if let title = dict["window_title"] as? String, !title.isEmpty {
                    return "\(target) · \(title)"
                }
                return target
            },
            // Coordinates resolved via `optionalInt` — the SAME coercion the handler/gate use, so
            // a fractional NSNumber ({"x":834.5}) the handler truncates-and-runs doesn't collapse
            // the summary (and thus the loop-detector identity key) to "?" and re-open the
            // distinct-clicks-flagged-as-identical misfire this whole entry exists to prevent.
            TN.uiClick: { dict in
                guard let x = optionalInt(dict, "x"), let y = optionalInt(dict, "y") else { return "?" }
                var parts = ["(\(x), \(y))"]
                if (dict["button"] as? String)?.lowercased() == "right" { parts.append("right") }
                if optionalBool(dict, "double") { parts.append("double") }
                if let target = dict["target"] as? String, !target.isEmpty { parts.append("→ \(target)") }
                return parts.joined(separator: " ")
            },
            TN.uiType: { dict in
                let text = (dict["text"] as? String) ?? resolveContentString(dict) ?? ""
                return text.count > 60 ? String(text.prefix(60)) + "…" : text
            },
            TN.uiKey: { ($0["keys"] as? String) ?? ($0["key"] as? String) ?? "?" },
            TN.uiScroll: { dict in
                guard let x = optionalInt(dict, "x"), let y = optionalInt(dict, "y") else { return "?" }
                let dx = optionalInt(dict, "dx") ?? 0
                let dy = optionalInt(dict, "dy") ?? 0
                return "(\(x), \(y)) d(\(dx), \(dy))"
            },
            TN.delegateToTeam: { dict in
                let teamID = (dict["team_id"] as? String) ?? ""
                let brief = (dict["task_brief"] as? String) ?? ""
                let teamLabel: String
                if teamID == DelegationConstants.generatedTeamSentinel {
                    teamLabel = "Generated"
                } else if teamID.isEmpty {
                    teamLabel = "?"
                } else {
                    // Surface only the trailing component of the UUID-like id so the
                    // chip stays scannable; full id is available in the expanded view.
                    teamLabel = String(teamID.suffix(8))
                }
                let trimmedBrief = brief.count > 60 ? String(brief.prefix(60)) + "…" : brief
                if trimmedBrief.isEmpty { return teamLabel }
                return "\(teamLabel) · \(trimmedBrief)"
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

    nonisolated(unsafe) private static let resultSummarizers: [String: ([String: Any]) -> String] = [
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
            if let data = dict["data"] as? [String: Any],
               let end = data["end_line"] as? Int,
               let total = data["total_lines"] as? Int {
                return end < total ? "lines 1–\(end) of \(total)" : "\(total) lines"
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
