import SwiftUI

/// The header row of a feed speaker: role name (with an optional ` from <Team>` suffix in
/// secondary gray for child-team items), the agent mark when someone other than the person wrote
/// the turn, the context word in parentheses, the time.
///
/// Shared by a message bubble (`MessageBubbleView`) and the Supervisor's task card
/// (`SupervisorTaskItemView`), so the two places a Supervisor speaks name its author one way.
/// Until 2026-11-08 the card drew its own header with the `.agent` mark while the bubble printed
/// the author inside the parentheses, beside the context word: `Supervisor [CLAUDE CODE]` above
/// `Supervisor (Claude Code)`.
///
/// **Narrow feed.** At the feed's minimum width (`WindowLayout.teamBoardActivityMinWidth`, a
/// ~138pt content column) the name, a fixed-size mark and the time do not fit on one line —
/// measured 2026-11-08, the card's header turned "Supervisor" into "S" and cut the time to "1".
/// So a header that does not fit falls back to two lines — name and time, then the mark and the
/// context — and, when even name and time do not fit (a 12-hour clock: `10:08 PM` is 49pt where
/// a 24-hour `HH:mm` is 31pt, CoreText), to the name alone above the mark, the context and the time. Only
/// on a line of its own may the mark itself truncate, for a long label at the narrowest width.
/// The policy is the header's, not the author's: the person's own task card (no mark) wrapped
/// "Supervisor" at the same width on a 12-hour clock.
struct MessageBubbleHeader: View {
    let roleName: String
    var teamSuffix: String? = nil
    let tintColor: Color
    /// What kind of turn it is — `consultation`, `supervisor answer`, … — drawn in parentheses.
    var contextLabel: String? = nil
    /// Who wrote it when that was not the person — drawn as `TerminalStatusBadge.agent`.
    var authorLabel: String? = nil
    let timestamp: Date
    let isStreaming: Bool
    /// The terminal prompt mark the Supervisor's task card opens with.
    var showsPromptMarker: Bool = false

    private var author: String? {
        guard let trimmed = authorLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var body: some View {
        // One layout policy for every header — the card and the bubble alike: the first
        // candidate whose ideal width fits wins, and when none does the last one is used, which
        // is the one built to compress. `Spacer(minLength: 0)` throughout: the stack's own
        // spacing already puts a gap on each side of it, and the extra 8pt is what wrapped
        // "Supervisor" at the narrowest width.
        ViewThatFits(in: .horizontal) {
            // 1. Everything on one line.
            HStack(spacing: Spacing.s) {
                speaker
                mark(truncatesWhenNarrow: false)
                context
                Spacer(minLength: 0)
                time
            }
            // 2. Name and time, then the mark and the context under the name.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    speaker
                    Spacer(minLength: 0)
                    time
                }
                if hasSecondaryFacts {
                    HStack(spacing: Spacing.s) {
                        mark(truncatesWhenNarrow: true)
                        context
                    }
                }
            }
            // 3. The name alone, then everything else — the time included.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // Wrapped: `speaker` is two views, and a VStack would stack the prompt mark
                // above the name.
                HStack(spacing: Spacing.s) {
                    speaker
                }
                HStack(spacing: Spacing.s) {
                    mark(truncatesWhenNarrow: true)
                    context
                    Spacer(minLength: 0)
                    time
                }
            }
        }
        // One stop for VoiceOver: "Supervisor, by Claude Code, 10:08 PM".
        .accessibilityElement(children: .combine)
    }

    /// A mark or a context word to move under the name. Without either, the second layout is
    /// the name and the time alone — no empty row to add a gap.
    private var hasSecondaryFacts: Bool {
        author != nil || contextLabel != nil
    }

    /// Only the two fallback layouts let the mark truncate: they put it on a line of its own,
    /// where a long label at the narrowest width has nothing left to push.
    @ViewBuilder
    private func mark(truncatesWhenNarrow: Bool) -> some View {
        if let author {
            TerminalStatusBadge.agent(label: author, truncatesWhenNarrow: truncatesWhenNarrow)
        }
    }

    @ViewBuilder
    private var speaker: some View {
        if showsPromptMarker {
            PromptMarker()
        }
        roleNameText(roleName: roleName, teamSuffix: teamSuffix, tintColor: tintColor)
    }

    @ViewBuilder
    private var context: some View {
        if let contextLabel {
            Text("(\(contextLabel))")
                .font(Typography.term2xs)
                .lineLimit(1)
                .foregroundStyle(Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var time: some View {
        if !isStreaming {
            // `Text(_:format:)`, not `timestamp.formatted(...)`: the same string, but formatted
            // in the view's environment locale — so a preview can render the 12-hour clock the
            // narrow layouts are sized against.
            Text(timestamp, format: Date.FormatStyle(date: .omitted, time: .shortened))
                .font(Typography.term2xs)
                .lineLimit(1)
                .foregroundStyle(Colors.textTertiary)
                // The time keeps its width; the name and the context share what is left.
                .layoutPriority(1)
        }
    }
}

#Preview("Headers") {
    VStack(alignment: .leading, spacing: 12) {
        MessageBubbleHeader(
            roleName: "Engineer",
            tintColor: Colors.info,
            contextLabel: "consultation",
            timestamp: .now,
            isStreaming: false
        )
        MessageBubbleHeader(
            roleName: "Reviewer",
            tintColor: Colors.warning,
            timestamp: .now,
            isStreaming: true
        )
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            authorLabel: "Claude Code",
            timestamp: .now,
            isStreaming: false,
            showsPromptMarker: true
        )
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            authorLabel: LLMMessage.automatedSupervisorLabel,
            timestamp: .now,
            isStreaming: false
        )
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            contextLabel: "supervisor answer",
            authorLabel: "Claude Code",
            timestamp: .now,
            isStreaming: false
        )
    }
    .padding()
    .frame(maxWidth: 420)
}

/// The feed's narrowest content column (~138pt at the 200pt panel minimum) and a middling one,
/// on a 12-hour clock at its widest (`10:08 PM`): where the one-line header no longer fits and
/// the mark moves under the name, and where even the name and the time no longer share a line.
#Preview("Narrow") {
    let late = Calendar.current.date(bySettingHour: 22, minute: 8, second: 0, of: .now) ?? .now
    HStack(alignment: .top, spacing: 24) {
        narrowHeaderColumn(width: 138, at: late).environment(\.locale, Locale(identifier: "en_US"))
        narrowHeaderColumn(width: 138, at: late).environment(\.locale, Locale(identifier: "ru_RU"))
        narrowHeaderColumn(width: 226, at: late).environment(\.locale, Locale(identifier: "en_US"))
    }
    .padding()
    .background(Colors.surfacePrimary)
}

// periphery:ignore - used in #Preview macros
@ViewBuilder
private func narrowHeaderColumn(width: CGFloat, at time: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            authorLabel: "Claude Code",
            timestamp: time,
            isStreaming: false,
            showsPromptMarker: true
        )
        // The person's own task card: no mark, one line.
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            timestamp: time,
            isStreaming: false,
            showsPromptMarker: true
        )
        MessageBubbleHeader(
            roleName: "Supervisor",
            tintColor: Role.supervisor.tintColor,
            contextLabel: "supervisor answer",
            authorLabel: "An agent whose label runs far longer than any header has room for",
            timestamp: time,
            isStreaming: false
        )
        MessageBubbleHeader(
            roleName: "Software Engineer",
            tintColor: Colors.info,
            contextLabel: "consultation",
            timestamp: time,
            isStreaming: false
        )
    }
    .frame(width: width, alignment: .topLeading)
}
