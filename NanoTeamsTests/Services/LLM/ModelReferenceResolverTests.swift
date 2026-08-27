import XCTest

@testable import NanoTeams

/// `ModelReferenceResolver` is `nonisolated` and pure, so this suite is a plain `XCTestCase`.
final class ModelReferenceResolverTests: XCTestCase {

    private func folder(_ id: String, hints: [String]) -> DownloadedModel {
        DownloadedModel(id: id, displayName: id, referenceHints: hints)
    }

    private func site(_ name: String, _ description: String = "Your LLM settings currently use this model.")
        -> ModelReferenceResolver.Site {
        .init(modelName: name, description: description)
    }

    /// The MEASURED case, and the whole reason this type exists: on a live 12-model library the
    /// shipped default `openai/gpt-oss-20b` matched NEITHER folder that backs it, so the old
    /// Bool reported "not referenced" and Remove sent ~11 GB to the Trash with no warning.
    private var measuredFolders: [DownloadedModel] {
        [folder("lmstudio-community/gpt-oss-20b-GGUF",
                hints: ["lmstudio-community/gpt-oss-20b-GGUF", "lmstudio-community/gpt-oss-20b",
                        "gpt-oss-20b-GGUF"]),
         folder("mlx-community/gpt-oss-20b-MXFP4-Q8",
                hints: ["mlx-community/gpt-oss-20b-MXFP4-Q8", "gpt-oss-20b-MXFP4-Q8"])]
    }

    /// RED: require a folder-ID match rather than a HINT match → an exact reference to a hint
    /// form stops being recognised and every determinate YES disappears.
    func testReferenced_whenAHintMatchesExactly() {
        let f = folder("pub/a-GGUF", hints: ["pub/a-GGUF", "pub/a"])
        let v = ModelReferenceResolver.resolve(
            folder: f, allFolders: [f], references: [site("pub/a")], serverKeys: ["pub/a"])
        XCTAssertEqual(v, .referenced(descriptions: ["Your LLM settings currently use this model."]))
    }

    /// RED: let an unresolved reference still yield `.notReferenced` → the measured 11 GB case
    /// silently returns to producing no warning at all.
    func testUndetermined_whenAReferenceMatchesNoFolder() {
        let folders = measuredFolders
        let v = ModelReferenceResolver.resolve(
            folder: folders[0], allFolders: folders,
            references: [site("openai/gpt-oss-20b")],
            serverKeys: ["openai/gpt-oss-20b"])
        XCTAssertEqual(v, .undetermined(unresolved: ["openai/gpt-oss-20b"]))
    }

    /// BOTH folders must go undetermined — one API key legitimately maps to two folders, and
    /// scoping the doubt to the "similar-looking" one would be string similarity by the back
    /// door, which the measured `gemma-4-E2B-it-MLX-4bit` case rules out.
    ///
    /// RED: restrict `.undetermined` to folders whose name resembles the key → the second row
    /// reports `.notReferenced` and Remove on it is silent again.
    func testUndetermined_reachesEveryUnmatchedFolder_notJustTheSimilarOne() {
        let folders = measuredFolders
        for f in folders {
            XCTAssertEqual(
                ModelReferenceResolver.resolve(
                    folder: f, allFolders: folders,
                    references: [site("openai/gpt-oss-20b")],
                    serverKeys: ["openai/gpt-oss-20b"]),
                .undetermined(unresolved: ["openai/gpt-oss-20b"]),
                "folder \(f.id) must also be in doubt")
        }
    }

    /// RED: drop the `matchedElsewhere` test → a reference that plainly belongs to a SIBLING
    /// folder puts this row in doubt, and every row cautions about every other row's model.
    func testNotReferenced_whenTheReferenceResolvedToAnotherFolder() {
        let a = folder("pub/a", hints: ["pub/a"])
        let b = folder("pub/b", hints: ["pub/b"])
        let v = ModelReferenceResolver.resolve(
            folder: a, allFolders: [a, b], references: [site("pub/b")], serverKeys: ["pub/b"])
        XCTAssertEqual(v, .notReferenced)
    }

    /// RED: drop the `serverKeys` membership test → a stale reference to a model this server
    /// does not serve leaves the row `.undetermined` forever, which is the noise the design
    /// promised not to add.
    func testNotReferenced_whenTheServerDoesNotServeTheKeyAtAll() {
        let f = folder("pub/a", hints: ["pub/a"])
        let v = ModelReferenceResolver.resolve(
            folder: f, allFolders: [f], references: [site("gone/model")],
            serverKeys: ["pub/a"])
        XCTAssertEqual(v, .notReferenced)
    }

    /// Silence is a third state (#87): a server that did not answer cannot license "not
    /// referenced".
    ///
    /// RED: treat `nil` as an empty set → the unmatched reference is read as "not served here"
    /// and the row reports `.notReferenced` on no evidence.
    func testUndetermined_whenTheServerIsSilent() {
        let f = folder("pub/a", hints: ["pub/a"])
        let v = ModelReferenceResolver.resolve(
            folder: f, allFolders: [f], references: [site("mystery/model")], serverKeys: nil)
        XCTAssertEqual(v, .undetermined(unresolved: ["mystery/model"]))
    }

    /// Where the two namespaces agree — the common case, and Ollama's by construction — every
    /// row is determinate and nothing cautions.
    ///
    /// RED: make `.undetermined` the fallback whenever a reference does not match THIS folder →
    /// this fails, and a healthy library cautions on every row.
    func testNoNoise_whenEveryReferenceResolves() {
        let a = folder("llama3:8b", hints: ["llama3:8b"])
        let b = folder("qwen3:14b", hints: ["qwen3:14b"])
        XCTAssertEqual(
            ModelReferenceResolver.resolve(
                folder: a, allFolders: [a, b],
                references: [site("qwen3:14b")], serverKeys: ["llama3:8b", "qwen3:14b"]),
            .notReferenced)
    }

    /// The control CLAUDE.md #56 requires, predicted GREEN: `sameModel` is the SSOT for
    /// load/unload identity and must not be widened to paper over the namespace gap.
    ///
    /// RED: add a `-GGUF` suffix rule to `ChatModelEnsurer.sameModel` → this reds (the two stop
    /// being different models), and so does `LMStudioModelsFolderTests`, which is what proves
    /// the fix landed ABOVE the hints rather than inside them.
    func testSameModelIsUnchanged() {
        XCTAssertFalse(ChatModelEnsurer.sameModel("openai/gpt-oss-20b",
                                                  "lmstudio-community/gpt-oss-20b-GGUF"))
        XCTAssertTrue(ChatModelEnsurer.sameModel("pub/a", "PUB/A"),
                      "case folding is the only tolerance it has")
    }
}
