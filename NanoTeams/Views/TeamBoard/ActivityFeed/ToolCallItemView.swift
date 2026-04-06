import SwiftUI

/// Renders a single tool call card with expandable arguments and result.
struct ToolCallItemView: View {
    let call: StepToolCall
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    let teamRoles: [TeamRoleDefinition]
    var onAvatarTap: (() -> Void)? = nil
    @Binding var toolCallsExpanded: Set<UUID>

    // MARK: - Derived

    private var roleName: String { roleDefinition?.name ?? role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? role.tintColor }

    private var isExpanded: Bool { toolCallsExpanded.contains(call.id) }

    private static let customSummaryTools: Set<String> = [
        ToolNames.requestTeamMeeting,
    ]
    private var hasCustomSummary: Bool { Self.customSummaryTools.contains(call.name) }

    private var statusColor: Color {
        if call.resultJSON == nil || call.isAnalyzing { return Colors.info }
        return call.isError == true ? Colors.error : Colors.success
    }

    // MARK: - Body

    private static let noHeaderLeading: CGFloat = ActivityCardTokens.avatarSize + ActivityCardTokens.cardPadding

    var body: some View {
        if showHeader {
            HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
                ActivityFeedRoleAvatar(role: role, roleDefinition: roleDefinition, onTap: onAvatarTap)

                VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                    HStack(spacing: 6) {
                        Text(roleName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tintColor)
                        Spacer()
                        Text(call.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    toolCard
                }
            }
        } else {
            toolCard
                .padding(.leading, Self.noHeaderLeading)
        }
    }

    // MARK: - Tool Card

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
            HStack(spacing: Spacing.s) {
                statusIcon
                Text(call.name)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if !hasCustomSummary {
                    let argSummary = ToolCallSummarizer.summarizeArguments(
                        toolName: call.name, json: call.argumentsJSON,
                        resolveRoleName: { teamRoles.roleName(for: $0) }
                    )
                    if !argSummary.isEmpty {
                        Text(argSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            callSummary

            if isExpanded {
                callDetails
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    toolCallsExpanded.remove(call.id)
                } else {
                    toolCallsExpanded.insert(call.id)
                }
            }
        }
    }

    private static let statusIconSize: CGFloat = 14

    @ViewBuilder
    private var statusIcon: some View {
        Group {
            if call.resultJSON == nil || call.isAnalyzing {
                NTMSLoader(.inline)
            } else if call.isError == true {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Colors.error)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Colors.success)
            }
        }
        .frame(width: Self.statusIconSize, height: Self.statusIconSize)
    }

    @ViewBuilder
    private var callSummary: some View {
        ToolCallCustomSummaryView(toolName: call.name, argumentsJSON: call.argumentsJSON)
    }

    private var callDetails: some View {
        let displayArgs = call.argumentsJSON.count > 500
            ? String(call.argumentsJSON.prefix(500)) + "\n... [content truncated]"
            : call.argumentsJSON

        return VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    Text(formattedJSON(displayArgs))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: ActivityCardTokens.toolArgsMaxHeight)
                .padding(Spacing.s)
                .background(Colors.surfaceOverlay)
                .clipShape(RoundedRectangle(cornerRadius: ActivityCardTokens.innerCornerRadius, style: .continuous))
            }

            if let result = call.resultJSON {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Result").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        if call.isError == true {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Colors.error)
                                .font(.caption2)
                        }
                    }
                    ScrollView {
                        Text(formattedJSON(result))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: ActivityCardTokens.toolResultMaxHeight)
                    .padding(Spacing.s)
                    .background(
                        call.isError == true ? Colors.errorTint : Colors.surfaceOverlay
                    )
                    .clipShape(RoundedRectangle(cornerRadius: ActivityCardTokens.innerCornerRadius, style: .continuous))
                }
            }
        }
    }

    // MARK: - Helpers

    private func formattedJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let formatted = String(data: pretty, encoding: .utf8)
        else { return json }
        return formatted
    }
}

// MARK: - Custom Summary

/// Inline summary rendered above the expandable details of a tool call card.
/// Handles `ask_teammate` (shows question) and `request_team_meeting` (shows topic + participants).
/// Returns an empty view for tools without a custom summary.
private struct ToolCallCustomSummaryView: View {
    let toolName: String
    let argumentsJSON: String

    var body: some View {
        switch toolName {
        case ToolNames.askTeammate:
            if let args = JSONUtilities.parseJSONDictionary(argumentsJSON),
               let question = args["question"] as? String,
               !question.isEmpty
            {
                Text(question)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
        case ToolNames.requestTeamMeeting:
            if let args = JSONUtilities.parseJSONDictionary(argumentsJSON) {
                let topic = (args["topic"] as? String) ?? ""
                let participantIDs = (args["participants"] as? [String]) ?? []
                let names = participantIDs.compactMap { Role.builtInRole(for: $0)?.displayName }
                VStack(alignment: .leading, spacing: 3) {
                    if !topic.isEmpty {
                        Text(topic)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    if !names.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.3.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(names.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Preview

#Preview("Collapsed") {
    @Previewable @State var expanded: Set<UUID> = []
    VStack(spacing: 16) {
        ToolCallItemView(
            call: StepToolCall(
                name: "read_file",
                argumentsJSON: "{\"path\": \"Sources/Sorting.swift\"}",
                resultJSON: "{\"content\": \"import Foundation\\n\\nstruct Sorting {\\n    // TODO\\n}\"}",
                isError: false
            ),
            role: .softwareEngineer,
            roleDefinition: nil,
            showHeader: true,
            teamRoles: [],
            toolCallsExpanded: $expanded
        )
        ToolCallItemView(
            call: StepToolCall(
                name: "write_file",
                argumentsJSON: "{\"path\": \"Sources/Sorting.swift\", \"content\": \"...\"}",
                resultJSON: "{\"error\": \"Permission denied\"}",
                isError: true
            ),
            role: .softwareEngineer,
            roleDefinition: nil,
            showHeader: false,
            teamRoles: [],
            toolCallsExpanded: $expanded
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Expanded") {
    @Previewable @State var expanded: Set<UUID> = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]
    ToolCallItemView(
        call: StepToolCall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "edit_file",
            argumentsJSON: "{\"path\": \"Sources/Sorting.swift\", \"old_text\": \"// TODO\", \"new_text\": \"static func bubbleSort(_ arr: [Int]) -> [Int] { var a = arr; for i in 0..<a.count { for j in 0..<a.count-i-1 { if a[j] > a[j+1] { a.swapAt(j, j+1) } } }; return a }\"}",
            resultJSON: "{\"success\": true, \"path\": \"Sources/Sorting.swift\"}",
            isError: false
        ),
        role: .softwareEngineer,
        roleDefinition: nil,
        showHeader: true,
        teamRoles: [],
        toolCallsExpanded: $expanded
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("In Progress") {
    @Previewable @State var expanded: Set<UUID> = []
    ToolCallItemView(
        call: StepToolCall(
            name: "run_xcodebuild",
            argumentsJSON: "{\"action\": \"build\"}",
            resultJSON: nil,
            isError: nil
        ),
        role: .softwareEngineer,
        roleDefinition: nil,
        showHeader: true,
        teamRoles: [],
        toolCallsExpanded: $expanded
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Error Expanded") {
    @Previewable @State var expanded: Set<UUID> = [UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]
    ToolCallItemView(
        call: StepToolCall(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "git_commit",
            argumentsJSON: "{\"message\": \"Add sorting implementation\"}",
            resultJSON: "{\"error\": \"fatal: not a git repository (or any of the parent directories): .git\"}",
            isError: true
        ),
        role: .softwareEngineer,
        roleDefinition: nil,
        showHeader: true,
        teamRoles: [],
        toolCallsExpanded: $expanded
    )
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}
