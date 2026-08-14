import XCTest

@testable import NanoTeams

/// Pure decisions behind the status-bar model picker's popover: row identity,
/// order stability across an in-flight refresh, filtering, Return-key resolution,
/// and which empty state to show.
///
/// The subject is `nonisolated`, so this is a plain `XCTestCase`.
final class ModelQuickPickerLogicTests: XCTestCase {

    private typealias Logic = ModelQuickPickerLogic

    // MARK: - rows

    func testRows_selectedPresent_marksExactlyOneAndPreservesOrder() {
        let rows = Logic.rows(available: ["b", "a", "c"], selected: "a")

        XCTAssertEqual(rows.map(\.name), ["b", "a", "c"], "server order is preserved verbatim")
        XCTAssertEqual(rows.filter(\.isSelected).map(\.name), ["a"])
        XCTAssertTrue(rows.allSatisfy { !$0.isMissingFromServer })
    }

    /// Without this the picker shows "no checkmark anywhere" while a model IS
    /// configured — the user cannot tell what they are running.
    func testRows_selectedAbsentFromServer_isPrependedAndFlagged() {
        let rows = Logic.rows(available: ["a", "b"], selected: "gone")

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.name, "gone")
        XCTAssertEqual(rows.first?.isSelected, true)
        XCTAssertEqual(rows.first?.isMissingFromServer, true)
    }

    func testRows_emptySelection_addsNoPhantomRow() {
        let rows = Logic.rows(available: ["a"], selected: "")

        XCTAssertEqual(rows.map(\.name), ["a"])
        XCTAssertTrue(rows.allSatisfy { !$0.isSelected })
    }

    func testRows_whitespaceOnlySelection_addsNoPhantomRow() {
        let rows = Logic.rows(available: ["a"], selected: "   ")

        XCTAssertEqual(rows.map(\.name), ["a"])
        XCTAssertTrue(rows.allSatisfy { !$0.isMissingFromServer })
    }

    /// `id` is the name, so a repeat is a duplicate `ForEach` id — the crash class
    /// CLAUDE.md #22 names. Defense in depth: every decode path already calls
    /// `.normalizedUnique()`, but the seam must not depend on that.
    /// Mutation: drop the dedup.
    func testRows_duplicateNames_collapseToOneRow() {
        let rows = Logic.rows(available: ["a", "a", "b"], selected: "")

        XCTAssertEqual(rows.map(\.name), ["a", "b"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "ids must be unique")
    }

    /// An empty name is the degenerate duplicate id.
    func testRows_emptyAndWhitespaceEntries_areDropped() {
        let rows = Logic.rows(available: ["", "   ", "a"], selected: "")

        XCTAssertEqual(rows.map(\.name), ["a"])
    }

    /// The exact server id is what gets written to `llmModelName` and put on the
    /// wire, so a non-empty name must survive byte for byte.
    func testRows_doesNotTrimNonEmptyNames() {
        let rows = Logic.rows(available: ["a "], selected: "")

        XCTAssertEqual(rows.map(\.name), ["a "])
    }

    func testRows_serverListEmptyButModelConfigured_yieldsTheMissingRowAlone() {
        let rows = Logic.rows(available: [], selected: "x")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "x")
        XCTAssertTrue(rows[0].isMissingFromServer)
    }

    // MARK: - stableOrder

    func testStableOrder_noPriorOrder_returnsFreshUnchanged() {
        XCTAssertEqual(Logic.stableOrder(fresh: ["a", "b"], priorOrder: []), ["a", "b"])
    }

    /// `normalizedUnique()` sorts case-insensitively, so a refresh re-sorts the list
    /// underneath an open popover. Rows already on screen must not move — otherwise
    /// a refresh landing mid-aim changes what the next click hits.
    /// Mutation: return `fresh` → this is the anti-mis-click test.
    func testStableOrder_sortedRefresh_doesNotReorderRowsAlreadyOnScreen() {
        XCTAssertEqual(Logic.stableOrder(fresh: ["a", "b"], priorOrder: ["b", "a"]), ["b", "a"])
    }

    func testStableOrder_arrival_isAppendedNotInserted() {
        XCTAssertEqual(
            Logic.stableOrder(fresh: ["a", "b", "c"], priorOrder: ["a", "c"]),
            ["a", "c", "b"])
    }

    /// A model the server no longer has must stop being clickable immediately.
    func testStableOrder_removal_dropsTheRow() {
        XCTAssertEqual(Logic.stableOrder(fresh: ["a"], priorOrder: ["a", "b"]), ["a"])
    }

    func testStableOrder_totalReplacement_takesTheFreshList() {
        XCTAssertEqual(Logic.stableOrder(fresh: ["y", "z"], priorOrder: ["x"]), ["y", "z"])
    }

    func testStableOrder_duplicatesInEitherInput_appearOnce() {
        XCTAssertEqual(
            Logic.stableOrder(fresh: ["a", "a", "b"], priorOrder: ["b", "b"]),
            ["b", "a"])
    }

    func testStableOrder_freshEmpty_yieldsEmpty() {
        XCTAssertEqual(Logic.stableOrder(fresh: [], priorOrder: ["a"]), [])
    }

    // MARK: - filter

    private func rows(_ names: [String]) -> [Logic.Row] {
        Logic.rows(available: names, selected: "")
    }

    func testFilter_emptyQuery_isIdentity() {
        let all = rows(["a", "b"])
        XCTAssertEqual(Logic.filter(all, query: "").map(\.name), ["a", "b"])
    }

    func testFilter_whitespaceOnlyQuery_isIdentity() {
        let all = rows(["a", "b"])
        XCTAssertEqual(Logic.filter(all, query: "   ").map(\.name), ["a", "b"])
    }

    /// The vendor prefix is a legitimate thing to search by — it is what
    /// distinguishes `unsloth/gpt-oss-20b` from `openai/gpt-oss-20b`.
    func testFilter_isCaseInsensitiveSubstringIncludingVendorPrefix() {
        let all = rows(["unsloth/gpt-oss-20b-GGUF", "google/gemma-4-e2b"])

        XCTAssertEqual(Logic.filter(all, query: "UNSLOTH").map(\.name), ["unsloth/gpt-oss-20b-GGUF"])
        XCTAssertEqual(Logic.filter(all, query: "gemma").map(\.name), ["google/gemma-4-e2b"])
    }

    func testFilter_noMatch_yieldsEmpty() {
        XCTAssertTrue(Logic.filter(rows(["a"]), query: "zzz").isEmpty)
    }

    // MARK: - submitSelection

    func testSubmitSelection_emptyQuery_isAmbiguous() {
        XCTAssertNil(Logic.submitSelection(in: rows(["a"]), query: ""))
    }

    func testSubmitSelection_singleFilterMatch_resolves() {
        XCTAssertEqual(
            Logic.submitSelection(in: rows(["alpha", "beta"]), query: "alp"),
            "alpha")
    }

    /// An exact name that is ALSO a prefix of a longer name must pick what was
    /// typed, not refuse as ambiguous. Mutation: drop the exact-match branch →
    /// `qwen3` returns nil because two rows match.
    func testSubmitSelection_exactNameWins_overAPrefixCollision() {
        XCTAssertEqual(
            Logic.submitSelection(in: rows(["qwen3", "qwen3-8b"]), query: "qwen3"),
            "qwen3")
    }

    func testSubmitSelection_exactMatchIsCaseInsensitive() {
        XCTAssertEqual(
            Logic.submitSelection(in: rows(["Qwen3"]), query: "qwen3"),
            "Qwen3",
            "returns the SERVER's spelling, not the user's")
    }

    func testSubmitSelection_manyMatchesNoExact_isAmbiguous() {
        XCTAssertNil(Logic.submitSelection(in: rows(["qwen3-8b", "qwen3-30b"]), query: "qwen3"))
    }

    func testSubmitSelection_noRows_isAmbiguous() {
        XCTAssertNil(Logic.submitSelection(in: [], query: "a"))
    }

    // MARK: - placeholder

    func testPlaceholder_withRows_isAlwaysNil() {
        for isFetching in [true, false] {
            for hasError in [true, false] {
                for hasEndpoint in [true, false] {
                    for hasLoadedList in [true, false] {
                        for isReachable in [true, false] {
                            XCTAssertNil(
                                Logic.placeholder(
                                    rowCount: 1, isFetching: isFetching, hasError: hasError,
                                    hasEndpoint: hasEndpoint, hasLoadedList: hasLoadedList,
                                    isReachable: isReachable),
                                "a rendered list never shows a placeholder")
                        }
                    }
                }
            }
        }
    }

    /// No address configured outranks everything: "offline" would blame the server
    /// for a setting the user never filled in.
    func testPlaceholder_noEndpoint_outranksEveryOtherSignal() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: true, hasError: true,
                hasEndpoint: false, hasLoadedList: true, isReachable: true),
            .noEndpoint)
    }

    func testPlaceholder_fetchingWithNothingCached_isLoading() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: true, hasError: false,
                hasEndpoint: true, hasLoadedList: false, isReachable: false),
            .loading)
    }

    /// The footer already renders the error. Reporting it in the body too reads as
    /// two separate problems.
    func testPlaceholder_errorWithNothingCached_defersToTheFooter() {
        XCTAssertNil(
            Logic.placeholder(
                rowCount: 0, isFetching: false, hasError: true,
                hasEndpoint: true, hasLoadedList: false, isReachable: false))
    }

    /// A COMPLETED fetch that returned nothing is a fact about this endpoint,
    /// observed just now. The pill is a shared bit a coalesced fetch or a timed-out
    /// 2 s probe can leave a poll interval stale — so it must not get to narrate
    /// this case. Mutation: drop the `hasLoadedList` branch → the picker says
    /// "Server is offline" about a server that just answered 2xx.
    func testPlaceholder_loadedButEmpty_outranksAStaleOfflinePill() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: false, hasError: false,
                hasEndpoint: true, hasLoadedList: true, isReachable: false),
            .emptyList)
    }

    /// Never fetched and the pill says down: the only case where blaming the server
    /// is honest.
    func testPlaceholder_neverFetchedAndUnreachable_saysOffline() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: false, hasError: false,
                hasEndpoint: true, hasLoadedList: false, isReachable: false),
            .offline)
    }

    func testPlaceholder_emptyAndReachable_saysTheServerHasNone() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: false, hasError: false,
                hasEndpoint: true, hasLoadedList: true, isReachable: true),
            .emptyList)
    }

    /// A spinner is in flight ⇒ the stale error must not also be shown, matching
    /// `EndpointStatus.resolve`'s "the spinner speaks" rule.
    func testPlaceholder_fetchingOutranksAStaleError() {
        XCTAssertEqual(
            Logic.placeholder(
                rowCount: 0, isFetching: true, hasError: true,
                hasEndpoint: true, hasLoadedList: false, isReachable: false),
            .loading)
    }

    /// The COPY, not just its shape. Swapping the offline and empty-list strings
    /// inverts exactly the distinction this state machine exists to draw, and the
    /// non-empty + pairwise-distinct assertions below would not notice.
    func testMessage_saysTheRightThingForEachState() {
        XCTAssertEqual(Logic.message(for: .noEndpoint), "No server address configured.")
        XCTAssertEqual(Logic.message(for: .loading), "Loading models…")
        XCTAssertEqual(Logic.message(for: .offline), "Server is offline — nothing to list.")
        XCTAssertEqual(Logic.message(for: .emptyList), "The server reported no models.")
    }

    func testMessage_isNonEmptyAndDistinctForEveryPlaceholder() {
        let all: [Logic.Placeholder] = [.noEndpoint, .loading, .offline, .emptyList]
        let messages = all.map(Logic.message(for:))

        XCTAssertTrue(messages.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(Set(messages).count, all.count, "each state must read differently")
    }
}
