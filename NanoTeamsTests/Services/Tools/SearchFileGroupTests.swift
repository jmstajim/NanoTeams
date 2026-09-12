import XCTest
@testable import NanoTeams

/// The pure fold that turns the executor's per-hit `SearchMatch` list into the per-FILE shape the
/// `search` envelope carries. Tested without a work folder because the fold is a function of its
/// input alone — which is itself the load-bearing property (see the determinism test).
final class SearchFileGroupTests: XCTestCase {

    private func match(
        _ path: String,
        _ line: Int,
        _ text: String,
        before: [(Int, String)] = [],
        after: [(Int, String)] = []
    ) -> SearchMatch {
        SearchMatch(
            path: path,
            line: line,
            text: text,
            context_before: before.isEmpty ? nil : before.map { LineRef(line: $0.0, text: $0.1) },
            context_after: after.isEmpty ? nil : after.map { LineRef(line: $0.0, text: $0.1) }
        )
    }

    // MARK: - Degenerate inputs

    func testGroup_emptyInput_yieldsNoGroups() {
        XCTAssertEqual(SearchFileGroup.group([]), [])
    }

    func testGroup_singleHitNoContext_isOneFileOneLine() {
        let groups = SearchFileGroup.group([match("a.swift", 7, "target")])

        XCTAssertEqual(groups, [
            SearchFileGroup(file: "a.swift", hits: [7], lines: [SearchLine(number: 7, text: "target")])
        ])
    }

    /// An empty line and a whitespace-only line are content, not absence: they carry the file's
    /// shape, and `read_lines` will return them at those numbers. Dropping either would make the
    /// numbers the model copies disagree with the file.
    func testGroup_emptyAndWhitespaceLines_areKept() {
        let groups = SearchFileGroup.group([
            match("a.swift", 3, "target", before: [(1, ""), (2, "   ")], after: [(4, "\t")])
        ])

        XCTAssertEqual(groups.first?.lines, [
            SearchLine(number: 1, text: ""),
            SearchLine(number: 2, text: "   "),
            SearchLine(number: 3, text: "target"),
            SearchLine(number: 4, text: "\t"),
        ])
    }

    // MARK: - The merge

    /// Two hits with overlapping context windows: the shared lines appear ONCE. This is where the
    /// saving comes from — the unfolded shape shipped lines 3–5 twice, once per hit.
    func testGroup_overlappingContextWindows_shareTheirLines() {
        let groups = SearchFileGroup.group([
            match("a.swift", 3, "hit A", before: [(1, "l1"), (2, "l2")], after: [(4, "l4"), (5, "l5")]),
            match("a.swift", 5, "l5", before: [(3, "hit A"), (4, "l4")], after: [(6, "l6"), (7, "l7")]),
        ])

        XCTAssertEqual(groups.count, 1, "one file, one group")
        XCTAssertEqual(groups.first?.lines.map(\.number), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(groups.first?.hits, [3, 5])
    }

    /// A line can be a hit for itself and context for its neighbour. The label has to survive the
    /// merge in both orders of arrival, or `hits` under-reports and `data.count` stops matching.
    func testGroup_lineThatIsBothHitAndContext_keepsTheHitLabel() {
        let contextFirst = SearchFileGroup.group([
            match("a.swift", 1, "alpha", after: [(2, "target")]),
            match("a.swift", 2, "target"),
        ])
        let hitFirst = SearchFileGroup.group([
            match("a.swift", 2, "target"),
            match("a.swift", 1, "alpha", after: [(2, "target")]),
        ])

        XCTAssertEqual(contextFirst.first?.hits, [1, 2])
        XCTAssertEqual(hitFirst.first?.hits, [1, 2])
        XCTAssertEqual(contextFirst.first?.lines.count, 2, "no duplicate line 2")
    }

    /// The scan yields one match per `(path, line)`, but nothing downstream should rely on that:
    /// a repeated hit must fold to one line and one entry in `hits`, not inflate either.
    func testGroup_repeatedHitOnTheSameLine_foldsToOne() {
        let groups = SearchFileGroup.group([
            match("a.swift", 4, "target"),
            match("a.swift", 4, "target"),
        ])

        XCTAssertEqual(groups.first?.hits, [4])
        XCTAssertEqual(groups.first?.lines.count, 1)
    }

    /// A hit's own text is the authority for its line. Context is captured by a neighbouring
    /// match and could in principle disagree (a file rewritten mid-scan); the hit wins so the
    /// text beside a number in `hits` is the text that matched.
    func testGroup_hitTextWinsOverContextTextForTheSameLine() {
        let groups = SearchFileGroup.group([
            match("a.swift", 1, "alpha", after: [(2, "stale")]),
            match("a.swift", 2, "target"),
        ])

        XCTAssertEqual(groups.first?.lines.last, SearchLine(number: 2, text: "target"))
    }

    // MARK: - Order is a function of the input alone

    /// Files keep WALK order (first appearance), lines are numeric — never the `Dictionary`
    /// iteration the fold groups through, which is seeded per process. A prompt prefix that
    /// reorders between runs costs a full re-prefill (~4300-6100 ms against ~350 warm) for a
    /// result that did not change. `SkippedFileGroup.group` carries the same contract.
    func testGroup_fileOrderIsFirstAppearance_andLinesAreNumeric() {
        let input = [
            match("zeta.swift", 9, "target"),
            match("alpha.swift", 4, "target"),
            match("zeta.swift", 2, "target"),
        ]

        let groups = SearchFileGroup.group(input)

        XCTAssertEqual(groups.map(\.file), ["zeta.swift", "alpha.swift"],
                       "walk order, not alphabetical and not hash order")
        XCTAssertEqual(groups.first?.lines.map(\.number), [2, 9], "lines ascend regardless")
        XCTAssertEqual(groups.first?.hits, [2, 9])
    }

    /// One input, many folds, one answer. A per-process hash seed makes a single run look stable
    /// while differing between launches, so repetition inside one process is the weaker half —
    /// paired with the walk-order pin above it is what the envelope's byte-stability rests on.
    func testGroup_repeatedFolds_produceTheSameOrder() {
        let input = (0..<40).map { match("f\($0 % 7).swift", $0, "target") }

        let first = SearchFileGroup.group(input)
        for _ in 0..<20 {
            XCTAssertEqual(SearchFileGroup.group(input), first)
        }
    }

    // MARK: - Wire shape

    /// The pair is POSITIONAL. Keyed `{"line":…,"text":…}` is what cost 40% of the array, and the
    /// key order of the group itself (`file`, `hits`, `lines` under `.sortedKeys`) is what keeps
    /// the path above its own content instead of thousands of bytes below it.
    func testEncoding_groupIsFileHitsLines_andLinesArePositionalPairs() throws {
        let group = SearchFileGroup(
            file: "a/b.swift",
            hits: [2],
            lines: [SearchLine(number: 1, text: "alpha"), SearchLine(number: 2, text: "target")]
        )

        let data = try JSONCoderFactory.makeWireEncoder().encode([group])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(json, #"[{"file":"a/b.swift","hits":[2],"lines":[[1,"alpha"],[2,"target"]]}]"#)
    }

    func testEncoding_roundTripsThroughTheWireCoders() throws {
        let groups = SearchFileGroup.group([
            match("a.swift", 2, "target", before: [(1, "alpha")], after: [(3, "omega")])
        ])

        let data = try JSONCoderFactory.makeWireEncoder().encode(groups)
        let decoded = try JSONCoderFactory.makeWireDecoder().decode([SearchFileGroup].self, from: data)

        XCTAssertEqual(decoded, groups)
    }
}
