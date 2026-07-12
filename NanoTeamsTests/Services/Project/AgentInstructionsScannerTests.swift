import XCTest

@testable import NanoTeams

final class AgentInstructionsScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // standardizedFileURL resolves /var -> /private/var so relative-path
        // computation matches what the scanner standardizes internally.
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            // Restore any 0o000 perms so removeItem can recurse.
            restorePermissionsRecursively(at: tempDir)
            try? fileManager.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func createFile(named name: String, content: String = "instructions") throws {
        let fileURL = tempDir.appendingPathComponent(name)
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func createRawFile(named name: String, bytes: Data) throws {
        let fileURL = tempDir.appendingPathComponent(name)
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try bytes.write(to: fileURL)
    }

    private func scan(
        manualPaths: [String] = [],
        excludedPaths: [String] = [],
        injectedPaths: [String] = []
    ) -> AgentInstructionsSnapshot {
        AgentInstructionsScanner.scan(
            workFolderRoot: tempDir, manualPaths: manualPaths,
            excludedPaths: excludedPaths, injectedPaths: injectedPaths)
    }

    private func restorePermissionsRecursively(at url: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        guard let items = try? fileManager.contentsOfDirectory(atPath: url.path) else { return }
        for item in items {
            let child = url.appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                restorePermissionsRecursively(at: child)
            }
        }
    }

    private let sixFiles = [
        "CLAUDE.md", "AGENTS.md", "GEMINI.md",
        ".cursorrules", ".github/copilot-instructions.md", ".windsurfrules",
    ]

    // MARK: - Empty / none

    func testScan_emptyFolder_returnsEmpty() {
        let snap = scan()
        XCTAssertTrue(snap.isEmpty)
        XCTAssertNil(snap.mainFile)
        XCTAssertTrue(snap.listedPaths.isEmpty)
    }

    func testScan_noInstructionFiles_returnsEmpty() throws {
        try createFile(named: "README.md")
        try createFile(named: "main.swift")
        try createFile(named: "docs/overview.md")
        let snap = scan()
        XCTAssertTrue(snap.isEmpty)
    }

    // MARK: - Main content is uncapped

    func testScan_rootClaude_isMain_contentUncapped() throws {
        let big = String(repeating: "x", count: 5000)  // > ArtifactConstants.maxDescriptionChars (2000)
        try createFile(named: "CLAUDE.md", content: big)
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md")
        XCTAssertEqual(snap.mainFile?.injectedContent?.count, 5000, "main content must NOT be capped")
        XCTAssertTrue(snap.listedPaths.isEmpty)
    }

    func testScan_mainContentTrimmedAtScanTime() throws {
        try createFile(named: "CLAUDE.md", content: "\n\n  Body text  \n")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.injectedContent, "Body text",
                       "content is edge-trimmed once at scan time")
    }

    /// Content larger than the internal probe window must survive intact —
    /// the probe is a binary-rejection optimization, not a cap.
    func testScan_contentLargerThanProbeWindow_readFully() throws {
        let big = String(repeating: "y", count: 100_000)
        try createFile(named: "CLAUDE.md", content: big)
        XCTAssertEqual(scan().mainFile?.injectedContent?.count, 100_000)
    }

    // MARK: - Priority ladder

    func testScan_priorityLadder_peelFromTop() throws {
        for name in sixFiles { try createFile(named: name) }

        let expectedMains = [
            "CLAUDE.md", "AGENTS.md", "GEMINI.md",
            ".cursorrules", ".github/copilot-instructions.md", ".windsurfrules",
        ]
        for (i, expected) in expectedMains.enumerated() {
            let snap = scan()
            XCTAssertEqual(snap.mainFile?.relativePath, expected, "step \(i)")
            try fileManager.removeItem(at: tempDir.appendingPathComponent(expected))
        }
        XCTAssertTrue(scan().isEmpty)
    }

    // MARK: - Case-insensitive basename match

    func testScan_caseInsensitiveBasenames() throws {
        try createFile(named: "Claude.MD", content: "hi")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "Claude.MD", "original case preserved")
    }

    func testScan_caseInsensitive_agents() throws {
        try createFile(named: "AGENTS.MD", content: "hi")
        XCTAssertEqual(scan().mainFile?.relativePath, "AGENTS.MD")
    }

    // MARK: - Root beats nested

    func testScan_rootBeatsNested() throws {
        try createFile(named: "AGENTS.md")            // root tier, priority 1
        try createFile(named: "sub/CLAUDE.md")        // nested, basename priority 0
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md",
                       "root-tier file wins over higher-basename-priority nested file")
        XCTAssertEqual(snap.listedPaths, ["sub/CLAUDE.md"])
    }

    // MARK: - Nested tier ordering (basename priority, then depth, then path)

    func testScan_nestedTierOrdering() throws {
        try createFile(named: "a/GEMINI.md")          // basename rank 2
        try createFile(named: "b/CLAUDE.md")          // basename rank 0, depth 1
        try createFile(named: "deep/x/CLAUDE.md")     // basename rank 0, depth 2
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "b/CLAUDE.md",
                       "claude beats gemini; shallower depth wins between claudes")
        XCTAssertEqual(snap.listedPaths, ["a/GEMINI.md", "deep/x/CLAUDE.md"])
    }

    // MARK: - .github traversal

    func testScan_githubCopilot_discoveredAndRootTier() throws {
        try createFile(named: ".github/copilot-instructions.md", content: "copilot")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, ".github/copilot-instructions.md")
    }

    // MARK: - Skip rules

    func testScan_skipsNodeModulesAndGit() throws {
        try createFile(named: "node_modules/pkg/CLAUDE.md")
        try createFile(named: ".git/CLAUDE.md")
        try createFile(named: "AGENTS.md")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md")
        XCTAssertTrue(snap.listedPaths.isEmpty, "node_modules & .git contents skipped")
    }

    func testScan_nanoteamsSkippedWholesale() throws {
        // App storage is never an instruction source — a CLAUDE.md attached to
        // a task must not be discovered, let alone promoted to MAIN.
        try createFile(named: ".nanoteams/internal/CLAUDE.md")
        try createFile(named: ".nanoteams/tasks/1/attachments/CLAUDE.md", content: "attachment")
        let snap = scan()
        XCTAssertTrue(snap.isEmpty, ".nanoteams subtree is excluded from discovery")
    }

    // MARK: - Symlinks

    func testScan_symlinkCycle_terminates() throws {
        try createFile(named: "dir/CLAUDE.md", content: "loop")
        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("dir/loop"),
            withDestinationURL: tempDir.appendingPathComponent("dir"))
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "dir/CLAUDE.md")
    }

    func testScan_symlinkEscape_fileOutsideRoot_skipped() throws {
        // A symlink resolving OUTSIDE the work folder must never be injected —
        // the sandboxed read_file would refuse to serve it.
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("CLAUDE.md"),
                           atomically: true, encoding: .utf8)

        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("CLAUDE.md"),
            withDestinationURL: outside.appendingPathComponent("CLAUDE.md"))
        XCTAssertTrue(scan().isEmpty, "escaping symlink file skipped")
    }

    func testScan_symlinkEscape_dirOutsideRoot_skipped() throws {
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("AGENTS.md"),
                           atomically: true, encoding: .utf8)

        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("docs"),
            withDestinationURL: outside)
        XCTAssertTrue(scan().isEmpty, "escaping symlink dir not recursed")
    }

    func testScan_brokenSymlink_skippedNoCrash() throws {
        try createFile(named: "CLAUDE.md", content: "root")
        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("dangling"),
            withDestinationURL: tempDir.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(scan().mainFile?.relativePath, "CLAUDE.md")
    }

    // MARK: - Fall-through cases

    func testScan_nonUTF8Main_fallsThroughButStaysListed() throws {
        try createRawFile(named: "CLAUDE.md", bytes: Data([0xFF, 0xFE, 0xFF, 0x00]))
        try createFile(named: "AGENTS.md", content: "valid")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md",
                       "non-UTF8 candidate cannot be main")
        XCTAssertEqual(snap.mainFile?.injectedContent, "valid")
        XCTAssertTrue(snap.listedPaths.contains("CLAUDE.md"),
                      "non-UTF8 file still listed")
    }

    func testScan_emptyContentMain_fallsThrough() throws {
        try createFile(named: "CLAUDE.md", content: "   \n\t ")  // whitespace only
        try createFile(named: "AGENTS.md", content: "valid")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md")
        XCTAssertTrue(snap.listedPaths.contains("CLAUDE.md"))
    }

    func testScan_allEmpty_noMainButPathsListed() throws {
        try createFile(named: "CLAUDE.md", content: "")
        try createFile(named: "AGENTS.md", content: "  ")
        let snap = scan()
        XCTAssertNil(snap.mainFile, "no readable non-empty candidate → no main")
        XCTAssertEqual(snap.listedPaths, ["AGENTS.md", "CLAUDE.md"])
        XCTAssertFalse(snap.isEmpty)
    }

    // MARK: - listedPaths sorting / main exclusion

    func testScan_listedPathsSortedExcludeMain() throws {
        try createFile(named: "CLAUDE.md")
        try createFile(named: "z/GEMINI.md")
        try createFile(named: "sub/AGENTS.md")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md")
        XCTAssertEqual(snap.listedPaths, ["sub/AGENTS.md", "z/GEMINI.md"])
        XCTAssertFalse(snap.listedPaths.contains("CLAUDE.md"))
    }

    func testScan_items_mainFirstThenOthers() throws {
        try createFile(named: "CLAUDE.md")
        try createFile(named: "sub/AGENTS.md")
        let snap = scan()
        XCTAssertEqual(snap.items.map(\.relativePath), ["CLAUDE.md", "sub/AGENTS.md"])
    }

    // MARK: - Exclusions

    func testScan_excludedMain_nextCandidatePromoted_staysListed() throws {
        try createFile(named: "CLAUDE.md", content: "claude")
        try createFile(named: "AGENTS.md", content: "agents")
        let snap = scan(excludedPaths: ["CLAUDE.md"])

        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md",
                       "excluded file never qualifies as main")
        // Exclusion DEMOTES to path listing — the file stays in the grid
        // (dimmed) AND in the prompt's path list; only content injection stops.
        let excludedItem = snap.items.first { $0.relativePath == "CLAUDE.md" }
        XCTAssertEqual(excludedItem?.isExcluded, true)
        XCTAssertNil(excludedItem?.injectedContent)
        XCTAssertTrue(snap.listedPaths.contains("CLAUDE.md"),
                      "excluded file remains path-listed for on-demand reading")
    }

    func testScan_excludedNonMain_remainsListed() throws {
        try createFile(named: "CLAUDE.md", content: "claude")
        try createFile(named: "sub/AGENTS.md")
        let snap = scan(excludedPaths: ["sub/AGENTS.md"])
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md")
        XCTAssertEqual(snap.listedPaths, ["sub/AGENTS.md"],
                       "exclusion never hides a file from the path list")
        XCTAssertEqual(snap.items.first { $0.relativePath == "sub/AGENTS.md" }?.isExcluded, true)
    }

    // MARK: - Injection promotion (quick "INJECT" from the All-files list)

    func testScan_promotedListedTextFile_contentInjected() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        try createFile(named: "sub/AGENTS.md", content: "sub rules")
        let snap = scan(injectedPaths: ["sub/AGENTS.md"])

        XCTAssertEqual(snap.injectedFiles.map(\.relativePath), ["CLAUDE.md", "sub/AGENTS.md"])
        XCTAssertEqual(
            snap.items.first { $0.relativePath == "sub/AGENTS.md" }?.injectedContent, "sub rules")
        XCTAssertTrue(snap.listedPaths.isEmpty)
    }

    func testScan_promotedBinary_staysListed() throws {
        try createRawFile(named: "GEMINI.md", bytes: Data([0xFF, 0xFE, 0x00, 0xFF]))
        let snap = scan(injectedPaths: ["GEMINI.md"])
        XCTAssertTrue(snap.injectedFiles.isEmpty, "non-text promotion silently fails")
        XCTAssertEqual(snap.listedPaths, ["GEMINI.md"])
    }

    func testScan_promotedButExcluded_exclusionWins() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        try createFile(named: "sub/AGENTS.md", content: "sub")
        let snap = scan(excludedPaths: ["sub/AGENTS.md"], injectedPaths: ["sub/AGENTS.md"])
        XCTAssertEqual(snap.injectedFiles.map(\.relativePath), ["CLAUDE.md"])
        XCTAssertTrue(snap.listedPaths.contains("sub/AGENTS.md"))
    }

    func testScan_manualExcluded_demotedToListing() throws {
        try createFile(named: "notes.md", content: "text")
        let snap = scan(manualPaths: ["notes.md"], excludedPaths: ["notes.md"])
        let item = snap.items.first { $0.relativePath == "notes.md" }
        XCTAssertEqual(item?.isExcluded, true)
        XCTAssertNil(item?.injectedContent, "excluded manual text is not injected")
        XCTAssertEqual(snap.listedPaths, ["notes.md"], "…but stays path-listed")
    }

    func testScan_staleExclusion_noMatchingFile_ignored() throws {
        try createFile(named: "CLAUDE.md", content: "claude")
        let snap = scan(excludedPaths: ["deleted/AGENTS.md"])
        XCTAssertEqual(snap.items.count, 1, "stale exclusion produces no item")
    }

    // MARK: - Manual attachments

    func testScan_manualTextFile_contentInjected() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        try createFile(named: "docs/style-guide.txt", content: "Use tabs.")
        let snap = scan(manualPaths: ["docs/style-guide.txt"])

        let manual = snap.items.first { $0.relativePath == "docs/style-guide.txt" }
        XCTAssertEqual(manual?.source, .manual)
        XCTAssertEqual(manual?.injectedContent, "Use tabs.",
                       "manual UTF-8 text file is content-injected")
        XCTAssertEqual(snap.injectedFiles.map(\.relativePath),
                       ["CLAUDE.md", "docs/style-guide.txt"],
                       "main first, then manual texts")
    }

    func testScan_manualBinaryFile_pathListed() throws {
        try createRawFile(named: "mockup.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]))
        let snap = scan(manualPaths: ["mockup.png"])

        let manual = snap.items.first { $0.relativePath == "mockup.png" }
        XCTAssertEqual(manual?.source, .manual)
        XCTAssertNil(manual?.injectedContent, "binary/image → path-listed, not injected")
        XCTAssertEqual(snap.listedPaths, ["mockup.png"])
    }

    func testScan_manualMissingFile_dropped() throws {
        let snap = scan(manualPaths: ["gone.md"])
        XCTAssertTrue(snap.isEmpty)
    }

    func testScan_manualDuplicateOfDiscovered_skipped() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        let snap = scan(manualPaths: ["CLAUDE.md"])
        XCTAssertEqual(snap.items.count, 1, "manual path duplicating a discovered file is skipped")
    }

    func testScan_manualInsideInternal_rejected() throws {
        try createFile(named: ".nanoteams/internal/secrets.md", content: "hidden")
        let snap = scan(manualPaths: [".nanoteams/internal/secrets.md"])
        XCTAssertTrue(snap.isEmpty, "internal/ is hidden from the LLM — never injectable")
    }

    func testScan_manualEscapingSymlink_rejected() throws {
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("notes.md"),
                           atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("notes.md"),
            withDestinationURL: outside.appendingPathComponent("notes.md"))

        let snap = scan(manualPaths: ["notes.md"])
        XCTAssertTrue(snap.isEmpty, "manual path resolving outside the folder is rejected")
    }

    func testScan_manualOrderPreserved() throws {
        try createFile(named: "b.md", content: "b")
        try createFile(named: "a.md", content: "a")
        let snap = scan(manualPaths: ["b.md", "a.md"])
        XCTAssertEqual(snap.items.map(\.relativePath), ["b.md", "a.md"],
                       "manual files keep the order the user attached them in")
    }

    // MARK: - Identity corners

    func testScan_inRootSymlinkToDiscoveredFile_noDuplicateItems() throws {
        // A well-known-named symlink resolving to ANOTHER discovered file must
        // not produce two items with the same relativePath (NTMSPaths resolves
        // symlinks, so both hits collapse to the target's path — duplicate ids
        // would break SwiftUI ForEach identity in the grid).
        try createFile(named: "CLAUDE.md", content: "main")
        try createFile(named: "sub/AGENTS.md", content: "real")
        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("GEMINI.md"),
            withDestinationURL: tempDir.appendingPathComponent("sub/AGENTS.md"))

        let snap = scan()
        let paths = snap.items.map(\.relativePath)
        XCTAssertEqual(paths, ["CLAUDE.md", "sub/AGENTS.md"],
                       "resolved duplicate collapses to one item")
        XCTAssertEqual(Set(paths).count, paths.count, "item ids must be unique")
    }

    func testScan_symlinkAliasOfMain_collapsesIntoMain() throws {
        // Symlink alias of the file that WINS main selection — the alias must
        // not resurface as a second listed item.
        try createFile(named: "CLAUDE.md", content: "main")
        try fileManager.createSymbolicLink(
            at: tempDir.appendingPathComponent("AGENTS.md"),
            withDestinationURL: tempDir.appendingPathComponent("CLAUDE.md"))

        let snap = scan()
        XCTAssertEqual(snap.items.map(\.relativePath), ["CLAUDE.md"])
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md")
    }

    func testScan_directoryNamedClaudeMd_notTreatedAsFile() throws {
        // A DIRECTORY named CLAUDE.md is recursed, never injected as a file.
        try createFile(named: "CLAUDE.md/inner.txt", content: "not instructions")
        let snap = scan()
        XCTAssertTrue(snap.isEmpty, "directory with a well-known name is not an instruction file")
    }

    func testScan_lowercaseRootClaude_qualifiesForRootTier() throws {
        try createFile(named: "claude.md", content: "lower")
        try createFile(named: "sub/AGENTS.md", content: "nested")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "claude.md",
                       "root tier matches case-insensitively, not just basenames")
    }

    func testScan_nestedGithubCopilot_isNestedTierOnly() throws {
        // Only the CANONICAL .github/copilot-instructions.md at the root is
        // root-tier; a copy nested deeper competes in the nested tier.
        try createFile(named: "sub/.github/copilot-instructions.md", content: "nested copilot")
        try createFile(named: ".windsurfrules", content: "root windsurf")
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, ".windsurfrules",
                       "root-tier windsurf beats nested copilot")
        XCTAssertEqual(snap.listedPaths, ["sub/.github/copilot-instructions.md"])
    }

    // MARK: - Override corners

    func testScan_promoteMainItself_noDuplicateInjection() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        let snap = scan(injectedPaths: ["CLAUDE.md"])
        XCTAssertEqual(snap.injectedFiles.map(\.relativePath), ["CLAUDE.md"],
                       "promoting the already-injected main is a no-op, not a duplicate")
    }

    func testScan_excludedMainAlsoPromoted_exclusionWins_nextMainPromoted() throws {
        try createFile(named: "CLAUDE.md", content: "claude")
        try createFile(named: "AGENTS.md", content: "agents")
        let snap = scan(excludedPaths: ["CLAUDE.md"], injectedPaths: ["CLAUDE.md"])
        XCTAssertEqual(snap.mainFile?.relativePath, "AGENTS.md")
        XCTAssertTrue(snap.listedPaths.contains("CLAUDE.md"))
        XCTAssertEqual(snap.injectedFiles.count, 1)
    }

    func testScan_staleInjectedPath_ignored() throws {
        try createFile(named: "CLAUDE.md", content: "main")
        let snap = scan(injectedPaths: ["deleted/AGENTS.md"])
        XCTAssertEqual(snap.items.count, 1, "stale promotion produces no item")
    }

    func testScan_exclusionMatchIsExactPath() throws {
        // Overrides store the scanner's original-case relativePath — a
        // case-mismatched exclusion (e.g. after a file rename) is stale and
        // must NOT accidentally match.
        try createFile(named: "CLAUDE.md", content: "main")
        let snap = scan(excludedPaths: ["claude.md"])
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md",
                       "stale case-mismatched exclusion does not suppress injection")
    }

    func testScan_manualBinaryPromoted_staysListed() throws {
        try createRawFile(named: "photo.png", bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x00]))
        let snap = scan(manualPaths: ["photo.png"], injectedPaths: ["photo.png"])
        XCTAssertTrue(snap.injectedFiles.isEmpty)
        XCTAssertEqual(snap.listedPaths, ["photo.png"])
    }

    // MARK: - Manual-path input corners

    func testScan_manualEmptyString_ignoredNoCrash() throws {
        let snap = scan(manualPaths: [""])
        XCTAssertTrue(snap.isEmpty)
    }

    func testScan_manualParentTraversal_rejected() throws {
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("traversal-\(UUID().uuidString).md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: outside) }

        let snap = scan(manualPaths: ["../\(outside.lastPathComponent)"])
        XCTAssertTrue(snap.isEmpty, "`..` traversal resolves outside the folder → rejected")
    }

    func testScan_manualDuplicateEntries_singleItem() throws {
        try createFile(named: "a.md", content: "a")
        let snap = scan(manualPaths: ["a.md", "a.md"])
        XCTAssertEqual(snap.items.count, 1)
    }

    // MARK: - Probe-boundary corners

    func testScan_fileExactlyProbeSize_readFully() throws {
        let content = String(repeating: "a", count: 8192)
        try createFile(named: "CLAUDE.md", content: content)
        XCTAssertEqual(scan().mainFile?.injectedContent, content)
    }

    func testScan_fileOneOverProbeSize_readFully() throws {
        let content = String(repeating: "b", count: 8193)
        try createFile(named: "CLAUDE.md", content: content)
        XCTAssertEqual(scan().mainFile?.injectedContent, content)
    }

    func testScan_multibyteCharStraddlingProbeBoundary_survives() throws {
        // 8191 ASCII chars + a 4-byte emoji = the probe window cuts the emoji
        // mid-sequence; decodeUTF8Prefix must tolerate the cut and the full
        // read must deliver the emoji intact.
        let content = String(repeating: "c", count: 8191) + "🚀" + String(repeating: "d", count: 100)
        try createFile(named: "CLAUDE.md", content: content)
        let injected = scan().mainFile?.injectedContent
        XCTAssertEqual(injected, content)
        XCTAssertTrue(injected?.contains("🚀") ?? false)
    }

    // MARK: - Robustness

    func testScan_unreadableSubdir_partialNoCrash() throws {
        try createFile(named: "CLAUDE.md", content: "root")
        try createFile(named: "locked/AGENTS.md")
        try fileManager.setAttributes([.posixPermissions: 0o000],
                                      ofItemAtPath: tempDir.appendingPathComponent("locked").path)
        let snap = scan()
        XCTAssertEqual(snap.mainFile?.relativePath, "CLAUDE.md")
    }
}
