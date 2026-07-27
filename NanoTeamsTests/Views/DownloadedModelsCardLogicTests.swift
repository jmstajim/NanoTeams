import XCTest

@testable import NanoTeams

/// Regression pin for a real defect: the Downloaded Models card used to resolve
/// its delete target from LIVE settings (`config.globalLLMConfig`) while its
/// rows came from a previous fetch.
///
/// The provider picker shares the LLM settings sheet, and `refresh()` leaves the
/// previous endpoint's rows on screen — with Remove enabled — for the entire
/// fetch, which against an unresponsive Ollama is ~10 s (`/api/tags` +
/// `/api/ps`, 5 s each). Switching provider or server inside that window and
/// then confirming a still-visible row sent that row's id to the NEW endpoint.
/// Two ways that goes wrong, both silent:
///
/// - an LM Studio `publisher/repoDir` id arriving at Ollama is answered by its
///   idempotent-404-is-success rule, so the UI reports a deletion that never
///   happened;
/// - between two Ollama hosts, a common tag like `llama3.1:8b` is genuinely
///   deleted on the machine the user was not looking at.
@MainActor
final class DownloadedModelsCardLogicTests: XCTestCase {

    private func model(_ id: String) -> DownloadedModel {
        DownloadedModel(id: id, displayName: id)
    }

    private func listing(
        provider: LLMProvider = .lmStudio,
        base: String = "http://127.0.0.1:1234",
        modelIDs: [String]
    ) -> DownloadedModelsCard.Listing {
        DownloadedModelsCard.Listing(
            config: LLMConfig(provider: provider, baseURLString: base, modelName: "m"),
            models: modelIDs.map(model),
            deletion: .movesToTrash,
            storageLocation: nil)
    }

    func testTarget_isTheConfigTheRowWasListedUnder() throws {
        let listed = listing(provider: .lmStudio, base: "http://127.0.0.1:1234",
                             modelIDs: ["pub/a-GGUF"])

        let target = try XCTUnwrap(
            DownloadedModelsCardLogic.deletionTarget(for: model("pub/a-GGUF"), in: listed))

        XCTAssertEqual(target.provider, .lmStudio)
        XCTAssertEqual(target.baseURLString, "http://127.0.0.1:1234")
    }

    /// The core of the bug: whatever the live settings now say, the target
    /// stays the endpoint the row came from.
    func testTarget_ignoresAProviderSwitchAfterListing() throws {
        let listed = listing(provider: .lmStudio, base: "http://127.0.0.1:1234",
                             modelIDs: ["pub/a-GGUF"])
        // Simulates the user flipping the picker to Ollama mid-fetch: the live
        // config is now something else entirely, but `listed` is unchanged.
        let target = try XCTUnwrap(
            DownloadedModelsCardLogic.deletionTarget(for: model("pub/a-GGUF"), in: listed))

        XCTAssertNotEqual(
            target.provider, .ollama,
            "An LM Studio folder id must never be routed to Ollama, where the "
                + "idempotent-404 rule would report a deletion that never happened")
    }

    /// Same-provider, different-host is the destructive variant: `llama3.1:8b`
    /// exists on plenty of machines.
    func testTarget_ignoresAServerSwitchAfterListing() throws {
        let listed = listing(provider: .ollama, base: "http://127.0.0.1:11434",
                             modelIDs: ["llama3.1:8b"])

        let target = try XCTUnwrap(
            DownloadedModelsCardLogic.deletionTarget(for: model("llama3.1:8b"), in: listed))

        XCTAssertEqual(
            target.baseURLString, "http://127.0.0.1:11434",
            "A delete must reach the host the row was listed from, never whichever "
                + "host is selected by the time the user confirms")
    }

    func testTarget_nilWhenNothingHasBeenListedYet() {
        XCTAssertNil(DownloadedModelsCardLogic.deletionTarget(for: model("pub/a"), in: nil))
    }

    /// A row that is no longer listed is no longer on screen, so a tap that
    /// resolves to it is acting on a view that has been replaced.
    func testTarget_nilWhenTheRowIsNoLongerListed() {
        let listed = listing(modelIDs: ["pub/kept"])
        XCTAssertNil(DownloadedModelsCardLogic.deletionTarget(for: model("pub/gone"), in: listed))
    }

    func testTarget_nilForAnEmptyListing() {
        XCTAssertNil(
            DownloadedModelsCardLogic.deletionTarget(for: model("pub/a"), in: listing(modelIDs: [])))
    }

    /// Ids are matched exactly — no prefix or case folding, either of which
    /// would let one row's tap resolve to a different model's endpoint.
    func testTarget_matchesIDsExactly() {
        let listed = listing(modelIDs: ["pub/a-GGUF"])
        for near in ["pub/a", "pub/a-gguf", "pub/a-GGUF-extra", " pub/a-GGUF"] {
            XCTAssertNil(
                DownloadedModelsCardLogic.deletionTarget(for: model(near), in: listed),
                "\"\(near)\" must not match the listed \"pub/a-GGUF\"")
        }
    }
}
