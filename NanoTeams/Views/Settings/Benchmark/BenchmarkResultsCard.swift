import SwiftUI

/// The leaderboard and the raw run history, in one card with a mode switch.
///
/// Everything it renders comes from `BenchmarkLeaderboard`, so the comparability rules — current
/// prompt version only, throttled runs held back, prefill sources not mixed — are enforced in one
/// tested place rather than re-implemented here.
struct BenchmarkResultsCard: View {
    let runs: [GenerationBenchmarkRun]
    let samples: [GenerationBenchmarkSample]
    /// Raised, not performed: this card owns no store. The settings view holds the history and is
    /// the only thing that may write to it, so a delete here is a request and a reload there.
    let onDelete: (Set<UUID>) -> Void
    /// Separate from `onDelete` because the store's two primitives are genuinely different:
    /// deleting by id preserves lines this build cannot read, wiping the history takes them too.
    let onClearAll: () -> Void
    /// A measurement is in flight. Deletes are held back while it is: the run appends when it
    /// settles, so a row deleted now can reappear a minute later, which reads as a delete that
    /// failed. Correctness does not need this — the store serialises both — the reader does.
    let isMeasuring: Bool

    enum Mode: String, CaseIterable {
        case leaderboard = "Leaderboard"
        case history = "Runs"
    }

    @State private var mode: Mode = .leaderboard
    @State private var sortColumn: BenchmarkLeaderboard.SortColumn = .generation
    @State private var sortDescending = true
    @State private var includeThrottled = false
    /// One query for both tables, kept across the mode switch on purpose: "show me this model" is
    /// the same question on either tab, and re-typing it to cross over would be the surprise.
    @State private var query = ""
    /// The delete awaiting confirmation. One slot for all three scopes — two dialogs cannot be on
    /// screen at once, and a second request arriving replaces the first rather than queueing
    /// behind it.
    @State private var pendingDeletion: BenchmarkDeletion.Request?
    /// The run whose detail is open, by id rather than by value so the sheet cannot render a copy
    /// that a reload has since replaced. Keyed on `run.id` — a UUID assigned at creation, never a
    /// positional index (CLAUDE.md #22).
    ///
    /// A sheet and not a disclosure row inside the Grid, and the reason is width rather than
    /// taste: a cell spanning the table's columns takes part in solving their widths, so one
    /// verbatim `serverFields` value — "Unloaded for this run: qwen/qwen3-coder-30b,
    /// mistral-small-3.2, gpt-oss-20b" — would widen Format, Quantization, Generation, TTFT and
    /// Prefill for EVERY row. That dictionary is unbounded by design ("a field a provider starts
    /// reporting tomorrow lands in the record without a schema change"), so the hazard is standing
    /// rather than one-time, and nothing in the suite can pin a layout regression. A sheet also
    /// gives the per-sample table the room it needs to be worth reading.
    @State private var detailRunID: UUID?

    /// Hover + row-frame state for the Runs table, an `@Observable` rather than card `@State` so
    /// pointer-move and layout events re-render only `BenchmarkRowBandLayer` — never this card's
    /// `body`, whose re-evaluation re-derives `historyEntries` (view convention #11). The class's
    /// own doc carries the full reasoning.
    @State private var rowInteraction = BenchmarkRowInteractionState<UUID>()

    /// The leaderboard's own instance — "the row under the pointer" is a fact about one Grid, and
    /// its rows are keyed by `BenchmarkLeaderboard.Row.id` (a composite String), not by run.
    @State private var leaderboardInteraction = BenchmarkRowInteractionState<String>()

    /// The Runs Grid's coordinate space. Cell frames are REPORTED in it and hover/tap points are
    /// RESOLVED in it, so the two cannot disagree by an ancestor's offset.
    private static let historyTableSpace = "benchmark-history-table"

    /// Same contract for the leaderboard Grid — a separate name because the two Grids can never
    /// share an ancestor space without their frames landing in each other's dictionaries.
    private static let leaderboardTableSpace = "benchmark-leaderboard-table"

    /// The clock the date cells format against — only its YEAR is ever read, to decide whether the
    /// year is worth printing. Not `@State`: a stored value would be captured when the card first
    /// appeared and would keep hiding the year for a while after midnight on 1 January.
    private var renderedAt: Date { Date() }

    var body: some View {
        // Each list is built once per render and handed to whoever needs it: the footer has to
        // describe the table that is actually on screen, and re-deriving it there would be a
        // second answer to the same question.
        let ranked = mode == .leaderboard ? rankedRows : []
        let entries = mode == .history ? historyEntries : []

        return SettingsCard(
            header: mode == .leaderboard ? "Leaderboard" : "Runs",
            systemImage: "list.number",
            footer: Self.footer(
                mode: mode, hiddenRunCount: hiddenRunCount,
                hasRows: mode == .leaderboard ? !ranked.isEmpty : !entries.isEmpty)
        ) {
            TerminalSegmentedPicker(
                selection: $mode,
                options: Mode.allCases.map { ($0, $0.rawValue) })

            switch mode {
            case .leaderboard: leaderboardSection(ranked)
            case .history: historySection(entries)
            }

            // Last thing in the card, below both tables and away from every per-row control: the
            // one button here that destroys more than the row it sits on should not be reachable
            // on the way to anything else. Absent while there is nothing to clear.
            if !runs.isEmpty {
                TerminalDivider()
                HStack {
                    Spacer()
                    clearButton
                }
            }
        }
        .confirmationDialog(
            pendingDeletion.map(BenchmarkDeletion.title(for:)) ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            Button(BenchmarkDeletion.confirmLabel(for: request), role: .destructive) {
                let captured = request
                pendingDeletion = nil
                perform(captured)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text(BenchmarkDeletion.message(for: request))
        }
        .sheet(item: detailRun) { run in
            BenchmarkRunDetailSheet(run: run, samples: samples.filter { $0.runID == run.id })
        }
    }

    /// The run the detail sheet is showing, resolved from `runs` at presentation time rather than
    /// captured when the button was pressed — a reload while the sheet is open must not leave it
    /// rendering a run the history no longer holds. Same reason the state is the id, not the value.
    ///
    /// A stored property rather than the `Binding(get:set:)` written inline at the modifier: as one
    /// expression inside `body` the type-checker gave up on it (CLAUDE.md #10).
    private var detailRun: Binding<GenerationBenchmarkRun?> {
        Binding(
            get: { runs.first { $0.id == detailRunID } },
            set: { if $0 == nil { detailRunID = nil } })
    }

    /// The one place a delete leaves this view. `.everything` goes out through `onClearAll` rather
    /// than as a set of ids, because wiping the files also takes lines no build here can decode —
    /// an id-based delete deliberately keeps those, and "Clear" deliberately does not.
    private func perform(_ request: BenchmarkDeletion.Request) {
        switch request.scope {
        case .everything: onClearAll()
        case .model, .run: onDelete(request.runIDs)
        }
    }

    /// "Delete all", not "Clear": the filter field on this same card already owns that verb with
    /// its own clear button, and one of the two removes a query while the other removes the
    /// history. The dialog's confirm reads "Delete all N runs", so the button and its confirmation
    /// now say the same word.
    private var clearButton: some View {
        SettingsPillButton(
            title: "Delete all",
            icon: "trash",
            isDestructive: true,
            action: {
                pendingDeletion = BenchmarkDeletion.everything(
                    in: runs,
                    currentPromptVersion: BenchmarkPrompt.version,
                    hiddenByFilter: hiddenByFilterCount)
            })
            .disabled(isMeasuring)
            .help(isMeasuring ? Self.measuringHelp : Self.deleteAllHelp)
    }

    /// How many runs the active filter is keeping off screen — the number the Clear confirmation
    /// has to name, since it destroys those too and the table cannot be used to check the count.
    private var hiddenByFilterCount: Int {
        runs.count { !BenchmarkSearch.matches($0, query: query) }
    }

    /// Runs excluded from the leaderboard because they were measured with a different prompt.
    private var hiddenRunCount: Int {
        runs.count { $0.promptVersion != BenchmarkPrompt.version }
    }

    // MARK: - Leaderboard

    /// The ranked table, then the filter, then whichever of the two the query leaves.
    ///
    /// The empty states are distinct and both are needed: an untouched history and a query that
    /// matched nothing look identical on screen and have opposite fixes — run the benchmark, or
    /// clear the field.
    @ViewBuilder
    private func leaderboardSection(
        _ ranked: [(rank: Int, row: BenchmarkLeaderboard.Row)]
    ) -> some View {
        let visible = ranked.filter { BenchmarkSearch.matches($0.row, query: query) }

        if ranked.isEmpty {
            emptyText(
                Self.emptyLeaderboardText(runCount: runs.count, hiddenRunCount: hiddenRunCount))
        } else {
            filterField(visible: visible.count, total: ranked.count)
            if visible.isEmpty {
                emptyText(Self.noMatches(for: query, mode: .leaderboard))
            } else {
                leaderboardTable(visible)
            }
            throttleToggle
        }
    }

    /// Ranks are taken from the UNFILTERED order and carried into the filtered view, so a search
    /// that leaves one row still says "#4". Renumbering the survivor to #1 would turn a claim
    /// about the whole table into a claim about the query — a filter is not a race.
    private var rankedRows: [(rank: Int, row: BenchmarkLeaderboard.Row)] {
        BenchmarkLeaderboard.sorted(
            BenchmarkLeaderboard.rows(
                runs: runs, samples: samples,
                currentPromptVersion: BenchmarkPrompt.version,
                includeThrottled: includeThrottled),
            by: sortColumn, descending: sortDescending)
            .enumerated()
            .map { (rank: $0.offset + 1, row: $0.element) }
    }

    /// `Spacing.m` between columns rather than `Spacing.l`, and that is a consequence of spelling
    /// the headings out: the settings detail pane is 670 pt at the window's minimum width (900 pt
    /// less a fixed 230 pt sidebar), and eleven columns of full words need the 80 pt those gaps
    /// give back. The alternative was to keep abbreviating, which is what made the table
    /// unreadable. Format and Quantization cost less than they look: they took their width back
    /// out of the Model cell, which no longer carries either of them as a capsule.
    private func leaderboardTable(
        _ rows: [(rank: Int, row: BenchmarkLeaderboard.Row)]
    ) -> some View {
        // Same hoist as `historyTable`: one answer to "which rows, in what order" for the
        // measured cells, the bands and the hover hit-test.
        let ids = rows.map(\.row.id)
        return Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            GridRow {
                Text("#").font(Typography.caption).foregroundStyle(Colors.textTertiary)
                header(Self.modelColumn)
                header(Self.formatColumn)
                header(Self.quantizationColumn)
                header(Self.providerColumn)
                header(Self.versionColumn)
                header(Self.generationColumn)
                header(Self.bestColumn)
                header(Self.ttftColumn)
                header(Self.prefillColumn)
                header(Self.runsColumn)
                header(Self.lastRunColumn)
                // The delete column has no heading: a word there would sort like the others and
                // read as a quantity, which is the defect the rest of this row was rewritten for.
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ForEach(rows, id: \.row.id) { entry in
                let row = entry.row
                GridRow {
                    Text("\(entry.rank)")
                        .font(Typography.caption).monospacedDigit()
                        .foregroundStyle(Colors.textTertiary)
                    HStack(spacing: Spacing.xs) {
                        // The endpoint is the other half of this row's identity, and it rides the
                        // NAME rather than a line of its own: on a machine running one server per
                        // provider it is the same address on every row, and a column of identical
                        // addresses states nothing. The tooltip is on the name and not on the
                        // HStack because the throttle glyph carries its own `.help`, which would
                        // win over an outer one wherever the two overlap.
                        Text(row.modelName)
                            .font(Typography.subheadlineMedium)
                            .help(Self.endpointTooltip(
                                provider: row.provider, endpoint: row.baseURLString,
                                lastMeasured: row.lastMeasuredAt))
                        if row.isThrottled {
                            Image(systemName: "exclamationmark.triangle")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.warning)
                                .help(Self.throttledTooltip(everyContributingRun: true))
                        }
                    }
                    // The one measured cell per row — same stretched-cell contract as the Runs
                    // table; see `historyTable`'s twin comment.
                    .frame(maxHeight: .infinity)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.leaderboardTableSpace))
                    } action: {
                        leaderboardInteraction.reportFrame($0, for: row.id, orderedIDs: ids)
                    }
                    descriptor(ModelDescriptorText.format(row.modelFormat))
                    descriptor(ModelDescriptorText.quantization(row.quantization))
                    value(row.provider.displayName)
                    value(row.providerVersion ?? "—")
                    rateView(Self.rateCell(
                        rate: row.generationTokensPerSecond,
                        approximate: row.generationRateIsApproximate,
                        tip: BenchmarkRunCard.generationTip(for: row.generationRateSource)))
                    // Best run is the SAME quantity from the SAME runs, so it inherits
                    // Generation's provenance and therefore Generation's marker. It shipped bare
                    // in the cell next to a marked one, printing `~47 | 51` on a single row.
                    rateView(
                        Self.rateCell(
                            rate: row.bestGenerationTokensPerSecond,
                            approximate: row.generationRateIsApproximate,
                            tip: BenchmarkRunCard.generationTip(for: row.generationRateSource)),
                        showsTip: false)
                    value(BenchmarkMetricsPolicy.formatDuration(row.timeToFirstTokenMs))
                    rateView(Self.rateCell(
                        rate: row.prefillTokensPerSecond,
                        approximate: row.prefillIsApproximate,
                        tip: BenchmarkRunCard.prefillTip(for: row.prefillSource)))
                    value(Self.runsCell(priced: row.runCount, failed: row.failedRunCount))
                    value(Self.runTimestamp(
                        row.lastMeasuredAt, now: renderedAt, includingTime: false))
                    deleteButton(
                        help: Self.deleteRowHelp,
                        accessibilityLabel: "Delete every result for \(row.modelName) on "
                            + row.baseURLString.endpointHostLabel,
                        request: BenchmarkDeletion.model(
                            row: row, in: runs, currentPromptVersion: BenchmarkPrompt.version))
                }
            }
        }
        // Hover highlight only — deliberately NO tap gesture and no chevron: a leaderboard row
        // aggregates many runs and has no detail sheet to open, so the band here is pointer
        // feedback for the row being read, not a promise of a click. Everything else mirrors
        // `historyTable`'s stack, including the full-width stretch.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            // Same full-bleed outset as the Runs table — see its twin comment.
            BenchmarkRowBandLayer(
                ids: ids, interaction: leaderboardInteraction, horizontalOutset: Spacing.standard)
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.leaderboardTableSpace)) { phase in
            switch phase {
            case .active(let point):
                leaderboardInteraction.pointerMoved(to: point, orderedIDs: ids)
            case .ended:
                leaderboardInteraction.pointerEnded()
            }
        }
        .coordinateSpace(.named(Self.leaderboardTableSpace))
        .onChange(of: ids) { _, visible in
            leaderboardInteraction.prune(keeping: visible)
        }
    }

    private var throttleToggle: some View {
        Toggle(isOn: $includeThrottled) {
            Text("Include runs measured while the machine was throttled")
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        }
        .toggleStyle(.terminal)
    }

    // MARK: - History

    /// Same shape as `leaderboardSection`, with one difference that matters: this branch asks
    /// whether there is any RUN, not whether the leaderboard has rows. A history made entirely of
    /// older-prompt runs produces no rankable row, and gating this tab on that count is what used
    /// to make it say "No results yet" while holding the very runs it exists to show.
    @ViewBuilder
    private func historySection(
        _ entries: [(run: GenerationBenchmarkRun, summary: BenchmarkMetricsPolicy.RunSummary)]
    ) -> some View {
        let visible = entries.filter { BenchmarkSearch.matches($0.run, query: query) }

        if entries.isEmpty {
            emptyText(Self.noResultsYet)
        } else {
            filterField(visible: visible.count, total: entries.count)
            if visible.isEmpty {
                emptyText(Self.noMatches(for: query, mode: .history))
            } else {
                historyTable(visible)
            }
        }
    }

    private func historyTable(
        _ entries: [(run: GenerationBenchmarkRun, summary: BenchmarkMetricsPolicy.RunSummary)]
    ) -> some View {
        // Derived once and captured by every closure below: three sites ask "which rows, in what
        // order", and one answered three ways is how hover, tap and highlight would come to
        // disagree — besides re-allocating the array on every pointer-move event.
        let ids = entries.map(\.run.id)
        return Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            GridRow {
                // The disclosure column has no heading, for the reason the delete column has
                // none: a word there would sit in the header row and read as another quantity.
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                historyHeader(Self.dateColumn)
                historyHeader(Self.modelColumn)
                historyHeader(Self.formatColumn)
                historyHeader(Self.quantizationColumn)
                historyHeader(Self.historyGenerationColumn)
                historyHeader(Self.ttftColumn)
                historyHeader(Self.prefillColumn)
                historyHeader(Self.samplesColumn)
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            ForEach(entries, id: \.run.id) { entry in
                GridRow {
                    detailButton(for: entry.run)
                    value(Self.runTimestamp(
                        entry.run.startedAt, now: renderedAt, includingTime: true))
                    HStack(spacing: Spacing.xs) {
                        // This tab has no Provider column, so the tooltip is the only thing here
                        // that names which server produced the run — which is why it names both.
                        Text(entry.run.modelName)
                            .font(Typography.subheadlineMedium)
                            .help(Self.endpointTooltip(
                                provider: entry.run.provider, endpoint: entry.run.baseURLString))
                        // The leaderboard holds throttled runs back by default, so this is the
                        // only table that normally shows one — and it was the one drawing it
                        // identically to a clean run.
                        if entry.run.wasThrottled {
                            Image(systemName: "exclamationmark.triangle")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.warning)
                                .help(Self.throttledTooltip(everyContributingRun: false))
                        }
                        if entry.run.promptVersion != BenchmarkPrompt.version {
                            Text("older prompt")
                                .font(Typography.caption)
                                .foregroundStyle(Colors.textTertiary)
                        }
                    }
                    // The one measured cell per row. `maxHeight: .infinity` is what makes it
                    // stand in for the WHOLE row rather than for itself: the Grid offers every
                    // cell the row's height and a flexible cell fills it, so the premise "this
                    // frame is the row's" is structural, not a claim about which cell happens to
                    // be tallest today.
                    .frame(maxHeight: .infinity)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.historyTableSpace))
                    } action: {
                        rowInteraction.reportFrame($0, for: entry.run.id, orderedIDs: ids)
                    }
                    descriptor(ModelDescriptorText.format(entry.run.modelFormat))
                    descriptor(ModelDescriptorText.quantization(entry.run.quantization))
                    rateView(Self.rateCell(
                        rate: entry.summary.generationTokensPerSecond,
                        approximate: entry.summary.generationRateIsApproximate,
                        tip: BenchmarkRunCard.generationTip(
                            for: entry.summary.generationRateSource)))
                    value(BenchmarkMetricsPolicy.formatDuration(entry.summary.timeToFirstTokenMs))
                    rateView(Self.rateCell(
                        rate: entry.summary.prefillTokensPerSecond,
                        approximate: entry.summary.prefillIsApproximate,
                        tip: BenchmarkRunCard.prefillTip(for: entry.summary.prefillSource)))
                    value(Self.samplesCell(
                        usable: entry.summary.usableCount, voided: entry.summary.voidedCount))
                    deleteButton(
                        help: Self.deleteRunHelp,
                        accessibilityLabel: "Delete the \(entry.run.modelName) run from "
                            + Self.runTimestampFull(entry.run.startedAt),
                        request: BenchmarkDeletion.run(
                            entry.run, currentPromptVersion: BenchmarkPrompt.version))
                        // While a measurement disables the trash, its own gesture leaves
                        // arbitration and a click would fall through to the row tap below —
                        // opening the detail sheet under a pointer that aimed at "delete", while
                        // the trash's tooltip promises only that deleting is held back. This
                        // empty gesture is deeper than the row tap, so it wins and keeps the
                        // disabled control inert, like the disabled "Delete all" pill. When the
                        // trash is enabled its own Button is deeper still and nothing changes.
                        .onTapGesture {}
                }
            }
        }
        // The Grid hugs its columns; the ROW does not: stretched to the card's full inner width
        // (columns stay leading-packed), so the band, the hover and the click all run edge to
        // edge instead of stopping at the last column. The frame sits BEFORE the interaction
        // modifiers on purpose — they attach to the widened view.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Row interaction lives on the GRID, not on the cells: a GridRow is not a view, so
        // per-cell handlers would leave every 12 pt column gap hover-dead and click-dead and
        // flicker the band on each crossing. One hover handler and one tap gesture hit-test
        // against the row bands instead, which cover the row edge to edge. Clicks on the inner
        // Buttons — chevron, InfoTip, trash — are deeper than this ancestor gesture and keep
        // winning.
        .background(alignment: .topLeading) {
            // `horizontalOutset` mirrors SettingsCard's `contentPadding` (Spacing.standard):
            // the band bleeds under the card's padding so the lit row runs edge to edge of the
            // card, stopping only at its border.
            BenchmarkRowBandLayer(
                ids: ids, interaction: rowInteraction, horizontalOutset: Spacing.standard)
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named(Self.historyTableSpace)) { phase in
            switch phase {
            case .active(let point):
                rowInteraction.pointerMoved(to: point, orderedIDs: ids)
            case .ended:
                rowInteraction.pointerEnded()
            }
        }
        .gesture(
            SpatialTapGesture(coordinateSpace: .named(Self.historyTableSpace))
                .onEnded { tap in
                    guard let id = BenchmarkRowInteractionState.rowID(
                        at: tap.location, frames: rowInteraction.frames, orderedIDs: ids)
                    else { return }
                    openDetail(for: id)
                })
        .coordinateSpace(.named(Self.historyTableSpace))
        .onChange(of: ids) { _, visible in
            rowInteraction.prune(keeping: visible)
        }
    }

    /// Opens the run's detail — the same thing a click anywhere on the row does, and it stays a
    /// Button anyway: a tap gesture is invisible to accessibility, so this chevron IS the
    /// VoiceOver path to the sheet, and the visible affordance that says the row opens at all.
    /// Always visible, never revealed on hover — the same rule the delete button states: a
    /// control that appears under the pointer is found by accident.
    private func detailButton(for run: GenerationBenchmarkRun) -> some View {
        Button {
            openDetail(for: run.id)
        } label: {
            Image(systemName: "chevron.right")
                .font(Typography.caption2.weight(.semibold))
                .foregroundStyle(Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .help(Self.detailHelp)
        .accessibilityLabel(
            "Show everything recorded for the \(run.modelName) run from "
                + Self.runTimestampFull(run.startedAt))
    }

    /// Opens a run's detail and puts the highlight out first — see
    /// `BenchmarkRowInteractionState.willPresentModal` for why the order matters.
    private func openDetail(for id: UUID) {
        rowInteraction.willPresentModal()
        detailRunID = id
    }

    private var historyEntries: [(run: GenerationBenchmarkRun, summary: BenchmarkMetricsPolicy.RunSummary)] {
        let byRun = Dictionary(grouping: samples, by: \.runID)
        return runs.sorted { $0.startedAt > $1.startedAt }.map {
            ($0, BenchmarkMetricsPolicy.summarize(byRun[$0.id] ?? []))
        }
    }

    // MARK: - Filter

    /// Wide enough for a full model id to be recognisable while typing, short enough that the
    /// field does not read as another table column across a 670 pt settings pane.
    private static let filterFieldWidth: CGFloat = 260

    /// One field, in the same place on both tabs, because the question it answers does not change
    /// with the tab. The count beside it is the honest part: a filtered table looks like a short
    /// table, and "2 of 9" is what says it is not.
    private func filterField(visible: Int, total: Int) -> some View {
        HStack(spacing: Spacing.s) {
            TextField(Self.filterPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .inputSurface(.field) {
                    EmptyView()
                } trailing: {
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(Colors.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the filter")
                    }
                }
                .frame(maxWidth: Self.filterFieldWidth)

            if let label = Self.matchCountLabel(visible: visible, total: total, query: query) {
                Text(label)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Always visible rather than revealed on hover: a control that appears under the pointer is
    /// found by accident, and this one is guarded by a confirmation naming exactly what it removes.
    ///
    /// No empty-request branch. Every row this draws is built FROM runs — a leaderboard row cannot
    /// exist without at least one, and a Runs row IS one — so a guard here would be a branch no
    /// input can reach, and a doc comment explaining it would make dead code read as live
    /// (CLAUDE.md #79). `BenchmarkDeletionTests` pins the emptiness case where it is real.
    ///
    /// `help` explains the SCOPE and is the same on every row; `accessibilityLabel` names the
    /// TARGET, because nine identical "Delete" labels are what VoiceOver would otherwise read.
    private func deleteButton(
        help: String, accessibilityLabel: String, request: BenchmarkDeletion.Request
    ) -> some View {
        Button {
            // The confirmation dialog is as modal as the detail sheet, and it swallows
            // pointer-exit the same way — without this the row the trash sits on stays lit
            // behind the dialog and after Cancel (CLAUDE.md #52: the guard must sit on both
            // presenting branches). Both tables' states are cleared because this button serves
            // both; the one whose Grid is not on screen clears nothing.
            rowInteraction.willPresentModal()
            leaderboardInteraction.willPresentModal()
            pendingDeletion = request
        } label: {
            Image(systemName: "trash")
                .font(Typography.caption)
                .foregroundStyle(isMeasuring ? Colors.textQuaternary : Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(isMeasuring)
        .help(isMeasuring ? Self.measuringHelp : help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(Typography.subheadline)
            .foregroundStyle(Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Cells

    /// One column heading: a full word, the unit under it, and the whole explanation on hover.
    ///
    /// The unit belongs in the heading rather than in every cell — eight rows of "tok/s" is noise,
    /// and a bare column of numbers is the thing that made "Gen" unanswerable. `First token` is the
    /// exception with no unit line: `formatDuration` prints "410 ms" / "1.4 s", so the cell already
    /// says what it is.
    private func header(_ spec: Column) -> some View {
        Button {
            // `.map` rather than `if let`: every spec the leaderboard draws has a sort, so an
            // else-branch here would be code no input can reach (CLAUDE.md #79).
            spec.column.map(applySort)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.headerLabel(
                    spec.title, column: spec.column,
                    sortColumn: sortColumn, descending: sortDescending))
                    .font(Typography.caption)
                    .foregroundStyle(sortColumn == spec.column ? Colors.accent : Colors.textTertiary)
                if let unit = spec.unit {
                    Text(unit)
                        .font(Typography.caption2)
                        .foregroundStyle(Colors.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(spec.help)
    }

    private func applySort(_ sort: BenchmarkLeaderboard.SortColumn) {
        if sortColumn == sort {
            sortDescending.toggle()
        } else {
            sortColumn = sort
            sortDescending = Self.defaultDescending(for: sort)
        }
    }

    /// The history table does not sort, so its headings are plain text rather than buttons — but
    /// they are the same `Column` values, carrying the same words, units AND hover explanations.
    ///
    /// The `.help` is not symmetry for its own sake. `Samples` means "how many were USABLE", a
    /// fact that lived only in a source comment and reached no reader; and once a `~` can appear
    /// on this tab, the whole explanation of what it means lives in these strings.
    private func historyHeader(_ spec: Column) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(spec.title).font(Typography.caption).foregroundStyle(Colors.textTertiary)
            if let unit = spec.unit {
                Text(unit).font(Typography.caption2).foregroundStyle(Colors.textTertiary)
            }
        }
        .help(spec.help)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(Typography.subheadlineMedium)
            .monospacedDigit()
            .foregroundStyle(Colors.textPrimary)
    }

    /// A Format / Quantization cell — the same weight as Provider and Version, because it answers
    /// the same kind of question about the row.
    private func descriptor(_ text: String?) -> some View {
        value(Self.descriptorCell(text))
    }

    /// Draws what `Self.rateCell` decided. Every rate on both tables goes through here.
    ///
    /// `showsTip: false` is the one sanctioned opt-out, and `Best run` is its only caller: it
    /// carries the same `~` for the same reason as the `Generation` cell beside it, so a second
    /// identical popover on every row explains the same thing twice. The MARKER is never
    /// optional — only the repeated icon.
    private func rateView(_ cell: Self.RateCell, showsTip: Bool = true) -> some View {
        HStack(spacing: Spacing.xxs) {
            value(cell.text)
            if showsTip, let tip = cell.tip {
                InfoTip(tip, font: Typography.caption)
            }
        }
    }

    // MARK: - Pure presentation (unit-tested)

    // MARK: - What each column means
    //
    // Two rules, learned in that order. The headings this replaced ("Gen", "Best", "TTFT", "Prov")
    // named no quantity and no unit — two adjacent columns of bare numbers, both tokens per second,
    // with nothing saying which was which. Spelling them out fixed that and broke something else:
    // "First token" and "Prompt" are not what these quantities are CALLED, so a reader who wanted
    // to look one up, or compare it with a figure from llama-bench or an Ollama log, had no term to
    // search for. So the title now carries the name the field uses — TTFT, prefill — and the line
    // under it says what that name means. Neither half is optional: an abbreviation alone is where
    // this started, and a description alone is unsearchable.

    /// One column of the leaderboard: what it is called, what it is measured in, and the whole
    /// explanation on hover.
    ///
    /// A value rather than ten inline argument lists, because the defect this table keeps
    /// producing is a heading that names no quantity — and a defect that recurs is a rule the tests
    /// should hold, which they can only do if every heading is reachable from one place.
    nonisolated struct Column: Identifiable, Sendable {
        /// The sort this heading applies where the table sorts, and `nil` for a heading only the
        /// Runs tab has.
        ///
        /// Optional rather than minting a `SortColumn` for `Date` and `Samples`: the Runs tab
        /// ranks nothing, so those cases would be enum members no header could ever reach —
        /// which is the exact shape `.lastMeasured` was in before this change (CLAUDE.md #79).
        let column: BenchmarkLeaderboard.SortColumn?
        /// What the quantity is called, in the field's own vocabulary.
        let title: String
        /// The unit, or — where the title is an abbreviation — what it stands for. Never both:
        /// `TTFT` prints its own unit in the cell ("410 ms" / "1.4 s"), so the line under it is
        /// worth more as the expansion.
        let unit: String?
        let help: String

        var id: String { column?.rawValue ?? title }
    }

    static let modelColumn = Column(
        column: .model, title: "Model", unit: nil, help: modelHelp)

    /// The titles are literals rather than `ModelLoadDetails.formatLabel` / `.quantizationLabel`,
    /// which spell the same two words. That constant is also the `serverFields` DICTIONARY KEY that
    /// persisted runs decode by, so its lifetime is "forever" while a heading's lifetime is a
    /// design decision — two facts that happen to agree, and wiring them together would turn a
    /// rewording of this column into a data bug (CLAUDE.md #91).
    static let formatColumn = Column(
        column: .format, title: "Format", unit: nil, help: formatHelp)

    static let quantizationColumn = Column(
        column: .quantization, title: "Quantization", unit: nil, help: quantizationHelp)

    static let providerColumn = Column(
        column: .provider, title: "Provider", unit: nil, help: providerHelp)

    /// Titled `Version`, not `Server`, since the endpoint moved under the model name: a column
    /// called Server that holds `0.4.21` while the server itself is nowhere on screen is the exact
    /// confusion this table was reported for.
    static let versionColumn = Column(
        column: .providerVersion, title: "Version", unit: "server", help: versionHelp)

    static let generationColumn = Column(
        column: .generation, title: "Generation", unit: "median tok/s", help: generationHelp)

    static let bestColumn = Column(
        column: .best, title: "Best run", unit: "tok/s", help: bestHelp)

    /// The one abbreviation everybody in the field uses for this quantity, with its expansion
    /// underneath. No unit line: `formatDuration` prints "410 ms" / "1.4 s", so the cell carries it.
    static let ttftColumn = Column(
        column: .timeToFirstToken, title: "TTFT", unit: "time to first token", help: firstTokenHelp)

    /// `Prefill` is what the serving literature calls this phase; llama.cpp and Ollama spell the
    /// same measurement `prompt eval`. The old title, `Prompt`, named neither.
    static let prefillColumn = Column(
        column: .prefill, title: "Prefill", unit: "prompt tok/s", help: promptHelp)

    static let runsColumn = Column(
        column: .runCount, title: "Runs", unit: nil, help: runsHelp)

    /// No unit line, by the same rule as `Model`, `Provider` and `Runs`: the title is already
    /// plain words naming what the cell holds, and a second line would be a restatement rather
    /// than an expansion. The cell prints an abbreviated date; the full timestamp is on hover.
    static let lastRunColumn = Column(
        column: .lastMeasured, title: "Last run", unit: nil, help: lastRunHelp)

    // MARK: Runs-tab headings

    /// `Date` and `Samples` exist only on the Runs tab and sort nothing — hence `column: nil`.
    static let dateColumn = Column(column: nil, title: "Date", unit: nil, help: dateHelp)

    static let samplesColumn = Column(
        column: nil, title: "Samples", unit: nil, help: samplesHelp)

    /// The Runs tab's Generation heading is NOT `generationColumn`, and the difference is the
    /// whole reason both exist: on the leaderboard the figure is a median across a model's RUNS,
    /// here it is a median across ONE run's samples. Same name, same unit, different population —
    /// so the unit line drops the word "median" (there is only one run to median over) and the
    /// help says what it is a median OF. Reusing the leaderboard's string would have this tab
    /// claim a median "across this model's runs" on a row that IS one run.
    static let historyGenerationColumn = Column(
        column: nil, title: "Generation", unit: "tok/s", help: historyGenerationHelp)

    /// Left-to-right, exactly as the table draws them. The header row still calls `header(_:)` per
    /// column rather than iterating this — a `ForEach` inside a `GridRow` is one cell's worth of
    /// layout risk for no gain — so this list exists to be ASSERTED against, and the pin that every
    /// abbreviation carries its expansion reads it.
    static let columns: [Column] = [
        modelColumn, formatColumn, quantizationColumn, providerColumn, versionColumn,
        generationColumn, bestColumn, ttftColumn, prefillColumn, runsColumn, lastRunColumn,
    ]

    /// The Runs tab's headings, left-to-right, as its header row draws them.
    ///
    /// Specs the two tabs share appear here BY REFERENCE rather than as copies, so a reworded
    /// column cannot come to mean two things on two tabs (CLAUDE.md #55). `Generation` is
    /// deliberately NOT shared — see `historyGenerationColumn`.
    ///
    /// Its existence is the point as much as its contents: these headings used to be string
    /// literals inside the Grid, so every pin about naming, units and uniqueness read `columns`
    /// and covered exactly half the screen.
    static let historyColumns: [Column] = [
        dateColumn, modelColumn, formatColumn, quantizationColumn,
        historyGenerationColumn, ttftColumn, prefillColumn, samplesColumn,
    ]

    static let noResultsYet = "No results yet. Run the benchmark above to record one."

    /// Says which runs go, because the row shows fewer than the delete removes: a throttled or
    /// older-prompt run of the same model on the same server has no line of its own here.
    static let deleteRowHelp =
        "Delete every run of this model on this server. The confirmation says how many."

    static let deleteRunHelp = "Delete this one run and its samples."

    static let detailHelp =
        "Everything recorded with this run: every sample including the ones the medians excluded "
            + "and why, the machine's state at the time, and what the server said about itself."

    static let deleteAllHelp = "Delete every recorded run and sample."

    /// Why the delete controls are inert right now. Without it a disabled trash icon is a bug.
    static let measuringHelp =
        "A benchmark is running. It records its result when it finishes, so deleting is held back "
            + "until then — otherwise a row removed now would come back on its own."

    /// Names the model AND the server because both are searched — a filter that only said "model"
    /// would make the two rows this table deliberately keeps apart look unreachable.
    static let filterPlaceholder = "Filter by model or server"

    /// Repeats the query back. An empty table under a full field is the one state where the reader
    /// needs to be told what was asked, not just what was found.
    static func noMatches(for query: String, mode: Mode) -> String {
        let subject = mode == .leaderboard ? "model" : "run"
        return "No \(subject) matches \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"."
    }

    /// `nil` while the field is empty: "9 of 9" beside an untouched filter states nothing.
    static func matchCountLabel(visible: Int, total: Int, query: String) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "\(visible) of \(total)"
    }

    static let modelHelp =
        "One row per model AND server. The same model measured against two endpoints is two rows — "
            + "they are two machines, and averaging them would describe neither. The endpoint has no "
            + "column of its own: hover a model's name to see which server that row was measured "
            + "against."

    /// Carries the paragraph that used to live in `modelHelp`, because the fact moved with the
    /// value: a reader wanting to know what SAFETENSORS means now hovers the column that holds it.
    static let formatHelp =
        "The model's file format as the server reported it, VERBATIM and untranslated — and the "
            + "two servers answer slightly different questions with that word. LM Studio names the "
            + "runtime it will use (GGUF, MLX); Ollama names the weights on disk (GGUF, safetensors), "
            + "so a model it runs through MLX still reads safetensors there. Neither is rewritten into "
            + "the other, because the runtime is only inferable from the format and an inference in "
            + "this table would be indistinguishable from a measurement. A dash means the server "
            + "reported none."

    static let quantizationHelp =
        "How the weights were quantized, exactly as the server spells it — Q4_K_M, 4bit, nvfp4, "
            + "MXFP4. Never normalized into one vocabulary: this string is what you would search for, "
            + "or match against a model card or another tool's output, and a tidied-up spelling would "
            + "match nothing. A dash means the server reported none."

    /// What the endpoint line used to say, moved onto the name it identifies.
    ///
    /// Names the PROVIDER as well as the address. On the leaderboard that repeats the Provider
    /// column, which is the cheaper mistake: the Runs tab has no such column, and one wording for
    /// both tables is what keeps them from drifting into two (CLAUDE.md #55).
    ///
    /// `lastMeasured` is the leaderboard's alone and is why the parameter has a default: a
    /// leaderboard row is N runs and its abbreviated `Last run` cell drops the time, so the full
    /// timestamp needs somewhere to live. A Runs row IS one run and already prints its own date,
    /// so repeating it here would tell the reader what the cell beside their pointer says.
    static func endpointTooltip(
        provider: LLMProvider, endpoint: String, lastMeasured: Date? = nil
    ) -> String {
        let measured = "Measured on \(provider.displayName) at \(endpoint.endpointHostLabel)"
        guard let lastMeasured else { return measured }
        return measured + ". Most recent run: \(runTimestampFull(lastMeasured))"
    }

    static let providerHelp = "Which local server produced these figures."

    static let versionHelp =
        "The version of the local inference SERVER — Ollama 0.32.14, LM Studio 0.4.21 — as it "
            + "reported itself on the most recent run behind this row. Not the model's version, not "
            + "the inference engine's (llama.cpp and MLX builds are recorded with the run, not shown "
            + "here), and not this app's. A dash means the server does not report one."

    static let generationHelp =
        "How fast the model WRITES, in tokens per second, once it has started — reading the prompt "
            + "is the separate Prefill column. Ollama's logs call this eval rate, llama-bench calls it "
            + "tg, serving docs call it decode. This is the MEDIAN across this model's runs, which is why "
            + "it is the ranked figure: a single thermally lucky run must not crown a model. Where a "
            + "server reports its own decoding rate the number is the server's; where none does, the "
            + "app times the window itself and the figure is marked with a ~."

    static let bestHelp =
        "The same quantity as Generation — tokens per second of writing — but from the single "
            + "FASTEST run instead of the median of them. It is shown beside the median rather than "
            + "instead of it: the gap between the two is how much this model's speed varies between "
            + "runs, and neither number can say that alone."

    static let firstTokenHelp =
        "TTFT — time to first token: how long from sending the request to the first token "
            + "appearing, as the median across runs. It contains queueing, loading the model and "
            + "reading the prompt — that is what it means, not a defect — so it is never used as a "
            + "generation denominator."

    static let promptHelp =
        "Prefill: how fast the server READS the prompt, in tokens per second, before it writes "
            + "anything. The same measurement llama.cpp and Ollama log as prompt eval and llama-bench "
            + "reports as pp. Measured over a fixed \(BenchmarkPrompt.measuredPromptTokens)-token "
            + "prompt. A ~ means the server did not "
            + "report the time and the app inferred it from the wait for the first token."

    static let runsHelp =
        "How many RUNS this row's medians were taken over — not how many samples. A median over one "
            + "run must not read as a median over seven. \"2 of 5\" means three of the five runs "
            + "produced no usable sample at all and are behind none of these figures."

    static let lastRunHelp =
        "When the most recent run behind this row was measured. It is also the run that supplied "
            + "the Version, Format and Quantization columns, which is why a row can rank on months-"
            + "old numbers while describing the model as it is configured today. The cell is "
            + "abbreviated; hover a row's model name for the full timestamp."

    static let dateHelp =
        "When this run was started — one row here is one run, newest first. The year is "
            + "printed only when it is not the current one; hover a row's model name for the "
            + "full timestamp."

    static let samplesHelp =
        "How many of this run's samples were USABLE — the figures on this row are medians over "
            + "those. \"2 of 5\" means three produced nothing that could be measured; open the row "
            + "to see what happened to each. The warm-up is in neither number: it is stopped on "
            + "purpose as soon as it has loaded the model, so counting it would report a lost "
            + "sample after every healthy run."

    /// Deliberately not `generationHelp`. See `historyGenerationColumn`.
    static let historyGenerationHelp =
        "How fast the model WROTE on this one run, in tokens per second — reading the prompt is the "
            + "separate Prefill column. Ollama's logs call this eval rate, llama-bench calls it tg, "
            + "serving docs call it decode. This is the median across THIS RUN's usable samples; "
            + "the Leaderboard's column of the same name is a median across runs. Where a server "
            + "reports its own decoding rate the number is the server's; where none does, the app "
            + "times the window itself and the figure is marked with a ~."

    /// Why a row carries the warning glyph.
    ///
    /// The SUBJECT differs between the two tables and the consequence does not, so the subject is
    /// a parameter rather than a second hand-written sentence: a leaderboard row is marked only
    /// when EVERY contributing run was throttled, a Runs row when that ONE run was. Two strings
    /// would drift on the half that matters (CLAUDE.md #55).
    ///
    /// The ranking clause is leaderboard-only. The Runs tab is ordered by date and ranks nothing,
    /// so promising "ranked last" there would describe a rule that surface does not have.
    static func throttledTooltip(everyContributingRun: Bool) -> String {
        let subject = everyContributingRun
            ? "Every run behind this figure was" : "This run was"
        let ranking = everyContributingRun ? " Throttled rows are always ranked last." : ""
        return subject
            + " measured while the machine was thermally throttled or in Low Power Mode, so it "
            + "describes that state as much as the model." + ranking
    }

    /// What a Format / Quantization cell prints, given what `ModelDescriptorText` spelled.
    ///
    /// One rule for both tables and both columns, so the absent case is decided once: a value the
    /// server did not report is a dash, exactly as the Version column already spells it. The
    /// capsules these columns replaced drew NOTHING in that case, and were right to — a chip
    /// stands alone, and an em-dash inside one claims a value the server never sent. Under a
    /// heading the reverse holds: a blank cell in a grid reads as a rendering fault.
    static func descriptorCell(_ text: String?) -> String {
        text ?? BenchmarkMetricsPolicy.noValue
    }

    /// One rate cell: the figure, the `~` when its source is not exact, and the explanation that
    /// belongs beside that `~`.
    ///
    /// A value rather than four hand-written `HStack`s, and that is the whole point. The `~` rides
    /// the VALUE and not the column heading — inside one column some rows are exact and some
    /// inferred — which means every site that formats a rate has to remember the marker, and four
    /// of the five did not. `Best run` shipped bare in the cell NEXT to a marked `Generation`
    /// holding the same quantity from the same runs, so one row printed `~47 | 51`; the Runs tab
    /// shipped a bare `47` for the identical client-timed figure the leaderboard marked; the sweep
    /// card passed a literal `false`. A rule remembered at each site is remembered at one of them
    /// (CLAUDE.md #51).
    ///
    /// `tip` is nil for an exact figure AND for an absent one. The second half is not symmetry:
    /// an explanation of how a number was inferred, standing beside a dash, describes an inference
    /// nobody made — the same reason `decorate` refuses to write `~—`.
    nonisolated struct RateCell: Equatable, Sendable {
        let text: String
        let tip: String?
    }

    /// A run's timestamp as a table cell prints it.
    ///
    /// `now` is a parameter and not a `Date()` read, so the year rule is testable without waiting
    /// for January — and because a function that silently consults the wall clock is the shape
    /// CLAUDE.md #81 warns about.
    ///
    /// The year appears only when it is not the current one. The old cell spelled
    /// `"Aug 21, 2026 at 2:03 PM"` in full on every row — 23 characters, the widest single-line
    /// cell in either table, and 5 of them repeating the same year down the column. The full form
    /// survives in `runTimestampFull`, where nothing has to fit.
    static func runTimestamp(_ date: Date, now: Date, includingTime: Bool) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if !sameYear { style = style.year() }
        if includingTime { style = style.hour().minute() }
        return date.formatted(style)
    }

    /// The unabbreviated form, for the places that are not a table cell: tooltips and the
    /// accessibility label of a delete button, which has to name unambiguously what it removes.
    static func runTimestampFull(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The `Runs` cell: how many runs are behind the medians, and — only when there were any —
    /// how many attempts that is out of.
    ///
    /// `"2 of 5"` rather than `"2"`, because a row built from two runs after five attempts is
    /// describing a model that failed three times, and the count alone says the opposite of that.
    /// A clean row stays a bare `"2"`: `"2 of 2"` is the noise this must not add, and a reader who
    /// sees the long form anywhere learns that the short form means nothing went wrong.
    static func runsCell(priced: Int, failed: Int) -> String {
        failed > 0 ? "\(priced) of \(priced + failed)" : "\(priced)"
    }

    /// The `Samples` cell, by the same rule and for the same reason one level down: usable samples,
    /// and the attempt count only when some attempt produced nothing.
    ///
    /// The warm-up is never in either number — it is stopped on purpose the moment it has done its
    /// job, so counting it would report a lost sample after every healthy run.
    static func samplesCell(usable: Int, voided: Int) -> String {
        voided > 0 ? "\(usable) of \(usable + voided)" : "\(usable)"
    }

    static func rateCell(rate: Double?, approximate: Bool, tip: String) -> RateCell {
        let text = BenchmarkRunCard.decorate(
            value: BenchmarkMetricsPolicy.formatRate(rate), unit: "", approximate: approximate)
        let measured = text != BenchmarkMetricsPolicy.noValue
        return RateCell(text: text, tip: measured && approximate ? tip : nil)
    }

    /// An unsortable heading (`column: nil`) never grows an arrow: `nil == sortColumn` is false for
    /// every case, so the guard returns the bare title. A `Date` heading wearing a ▼ that clicking
    /// cannot change is a control that lies about being one.
    static func headerLabel(
        _ title: String,
        column: BenchmarkLeaderboard.SortColumn?,
        sortColumn: BenchmarkLeaderboard.SortColumn,
        descending: Bool
    ) -> String {
        guard column == sortColumn else { return title }
        return "\(title) \(descending ? "▼" : "▲")"
    }

    /// First click on a column picks the direction that answers the question the column asks:
    /// "who is fastest" is descending, "who is slowest to first token" is ascending.
    static func defaultDescending(for column: BenchmarkLeaderboard.SortColumn) -> Bool {
        switch column {
        case .generation, .best, .prefill, .runCount, .lastMeasured: true
        case .model, .format, .quantization, .provider, .providerVersion, .timeToFirstToken:
            false
        }
    }

    /// Which empty this is.
    ///
    /// "No results yet. Run the benchmark above" is only true of an untouched history. Delete the
    /// last comparable run and it becomes a lie sitting an inch above a footer that says N runs
    /// are listed under Runs — two sentences contradicting each other on one card.
    static func emptyLeaderboardText(runCount: Int, hiddenRunCount: Int) -> String {
        guard runCount > 0 else { return noResultsYet }
        if hiddenRunCount == runCount {
            return "Nothing to rank: "
                + (runCount == 1
                    ? "the one run on record uses an older prompt"
                    : "all \(runCount) runs on record use an older prompt")
                + ". They are listed under Runs."
        }
        return "Nothing to rank: no comparable run produced a usable sample. "
            + "Everything on record is listed under Runs."
    }

    /// Short by design. Every column already explains itself on hover, so a footer that repeats
    /// those explanations is read once and skipped forever — it is worth the space only for what
    /// no single column can say: what a ROW is, and which runs are missing from the table.
    ///
    /// `nil` when there is no table: a footer describing columns that are not on screen is the
    /// same defect as an empty state describing a history that is not empty.
    static func footer(mode: Mode, hiddenRunCount: Int, hasRows: Bool) -> String? {
        guard hasRows else { return nil }
        switch mode {
        case .leaderboard:
            let base = "One row per model and server. Generation is the median of a model's runs "
                + "and ranks it; Best run is its fastest."
            guard hiddenRunCount > 0 else { return base }
            return base + " \(hiddenRunCount) "
                + (hiddenRunCount == 1 ? "run uses" : "runs use")
                + " an older prompt — under Runs only."
        case .history:
            return "Every run, newest first, including ones that cannot be ranked."
        }
    }
}
