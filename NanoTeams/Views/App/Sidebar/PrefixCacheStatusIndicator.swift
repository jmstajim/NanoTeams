import SwiftUI

/// Always-on count of prompt-prefix (KV) cache misses, with a popover breaking them down.
///
/// This is the surface that makes "always visible" true. The banner slot is a single coalescing
/// slot with a 4 s auto-dismiss shared by ~140 writers, so a recurring signal written there is
/// silently replaced by the next writer; a count is idempotent under repetition, so 47 misses
/// render as `CACHE ×47` with no windowing needed. The banner still fires — once per task, run
/// and cause — and points here.
///
/// Structural clone of `ExploratorySearchStatusIndicator`: appears when true, vanishes when
/// false, never touches the banner.
struct PrefixCacheStatusIndicator: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDetail = false

    private var reporter: PrefixCacheReporter { store.prefixCacheReporter }

    var body: some View {
        ZStack {
            if reporter.missCount > 0 { pill }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: reporter.missCount > 0)
    }

    private var pill: some View {
        Button { isShowingDetail.toggle() } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.warning)
                    .accessibilityHidden(true)
                Text("CACHE ×\(reporter.missCount)")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.warning)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle.squircle(CornerRadius.small).fill(Colors.warningTint)
            )
            .contentShape(RoundedRectangle.squircle(CornerRadius.small))
        }
        .buttonStyle(.plain)
        .help(Self.tooltip(for: reporter))
        .accessibilityLabel("\(reporter.missCount) prompt cache misses — click for details")
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .popover(isPresented: $isShowingDetail, arrowEdge: .top) { detail }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("PROMPT CACHE MISSES")
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(Colors.textTertiary)

            Text("The model re-processed prompts it should have been able to reuse — about "
                + "\(PrefixCachePolicy.formatSeconds(reporter.estimatedSecondsLost)) of extra work.")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !reporter.countsByCause.isEmpty {
                TerminalDivider()
                ForEach(Self.sortedCauses(reporter.countsByCause), id: \.0) { cause, count in
                    row(
                        label: Self.causeRowLabel(
                            cause, suspect: reporter.suspectLead(for: cause)),
                        count: count)
                }
            }

            if !reporter.countsByOwner.isEmpty {
                TerminalDivider()
                Text("BY CALLER")
                    .font(Typography.term2xs)
                    .tracking(Typography.labelTracking)
                    .foregroundStyle(Colors.textTertiary)
                ForEach(Self.sortedOwners(reporter.countsByOwner), id: \.0) { owner, count in
                    row(label: owner, count: count)
                }
            }
        }
        .padding(Spacing.standard)
        .frame(width: 320)
    }

    private func row(label: String, count: Int) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Text("×\(count)")
                .font(Typography.caption)
                .foregroundStyle(Colors.textSecondary)
        }
    }

    // MARK: - Pure presentation helpers (unit-tested)

    /// The cause row, with a lead appended when the aggregate has one.
    ///
    /// `CauseClass.label` stands alone by design (it is one string for a title-case row), so the
    /// lead is composed here rather than pushed into the enum: the suspect is a fact about the
    /// aggregate, not about the case. Without this the eviction row read "Server dropped the
    /// cached prefix" and nothing else — true, and unactionable, since the whole point of naming
    /// a suspect is to tell the user WHICH other caller to move off this model.
    ///
    /// "likely" is doing real work: interleaving is never a proven cause here, only the last
    /// other caller seen on the same (server, model).
    static func causeRowLabel(_ cause: PrefixCachePolicy.CauseClass, suspect: String?) -> String {
        guard let suspect, !suspect.isEmpty else { return cause.label }
        return "\(cause.label) — likely \(suspect)"
    }

    /// Deterministic order — counts desc, then name — so the popover does not reshuffle on every
    /// tick of an incrementing counter.
    static func sortedCauses(
        _ counts: [PrefixCachePolicy.CauseClass: Int]
    ) -> [(PrefixCachePolicy.CauseClass, Int)] {
        counts.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map { ($0.key, $0.value) }
    }

    static func sortedOwners(_ counts: [String: Int]) -> [(String, Int)] {
        counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }

    static func tooltip(for reporter: PrefixCacheReporter) -> String {
        "\(reporter.missCount) prompt cache "
            + (reporter.missCount == 1 ? "miss" : "misses")
            + " — about \(PrefixCachePolicy.formatSeconds(reporter.estimatedSecondsLost)) "
            + "of re-processing. Click for the breakdown."
    }
}
