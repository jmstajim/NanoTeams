import XCTest

@testable import NanoTeams

/// Xcode issue/test-failure paths are relativized against the work-folder root before they reach
/// the LLM. The relativization used to be a raw `hasPrefix` + `dropFirst(count + 1)`, which is the
/// same defect class as the `.gitignore` containment bug (`…/Application Supportive` matching
/// `…/Application Support`): `URL.path` carries no trailing slash, so a sibling directory whose
/// name merely EXTENDS the work folder's name passed the prefix test, and the paired `+ 1`
/// separator-eater then consumed a real character of that sibling's own name.
final class XcodeIssuePathRelativizationTests: XCTestCase {

    // MARK: - The boundary bug

    /// THE REGRESSION PIN. Work folder `/Users/x/NanoTeams`, issue in the sibling
    /// `/Users/x/NanoTeamsPrivate` — `hasPrefix` matched and `dropFirst(21 + 1)` produced
    /// `rivate/Sources/A.swift`, a path that has never existed. The model then burns iterations
    /// on a `read_file` that cannot resolve while the real, out-of-folder origin of the issue is
    /// hidden. Containment must be component-wise, and a non-contained path must stay ABSOLUTE
    /// so the origin remains visible.
    func testRelativizeIssuePath_prefixSiblingDirectory_keepsAbsolutePath() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)
        let sibling = "/Users/x/NanoTeamsPrivate/Sources/A.swift"

        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath(sibling, workFolderRoot: root),
            sibling,
            "a name-prefix sibling is NOT inside the work folder — it must not be relativized")
    }

    /// The same boundary, driven end-to-end through the real parser so the call site is pinned,
    /// not just the helper.
    func testParseIssues_prefixSiblingDirectory_keepsAbsolutePath() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)
        let output = "/Users/x/NanoTeamsPrivate/Sources/A.swift:12:5: warning: unused variable"

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.file, "/Users/x/NanoTeamsPrivate/Sources/A.swift")
        XCTAssertNotEqual(issues.first?.file, "rivate/Sources/A.swift", "the old off-by-one bug")
    }

    /// A genuine descendant still relativizes — the fix must not over-correct into "never
    /// relativize", which would push absolute paths at the model for every ordinary warning.
    func testRelativizeIssuePath_genuineDescendant_relativizes() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)

        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath(
                "/Users/x/NanoTeams/Sources/A.swift", workFolderRoot: root),
            "Sources/A.swift")
    }

    func testParseIssues_genuineDescendant_relativizes() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)
        let output = """
            /Users/x/NanoTeams/Sources/A.swift:12:5: warning: unused variable
            /Users/x/NanoTeams/Sources/B.swift:3:1: error: cannot find 'Foo' in scope
            """

        let issues = XcodeBuildRunner.parseIssues(from: output, workFolderRoot: root)

        XCTAssertEqual(issues.map(\.file), ["Sources/A.swift", "Sources/B.swift"])
    }

    // MARK: - Corner cases

    /// The degenerate case: the reported path IS the work-folder root. `dropFirst` past the end
    /// returns "" — an empty `file` erases the issue's location entirely, which is strictly worse
    /// than an absolute path. Keep it absolute.
    func testRelativizeIssuePath_exactlyTheRoot_keepsAbsolutePath() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)

        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath("/Users/x/NanoTeams", workFolderRoot: root),
            "/Users/x/NanoTeams")
    }

    /// A root of `/` is the other end of the same off-by-one: `dropFirst("/".count + 1)` == 2 ate
    /// the leading `e` of `/etc/…`. Component-wise containment gets it right.
    func testRelativizeIssuePath_filesystemRootAsWorkFolder_relativizesWithoutEatingACharacter() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)

        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath("/etc/hosts", workFolderRoot: root),
            "etc/hosts")
    }

    func testRelativizeIssuePath_outsideRoot_keepsAbsolutePath() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)

        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath("/etc/hosts", workFolderRoot: root),
            "/etc/hosts")
    }

    /// xcodebuild emits non-path tokens too (SwiftPM diagnostics, `<unknown>`, plain messages).
    /// They must pass through untouched rather than being mangled or emptied.
    func testRelativizeIssuePath_nonPathAndEmptyInputs_passThroughUnchanged() {
        let root = URL(fileURLWithPath: "/Users/x/NanoTeams", isDirectory: true)

        XCTAssertEqual(XcodeBuildRunner.relativizeIssuePath("", workFolderRoot: root), "")
        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath("<unknown>", workFolderRoot: root), "<unknown>")
        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath("Sources/A.swift", workFolderRoot: root),
            "Sources/A.swift",
            "an already-relative path is not under the absolute root and must not be rewritten")
    }

    /// Symlink divergence is the OTHER half of why a string prefix is wrong: macOS reports build
    /// paths in either the `/var` or the `/private/var` form depending on how the toolchain
    /// resolved them, and a raw prefix test misses the pair entirely. Containment resolves
    /// symlinks (same semantics as `NTMSPaths.relativePathFromProjectRoot`), so both spellings of
    /// the same file relativize identically.
    func testRelativizeIssuePath_symlinkedRootSpelling_relativizesEitherWay() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("nt_relpath_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let src = real.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let link = base.appendingPathComponent("link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let file = src.appendingPathComponent("A.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        // Root spelled through the symlink, issue path spelled through the real directory.
        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath(file.path, workFolderRoot: link),
            "Sources/A.swift")
        // ...and the mirror image.
        XCTAssertEqual(
            XcodeBuildRunner.relativizeIssuePath(
                link.appendingPathComponent("Sources/A.swift").path, workFolderRoot: real),
            "Sources/A.swift")
    }
}
