import Foundation

struct ConversationLogRenderer {
    private let dateFormatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
    }

    /// Render conversation log from network log records (same order as JSON)
    func render(records: [NetworkLogRecord]) -> String {
        var lines: [String] = []

        lines.append("# Conversation Log")
        lines.append("")
        lines.append("Generated: \(formatDate(MonotonicClock.shared.now()))")
        lines.append("")
        lines.append("---")
        lines.append("")

        if records.isEmpty {
            lines.append("_No network activity recorded._")
            return lines.joined(separator: "\n")
        }

        // Render each record in exact order from network_log.json
        for (idx, record) in records.enumerated() {
            renderRecord(index: idx + 1, record: record, lines: &lines)
        }

        return lines.joined(separator: "\n")
    }

    private func renderRecord(index: Int, record: NetworkLogRecord, lines: inout [String]) {
        let arrow = record.direction == .request ? "→" : "←"
        let label = record.direction == .request ? "Request" : "Response"
        let timeOnly = formatTimeOnly(record.createdAt)
        let stepStr = record.stepID.map { " · Step: \($0.prefix(8))" } ?? ""
        let roleStr = record.roleName.map { " · \($0)" } ?? ""

        var summaryTail = ""
        if record.direction == .response {
            let status = record.statusCode.map { " · \($0)" } ?? ""
            let dur = record.durationMs.map { " · \(String(format: "%.0f", $0))ms" } ?? ""
            let tok: String
            if let inTok = record.inputTokens, let outTok = record.outputTokens {
                tok = " · \(inTok)→\(outTok) tok"
            } else {
                tok = ""
            }
            summaryTail = status + dur + tok
        }

        lines.append("<details>")
        lines.append("<summary>\(index). \(arrow) \(label)\(roleStr)\(stepStr) · \(timeOnly)\(summaryTail)</summary>")
        lines.append("")

        lines.append("- Time: \(formatDate(record.createdAt))")
        lines.append("- Method: \(record.httpMethod)")
        if let roleName = record.roleName {
            lines.append("- Role: \(roleName)")
        }
        if let stepID = record.stepID {
            lines.append("- Step: \(stepID.prefix(8))")
        }
        lines.append("- Correlation: \(record.correlationID.uuidString.prefix(8))")

        if record.direction == .response {
            lines.append("- Status: \(record.statusCode ?? 0)")
            if let duration = record.durationMs {
                lines.append("- Duration: \(String(format: "%.1f", duration))ms")
            }
            if let inTok = record.inputTokens, let outTok = record.outputTokens {
                lines.append("- Tokens: \(inTok) in / \(outTok) out")
            }
            if let error = record.errorMessage {
                lines.append("- Error: \(error)")
            }
        }
        lines.append("")

        if let body = record.body {
            renderBody(body, isResponse: record.direction == .response, lines: &lines)
        }

        lines.append("</details>")
        lines.append("")
    }

    private func renderBody(_ body: String, isResponse: Bool, lines: inout [String]) {
        if isResponse && (body.contains("[reasoning]") || body.contains("[tool_calls]")) {
            renderStructuredResponse(body, lines: &lines)
        } else if body.hasPrefix("{") {
            renderJSONBody(body, lines: &lines)
        } else {
            let fence = codeFence(for: body)
            lines.append(fence)
            lines.append(body)
            lines.append(fence)
            lines.append("")
        }
    }

    private func renderStructuredResponse(_ body: String, lines: inout [String]) {
        // Extract reasoning
        if let reasoningRange = extractSection(from: body, tag: "reasoning") {
            let reasoning = String(body[reasoningRange])
            lines.append("> **Thinking:**")
            for line in reasoning.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
            lines.append("")
        }

        // Extract content (between tags)
        let content = body
            .replacingOccurrences(of: #"\[reasoning\][\s\S]*?\[/reasoning\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[tool_calls\][\s\S]*?\[/tool_calls\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !content.isEmpty {
            let fence = codeFence(for: content)
            lines.append(fence)
            lines.append(content)
            lines.append(fence)
            lines.append("")
        }

        // Extract tool calls
        if let toolsRange = extractSection(from: body, tag: "tool_calls") {
            let toolsJSON = String(body[toolsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("**Tool Calls:**")
            lines.append("")
            lines.append("```json")
            lines.append(toolsJSON)
            lines.append("```")
            lines.append("")
        }
    }

    private func extractSection(from text: String, tag: String) -> Range<String.Index>? {
        let startTag = "[\(tag)]"
        let endTag = "[/\(tag)]"
        guard let startRange = text.range(of: startTag),
              let endRange = text.range(of: endTag, range: startRange.upperBound..<text.endIndex)
        else { return nil }
        return startRange.upperBound..<endRange.lowerBound
    }

    private func renderJSONBody(_ body: String, lines: inout [String]) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let fence = codeFence(for: body)
            lines.append(fence + "json")
            lines.append(body)
            lines.append(fence)
            lines.append("")
            return
        }

        // LM Studio stateful format: "input" + optional "system_prompt" + optional "previous_response_id"
        if let input = json["input"] as? String {
            renderLMStudioRequest(json: json, input: input, lines: &lines)
            return
        }

        // OpenAI-style format: "messages" array
        if let messages = json["messages"] as? [[String: Any]] {
            for msg in messages {
                guard let role = msg["role"] as? String,
                      let content = msg["content"] as? String else { continue }

                lines.append("**[\(role.uppercased())]**")
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 100 && !trimmed.contains("\n") {
                    lines.append(trimmed)
                } else {
                    lines.append("")
                    let fence = codeFence(for: trimmed)
                    lines.append(fence)
                    lines.append(trimmed)
                    lines.append(fence)
                }
                lines.append("")
            }
        }

        renderToolsSection(json: json, lines: &lines)
    }

    private func renderLMStudioRequest(json: [String: Any], input: String, lines: inout [String]) {
        // Stateful continuation marker
        if let prevID = json["previous_response_id"] as? String {
            lines.append("_Stateful continuation · `\(prevID.prefix(20))...`_")
            lines.append("")
        }

        // System prompt — collapsed (can be ~3000 chars)
        if let sysPrompt = json["system_prompt"] as? String {
            lines.append("<details>")
            lines.append("<summary>[SYSTEM PROMPT] (\(sysPrompt.count) chars)</summary>")
            lines.append("")
            let preview = sysPrompt.count > 600
                ? String(sysPrompt.prefix(600)) + "\n..."
                : sysPrompt
            let fence = codeFence(for: preview)
            lines.append(fence)
            lines.append(preview)
            lines.append(fence)
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }

        // Input — full content
        lines.append("**[INPUT]**")
        lines.append("")
        let fence = codeFence(for: input)
        lines.append(fence)
        lines.append(input)
        lines.append(fence)
        lines.append("")

        renderToolsSection(json: json, lines: &lines)
    }

    private func renderToolsSection(json: [String: Any], lines: inout [String]) {
        if let tools = json["tools"] as? [[String: Any]], !tools.isEmpty {
            lines.append("**[TOOLS]** (\(tools.count) available)")
            lines.append("")
            for tool in tools {
                if let function = tool["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    let desc = (function["description"] as? String) ?? ""
                    let shortDesc = desc.count > 80 ? String(desc.prefix(80)) + "..." : desc
                    lines.append("- `\(name)`: \(shortDesc)")
                }
            }
            lines.append("")
        }
    }

    private func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func formatTimeOnly(_ date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func codeFence(for content: String) -> String {
        let maxTicks = content.split(separator: "\n").map { line -> Int in
            var count = 0, best = 0
            for ch in line { if ch == "`" { count += 1; best = max(best, count) } else { count = 0 } }
            return best
        }.max() ?? 0
        return String(repeating: "`", count: max(3, maxTicks + 1))
    }
}
