import SwiftUI

// MARK: - Model Quick Picker
//
// The model switcher in the middle of `TerminalStatusBar`. Opening it re-requests
// the model list AND re-probes the server, so what the user is about to pick from
// is current and the pill beside it agrees.
//
// Why a popover and not a `Menu`: SwiftUI's `Menu` exposes no will-open callback,
// and AppKit snapshots its content when it opens — a fetch that lands mid-open
// cannot repaint it, and an animating `NTMSLoader` cannot live in a menu item at
// all. `Button` + `.popover(isPresented:)` gives an exact open event that also
// fires for keyboard and VoiceOver activation. Same shape as the sibling
// `PrefixCacheStatusIndicator` in this row and as `SkillsPickerButton`.

struct ModelQuickPicker: View {
    @Environment(StoreConfiguration.self) private var config
    @Environment(ModelCatalog.self) private var modelCatalog
    @Environment(LLMStatusMonitor.self) private var monitor

    @State private var isPresented = false
    /// The endpoint the OPEN popover's rows belong to. Pinned at present time and
    /// never re-read from the live config while open, so a pick can only ever land
    /// on the endpoint whose list it was rendered from. Same hardening
    /// `DownloadedModelsCard` carries, applied to a surface that stays open across
    /// async updates.
    @State private var pinned: Endpoint?
    /// Row order frozen at present time. `normalizedUnique()` sorts
    /// case-insensitively, so a model arriving in the refresh lands in the MIDDLE
    /// of the list and would shift the row the user is aiming at.
    @State private var renderedOrder: [String] = []
    @State private var searchText = ""
    @State private var contentHeight: CGFloat = .infinity

    struct Endpoint: Equatable {
        let url: String
        let provider: LLMProvider
    }

    private var liveEndpoint: Endpoint {
        Endpoint(url: config.llmBaseURLString, provider: config.llmProvider)
    }

    private var displayModel: String {
        let trimmed = config.llmModelName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "—" : trimmed.uppercased()
    }

    var body: some View {
        Button { open() } label: { collapsedLabel }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .help(config.llmModelName.isEmpty ? "Switch model" : config.llmModelName)
            .accessibilityLabel("Model: \(displayModel)")
            .accessibilityHint("Opens the model list")
            .popover(isPresented: $isPresented, arrowEdge: .top) { popoverBody }
            .task(id: config.llmEndpointGeneration) {
                // Pre-warm only, so the FIRST open paints instantly. Keyed on the
                // commit generation, never on the live URL — the Settings URL field
                // writes that on every keystroke, which would fire one request per
                // typed character against half-typed hosts.
                await modelCatalog.loadIfNeeded(
                    url: liveEndpoint.url, provider: liveEndpoint.provider)
            }
            .onChange(of: liveEndpoint) { _, _ in
                // The endpoint moved out from under an open popover — Settings is a
                // separate window and can be open at the same time. Dismiss rather
                // than swap rows underneath the pointer.
                if isPresented { isPresented = false }
            }
    }

    private var collapsedLabel: some View {
        HStack(spacing: Spacing.xxs) {
            Text(displayModel)
                .font(Typography.term2xs)
                .tracking(Typography.labelTracking)
                .foregroundStyle(Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Colors.textQuaternary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    // MARK: Open / refresh

    private func open() {
        let endpoint = liveEndpoint
        pinned = endpoint
        searchText = ""
        contentHeight = .infinity
        renderedOrder = modelCatalog.models(for: endpoint.url, provider: endpoint.provider)
        isPresented = true
        refresh(endpoint)
    }

    /// Both halves of "this endpoint is now interesting". Fire-and-forget, and two
    /// independent tasks: results arrive through observation, and awaiting either
    /// would block the popover's presentation on a network round-trip — while the
    /// 2 s probe and the 5 s (Ollama: longer) fetch have very different latencies.
    private func refresh(_ endpoint: Endpoint) {
        Task {
            let reachedServer = await modelCatalog.refresh(
                url: endpoint.url, provider: endpoint.provider)
            // One-way: a returned list is a 2xx from the same path the pill probes,
            // so it can turn the pill green. A failure claims nothing and must never
            // turn it red — that is the probe's job.
            if reachedServer { monitor.noteReachable() }
        }
        Task { await monitor.checkNow() }
    }

    private func pick(_ model: String) {
        // Re-picking the current model is a dismiss, not a write: `switchChatModel`
        // already no-ops on the same model, but not writing keeps the residency hook
        // from being woken at all.
        if model != config.llmModelName { config.llmModelName = model }
        isPresented = false
    }

    private func submit() {
        guard let name = ModelQuickPickerLogic.submitSelection(in: rows, query: searchText)
        else { return }
        pick(name)
    }

    // MARK: Derived state (all against `pinned`, never the live config)

    private var freshModels: [String] {
        guard let pinned else { return [] }
        return modelCatalog.models(for: pinned.url, provider: pinned.provider)
    }

    private var rows: [ModelQuickPickerLogic.Row] {
        ModelQuickPickerLogic.rows(
            available: ModelQuickPickerLogic.stableOrder(
                fresh: freshModels, priorOrder: renderedOrder),
            selected: config.llmModelName)
    }

    private var hasLoadedList: Bool {
        guard let pinned else { return false }
        return modelCatalog.hasLoaded(pinned.url, provider: pinned.provider)
    }

    private var isFetchingModels: Bool {
        guard let pinned else { return false }
        return modelCatalog.isFetching(pinned.url, provider: pinned.provider)
    }

    private var fetchError: String? {
        guard let pinned else { return nil }
        return modelCatalog.error(for: pinned.url, provider: pinned.provider)
    }

    // MARK: Popover

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            TerminalDivider()
            searchField
            content
            footer
        }
        .padding(Spacing.m)
        .frame(width: 320)
        .onChange(of: freshModels) { _, arrived in
            // Seed the freeze the first time a list actually lands while we are on
            // screen. Opening with a cold cache (first open of a session, after a
            // provider flip, after a failed fetch) leaves `renderedOrder` empty —
            // which is exactly `stableOrder`'s identity case, so without this the
            // anti-reorder protection is absent on precisely the opens where a list
            // arrives mid-open and a second refresh could re-sort under the pointer.
            if renderedOrder.isEmpty { renderedOrder = arrived }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            MonoLabel(text: "Models", size: .xs)
            Spacer(minLength: Spacing.xs)
            if isFetchingModels {
                NTMSLoader(font: Typography.term2xs, color: Colors.accent)
            }
            Button {
                if let pinned { refresh(pinned) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFetchingModels)
            .help("Re-request the model list")
            .accessibilityLabel("Refresh model list")
        }
    }

    private var searchField: some View {
        TextField("Search models…", text: $searchText)
            .textFieldStyle(.plain)
            .font(Typography.termBase)
            .onSubmit { submit() }
            .inputSurface(.field) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textTertiary)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var content: some View {
        let visible = ModelQuickPickerLogic.filter(rows, query: searchText)
        if !visible.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(visible) { row in
                        rowView(row)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if abs(newHeight - contentHeight) > 1 { contentHeight = newHeight }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, 320))
        } else if !rows.isEmpty {
            message("No models match “\(searchText)”.")
        } else if let placeholder = ModelQuickPickerLogic.placeholder(
            rowCount: rows.count,
            isFetching: isFetchingModels,
            hasError: fetchError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasEndpoint: !(pinned?.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            hasLoadedList: hasLoadedList,
            isReachable: monitor.isReachable
        ) {
            if placeholder == .loading {
                HStack(spacing: Spacing.xs) {
                    NTMSLoader(.small)
                    message(ModelQuickPickerLogic.message(for: placeholder))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.s)
            } else {
                message(ModelQuickPickerLogic.message(for: placeholder))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if monitor.isChecking {
            HStack(spacing: Spacing.xs) {
                NTMSLoader(font: Typography.term2xs, color: Colors.accent)
                Text("Checking server…")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }
        } else if let status = EndpointStatus.resolve(
            fetchError: fetchError, isFetching: isFetchingModels) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "xmark.octagon")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.error)
                    .accessibilityHidden(true)
                Text(status.message)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowView(_ row: ModelQuickPickerLogic.Row) -> some View {
        Button { pick(row.name) } label: {
            HStack(spacing: Spacing.xs) {
                Text(row.name)
                    .font(Typography.termBase)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
                    // Middle, not head as the collapsed label uses: in a LIST the
                    // vendor prefix (`unsloth/`, `google/`) is the disambiguator.
                    .truncationMode(.middle)
                if row.isMissingFromServer {
                    Text("not on server")
                        .font(Typography.term2xs)
                        .tracking(Typography.labelTracking)
                        .foregroundStyle(Colors.warning)
                }
                Spacer(minLength: Spacing.xs)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(Typography.caption)
                        .foregroundStyle(Colors.success)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Spacing.xxs)
            .padding(.horizontal, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.name)
        .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pure logic

/// Presentation-free decisions behind `ModelQuickPicker`, split out so the row
/// identity, ordering and empty-state rules are unit-testable (the view keeps only
/// rendering). Mirrors `SkillsPickerLogic`.
nonisolated enum ModelQuickPickerLogic {

    struct Row: Identifiable, Equatable {
        let name: String
        let isSelected: Bool
        /// A configured model the server did not list, so the picker can never show
        /// "nothing selected" while a model IS configured.
        let isMissingFromServer: Bool
        var id: String { name }
    }

    enum Placeholder: Equatable {
        case noEndpoint
        case loading
        case offline
        case emptyList
    }

    /// Keeps rows already on screen where they are and appends arrivals, so a
    /// refresh landing under the pointer cannot move the row the user is aiming at.
    /// Empty `priorOrder` yields `fresh` unchanged. Names absent from `fresh` are
    /// dropped immediately — a model the server no longer has must not stay
    /// clickable.
    static func stableOrder(fresh: [String], priorOrder: [String]) -> [String] {
        guard !priorOrder.isEmpty else { return fresh }
        let available = Set(fresh)
        var seen = Set<String>()
        var result: [String] = []
        for name in priorOrder where available.contains(name) && seen.insert(name).inserted {
            result.append(name)
        }
        for name in fresh where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    /// Server list + configured model → rows, in `available` order.
    ///
    /// Dedup and empty-drop are LOAD-BEARING: `id` is the name, so a repeat or an
    /// empty entry is a duplicate `ForEach` id (rule #22). Defense in depth — every
    /// decode path already calls `.normalizedUnique()` — but the seam must not
    /// depend on that. Non-empty names are NOT trimmed: the exact server id is what
    /// gets written to `llmModelName` and put on the wire.
    static func rows(available: [String], selected: String) -> [Row] {
        let trimmedSelection = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var rows: [Row] = []
        for name in available
            where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && seen.insert(name).inserted {
            rows.append(Row(name: name,
                            isSelected: name == selected,
                            isMissingFromServer: false))
        }
        guard !trimmedSelection.isEmpty, !seen.contains(selected) else { return rows }
        return [Row(name: selected, isSelected: true, isMissingFromServer: true)] + rows
    }

    /// Case-insensitive substring on the name. Empty / whitespace-only query is the
    /// identity.
    static func filter(_ rows: [Row], query: String) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Return-key resolution. An exact case-insensitive name match wins (so typing a
    /// full name that is also a prefix of a longer one picks what was typed); else a
    /// filter that resolved to exactly one row. `nil` means ambiguous — do nothing.
    static func submitSelection(in rows: [Row], query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = rows.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return exact.name
        }
        let matches = filter(rows, query: trimmed)
        return matches.count == 1 ? matches[0].name : nil
    }

    /// What to render INSTEAD of a list. `hasError` yields `nil` on purpose — the
    /// footer already carries the error, and reporting it twice reads as two
    /// problems. Precedence: rows > noEndpoint > loading > error > loaded-empty >
    /// offline > never-fetched.
    ///
    /// `hasLoadedList` outranks `isReachable` deliberately. A completed fetch is a
    /// fact about THIS endpoint observed just now; the pill is a shared bit that a
    /// coalesced fetch or a timed-out probe can leave up to a poll interval stale.
    /// Narrating an empty list from the pill is what produced "Server is offline —
    /// nothing to list." about a server that had just answered 2xx.
    static func placeholder(
        rowCount: Int,
        isFetching: Bool,
        hasError: Bool,
        hasEndpoint: Bool,
        hasLoadedList: Bool,
        isReachable: Bool
    ) -> Placeholder? {
        guard rowCount == 0 else { return nil }
        guard hasEndpoint else { return .noEndpoint }
        if isFetching { return .loading }
        if hasError { return nil }
        if hasLoadedList { return .emptyList }
        return isReachable ? .emptyList : .offline
    }

    static func message(for placeholder: Placeholder) -> String {
        switch placeholder {
        case .noEndpoint: "No server address configured."
        case .loading: "Loading models…"
        case .offline: "Server is offline — nothing to list."
        case .emptyList: "The server reported no models."
        }
    }
}
