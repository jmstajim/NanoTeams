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

    private var statusColor: Color {
        if call.resultJSON == nil || call.isAnalyzing || call.isGeneratingTeam { return Colors.info }
        return call.isError == true ? Colors.error : Colors.success
    }

    // MARK: - Body

    private static let noHeaderLeading: CGFloat = ActivityCardTokens.contentColumnLeading

    var body: some View {
        // Derived ONCE per body pass. `canonicalName` / `isExploratorySearch` /
        // `hasCustomSummary` / the argument summary were computed properties, so each
        // reference re-ran `resolveToolName` and, on a `search` card, a second
        // `JSONSerialization` pass over the same `argumentsJSON`.
        let model = ToolCallCardModel.make(
            call: call, resolveRoleName: { teamRoles.roleName(for: $0) })
        return content(model: model)
    }

    @ViewBuilder
    private func content(model: ToolCallCardModel) -> some View {
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
                    toolCard(model)
                }
            }
        } else {
            toolCard(model)
                .padding(.leading, Self.noHeaderLeading)
        }
    }

    // MARK: - Tool Card

    private func toolCard(_ model: ToolCallCardModel) -> some View {
        VStack(alignment: .leading, spacing: ActivityCardTokens.contentSpacing) {
            HStack(spacing: Spacing.xs) {
                // Terminal command line: `$ tool args → ok/error`
                Text("$")
                    .font(Typography.termXs)
                    .foregroundStyle(Colors.textQuaternary)
                Text(model.canonicalName)
                    .font(Typography.termXs.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                if model.isExploratorySearch && !call.isExploratorySearchDisabled {
                    Image(systemName: "binoculars")
                        .font(Typography.term2xs)
                        .foregroundStyle(Colors.textTertiary)
                        .accessibilityLabel("Exploratory search")
                }
                if !model.argumentSummary.isEmpty {
                    Text(model.argumentSummary)
                        .font(Typography.termXs)
                        .foregroundStyle(Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Spacing.xs)
                resultIndicator
            }

            if let summary = model.customSummary {
                ToolCallCustomSummaryView(summary: summary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openWindow(value: ActivityDetailWindow.toolCall(
                id: call.id,
                toolName: model.canonicalName,
                argumentsJSON: call.argumentsJSON,
                resultJSON: call.resultJSON,
                isError: call.isError == true,
                createdAt: call.createdAt
            ))
        }
    }

    /// `→ ok` / `→ error`, and deliberately nothing more.
    ///
    /// The card carried the failure REASON inline for one build. It read as diagnosis and
    /// was not: every arm of `ToolErrorNotePolicy` that still speaks is a CONSTANT keyed on
    /// the error code, so a role stuck on one rejection produced a column of identical red
    /// paragraphs. A constant does not earn permanent screen space — the reason is one tap
    /// away, in full and selectable, via `ActivityDetailWindow.toolCall` below.
    ///
    /// This is not the `system: retry` row returning by another route either: that row was
    /// removed because it restated the envelope to the MODEL, an argument about context cost
    /// that this view never touched.
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

}

// MARK: - Custom Summary

/// Inline summary rendered next to the tool name in the card header.
/// Handles `ask_teammate` (shows question) and `request_team_meeting` (shows topic + participants).
/// Returns an empty view for tools without a custom summary. Tap on the card
/// (handled by the parent) opens full args + result in a standalone window.
/// Takes pre-resolved display values, not JSON. A `[String: Any]` stored in a `View` is
/// neither `Sendable` nor `Equatable` and is COW-boxed, so it would be a new box every
/// pass and SwiftUI's structural comparison would never match.
private struct ToolCallCustomSummaryView: View {
    let summary: ToolCallCustomSummary

    var body: some View {
        switch summary {
        case let .question(question):
            Text(question)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textPrimary)
                .lineLimit(3)
        case let .meeting(topic, names):
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
    }
}

// MARK: - Equatable

/// See `MessageBubbleView`'s Equatable extension for the full rationale —
/// `.equatable()` lets the timeline dispatcher skip diffing this card when
/// nothing observable has changed. `onAvatarTap` excluded (closure; captures
/// only props that are themselves in `==`).
///
/// `teamRoles` is compared element-wise on `renderIdentity`, non-allocating.
/// Two corrections to what stood here until 2026-08-25, and each was
/// load-bearing:
///   - it read `lhs.teamRoles.map(\.id) == rhs.teamRoles.map(\.id)`, which
///     allocates two `[String]` on EVERY comparison of every tool-call row —
///     the one `==` in the app that allocated;
///   - it justified the id-array with "`TeamRoleDefinition` is `Identifiable`
///     but not `Hashable`", which is false (it has been `Hashable` since
///     `01d21001`), and with "identity is the right granularity", which is
///     wrong for what this array is FOR: it exists only to resolve names via
///     `roleName(for:)`, which reads `.name` and `.systemRoleID`. A roster
///     rename therefore left a resolved name stale on screen.
/// Swapping in `TeamRoleDefinition.==` would not have helped — that is itself
/// `lhs.id == rhs.id` (CLAUDE.md #42), i.e. exactly as blind.
extension ToolCallItemView: Equatable {
    static func == (lhs: ToolCallItemView, rhs: ToolCallItemView) -> Bool {
        lhs.call == rhs.call
            && lhs.role == rhs.role
            && lhs.roleDefinition?.renderIdentity == rhs.roleDefinition?.renderIdentity
            && lhs.showHeader == rhs.showHeader
            && lhs.teamRoles.elementsEqual(rhs.teamRoles) { $0.renderIdentity == $1.renderIdentity }
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
