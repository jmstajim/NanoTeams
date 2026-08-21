import XCTest

@testable import NanoTeams

/// Wave 32 — the bash approval card must show the HUMAN the same facts the Auto judge gets.
///
/// The defect (found by the assign-only sweep): `BashApprovalRequest.workingDirectory` was
/// captured at gate time "the same value the Auto judge would see" — and never rendered.
/// The card showed only the command, so a human approved `rm -rf build/` without being told
/// the model set `working_directory: "Sources"`, while the machine judge DID see the cwd.
/// Same class as the 2026-06-28 gate↔handler split: a validate-then-execute surface must
/// feed every decider the same value — the human is a decider.
final class BashApprovalDisplayTests: XCTestCase {

    private func request(workingDirectory: String?) -> BashApprovalRequest {
        BashApprovalRequest(
            taskID: 1, stepID: "role", commandKey: "k", command: "ls",
            workingDirectory: workingDirectory, offerAlways: false, createdAt: Date())
    }

    /// RED: return `workingDirectory` untrimmed → the trimming assertion fails.
    func testDisplayWorkingDirectory_passesThroughATrimmedValue() {
        XCTAssertEqual(request(workingDirectory: "Sources").displayWorkingDirectory, "Sources")
        XCTAssertEqual(request(workingDirectory: " Sources\n").displayWorkingDirectory, "Sources")
        XCTAssertEqual(request(workingDirectory: "Sources/App").displayWorkingDirectory, "Sources/App")
    }

    /// nil and whitespace-only both RESOLVE to the work-folder root
    /// (`SandboxPathResolver.resolveFileURL` trims, then maps empty → root — pinned by
    /// `BashHandlersTests.testWorkingDirectory_whitespaceOnly_runsInWorkFolderRoot`), so the
    /// card hides the cwd line exactly when the directory does not change the command's
    /// meaning. Showing "cwd:    " for a whitespace value would imply a directory exists.
    ///
    /// RED: drop the trim-to-nil normalization → the whitespace assertion fails.
    func testDisplayWorkingDirectory_nilAndWhitespace_meanTheRootAndHide() {
        XCTAssertNil(request(workingDirectory: nil).displayWorkingDirectory)
        XCTAssertNil(request(workingDirectory: "   \n\t").displayWorkingDirectory)
        XCTAssertNil(request(workingDirectory: "").displayWorkingDirectory)
    }

    /// The card BODY is a `some View` — not reachable by behavioral XCTest — so the wiring is
    /// pinned at the source, mirroring `TeamActivityFeedContainerInvariantTests`. This is the
    /// half a pure-helper test cannot carry: the original defect was precisely "the field
    /// exists, tested, documented — and no view reads it".
    ///
    /// RED: remove the cwd line from `BashApprovalCard` → this fails while both tests above
    /// stay green (they pin the helper, not the render).
    func testApprovalCard_rendersTheWorkingDirectory() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LLM/
            .deletingLastPathComponent()  // Services/
            .deletingLastPathComponent()  // NanoTeamsTests/
            .deletingLastPathComponent()  // repo root
        let card = repoRoot
            .appendingPathComponent("NanoTeams/Views/TeamBoard/TeamActivityComposer.swift")
        let source = try String(contentsOf: card, encoding: .utf8)
        // Strip line comments so a doc comment mentioning the identifier can't satisfy the
        // pin (source-scan rule), and assemble the needle at runtime so THIS file's own
        // mention of it never matches itself.
        let code = source.components(separatedBy: "\n")
            .map { line -> String in
                if let slash = line.range(of: "//") { return String(line[line.startIndex..<slash.lowerBound]) }
                return line
            }
            .joined(separator: "\n")
        let needle = "displayWorking" + "Directory"
        XCTAssertTrue(code.contains(needle),
                      "BashApprovalCard no longer renders the working directory — the human "
                          + "approves a command without seeing the cwd the Auto judge sees")
    }
}
