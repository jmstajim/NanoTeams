import XCTest

@testable import NanoTeams

final class WorkFolderContextPromptPlannerTests: XCTestCase {

    private typealias Planner = WorkFolderContextPromptPlanner
    private typealias Excerpt = WorkFolderContextInput.FileExcerpt

    // MARK: - estimateTokens

    func testEstimateTokens_nonASCIIWeightedHeavierThanASCII() {
        let ascii = String(repeating: "a", count: 30)
        let cyrillic = String(repeating: "я", count: 30)
        XCTAssertGreaterThan(
            Planner.estimateTokens(cyrillic),
            Planner.estimateTokens(ascii),
            "Equal-length Cyrillic must estimate to MORE tokens than ASCII (conservative)."
        )
    }

    func testEstimateTokens_emptyIsZero() {
        XCTAssertEqual(Planner.estimateTokens(""), 0)
    }

    // MARK: - inputTokenBudget

    func testBudget_probeNil_equalsFallbackContext() {
        // nil probe must behave exactly like an explicit 4096-token context.
        let nilBudget = Planner.inputTokenBudget(contextTokens: nil, systemPromptChars: 200)
        let fallbackBudget = Planner.inputTokenBudget(contextTokens: 4096, systemPromptChars: 200)
        XCTAssertEqual(nilBudget, fallbackBudget)
    }

    func testBudget_tinyContext_flooredAtMinimum() {
        // A 100-token context can't yield a positive budget after reserves —
        // must clamp to the documented 1024 floor, never go negative.
        let budget = Planner.inputTokenBudget(contextTokens: 100, systemPromptChars: 0)
        XCTAssertEqual(budget, 1024)
    }

    /// The output reserve is a fixed constant now that the app carries no
    /// response-limit setting — the same context must always yield the same
    /// budget.
    func testBudget_deterministicForSameContext() {
        let a = Planner.inputTokenBudget(contextTokens: 8192, systemPromptChars: 0)
        let b = Planner.inputTokenBudget(contextTokens: 8192, systemPromptChars: 0)
        XCTAssertEqual(a, b)
    }

    func testBudget_systemPromptSubtracted() {
        let noSystem = Planner.inputTokenBudget(contextTokens: 8192, systemPromptChars: 0)
        let bigSystem = Planner.inputTokenBudget(contextTokens: 8192, systemPromptChars: 8000)
        XCTAssertGreaterThan(noSystem, bigSystem)
    }

    func testBudget_biggerContextBiggerBudget() {
        let small = Planner.inputTokenBudget(contextTokens: 4096, systemPromptChars: 0)
        let big = Planner.inputTokenBudget(contextTokens: 262144, systemPromptChars: 0)
        XCTAssertGreaterThan(big, small)
    }

    // MARK: - compose: fits path is byte-identical to legacy

    func testCompose_everythingFits_byteIdenticalToLegacyFormat() {
        let input = WorkFolderContextInput(
            rootName: "Proj",
            fileList: ["README.md", "Sources/A.swift"],
            fileTypeCounts: ["swift": 2, "md": 1],
            excerpts: [Excerpt(path: "README.md", content: "Hello\nWorld")]
        )

        let expected = [
            "Work folder name: Proj",
            "File types: swift: 2, md: 1",
            "File snapshot:",
            "- README.md",
            "- Sources/A.swift",
            "",
            "Excerpts:",
            "File: README.md",
            "```",
            "Hello\nWorld",
            "```",
        ].joined(separator: "\n")

        let composition = Planner.compose(input: input, tokenBudget: 10_000_000)
        XCTAssertEqual(composition.userMessage, expected)
        XCTAssertFalse(composition.atFloor)
        XCTAssertEqual(composition.trim, Planner.TrimSummary())
    }

    func testCompose_emptyInput_headerOnly() {
        let input = WorkFolderContextInput(rootName: "Empty", fileList: [], fileTypeCounts: [:], excerpts: [])
        let composition = Planner.compose(input: input, tokenBudget: 10_000_000)
        XCTAssertEqual(composition.userMessage, "Work folder name: Empty")
        XCTAssertFalse(composition.atFloor)
    }

    // MARK: - compose: file-list collapsing

    private func assetHeavyInput(extraFiles: [String] = []) -> WorkFolderContextInput {
        var files: [String] = []
        for i in 0..<800 { files.append("Assets/sprites/sprite\(i).png") }
        for i in 0..<20 { files.append("Assets/sprites/data\(i).json") }
        files.append("README.md")
        files.append("Sources/App.swift")
        files += extraFiles
        return WorkFolderContextInput(
            rootName: "Game",
            fileList: files.sorted(),
            fileTypeCounts: ["png": 800, "json": 20, "swift": 1, "md": 1],
            excerpts: []
        )
    }

    func testCompose_largeDirectory_collapsesToAggregateLine() {
        let composition = Planner.compose(input: assetHeavyInput(), tokenBudget: 400)

        XCTAssertTrue(
            composition.userMessage.contains("- Assets/sprites/ — 820 files: png 800, json 20"),
            "The 820-file sprite directory must collapse to one aggregate line."
        )
        XCTAssertFalse(composition.userMessage.contains("sprite0.png"),
                       "Individual sprite paths must be gone after collapsing.")
        XCTAssertTrue(composition.trim.collapsedDirs.contains("Assets/sprites"))
        XCTAssertTrue(composition.userMessage.contains("- README.md"),
                      "Collapsing the big dir must preserve the high-value tail (README).")
        XCTAssertTrue(composition.userMessage.contains("- Sources/App.swift"))
    }

    func testCompose_rootFilesNeverCollapsed_tailTruncatedInstead() {
        var files: [String] = []
        for i in 0..<100 { files.append(String(format: "file%03d.txt", i)) }
        let input = WorkFolderContextInput(
            rootName: "Flat",
            fileList: files.sorted(),
            fileTypeCounts: ["txt": 100],
            excerpts: []
        )

        let composition = Planner.compose(input: input, tokenBudget: 90)

        XCTAssertFalse(composition.userMessage.contains(" files: "),
                       "Root-level files have no parent dir — nothing to collapse.")
        XCTAssertTrue(composition.userMessage.contains("more files (truncated to fit the model's context window)"))
        XCTAssertGreaterThan(composition.trim.truncatedFileCount, 0)

        // Exact accounting: kept "- fileNNN" lines + truncatedFileCount == 100.
        let keptLines = composition.userMessage
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("- file") }
            .count
        XCTAssertEqual(keptLines + composition.trim.truncatedFileCount, 100)
    }

    func testCompose_smallDirectoryNotCollapsed() {
        var files: [String] = []
        for i in 0..<5 { files.append("small/f\(i).txt") } // < collapseMinFiles (10)
        for i in 0..<40 { files.append("big/f\(i).txt") }
        let input = WorkFolderContextInput(
            rootName: "Mixed",
            fileList: files.sorted(),
            fileTypeCounts: ["txt": 45],
            excerpts: []
        )

        let composition = Planner.compose(input: input, tokenBudget: 300)
        XCTAssertFalse(composition.trim.collapsedDirs.contains("small"),
                       "A directory with < 10 files must not be collapsed.")
    }

    // MARK: - compose: excerpt trimming (first N lines, floor 50)

    private func longExcerpt(path: String, lines: Int, isPriority: Bool = false, capped: Bool = false) -> Excerpt {
        let content = (0..<lines).map { "line\($0)" }.joined(separator: "\n")
        return Excerpt(path: path, content: content, isPriority: isPriority, wasReadCapped: capped)
    }

    func testCompose_excerptTrimmedToFirstNLines_withMarker() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "big.txt", lines: 200)]
        )

        let composition = Planner.compose(input: input, tokenBudget: 300)

        XCTAssertTrue(composition.userMessage.contains("line0"))
        XCTAssertFalse(composition.userMessage.contains("line199"),
                       "The tail of the excerpt must be trimmed.")
        XCTAssertTrue(composition.trim.trimmedExcerptPaths.contains("big.txt"))

        // Marker must state the exact kept count and be in [50, 200).
        let marker = composition.userMessage
            .components(separatedBy: "\n")
            .first { $0.hasPrefix("… [truncated: first ") }
        XCTAssertNotNil(marker)
        let n = extractFirstInt(marker ?? "")
        XCTAssertNotNil(n)
        XCTAssertGreaterThanOrEqual(n ?? 0, 50)
        XCTAssertLessThan(n ?? .max, 200)
        XCTAssertTrue(marker?.contains("of 200 lines") ?? false)
    }

    func testCompose_excerptFloor50_winsOverAllowedBudget() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "big.txt", lines: 300)]
        )

        // Tiny budget forces the per-excerpt allowance below 50 lines; the floor
        // must still emit 50 lines and flag `atFloor`.
        let composition = Planner.compose(input: input, tokenBudget: 80)

        XCTAssertTrue(composition.atFloor)
        XCTAssertTrue(composition.userMessage.contains("first 50 of 300 lines"))
        XCTAssertTrue(composition.userMessage.contains("line49"))
        XCTAssertFalse(composition.userMessage.contains("line50\n"))
    }

    func testCompose_excerptShorterThan50Lines_wholeFileNoTruncMarker() {
        // A 10-line file: even under pressure the floor is min(50, 10) = 10,
        // so the whole file ships with no "of M lines" marker.
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "short.txt", lines: 10)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 40)
        XCTAssertTrue(composition.userMessage.contains("line9"))
        XCTAssertFalse(composition.userMessage.contains("of 10 lines"))
    }

    // The user's verbatim requirement: "take the first N lines of a file, but
    // not fewer than 50." The next three tests pin it directly.

    func testCompose_excerptKeepsFirstNLinesContiguously() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "big.txt", lines: 200)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 300)
        let kept = emittedExcerptLines(in: composition.userMessage, path: "big.txt")
        XCTAssertGreaterThanOrEqual(kept.count, 50)
        XCTAssertLessThan(kept.count, 200)
        // Must be the FIRST N lines, in order — not a random / tail slice.
        for (i, line) in kept.enumerated() {
            XCTAssertEqual(line, "line\(i)", "Kept lines must be the first N, contiguous from the start.")
        }
    }

    func testCompose_excerptExactly50Lines_wholeFileNoMarker() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "fifty.txt", lines: 50)]
        )
        // Even under pressure: floor = min(50, 50) = 50 = whole file → no marker.
        let composition = Planner.compose(input: input, tokenBudget: 60)
        XCTAssertTrue(composition.userMessage.contains("line49"))
        XCTAssertFalse(composition.userMessage.contains("[truncated"))
    }

    func testCompose_floorNeverBelow50_acrossEveryTinyBudget() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "big.txt", lines: 500)]
        )
        // No matter how small the budget, an EMITTED excerpt must never be
        // trimmed below the 50-line floor. A budget too small for even the
        // header emits no excerpt (0 lines) — that is a whole-drop, never a
        // sub-floor stub.
        for budget in [1, 8, 20, 50, 100, 200] {
            let composition = Planner.compose(input: input, tokenBudget: budget)
            let kept = emittedExcerptLines(in: composition.userMessage, path: "big.txt")
            XCTAssertTrue(kept.isEmpty || kept.count >= 50,
                          "Budget \(budget): excerpt emitted with \(kept.count) lines — below the 50-line floor.")
        }
        // A modest budget must actually include the excerpt at (at least) the floor.
        let modest = Planner.compose(input: input, tokenBudget: 200)
        XCTAssertGreaterThanOrEqual(emittedExcerptLines(in: modest.userMessage, path: "big.txt").count, 50)
    }

    func testCompose_priorityExcerptGetsLargerShare() {
        let priority = longExcerpt(path: "README.md", lines: 200, isPriority: true)
        let plain = longExcerpt(path: "other.txt", lines: 200, isPriority: false)
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [priority, plain]
        )
        let composition = Planner.compose(input: input, tokenBudget: 400)

        let priorityN = keptLineCount(in: composition.userMessage, path: "README.md")
        let plainN = keptLineCount(in: composition.userMessage, path: "other.txt")
        XCTAssertGreaterThan(priorityN, plainN,
                             "The priority excerpt must get a larger line budget than the plain one.")
    }

    func testCompose_budgetExhausted_dropsWholeExcerpts_withNote() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [
                longExcerpt(path: "a.txt", lines: 60),
                longExcerpt(path: "b.txt", lines: 60),
                longExcerpt(path: "c.txt", lines: 60),
            ]
        )
        let composition = Planner.compose(input: input, tokenBudget: 80)

        XCTAssertTrue(composition.userMessage.contains("Note: 2 more excerpts omitted"))
        XCTAssertTrue(composition.userMessage.contains("b.txt"))
        XCTAssertTrue(composition.userMessage.contains("c.txt"))
        XCTAssertEqual(composition.trim.droppedExcerptPaths, ["b.txt", "c.txt"])
        XCTAssertTrue(composition.atFloor)
    }

    func testCompose_wasReadCapped_marksFileContinues() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "huge.log", lines: 200, capped: true)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 300)
        XCTAssertTrue(composition.userMessage.contains("; file continues]"),
                      "A byte-capped excerpt must not claim a definite total line count.")
        XCTAssertFalse(composition.userMessage.contains("of 200 lines"))
    }

    func testCompose_multibyteUnicodeLines_stable() {
        let content = (0..<80).map { "строка \($0) — тест" }.joined(separator: "\n")
        let input = WorkFolderContextInput(
            rootName: "Проект",
            fileList: ["файл.txt"],
            fileTypeCounts: ["txt": 1],
            excerpts: [Excerpt(path: "файл.txt", content: content)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 200)
        XCTAssertTrue(composition.userMessage.contains("Work folder name: Проект"))
        XCTAssertTrue(composition.userMessage.contains("строка 0"))
    }

    // MARK: - Corner cases: header

    func testCompose_noFileTypes_headerOmitsFileTypesLine() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: ["a"],
            fileTypeCounts: [:],
            excerpts: []
        )
        let composition = Planner.compose(input: input, tokenBudget: 10_000_000)
        XCTAssertEqual(composition.userMessage, "Work folder name: P\nFile snapshot:\n- a")
        XCTAssertFalse(composition.userMessage.contains("File types:"))
    }

    func testCompose_moreThan8FileTypes_headerShowsTop8ByCount() {
        let counts = ["a": 10, "b": 9, "c": 8, "d": 7, "e": 6, "f": 5, "g": 4, "h": 3, "i": 2, "j": 1]
        let input = WorkFolderContextInput(rootName: "P", fileList: [], fileTypeCounts: counts, excerpts: [])
        let composition = Planner.compose(input: input, tokenBudget: 10_000_000)
        XCTAssertTrue(composition.userMessage.contains(
            "File types: a: 10, b: 9, c: 8, d: 7, e: 6, f: 5, g: 4, h: 3"))
        XCTAssertFalse(composition.userMessage.contains("i: 2"),
                       "Only the top 8 file types must appear (legacy behavior).")
    }

    func testCompose_fileListOnly_noExcerptsSection() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: ["src/a.swift", "src/b.swift"],
            fileTypeCounts: ["swift": 2],
            excerpts: []
        )
        let expected = [
            "Work folder name: P",
            "File types: swift: 2",
            "File snapshot:",
            "- src/a.swift",
            "- src/b.swift",
        ].joined(separator: "\n")
        XCTAssertEqual(Planner.compose(input: input, tokenBudget: 10_000_000).userMessage, expected)
    }

    func testCompose_excerptsOnly_noFileSnapshotSection() {
        let input = WorkFolderContextInput(
            rootName: "P",
            fileList: [],
            fileTypeCounts: [:],
            excerpts: [Excerpt(path: "a.txt", content: "one\ntwo")]
        )
        let expected = [
            "Work folder name: P",
            "",
            "Excerpts:",
            "File: a.txt",
            "```",
            "one\ntwo",
            "```",
        ].joined(separator: "\n")
        XCTAssertEqual(Planner.compose(input: input, tokenBudget: 10_000_000).userMessage, expected)
    }

    // MARK: - Corner cases: collapse ordering & aggregate formatting

    func testCompose_collapseOrder_largestDirFirst() {
        var files: [String] = []
        for i in 0..<100 { files.append("big/f\(i).txt") }
        for i in 0..<15 { files.append("small/g\(i).txt") }
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(), fileTypeCounts: ["txt": 115], excerpts: []
        )
        let composition = Planner.compose(input: input, tokenBudget: 300)

        XCTAssertEqual(composition.trim.collapsedDirs, ["big"],
                       "Only the larger dir needs collapsing to fit → it must be tried first.")
        XCTAssertTrue(composition.userMessage.contains("- big/ — 100 files: txt 100"))
        XCTAssertTrue(composition.userMessage.contains("- small/g0.txt"),
                      "The small dir stays expanded when collapsing the big one already fits.")
        XCTAssertFalse(composition.userMessage.contains("big/f0.txt"))
    }

    func testCompose_collapseTieBreak_byPathAscending() {
        var files: [String] = []
        for i in 0..<20 { files.append("zzz/f\(i).txt") }
        for i in 0..<20 { files.append("aaa/f\(i).txt") }
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(), fileTypeCounts: ["txt": 40], excerpts: []
        )
        // Below the full 40-line list → both dirs collapse; the first tried is aaa.
        let composition = Planner.compose(input: input, tokenBudget: 100)
        XCTAssertEqual(composition.trim.collapsedDirs.first, "aaa",
                       "Equal-count dirs collapse in path-ascending order.")
    }

    func testCompose_aggregate_topThreeExtsPlusOther() {
        var files: [String] = []
        for i in 0..<10 { files.append("d/p\(i).png") }
        for i in 0..<5 { files.append("d/j\(i).json") }
        for i in 0..<3 { files.append("d/t\(i).txt") }
        for i in 0..<2 { files.append("d/x\(i).xml") }
        for i in 0..<4 { files.append("d/noext\(i)") }
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(),
            fileTypeCounts: ["png": 10, "json": 5, "txt": 3, "xml": 2], excerpts: []
        )
        let composition = Planner.compose(input: input, tokenBudget: 90)
        // 24 files, top-3 exts png/json/txt (18), remaining 6 (xml 2 + 4 no-ext).
        XCTAssertTrue(composition.userMessage.contains("- d/ — 24 files: png 10, json 5, txt 3, +6 other"),
                      "Aggregate shows top-3 exts and folds the rest (incl. extension-less) into +K other.")
    }

    func testCompose_aggregate_allExtensionless_noColon() {
        var files: [String] = []
        for i in 0..<12 { files.append("bin/blob\(i)") }
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(), fileTypeCounts: [:], excerpts: []
        )
        // Below the full 12-line list → the bin/ dir collapses.
        let composition = Planner.compose(input: input, tokenBudget: 45)
        XCTAssertTrue(composition.userMessage.contains("- bin/ — 12 files"))
        XCTAssertFalse(composition.userMessage.contains("bin/ — 12 files:"),
                       "All-extensionless dir must not emit a trailing ': ' with no exts.")
    }

    func testCompose_nestedDir_collapsesImmediateParentOnly() {
        var files: [String] = []
        for i in 0..<15 { files.append("A/B/x\(i).txt") } // 15 under A/B
        files.append("A/y.txt")                            // 1 direct child of A
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(), fileTypeCounts: ["txt": 16], excerpts: []
        )
        // Below the full 16-line list → A/B (15 direct children) collapses.
        let composition = Planner.compose(input: input, tokenBudget: 65)
        XCTAssertTrue(composition.trim.collapsedDirs.contains("A/B"))
        XCTAssertFalse(composition.trim.collapsedDirs.contains("A"),
                       "A has only 1 direct child — the collapse targets the immediate parent A/B.")
        XCTAssertTrue(composition.userMessage.contains("- A/y.txt"),
                      "A direct child of A must survive; only A/B's children collapse.")
    }

    func testCompose_truncationCount_includesCollapsedAggregateFiles() {
        // A collapsed 50-file dir + many root files, budget so tight the list is
        // both collapsed AND tail-truncated. No file may be silently dropped:
        // kept-represented + truncatedFileCount must equal the true total.
        var files: [String] = []
        for i in 0..<50 { files.append("assets/a\(i).png") }
        for i in 0..<200 { files.append(String(format: "root%03d.txt", i)) }
        let total = files.count
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(),
            fileTypeCounts: ["png": 50, "txt": 200], excerpts: []
        )
        let composition = Planner.compose(input: input, tokenBudget: 120)

        let lines = composition.userMessage.components(separatedBy: "\n")
        var representedKept = 0
        for line in lines where line.hasPrefix("- ") && !line.contains("more files (truncated") {
            if let n = aggregateFileCount(line) { representedKept += n } // aggregate → its N
            else { representedKept += 1 }                                 // plain entry → 1
        }
        XCTAssertEqual(representedKept + composition.trim.truncatedFileCount, total,
                       "No silent drops: kept-represented files + truncated count must equal the total.")
    }

    // MARK: - Corner cases: excerpts

    func testCompose_excerptExactlyFitsWithinShare_noMarker() {
        // A short excerpt that fits its share fully must ship whole with no marker
        // even when OTHER content forces the shaping (non-fits) path.
        var files: [String] = []
        for i in 0..<50 { files.append("dir/f\(i).txt") } // forces shaping
        let input = WorkFolderContextInput(
            rootName: "P", fileList: files.sorted(), fileTypeCounts: ["txt": 50],
            excerpts: [longExcerpt(path: "note.txt", lines: 8)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 300)
        XCTAssertTrue(composition.userMessage.contains("line7"))
        XCTAssertFalse(composition.userMessage.contains("[truncated"),
                       "A fully-included short excerpt must carry no truncation marker.")
    }

    func testCompose_cappedAndTrimmed_fileContinuesWins() {
        // Both trimmed AND read-capped → the honest marker is "file continues",
        // never a false "of M lines" total.
        let input = WorkFolderContextInput(
            rootName: "P", fileList: [], fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "log.txt", lines: 400, capped: true)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 200)
        XCTAssertTrue(composition.userMessage.contains("; file continues]"))
        XCTAssertFalse(composition.userMessage.contains(" of 400 lines"))
    }

    func testCompose_moderateBudgetTrims_notAtFloor() {
        // Trimming happens but the excerpt keeps well over 50 lines → NOT atFloor,
        // so the service would still be allowed to retry.
        let input = WorkFolderContextInput(
            rootName: "P", fileList: [], fileTypeCounts: [:],
            excerpts: [longExcerpt(path: "big.txt", lines: 400)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 500)
        XCTAssertFalse(composition.atFloor)
        XCTAssertGreaterThan(emittedExcerptLines(in: composition.userMessage, path: "big.txt").count, 50)
    }

    func testCompose_emptyContentExcerpt_doesNotCrash() {
        let input = WorkFolderContextInput(
            rootName: "P", fileList: [], fileTypeCounts: [:],
            excerpts: [Excerpt(path: "empty.txt", content: "")]
        )
        let composition = Planner.compose(input: input, tokenBudget: 10_000_000)
        XCTAssertTrue(composition.userMessage.contains("File: empty.txt"))
    }

    func testCompose_zeroBudget_headerOnly_atFloor() {
        let input = WorkFolderContextInput(
            rootName: "P", fileList: ["a", "b"], fileTypeCounts: ["x": 2],
            excerpts: [longExcerpt(path: "f.txt", lines: 100)]
        )
        let composition = Planner.compose(input: input, tokenBudget: 0)
        XCTAssertTrue(composition.atFloor)
        XCTAssertFalse(composition.userMessage.contains("Excerpts:"))
        XCTAssertTrue(composition.userMessage.hasPrefix("Work folder name: P"))
    }

    // MARK: - Helpers

    /// Parses the represented file count out of an aggregate line
    /// "- <dir>/ — <N> files…"; returns nil for a plain entry.
    private func aggregateFileCount(_ line: String) -> Int? {
        guard line.contains(" — "), line.contains(" files") else { return nil }
        return extractFirstInt(line)
    }

    private func extractFirstInt(_ s: String) -> Int? {
        let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Counts the `lineN` content lines emitted for the excerpt at `path`.
    private func keptLineCount(in message: String, path: String) -> Int {
        emittedExcerptLines(in: message, path: path).count
    }

    /// The content lines (between the ``` fences) emitted for `path`, excluding
    /// the "… [truncated …]" marker line.
    private func emittedExcerptLines(in message: String, path: String) -> [String] {
        let lines = message.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "File: \(path)") else { return [] }
        var result: [String] = []
        var i = start + 2 // skip "File: …" and opening ```
        while i < lines.count, lines[i] != "```" {
            if !lines[i].hasPrefix("… [truncated") { result.append(lines[i]) }
            i += 1
        }
        return result
    }
}
