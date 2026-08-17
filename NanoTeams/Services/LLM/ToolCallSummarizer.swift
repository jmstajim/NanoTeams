import Foundation

/// Generates compact human-readable summaries of tool arguments and results.
/// Used by ToolCallTracker for tracked-call display.
/// OCP: dictionary-based dispatch — add new tools by adding entries, not modifying switches.
nonisolated enum ToolCallSummarizer {

    private typealias TN = ToolNames

    // MARK: - Argument Summarization

    /// Longest a free-text fragment may occupy on the card. The row is one line with
    /// middle truncation, so a longer string costs width without adding identity —
    /// the full value is one tap away in `ActivityDetailWindow.toolCall`.
    private static let freeTextLimit = 40

    /// Shared truncation. New entries use `…`; the four older ones spell it `...` and
    /// are pinned that way by `ToolCallSummarizerTests`, so they are left alone rather
    /// than churning a pinned string for cosmetics.
    private static func clip(_ text: String?, _ limit: Int = freeTextLimit) -> String {
        guard let text else { return "" }
        let squashed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return squashed.count > limit ? String(squashed.prefix(limit)) + "…" : squashed
    }

    /// `#7` — how every task-addressing tool names its subject. Read through
    /// `optionalInt`, the SAME coercion the handlers use, so a string-encoded
    /// `{"task_id":"7"}` the handler accepts does not read as an unaddressed call.
    private static func taskRef(_ dict: [String: Any], _ key: String = "task_id") -> String {
        guard let id = optionalInt(dict, key) else { return "" }
        return "#\(id)"
    }

    /// Space-joins the parts that survived, dropping empties — so an absent optional
    /// leaves no double space and an all-absent call yields "" (renders nothing).
    private static func parts(_ values: String?...) -> String {
        values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated(unsafe) private static let argumentSummarizers: [String: ([String: Any]) -> String] = {
        let pathExtractor: ([String: Any]) -> String = { ($0["path"] as? String) ?? "?" }
        return [
            TN.readFile: pathExtractor,
            TN.writeFile: pathExtractor,
            // Bounds resolved via `optionalInt` — the SAME coercion the handler uses,
            // so a string-encoded range ({"start_line":"501"}) the handler reads does
            // not collapse the summary to the bare path and make successive pages of a
            // paginated read look like one repeated call ON THE CARD.
            // (This entry predates the identity split and its comment used to say the
            // summary WAS the loop-detector's key. It is not, and has not been since
            // `TrackedCall.argumentsIdentity` — canonical arguments JSON — took that
            // job; see the header note. Matching the handler's coercion is still right,
            // for the display reason above.)
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
            // Same reasoning as `readLines` above, one tool over: a bare path made every
            // edit to a given file look like the same call. The anchor is what
            // distinguishes them ON THE CARD. (Historical note, same as above: this
            // comment used to claim the summary was the loop-detector's identity key.
            // It is not — `argumentsIdentity` is.)
            //
            // Shown only when the edit FAILED. A successful edit answers the more useful
            // question — WHERE it landed — from its result envelope, via
            // `resultSummarizers`; the anchor is not news once it matched. The card
            // picks between the two on `call.isError`; see `ToolCallItemView`.
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
                // The handler accepts four spellings (`GitWriteHandlers`: paths / files /
                // path / file, a bare string coercing to a one-element list). Reading only
                // `paths` meant a model that staged with `{"file": "A.swift"}` — a shape
                // the handler acts on — got the literal word "files" and no filename.
                guard let paths = firstStringArray(dict, ["paths", "files", "path", "file"]),
                      !paths.isEmpty
                else { return "files" }
                return paths.count == 1 ? paths[0] : "\(paths.count) files"
            },
            TN.gitBranch: { dict in
                // `action` is required by the schema and inverts the meaning: `create` and
                // `delete` on one name are opposite outcomes, and the card showed only the
                // name for both. `new_name` is what a rename is FOR, so it earns its place.
                parts(
                    extractString(dict, "action"),
                    extractString(dict, "name") ?? "?",
                    extractString(dict, "new_name").map { "→ \($0)" }
                )
            },
            TN.gitCommit: { dict in
                // `extractString`, not `as? String`: the handler reads this through
                // `requiredString`, which recovers the value from a stringified
                // `__raw_input__` blob. A model that sent its whole call as one string —
                // the shape `ToolRuntime` repairs into `__raw_input__` — committed
                // successfully and left the card blank.
                let msg = extractString(dict, "message") ?? ""
                return msg.count > 30 ? String(msg.prefix(30)) + "..." : msg
            },
            // `run_xcodebuild` / `run_xcodetests` deliberately have NO entry. They took one
            // for years and it could never fire: both schemas are `JS.object(properties: [:])`
            // (XcodeHandlers.swift:13, :60) and the scheme is resolved from `settings.json` by
            // `XcodeBuildRunner.resolveSchemes`, never from an argument — so the old
            // `dict["scheme"]` extractor read a key no caller can send. An entry that cannot
            // fire is worse than none: it reads as covered. They are zero-argument tools and
            // are listed as such in `toolsWithoutArgumentSummary`.
            TN.updateScratchpad: { dict in
                let content = resolveContentString(dict) ?? ""
                return content.count > 40 ? String(content.prefix(40)) + "..." : content
            },
            // `create_artifact` has no entry by design — see `toolsWithoutArgumentSummary`.
            TN.analyzeImage: pathExtractor,
            // Both read through `extractString` for the same reason as `git_commit`: their
            // handlers use `requiredString`, so a `__raw_input__`-wrapped call consults the
            // teammate and left the card blank.
            TN.askTeammate: { dict in
                guard let id = extractString(dict, "teammate") else { return "" }
                return Role.builtInRole(for: id)?.displayName ?? id
            },
            TN.requestChanges: { dict in
                guard let id = extractString(dict, "target_role") else { return "" }
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
                // Three shapes reach this card, and reading only the first left the two
                // commonest blank:
                //  1. `team_config` as an object — the model called the tool properly.
                //  2. `team_config` as a STRING of JSON — `CreateTeamTool` accepts it
                //     (`GeneratedTeamHandlers`), so the team is built and the card was bare.
                //  3. `{"task": "<brief>"}` — the synthetic placeholder card that
                //     `TeamGenerationEnvelopes.makeGenerationArgsJSON` writes while
                //     generation is in flight. It never carries `team_config` at all, so
                //     the spinner row showed nothing about what was being generated.
                if let name = teamConfigName(dict) { return name }
                return clip(extractString(dict, "task"))
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
                // `extractString` on both, matching the handler (`extractString` for
                // `team_id`, `requiredString` for `task_brief`) — a strict cast turned a
                // delegation the handler had already dispatched into a bare "?".
                let teamID = extractString(dict, "team_id") ?? ""
                let brief = extractString(dict, "task_brief") ?? ""
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

            // MARK: Delegation follow-ups
            //
            // All three address a child by id, which is the whole question the card has to
            // answer — a role juggling two delegations sees `#12` vs `#13`, not two
            // identical `$ resume_delegation` rows.
            TN.cancelDelegation: { dict in
                parts(taskRef(dict, "child_task_id"), clip(extractString(dict, "reason")))
            },
            TN.resumeDelegation: { taskRef($0, "child_task_id") },
            TN.forwardToTeam: { dict in
                parts(taskRef(dict, "child_task_id"), clip(extractString(dict, "message")))
            },

            // MARK: Autovisor
            //
            // The manager's ten tools shipped with no entries at all, so its whole review
            // pass rendered as a column of bare `$ task_status` / `$ control_task` rows —
            // every call in a pass looking identical to every other. `task_id` is the
            // subject of eight of the ten, and the verb is the subject of the two that
            // carry one.
            //
            // `list_tasks` and `wait_for_events` are deliberately absent: their schemas are
            // `properties: [:]`, so there is nothing to say. See `toolsWithoutArgumentSummary`.
            TN.taskStatus: { taskRef($0) },
            TN.createManagedTask: { clip(extractString($0, "title")) },
            TN.controlTask: { dict in
                // The verb, not the id, is what distinguishes a pause from a delete —
                // but both are needed: the manager acts on several tasks per pass.
                parts(taskRef(dict), extractString(dict, "action"))
            },
            TN.manageRole: { dict in
                // The role id is shown RAW and never resolved through `resolveRoleName`.
                // That closure resolves against the team being VIEWED, which on the
                // Autovisor board is the manager's own single-role team — it would answer
                // with the wrong role's display name, or fall back to the id having
                // spent a lookup. The id belongs to the MANAGED task's team, which this
                // layer cannot see.
                parts(taskRef(dict), extractString(dict, "action"), extractString(dict, "role_id"))
            },
            TN.answerTaskQuestion: { dict in
                parts(taskRef(dict), clip(extractString(dict, "answer")))
            },
            TN.messageTask: { dict in
                parts(taskRef(dict), clip(extractString(dict, "message")))
            },
            TN.scheduleTask: { dict in
                // `0` clears the schedule (AutovisorHandlers), so it is not "every 0m".
                guard let minutes = optionalInt(dict, "interval_minutes") else { return taskRef(dict) }
                return parts(taskRef(dict), minutes <= 0 ? "off" : "every \(minutes)m")
            },
            TN.setWorkFolderContext: { clip(resolveContentString($0)) },

            // MARK: Supervisor / collaboration
            TN.askSupervisor: { clip(extractString($0, "question")) },
            TN.concludeMeeting: { clip(extractString($0, "decision")) },

            // MARK: Git — read
            //
            // `git_status` has no entry on purpose (zero-argument schema).
            TN.gitBranchList: { optionalBool($0, "all") ? "all" : "" },
            TN.gitLog: { dict in
                parts(
                    optionalInt(dict, "max").map { "-\($0)" },
                    optionalBool(dict, "oneline") ? "oneline" : nil,
                    pathScope(dict)
                )
            },
            TN.gitDiff: { dict in
                parts(
                    optionalBool(dict, "cached") ? "cached" : nil,
                    pathScope(dict)
                )
            },

            // MARK: Git — write
            TN.gitPull: { dict in
                let remote = extractString(dict, "remote")
                let branch = extractString(dict, "branch")
                let target: String?
                switch (remote, branch) {
                case let (r?, b?): target = "\(r)/\(b)"
                case let (r?, nil): target = r
                case let (nil, b?): target = b
                case (nil, nil): target = nil
                }
                return parts(target, optionalBool(dict, "rebase") ? "rebase" : nil)
            },
            TN.gitStash: { dict in
                // `action` is required by the schema and IS the call's identity —
                // a `pop` and a `drop` are opposite outcomes under one tool name.
                parts(
                    extractString(dict, "action"),
                    optionalInt(dict, "index").map { "\($0)" },
                    clip(extractString(dict, "message"))
                )
            },
            TN.gitMerge: { dict in
                parts(
                    extractString(dict, "branch") ?? "?",
                    optionalBool(dict, "squash") ? "squash" : nil,
                    optionalBool(dict, "no_ff") ? "no-ff" : nil
                )
            },

            // MARK: Shell
            TN.bashOutput: { dict in
                // The id is opaque and long; its tail is enough to tell two background
                // commands apart, and `stop` is worth showing because it is irreversible.
                let id = extractString(dict, "command_id").map { String($0.suffix(8)) }
                let action = extractString(dict, "action")
                return parts(id, action == "stop" ? "stop" : nil)
            },
        ]
    }()

    /// Shared by `git_log` / `git_diff`: one path reads better as itself, several as a count.
    /// Both handlers accept the array under `paths`.
    private static func pathScope(_ dict: [String: Any]) -> String? {
        guard let paths = optionalStringArray(dict, "paths"), !paths.isEmpty else { return nil }
        return paths.count == 1 ? paths[0] : "\(paths.count) paths"
    }

    /// First alias that yields a usable list — the read-only mirror of the handlers'
    /// `requiredStringArray(_:aliases:)`, so the card resolves the same key the tool did.
    private static func firstStringArray(_ dict: [String: Any], _ aliases: [String]) -> [String]? {
        for key in aliases {
            if let value = optionalStringArray(dict, key), !value.isEmpty { return value }
        }
        return nil
    }

    /// `team_config.name`, whether the config arrived as an object or as a JSON string.
    private static func teamConfigName(_ dict: [String: Any]) -> String? {
        func name(in config: [String: Any]) -> String? {
            (config["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let config = dict["team_config"] as? [String: Any] { return name(in: config) }
        guard let raw = dict["team_config"] as? String,
              let config = ToolCallDataUtils.parseJSON(raw)
        else { return nil }
        return name(in: config)
    }

    /// The tools that render with NO argument text, and why each is allowed to.
    ///
    /// This is the OTHER half of `argumentSummarizers`: together they must cover
    /// `ToolNames.allNames` exactly, which `ToolCallSummarizerCoveragePinTests` enforces.
    /// Without that pin a new tool joins the roster with no summary and nobody notices —
    /// which is exactly how all ten Autovisor tools, both Xcode runners and seven git
    /// tools came to render as a bare `$ name`, for months, across the activity feed AND
    /// every exported `conversation_log.md`.
    ///
    /// Membership requires one of two justifications, and "nobody wrote one yet" is
    /// neither:
    ///
    /// - **Zero-argument schema** — there is nothing to summarize. `list_tasks`,
    ///   `wait_for_events`, `git_status`, `run_xcodebuild`, `run_xcodetests` all declare
    ///   `JS.object(properties: [:])`.
    /// - **Already on screen** — the feed draws the same fact as its own item one row
    ///   later, and a second copy is noise. `create_artifact`'s name arrives as a
    ///   dedicated `.artifact` card (`ActivityFeedBuilder`), so the tool row would state
    ///   it twice. Same argument the tool card uses for not restating a failure reason
    ///   that its own detail window already carries in full.
    static let toolsWithoutArgumentSummary: Set<String> = [
        TN.listTasks,
        TN.waitForEvents,
        TN.gitStatus,
        TN.runXcodebuild,
        TN.runXcodetests,
        TN.createArtifact,
    ]

    /// Whether `toolName` is expected to produce argument text. Exposed for the coverage
    /// pin — the dictionary itself stays private so no caller can grow a second opinion
    /// about what a summary is.
    static func hasArgumentSummarizer(for toolName: String) -> Bool {
        argumentSummarizers[toolName] != nil
    }

    static func summarizeArguments(toolName: String, json: String, resolveRoleName: ((String) -> String)? = nil) -> String {
        guard let dict = ToolCallDataUtils.parseJSON(json) else { return "?" }

        // Role-aware summarizers (prefer resolved names when available).
        //
        // Deliberately only these two. Both address a role in the team being VIEWED, which
        // is what `resolveRoleName` can answer. `manage_role` also carries a `role_id` and
        // is deliberately absent: its role belongs to the MANAGED task's team, so resolving
        // it against the viewed team would answer with a different team's role name.
        if let resolve = resolveRoleName {
            switch toolName {
            case TN.askTeammate:
                if let id = extractString(dict, "teammate") { return resolve(id) }
            case TN.requestChanges:
                if let id = extractString(dict, "target_role") { return resolve(id) }
            default: break
            }
        }

        return argumentSummarizers[toolName]?(dict) ?? ""
    }

    // MARK: - Card Summary

    /// The single line of argument text a tool card shows next to the tool name.
    ///
    /// This is `summarizeArguments` for 49 of the 50 tools, and exists for the one where the
    /// most useful thing to show is not in the arguments at all.
    ///
    /// A successful `edit_file` is anchored by TEXT, so its arguments can only answer "what
    /// did you search for" — a question already settled by the fact that it matched. The
    /// open question is WHERE it landed, and that is known only after the splice, in the
    /// result envelope. So a successful edit shows `path 42-51` and a failed one keeps
    /// `path ‹anchor›`, where the anchor is exactly what did not match and therefore the
    /// only useful thing on the row.
    ///
    /// This does not re-open the argument the `resultIndicator` doc comment settles when it
    /// refuses to put failure text on the card. That text was a CONSTANT keyed on the error
    /// code, so a role stuck on one rejection produced a column of identical paragraphs and
    /// the constant earned no permanent space. A line range is the opposite: a per-call fact
    /// that differs on every row, and is the row's identity when a role edits one file
    /// repeatedly — which is the shape that motivated the anchor in the first place.
    static func cardSummary(
        toolName: String,
        argumentsJSON: String,
        resultJSON: String?,
        isError: Bool,
        resolveRoleName: ((String) -> String)? = nil
    ) -> String {
        if toolName == TN.editFile, !isError, let resultJSON,
           let span = editedLineSpan(resultJSON) {
            let path = editedPath(resultJSON)
                ?? ToolCallDataUtils.parseJSON(argumentsJSON).flatMap { extractString($0, "path") }
                ?? "?"
            // Under `replace_all` the pair is a BOUNDING span over N scattered regions, not
            // one contiguous run — `12-412` alone would read as four hundred changed lines.
            // The count is already in the envelope, so honesty costs no new field.
            let count = editedReplacementCount(resultJSON)
            return count > 1 ? "\(path) \(span) ×\(count)" : "\(path) \(span)"
        }
        return summarizeArguments(
            toolName: toolName, json: argumentsJSON, resolveRoleName: resolveRoleName)
    }

    /// `42-51`, or `42` when the change sits on one line. Nil when the handler reported no
    /// span — a byte-level no-op edit, where pointing at a line would contradict the
    /// envelope's own "the edit left the file unchanged" warning, so the caller falls back
    /// to the anchor.
    private static func editedLineSpan(_ resultJSON: String) -> String? {
        guard let data = ToolCallDataUtils.parseJSON(resultJSON)?["data"] as? [String: Any],
              let start = data["start_line"] as? Int,
              let end = data["end_line"] as? Int
        else { return nil }
        return start == end ? "\(start)" : "\(start)-\(end)"
    }

    private static func editedReplacementCount(_ resultJSON: String) -> Int {
        guard let data = ToolCallDataUtils.parseJSON(resultJSON)?["data"] as? [String: Any],
              let count = data["replacements_made"] as? Int
        else { return 1 }
        return count
    }

    private static func editedPath(_ resultJSON: String) -> String? {
        guard let data = ToolCallDataUtils.parseJSON(resultJSON)?["data"] as? [String: Any],
              let path = data["path"] as? String, !path.isEmpty
        else { return nil }
        return path
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
