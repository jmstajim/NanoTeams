import SwiftUI

/// One line of the feed recording a Supervisor ACTION — `✓ Claude Code closed task   22:08`.
///
/// An event is neither a speaker nor a card, so it wears neither's chrome. It is drawn as a log
/// line on the feed's own grid: a bare status glyph centred in the avatar gutter (the role rows'
/// avatars are bare glyphs too, so a status line has no reason to box its own), the sentence at
/// the content column, the time at the trailing edge where every header puts it. Until
/// 2026-11-08 it rode `NotificationItemView`'s card anatomy with the body removed — a tinted
/// `checkmark.seal` square and a semibold title in the status colour, louder than the role names
/// it sits among and, unlike the role rows around it, without a time.
///
/// The author and the action are inked apart, the author one step brighter: the agent's name is
/// the fact this row exists to record (§11 transparency), the verb is the same every time.
///
/// **Narrow feed.** So the author is the part a narrow feed keeps. A row that does not fit on
/// one line falls back the way `MessageBubbleHeader` does in the same column: the author and the
/// time, with the action under the author; and when even those two do not share a line, the
/// author alone above the action and the time. The action is what may truncate — a role name is
/// the person's own and unbounded — and the author only on a line of its own, for a label longer
/// than the column. Until 2026-11-09 the row stayed one line and the author shrank first: at the
/// feed's minimum width it read `✓ C accepted So… 22:08` (CLAUDE.md #397).
struct SupervisorEventRow: View {
    let event: SupervisorTimelineEvent
    var roleName: String? = nil
    /// The status colour of the glyph — `ActivityNotificationType.color(isChatMode:)`, so the
    /// event's colour keeps one source.
    let glyphColor: Color

    private var glyph: String {
        switch event.kind {
        case .roleAccepted: return TerminalGlyph.accepted
        case .taskClosed: return TerminalGlyph.done
        case .runPaused: return TerminalGlyph.paused
        case .runResumed: return TerminalGlyph.working
        }
    }

    var body: some View {
        // The glyph sits on the first line's baseline, whichever layout the text takes.
        HStack(alignment: .firstTextBaseline, spacing: ActivityCardTokens.cardPadding) {
            StatusGlyph(glyph: glyph, color: glyphColor)
                .frame(width: ActivityCardTokens.avatarSize)

            // The first candidate whose ideal width fits wins; when none does the last one is
            // used, which is the one built to compress. `Spacer(minLength: 0)`: the stack's own
            // spacing already leaves 8 pt before the time, and 16 pt cut "closed task" to
            // "closed ta…" at the feed's minimum width on a 12-hour clock (rendered 2026-11-09).
            ViewThatFits(in: .horizontal) {
                // 1. One line: the author, the action, the time.
                HStack(spacing: Spacing.xs) {
                    author
                    action
                    Spacer(minLength: 0)
                    time
                }
                // 2. The author and the time, then the action under the author.
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        author
                        Spacer(minLength: 0)
                        time
                    }
                    action
                }
                // 3. The author alone, then the action and the time.
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    author
                    HStack(spacing: Spacing.xs) {
                        action
                        Spacer(minLength: 0)
                        time
                    }
                }
            }
        }
        // One stop for VoiceOver: "Claude Code, closed task, 10:08 PM".
        .accessibilityElement(children: .combine)
    }

    private var author: some View {
        Text(event.authorLabel)
            .font(Typography.termXs.weight(.medium))
            .foregroundStyle(Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var action: some View {
        Text(event.actionText(roleName: roleName))
            .font(Typography.termXs)
            .foregroundStyle(Colors.textTertiary)
            .lineLimit(1)
    }

    private var time: some View {
        // `Text(_:format:)`, not `createdAt.formatted(...)`: the same string, formatted in the
        // view's environment locale — so a preview renders the 12-hour clock the narrow layouts
        // are sized against, as `MessageBubbleHeader`'s does.
        Text(event.createdAt, format: Date.FormatStyle(date: .omitted, time: .shortened))
            .font(Typography.term2xs)
            .lineLimit(1)
            .foregroundStyle(Colors.textTertiary)
            // The time keeps its width; the author and the action share what is left.
            .layoutPriority(1)
    }
}

#Preview("In the feed") {
    VStack(alignment: .leading, spacing: ActivityCardTokens.turnGapSpacing * 2) {
        SupervisorTaskItemView(
            createdAt: Date(),
            supervisorTask: "Review found four defects. Fix them in calculator/script.js.",
            clippedTexts: [],
            attachmentPaths: [],
            workFolderURL: nil,
            roleDefinition: nil,
            authorLabel: "Claude Code"
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(kind: .roleAccepted, authorLabel: "Claude Code"),
            roleName: "Software Engineer",
            glyphColor: Colors.success
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(kind: .taskClosed, authorLabel: "Claude Code"),
            glyphColor: Colors.success
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(
                kind: .taskClosed,
                authorLabel: "An agent whose label runs far longer than any header has room for"),
            glyphColor: Colors.success
        )
    }
    .padding()
    .frame(width: 500)
    .background(Colors.surfacePrimary)
}

/// The feed's narrowest content column (~138 pt at the 200 pt panel minimum) and a middling one,
/// on a 12-hour clock at its widest (`10:08 PM`): where the row no longer fits on one line, and
/// where even the author and the time no longer share one.
#Preview("Narrow") {
    let late = Calendar.current.date(bySettingHour: 22, minute: 8, second: 0, of: .now) ?? .now
    HStack(alignment: .top, spacing: 24) {
        narrowEventColumn(content: 138, at: late).environment(\.locale, Locale(identifier: "en_US"))
        narrowEventColumn(content: 138, at: late).environment(\.locale, Locale(identifier: "ru_RU"))
        narrowEventColumn(content: 226, at: late).environment(\.locale, Locale(identifier: "en_US"))
    }
    .padding()
    .background(Colors.surfacePrimary)
}

/// Event rows as wide as the feed's row at a `content`-point content column: the row draws its
/// own gutter, so the column adds it back.
// periphery:ignore - used in #Preview macros
@ViewBuilder
private func narrowEventColumn(content: CGFloat, at time: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        SupervisorEventRow(
            event: SupervisorTimelineEvent(createdAt: time, kind: .roleAccepted, authorLabel: "Claude Code"),
            roleName: "Software Engineer",
            glyphColor: Colors.success
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(createdAt: time, kind: .taskClosed, authorLabel: "Claude Code"),
            glyphColor: Colors.success
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(createdAt: time, kind: .taskClosed, authorLabel: "Claude Code live"),
            glyphColor: Colors.success
        )
        SupervisorEventRow(
            event: SupervisorTimelineEvent(
                createdAt: time, kind: .taskClosed,
                authorLabel: "An agent whose label runs far longer than any header has room for"),
            glyphColor: Colors.success
        )
    }
    .frame(width: ActivityCardTokens.avatarSize + ActivityCardTokens.cardPadding + content,
           alignment: .topLeading)
}
