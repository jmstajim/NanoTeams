import XCTest
@testable import NanoTeams

/// Tests for `SandboxPathResolver.isWithin(candidate:container:)` — the static
/// helper used across the codebase for "is path X contained within directory Y"
/// checks (internal-directory redaction, attachment-dir validation, source-
/// context self-capture guard, etc.).
///
/// The method must use path-component equality, NOT raw string prefix, so that
/// a container `/foo/internal` does NOT falsely contain `/foo/internal-backup`.
/// This is called out in the implementation's doc comment and is security-
/// critical: if `isWithin` returned true for partial-component matches, a
/// directory named `.nanoteams/internal-backup` (or similar adversarial layout)
/// could be redacted as if it were the protected internal dir — or worse, a
/// path outside the internal dir could be mistakenly blocked/allowed.
final class SandboxPathResolverIsWithinTests: XCTestCase {

    // MARK: - Positive cases (candidate IS contained)

    func testIsWithin_candidateEqualToContainer_returnsTrue() {
        let dir = URL(fileURLWithPath: "/tmp/project")
        XCTAssertTrue(SandboxPathResolver.isWithin(candidate: dir, container: dir))
    }

    func testIsWithin_candidateImmediateChild_returnsTrue() {
        let container = URL(fileURLWithPath: "/tmp/project")
        let candidate = URL(fileURLWithPath: "/tmp/project/file.txt")
        XCTAssertTrue(SandboxPathResolver.isWithin(candidate: candidate, container: container))
    }

    func testIsWithin_candidateDeepDescendant_returnsTrue() {
        let container = URL(fileURLWithPath: "/tmp/project")
        let candidate = URL(fileURLWithPath: "/tmp/project/a/b/c/file.txt")
        XCTAssertTrue(SandboxPathResolver.isWithin(candidate: candidate, container: container))
    }

    // MARK: - Security-critical: partial-component match must NOT count as "within"

    /// Docstring regression: `/foo/internal-backup` must NOT match `/foo/internal`.
    /// Raw string prefix would match; path-component equality must not.
    func testIsWithin_siblingWithSharedPrefix_returnsFalse() {
        let container = URL(fileURLWithPath: "/foo/internal")
        let sibling = URL(fileURLWithPath: "/foo/internal-backup/secret.json")

        XCTAssertFalse(
            SandboxPathResolver.isWithin(candidate: sibling, container: container),
            "`/foo/internal-backup/secret.json` must NOT be considered within `/foo/internal`"
        )
    }

    func testIsWithin_siblingWithSharedPrefix_noTrailingSlash_returnsFalse() {
        let container = URL(fileURLWithPath: "/project/.nanoteams/internal")
        let sibling = URL(fileURLWithPath: "/project/.nanoteams/internalfoo")

        XCTAssertFalse(
            SandboxPathResolver.isWithin(candidate: sibling, container: container),
            "`.nanoteams/internalfoo` (suffix-shares with `internal`) must not match"
        )
    }

    /// A candidate that is a PARENT of the container must NOT count as "within".
    /// (Containment is asymmetric — `/foo` is not inside `/foo/bar`.)
    func testIsWithin_candidateIsParentOfContainer_returnsFalse() {
        let container = URL(fileURLWithPath: "/tmp/project")
        let parent = URL(fileURLWithPath: "/tmp")
        XCTAssertFalse(SandboxPathResolver.isWithin(candidate: parent, container: container))
    }

    func testIsWithin_unrelatedPaths_returnsFalse() {
        let container = URL(fileURLWithPath: "/tmp/project")
        let other = URL(fileURLWithPath: "/var/log/system.log")
        XCTAssertFalse(SandboxPathResolver.isWithin(candidate: other, container: container))
    }

    // MARK: - Standardization

    /// The method calls `.standardizedFileURL` on both sides, so `./` and
    /// `..` in either path should be resolved before comparison. This guards
    /// against an LLM that submits a path with `.` segments slipping past
    /// the check.
    func testIsWithin_resolvesTrivialDotSegments() {
        let container = URL(fileURLWithPath: "/tmp/project")
        let candidate = URL(fileURLWithPath: "/tmp/project/./src/./file.txt")
        XCTAssertTrue(SandboxPathResolver.isWithin(candidate: candidate, container: container))
    }

    // MARK: - Real-world internal-dir check

    /// Mirrors the real call-site in `NTMSPaths.isInternalURL` — the internal
    /// dir check that protects `.nanoteams/internal/*`. A path like
    /// `.nanoteams/internal-foo/x` must not be classified as internal.
    func testIsWithin_internalDirPattern_regressionCheck() {
        let projectRoot = URL(fileURLWithPath: "/Users/test/project")
        let internalDir = projectRoot.appendingPathComponent(".nanoteams/internal")

        let trueInternal = internalDir.appendingPathComponent("tasks/5/task.json")
        XCTAssertTrue(SandboxPathResolver.isWithin(candidate: trueInternal, container: internalDir))

        let siblingDecoy = projectRoot
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent("internal-foo")
            .appendingPathComponent("tasks/5/task.json")
        XCTAssertFalse(
            SandboxPathResolver.isWithin(candidate: siblingDecoy, container: internalDir),
            "A sibling named with `internal` as a substring must not be treated as internal"
        )
    }
}
