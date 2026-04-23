import XCTest
@testable import NanoTeams

/// Tests for `NTMSPaths` role-ID sanitization — security-relevant path
/// validation that prevents roleIDs containing `/` or `..` from escaping
/// the run/role directory layout.
///
/// `sanitizePathComponent` is private, but exercised through every public
/// method that takes a `roleID: String` argument:
/// - `roleDir(taskID:runID:roleID:)` — LLM-accessible artifact dir
/// - `internalRoleDir(taskID:runID:roleID:)` — internal build-diagnostics dir
/// - `buildDiagnosticsJSON(...)` / `buildExcerptsTXT(...)` — derived URLs
///
/// All replacements preserve the original name's readability where possible
/// (`/` and `..` → `_`, but legitimate dots and digits are kept).
final class NTMSPathsSanitizationTests: XCTestCase {

    private var paths: NTMSPaths!

    override func setUp() {
        super.setUp()
        let root = URL(fileURLWithPath: "/tmp/test_project")
        paths = NTMSPaths(workFolderRoot: root)
    }

    override func tearDown() {
        paths = nil
        super.tearDown()
    }

    // MARK: - Traversal-attempt role IDs

    /// A role ID containing `..` must never surface as a directory segment
    /// that Finder/URL could resolve up the tree. The current implementation
    /// replaces `..` with `_` BEFORE URL construction.
    func testRoleDir_dotDotRoleID_isSanitized() {
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "..")
        XCTAssertFalse(url.path.contains("/../"),
                       "Role ID `..` must not produce a `/../` path segment")
        // Actual replacement: ".." → "_"
        XCTAssertTrue(url.path.contains("/_"),
                      "Sanitized `..` should appear as `_` in the path")
    }

    func testRoleDir_embeddedDotDot_isSanitized() {
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "foo..bar")
        // "foo..bar" → "foo_bar" (".." replaced)
        XCTAssertFalse(url.path.contains("foo..bar"),
                       "Embedded `..` must be scrubbed from the role ID")
        XCTAssertTrue(url.path.hasSuffix("foo_bar"),
                      "Replacement should yield `foo_bar`, got `\(url.path)`")
    }

    func testInternalRoleDir_dotDotRoleID_staysInsideInternalDir() {
        let url = paths.internalRoleDir(taskID: 1, runID: 0, roleID: "../..")
        // Must still be within the internal directory — no escape.
        XCTAssertTrue(
            SandboxPathResolver.isWithin(candidate: url, container: paths.internalDir),
            "Sanitized internalRoleDir must remain inside .nanoteams/internal"
        )
    }

    // MARK: - Slash role IDs

    /// `/` in a role ID would create a sub-directory segment — confusing
    /// directory layout and breaking listings that assume flat role dirs.
    /// Must be replaced with `_` before URL construction.
    func testRoleDir_slashRoleID_isSanitized() {
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "team/member")
        XCTAssertFalse(url.path.hasSuffix("team/member"),
                       "`/` in role ID must not create a nested directory")
        // "team/member" → "team_member"
        XCTAssertTrue(url.path.hasSuffix("team_member"),
                      "Slash should be replaced with `_`, got `\(url.path)`")
    }

    func testRoleDir_multipleSlashes_allReplaced() {
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "a/b/c")
        XCTAssertTrue(url.path.hasSuffix("a_b_c"),
                      "All `/` chars must be replaced with `_`")
    }

    // MARK: - Build diagnostics paths

    func testBuildDiagnosticsJSON_dotDotRoleID_isSanitized() {
        let url = paths.buildDiagnosticsJSON(taskID: 1, runID: 0, roleID: "..")
        XCTAssertFalse(url.path.contains("/../"),
                       "Build diagnostics file must not use an unsanitized `..` segment")
        XCTAssertTrue(url.lastPathComponent == "build_diagnostics.json")
    }

    func testBuildExcerptsTXT_slashRoleID_isSanitized() {
        let url = paths.buildExcerptsTXT(taskID: 1, runID: 0, roleID: "role/with/slash")
        // The role-dir segment should be `role_with_slash`, but the file
        // name stays exactly `build_excerpts.txt`.
        XCTAssertEqual(url.lastPathComponent, "build_excerpts.txt")
        XCTAssertTrue(url.path.contains("role_with_slash"))
    }

    // MARK: - Safe role IDs pass through untouched

    func testRoleDir_safeRoleID_isUnchanged() {
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "software_engineer")
        XCTAssertTrue(url.path.hasSuffix("software_engineer"))
    }

    func testRoleDir_teamScopedRoleID_isUnchanged() {
        // Team-scoped IDs like `faang_team_software_engineer` use only
        // letters/digits/underscores — must pass through.
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "faang_team_software_engineer")
        XCTAssertTrue(url.path.hasSuffix("faang_team_software_engineer"))
    }

    func testRoleDir_singleDotInRoleID_preserved() {
        // A single `.` is NOT `..` — should be preserved.
        let url = paths.roleDir(taskID: 1, runID: 0, roleID: "v1.beta")
        XCTAssertFalse(url.path.contains("/../"))
        XCTAssertTrue(url.path.contains("v1.beta"),
                      "Single dots in IDs must be preserved, got `\(url.path)`")
    }

    // MARK: - Sandbox containment

    /// Composite invariant: for any role ID (malicious or benign), the
    /// resulting `roleDir` URL must stay inside the work folder root.
    func testRoleDir_alwaysStaysInsideWorkFolder() {
        let mischievous = ["..", "../../etc", "a/b", "..", "a//..//b", "///"]
        for roleID in mischievous {
            let url = paths.roleDir(taskID: 1, runID: 0, roleID: roleID)
            XCTAssertTrue(
                SandboxPathResolver.isWithin(candidate: url, container: paths.workFolderRoot),
                "roleDir for `\(roleID)` escaped work folder: \(url.path)"
            )
        }
    }

    func testInternalRoleDir_alwaysStaysInsideInternalDir() {
        let mischievous = ["..", "../..", "a/b", "./../"]
        for roleID in mischievous {
            let url = paths.internalRoleDir(taskID: 1, runID: 0, roleID: roleID)
            XCTAssertTrue(
                SandboxPathResolver.isWithin(candidate: url, container: paths.internalDir),
                "internalRoleDir for `\(roleID)` escaped internal dir: \(url.path)"
            )
        }
    }
}
