import SwiftUI

/// Renders a single tool call card. Tap opens full untruncated arguments and
/// result in a standalone window — there is no inline expansion or chevron.
struct ToolCallItemView: View {
    let call: StepToolCall
    let role: Role
    let roleDefinition: TeamRoleDefinition?
    let showHeader: Bool
    let teamRoles: [TeamRoleDefinition]
    var onAvatarTap: (() -> Void)? = nil
    /// Override role display name. `nil` falls back to roleDefinition.name.
    var roleLabelOverride: String? = nil
    /// Optional ` from <Team>` suffix in secondary gray for delegated
    /// child-team items.
    var roleTeamSuffix: String? = nil

    @Environment(\.openWindow) private var openWindow

    // MARK: - Derived

    private var roleName: String { roleLabelOverride ?? roleDefinition?.name ?? role.displayName }
    private var tintColor: Color { roleDefinition?.resolvedTintColor ?? role.tintColor }

    /// Display + dispatch name with model-emitted namespace prefixes (`repo_browser.`,
    /// `functions.`) and common aliases stripped. `call.name` stays as-emitted on the
    /// model — that form is what the LLM saw in the rejection envelope and what error
    /// messages quote; the UI and tool-name matching always work on the canonical form.
    private var canonicalName: String { ToolRegistry.resolveToolName(call.name) }

    private static let customSummaryTools: Set<String> = [
        ToolNames.requestTeamMeeting,
    ]
    private var hasCustomSummary: Bool { Self.customSummaryTools.contains(canonicalName) }

    private var statusColor: Color {
        if call.resultJSON == nil || call.isAnalyzing || call.isGeneratingTeam { return Colors.info }
        return call.isError == true ? Colors.error : Colors.success
    }

    /// True when this `search` call took the exploratory branch. `SearchTool` canonicalizes
    /// the resolved `exploratory` value into `argumentsJSON` (covering both the explicit-arg
    /// case and the `searchExploratoryByDefault`-ON case), so this is a direct args check.
    private var isExploratorySearch: Bool {
        guard canonicalName == ToolNames.search else { return false }
        guard let args = JSONUtilities.parseJSONDictionary(call.argumentsJSON) else { return false }
        return args["exploratory"] as? Bool == true
    }

    // MARK: - Body

    private static let noHeaderLeading: CGFloat = ActivityCardTokens.avatarSize + ActivityCardTokens.cardPadding

    var body: some View {
        if showHeader {
            HStack(alignment: .top, spacing: ActivityCardTokens.cardPadding) {
                ActivityFeedRoleAvatar(role: role, roleDefinition: roleDefinition, onTap: onAvatarTap)

                VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
                    HStack(spacing: 6) {
                        roleNameText(roleName: roleName, teamSuffix: roleTeamSuffix, tintColor: tintColor)
                        Spacer()
                        Text(call.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(Typography.term2xs)
                            .foregroundStyle(Colors.textTertiary)
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
            HStack(spacing: Spacing.xs) {
                // Terminal command line: `$ tool args → ok/error`
                Text("$")
                    .font(Typography.termXs)
                    .foregroundStyle(Colors.textQuaternary)
                Text(canonicalName)
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if isExploratorySearch && !call.isExploratorySearchDisabled {
                    Image(systemName: "binoculars")
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .accessibilityLabel("Exploratory search")
                }
                if !hasCustomSummary {
                    let argSummary = ToolCallSummarizer.summarizeArguments(
                        toolName: canonicalName, json: call.argumentsJSON,
                        resolveRoleName: { teamRoles.roleName(for: $0) }
                    )
                    if !argSummary.isEmpty {
                        Text(argSummary)
                            .font(Typography.termXs)
                            .foregroundStyle(Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: Spacing.xs)
                resultIndicator
            }

            callSummary
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openWindow(value: ActivityDetailWindow.toolCall(
                id: call.id,
                toolName: canonicalName,
                argumentsJSON: call.argumentsJSON,
                resultJSON: call.resultJSON,
                isError: call.isError == true,
                createdAt: call.createdAt
            ))
        }
    }

    @ViewBuilder
    private var resultIndicator: some View {
        if call.resultJSON == nil || call.isAnalyzing || call.isGeneratingTeam {
            NTMSLoader(font: Typography.termXs, color: Colors.info)
        } else {
            HStack(spacing: 2) {
                Text("→").foregroundStyle(Colors.textTertiary)
                Text(call.isError == true ? "error" : "ok").foregroundStyle(statusColor)
            }
            .font(Typography.termXs)
        }
    }

    @ViewBuilder
    private var callSummary: some View {
        ToolCallCustomSummaryView(toolName: canonicalName, argumentsJSON: call.argumentsJSON)
    }
}

// MARK: - Custom Summary

/// Inline summary rendered next to the tool name in the card header.
/// Handles `ask_teammate` (shows question) and `request_team_meeting` (shows topic + participants).
/// Returns an empty view for tools without a custom summary. Tap on the card
/// (handled by the parent) opens full args + result in a standalone window.
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
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.textPrimary)
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
                            .font(Typography.captionSemibold)
                            .foregroundStyle(Colors.textPrimary)
                            .lineLimit(2)
                    }
                    if !names.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.3")
                                .font(Typography.term2xs)
                                .foregroundStyle(Colors.textSecondary)
                            Text(names.joined(separator: ", "))
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textSecondary)
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

// MARK: - Equatable

/// See `MessageBubbleView`'s Equatable extension for the full rationale —
/// `.equatable()` lets the timeline dispatcher skip diffing this card when
/// nothing observable has changed. `teamRoles` is compared by id-array
/// (`TeamRoleDefinition` is `Identifiable` but not `Hashable`); the role
/// definitions are read for name resolution inside `summarizeArguments` and
/// identity is the right granularity. `onAvatarTap` excluded (closure;
/// captures only props that are themselves in `==`).
extension ToolCallItemView: Equatable {
    static func == (lhs: ToolCallItemView, rhs: ToolCallItemView) -> Bool {
        lhs.call == rhs.call
            && lhs.role == rhs.role
            && lhs.roleDefinition?.id == rhs.roleDefinition?.id
            && lhs.showHeader == rhs.showHeader
            && lhs.teamRoles.map(\.id) == rhs.teamRoles.map(\.id)
            && lhs.roleLabelOverride == rhs.roleLabelOverride
            && lhs.roleTeamSuffix == rhs.roleTeamSuffix
    }
}

// MARK: - Preview

#Preview("Variants") {
    VStack(spacing: 16) {
        ToolCallItemView(
            call: StepToolCall(
                name: "read_file",
                argumentsJSON: "{\"path\": \"Sources/Sorting.swift\"}",
                resultJSON: "{\"content\": \"import Foundation\"}",
                isError: false
            ),
            role: .softwareEngineer,
            roleDefinition: nil,
            showHeader: true,
            teamRoles: []
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
            teamRoles: []
        )
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
            teamRoles: []
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

#Preview("Collaboration variants") {
    VStack(spacing: 16) {
        ToolCallItemView(
            call: StepToolCall(
                name: "ask_teammate",
                argumentsJSON: "{\"teammate\":\"tech_lead\",\"question\":\"Should we use Combine or async/await for the new networking layer?\"}",
                resultJSON: "{\"ok\": true}",
                isError: false
            ),
            role: .softwareEngineer,
            roleDefinition: nil,
            showHeader: true,
            teamRoles: []
        )
        ToolCallItemView(
            call: StepToolCall(
                name: "request_team_meeting",
                argumentsJSON: "{\"topic\":\"Architecture review for storage layer\",\"participants\":[\"tech_lead\",\"software_engineer\",\"code_reviewer\"]}",
                resultJSON: "{\"ok\": true}",
                isError: false
            ),
            role: .softwareEngineer,
            roleDefinition: nil,
            showHeader: false,
            teamRoles: []
        )
        ToolCallItemView(
            call: StepToolCall(
                name: "search",
                argumentsJSON: "{\"query\":\"refactor authentication\",\"exploratory\":true}",
                resultJSON: "{\"matches\": []}",
                isError: false
            ),
            role: .codeReviewer,
            roleDefinition: nil,
            showHeader: true,
            teamRoles: []
        )
    }
    .padding()
    .frame(width: 520)
    .background(Colors.surfacePrimary)
}
