import SwiftUI

/// Settings → LLM → Downloaded Models: what the current server has on disk, and
/// how to remove it.
///
/// Model names appear nowhere else as individual rows — every other surface
/// renders them inside a `TerminalPicker` menu, which has no room for a size or
/// a per-row action. That, plus the fact that on-disk size is the entire reason
/// anyone deletes a model, is why this is its own card rather than a button
/// bolted onto the picker.
///
/// Modelled on `DictationSettingsView`'s languages card — the same
/// list/confirm/remove problem, already solved once in this codebase.
struct DownloadedModelsCard: View {
    @Environment(NTMSOrchestrator.self) private var store
    @Environment(StoreConfiguration.self) private var config
    @Environment(ModelCatalog.self) private var modelCatalog

    /// The rows on screen AND the endpoint that produced them, replaced as ONE
    /// value so they cannot drift apart.
    ///
    /// Deleting must use the config a row was LISTED under, never the live
    /// `config.globalLLMConfig`. The provider picker sits in this same sheet,
    /// and `refresh()` leaves the previous endpoint's rows on screen with
    /// Remove enabled for the whole fetch — up to ~10 s against an
    /// unresponsive Ollama (`/api/tags` + `/api/ps`, 5 s each). Re-reading the
    /// live config at delete time would send a stale row's id to the NEW
    /// server: an LM Studio `publisher/repoDir` id arriving at Ollama reports
    /// SUCCESS via its idempotent-404 rule while deleting nothing, and between
    /// two Ollama hosts a common tag like `llama3.1:8b` would be genuinely
    /// deleted on the wrong machine.
    /// Internal, not private, so `DownloadedModelsCardLogic` can be pinned by
    /// tests — the invariant it encodes was a real bug, not a hypothetical.
    struct Listing {
        let config: LLMConfig
        let models: [DownloadedModel]
        let deletion: DownloadedModelDeletion
        let storageLocation: String?
    }

    @State private var listing: Listing?
    @State private var isLoading = false
    @State private var removing: Set<String> = []
    @State private var pendingRemoval: DownloadedModel?
    @State private var lastErrorMessage: String?
    /// Guards against a slow probe from a previous (provider, server) selection
    /// overwriting fresh results (CLAUDE.md #38).
    @State private var fetchGeneration = 0

    /// Only (provider, server) — NOT the selected model. This card is about
    /// what is on disk, which doesn't change when the user picks a model.
    ///
    /// The server half is the endpoint COMMIT generation, not the live URL: the
    /// Settings URL field writes `llmBaseURLString` on every keystroke, and this
    /// card's fetch is two round-trips (`/api/tags` + `/api/ps`, 5 s each).
    private var fetchKey: String {
        "\(config.llmProvider.rawValue)|\(config.llmEndpointGeneration)"
    }

    private var models: [DownloadedModel] { listing?.models ?? [] }

    /// No listing yet ⇒ no deletion offered. The empty reason renders nothing,
    /// so the card doesn't flash an "unavailable" notice before its first probe.
    private var deletion: DownloadedModelDeletion {
        listing?.deletion ?? .unavailable(reason: "")
    }

    /// The provider the ROWS belong to, which during a switch is not yet the
    /// live one.
    private var listedProvider: LLMProvider { listing?.config.provider ?? config.llmProvider }

    var body: some View {
        SettingsCard(
            header: "Downloaded Models",
            systemImage: "internaldrive",
            footer: footerText
        ) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.error)
                }

                if case .unavailable(let reason) = deletion, !reason.isEmpty {
                    Text(reason)
                        .font(Typography.caption)
                        .foregroundStyle(Colors.textSecondary)
                }

                content

                HStack {
                    SettingsPillButton(
                        title: "Refresh",
                        icon: "arrow.clockwise",
                        isLoading: isLoading,
                        action: { Task { await refresh() } }
                    )
                    .disabled(isLoading)

                    Spacer()

                    if let total = totalSizeText {
                        Text(total)
                            .font(Typography.caption)
                            .foregroundStyle(Colors.textTertiary)
                    }
                }
            }
        }
        .task(id: fetchKey) {
            await refresh()
        }
        .onChange(of: fetchKey) {
            // Synchronous, unlike `.task` — a dialog opened against the old
            // endpoint must not survive into the new one, and the rows it was
            // raised from are about to be replaced.
            pendingRemoval = nil
        }
        .confirmationDialog(
            "Remove downloaded model?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { model in
            Button("Remove \(model.displayName)", role: .destructive) {
                let captured = model
                pendingRemoval = nil
                Task { await remove(model: captured) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { model in
            Text(confirmationMessage(for: model))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && models.isEmpty {
            HStack(spacing: Spacing.s) {
                NTMSLoader(.small)
                Text("Reading downloaded models…")
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                Spacer()
            }
            .padding(.vertical, Spacing.s)
        } else if models.isEmpty {
            Text(emptyStateText)
                .font(Typography.caption)
                .foregroundStyle(Colors.textTertiary)
        } else {
            ForEach(models) { model in
                DownloadedModelRow(
                    model: model,
                    canRemove: deletion.isAvailable,
                    isRemoving: removing.contains(model.id),
                    onRemove: { pendingRemoval = model }
                )
            }
        }
    }

    /// "We looked and found nothing" and "we can't look from here" are different
    /// facts. Only LM Studio can be in the second state — its downloads are
    /// readable through the filesystem, not the API, so a remote server is
    /// opaque. Saying "no models found" there would be a claim we can't make.
    private var emptyStateText: String {
        if listedProvider == .lmStudio, !deletion.isAvailable {
            return "This server's downloads aren't visible from here."
        }
        return switch listedProvider {
        case .lmStudio: "No models found in LM Studio's models folder."
        case .ollama: "No models downloaded yet."
        }
    }

    private var footerText: String? {
        var parts: [String] = []
        if let storageLocation = listing?.storageLocation {
            parts.append("Stored in \(storageLocation).")
        }
        if listedProvider == .lmStudio, deletion == .movesToTrash {
            // Stated plainly because it is a real, reported LM Studio behaviour
            // (lmstudio-bug-tracker#835) and the alternative — reaching into
            // `~/.lmstudio/.internal/model-index-cache.json` — would couple this
            // app to an undocumented file format that changes between releases.
            parts.append("LM Studio may keep showing a removed model until it restarts.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var totalSizeText: String? {
        let sizes = models.compactMap(\.sizeBytes)
        guard !sizes.isEmpty else { return nil }
        return "\(Self.formatBytes(sizes.reduce(0, +))) total"
    }

    private func confirmationMessage(for model: DownloadedModel) -> String {
        var parts: [String] = []
        // Scoped to the endpoint the ROW came from, matching what the delete
        // will target — the reference check is base-URL-keyed, so using the
        // live URL here would answer about a different server.
        let base = listing?.config.baseURLString ?? config.llmBaseURLString
        if let warning = store.downloadedModelReferenceWarning(model, base: base) {
            parts.append(warning)
        }
        if let detail = deletion.confirmationDetail {
            parts.append(detail)
        }
        if let size = model.sizeBytes {
            parts.append("Frees \(Self.formatBytes(size)).")
        }
        return parts.joined(separator: " ")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Actions

    private func refresh() async {
        fetchGeneration += 1
        let expected = fetchGeneration
        isLoading = true
        defer { if fetchGeneration == expected { isLoading = false } }

        // Read the config ONCE. The three probes below are separated by awaits
        // during which the user can change provider or server, and a listing
        // stitched from two different endpoints would be incoherent.
        let requestConfig = config.globalLLMConfig

        let capability = await store.downloadedModelDeletion(config: requestConfig)
        let location = await store.downloadedModelStorageLocation(config: requestConfig)
        let fetched: [DownloadedModel]
        var failure: String?
        do {
            fetched = try await store.downloadedModels(config: requestConfig)
        } catch {
            fetched = []
            failure = "Couldn't read downloaded models: \(error.localizedDescription)"
        }

        guard fetchGeneration == expected else { return }
        listing = Listing(
            config: requestConfig,
            models: fetched,
            deletion: capability,
            storageLocation: location)
        lastErrorMessage = failure
    }

    private func remove(model: DownloadedModel) async {
        // Delete against the endpoint the row was LISTED under, and only while
        // the row is still one of the listed ones. Both conditions come from
        // the same pinned `Listing`, so a provider/server switch mid-fetch can
        // neither retarget the delete nor act on a row that has been replaced.
        guard let deletedFrom = DownloadedModelsCardLogic.deletionTarget(for: model, in: listing)
        else { return }

        removing.insert(model.id)
        defer { removing.remove(model.id) }
        lastErrorMessage = nil

        let result = await store.deleteDownloadedModel(model, config: deletedFrom)
        if case .failure(let error) = result {
            // Formatted from the returned error, NOT re-read from
            // `store.lastErrorMessage`: the global banner CONSUMES that slot
            // (sets it back to nil), so reading it here would be a race whose
            // loser shows an empty message. The banner is the transient
            // notice; this is the copy that stays next to the row.
            lastErrorMessage = "Couldn't remove \(model.displayName): \(error.localizedDescription)"
            return
        }

        await refresh()
        // `ModelCatalog` has no invalidation API — only a per-key refresh — so
        // every key that could still be offering the deleted model has to be
        // refreshed explicitly. Keyed on the endpoint we deleted FROM, not the
        // live one: `refresh()` above may already have re-pinned `listing` to a
        // different server, and it is the old server's cache that is now stale.
        // The vision-only key is a DIFFERENT cache entry.
        await modelCatalog.refresh(url: deletedFrom.baseURLString, provider: deletedFrom.provider)
        await modelCatalog.refresh(
            url: deletedFrom.baseURLString, provider: deletedFrom.provider, visionOnly: true)
    }
}

// MARK: - Logic

/// The one decision in this card that can destroy data if it is wrong, split
/// out so it can be pinned without rendering a view.
enum DownloadedModelsCardLogic {

    /// The endpoint a Remove tap must target, or `nil` when the tap must be
    /// ignored.
    ///
    /// Answers from the pinned `Listing` and NEVER from live settings. The
    /// provider picker shares this sheet and `refresh()` leaves the previous
    /// endpoint's rows on screen for the whole fetch — up to ~10 s against an
    /// unresponsive Ollama — so a live read would let a switch retarget a
    /// delete that is already on screen. Two ways that goes wrong: an LM Studio
    /// `publisher/repoDir` id arriving at Ollama reports SUCCESS through its
    /// idempotent-404 rule while deleting nothing, and between two Ollama hosts
    /// a common tag like `llama3.1:8b` is genuinely deleted on the wrong
    /// machine.
    ///
    /// Requiring the row to still be listed closes the other half: a row that
    /// has since been replaced is no longer something the user can see, so
    /// acting on it would be acting on a screen that no longer exists.
    static func deletionTarget(
        for model: DownloadedModel,
        in listing: DownloadedModelsCard.Listing?
    ) -> LLMConfig? {
        guard let listing, listing.models.contains(where: { $0.id == model.id }) else { return nil }
        return listing.config
    }
}

// MARK: - Row

private struct DownloadedModelRow: View {
    let model: DownloadedModel
    let canRemove: Bool
    let isRemoving: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.displayName)
                    .font(Typography.subheadlineMedium)
                    .foregroundStyle(Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
            }

            Spacer()

            if model.isLoaded {
                Text("Loaded")
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Colors.success)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                        RoundedRectangle.squircle(CornerRadius.small).fill(Colors.successTint)
                    )
            }

            if canRemove {
                SettingsPillButton(
                    title: isRemoving ? "Removing…" : "Remove",
                    icon: "trash",
                    isLoading: isRemoving,
                    isDestructive: true,
                    action: onRemove
                )
                .disabled(isRemoving)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.s)
        .background(
            RoundedRectangle.squircle(CornerRadius.small)
                .fill(isHovered ? Colors.surfaceHover : Color.clear)
        )
        .contentShape(Rectangle())
        .trackHover($isHovered)
        .animationWithReduceMotion(Animations.quick, value: isHovered)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let size = model.sizeBytes {
            parts.append(DownloadedModelsCard.formatBytes(size))
        }
        if let detail = model.detail {
            parts.append(detail)
        }
        return parts.isEmpty ? "Size unknown" : parts.joined(separator: " · ")
    }
}
