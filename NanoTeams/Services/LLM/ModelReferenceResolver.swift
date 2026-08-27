import Foundation

/// Whether a downloaded model FOLDER backs any model the app references — answered in three
/// states, because two are not enough.
///
/// ## The namespaces do not match, and no string rule can bridge them
///
/// `LMStudioModelsFolder.referenceHints` builds ids from what is on DISK (`<publisher>/<repoDir>`,
/// the `-GGUF`-stripped form, the bare repo name). Settings, `teams.json` role overrides,
/// generated-team rosters and the benchmark target all store the key the SERVER reports. Measured
/// on a live 12-model library: `lmstudio-community/gpt-oss-20b-GGUF` on disk against
/// `openai/gpt-oss-20b` in settings — and that key is the SHIPPED DEFAULT for the shipped default
/// provider, so the failing case is the canonical path, not an exotic one.
///
/// String similarity was refused rather than untried: `google/gemma-4-e2b` sits on disk as
/// `gemma-4-E2B-it-MLX-4bit` (an infix `-it-` no prefix rule survives), and one API key can map
/// to TWO folders (`openai/gpt-oss-20b` → both a GGUF and an MLX build). The server does not
/// supply the missing edge either: neither model-list response carries a path, checked by body.
///
/// ## What IS in the data: a residue argument over the whole listing
///
/// Exact equality, applied to the SET rather than the pair. A reference that matches no folder
/// at all is unresolved — and an unresolved reference may be backed by ANY folder here, including
/// this one. That is `.undetermined`, and it is the state the old `Bool` could not express: it
/// reported "not referenced", which the user reads as "safe to delete".
///
/// Where the namespaces agree — the common case, and Ollama's by construction, since
/// `OllamaDownloadedModelStore` seeds hints from the same names the API reports — the residue is
/// empty and every row is determinate. So this adds NO new noise where nothing was wrong.
///
/// `ChatModelEnsurer.sameModel` is used unchanged and must NOT be widened: it is the SSOT for
/// load/unload identity, where being exact is what stops the wrong instance being unloaded.
nonisolated enum ModelReferenceResolver {

    /// One place the app names a model, plus a human-readable description of that place.
    struct Site: Equatable, Hashable {
        let modelName: String
        /// The COMPLETE sentence shown to the user, not a fragment: "your LLM settings
        /// currently USE" and "a team role currently USES" disagree on the verb, so a caller
        /// composing one sentence from a fragment gets one of the two wrong.
        let description: String
    }

    enum Verdict: Equatable {
        /// Determinate YES — some reference matches THIS folder's hints exactly.
        case referenced(descriptions: [String])
        /// Determinate NO — every reference resolved to a different folder, or is not served here.
        case notReferenced
        /// Could not determine: at least one reference matched no folder at all (or the server
        /// did not answer). Not the same as "no" (#97).
        case undetermined(unresolved: [String])
    }

    /// - Parameters:
    ///   - folder: the row being judged.
    ///   - allFolders: every downloaded folder in the same root — needed to decide whether an
    ///     unmatched reference is unresolved GLOBALLY or merely resolved elsewhere.
    ///   - references: every place the app names a model on this server.
    ///   - serverKeys: model keys the server reports, or `nil` when it did not answer.
    ///
    ///     Load-bearing, and NOT optional in practice. It is what keeps this from cautioning on
    ///     every row: a reference the server does not serve at all cannot be backed by a folder
    ///     here, so it leaves the row determinate. Without it — the server silent — every
    ///     unmatched reference is genuinely undecidable, and saying so is the honest answer
    ///     (#87, silence is a third state), not noise.
    static func resolve(
        folder: DownloadedModel,
        allFolders: [DownloadedModel],
        references: [Site],
        serverKeys: Set<String>?
    ) -> Verdict {
        guard !references.isEmpty else { return .notReferenced }

        let matchesThisFolder = { (name: String) in
            folder.referenceHints.contains { ChatModelEnsurer.sameModel($0, name) }
        }
        let hits = references.filter { matchesThisFolder($0.modelName) }
        if !hits.isEmpty {
            return .referenced(descriptions: Array(Set(hits.map(\.description))).sorted())
        }

        // Every remaining reference either resolved to a DIFFERENT folder (fine — it is not
        // this one), or resolved to nothing. Only the second kind leaves this row in doubt.
        let unresolved = references
            .filter { reference in
                let matchedElsewhere = allFolders.contains { other in
                    other.id != folder.id
                        && other.referenceHints.contains {
                            ChatModelEnsurer.sameModel($0, reference.modelName)
                        }
                }
                if matchedElsewhere { return false }
                // A reference the server does not serve at all cannot be backed by a folder
                // here, so it leaves this row determinate. Only meaningful when the server
                // answered; with `nil` we know nothing and must stay in doubt.
                if let serverKeys,
                   !serverKeys.contains(where: { ChatModelEnsurer.sameModel($0, reference.modelName) }) {
                    return false
                }
                return true
            }
            .map(\.modelName)

        return unresolved.isEmpty
            ? .notReferenced
            : .undetermined(unresolved: Array(Set(unresolved)).sorted())
    }
}
