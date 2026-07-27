import XCTest

@testable import NanoTeams

/// Config resolution for headless runs.
///
/// The bug these pin: `run_headless.sh` exported `NANOTEAMS_CONFIG_PATH` and
/// nothing read it, so the wrapper's argument was ignored and a missing config
/// made the test PASS while doing nothing.
final class HeadlessConfigLocatorTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/repo")
    private let key = HeadlessConfigLocator.environmentKey

    private func resolve(
        env: [String: String],
        existing: Set<String>
    ) -> HeadlessConfigLocator.Resolution {
        HeadlessConfigLocator.resolve(
            environment: env,
            repositoryRoot: root,
            fileExists: { existing.contains($0.path) }
        )
    }

    // MARK: - Environment override

    func testEnvironmentOverride_whenPresent_wins() {
        let r = resolve(env: [key: "/elsewhere/cfg.json"], existing: ["/elsewhere/cfg.json"])
        XCTAssertEqual(r, .found(URL(fileURLWithPath: "/elsewhere/cfg.json"), source: .environment))
    }

    /// The override beats the repository default even when BOTH exist —
    /// otherwise `./run_headless.sh other.json` would silently run the file the
    /// train-app skill last wrote.
    func testEnvironmentOverride_outranksAnExistingRepositoryDefault() {
        let r = resolve(
            env: [key: "/elsewhere/cfg.json"],
            existing: ["/elsewhere/cfg.json", "/repo/.nanoteams/headless_task.json"])
        XCTAssertEqual(r, .found(URL(fileURLWithPath: "/elsewhere/cfg.json"), source: .environment))
    }

    /// A named-but-absent override is a FAILURE, not a skip: the caller stated
    /// where to look, so silence there is a broken invocation.
    func testEnvironmentOverride_whenAbsent_isMissingOverrideNotSkip() {
        let r = resolve(env: [key: "/elsewhere/cfg.json"], existing: [])
        XCTAssertEqual(r, .missingOverride(URL(fileURLWithPath: "/elsewhere/cfg.json")))
    }

    func testEnvironmentOverride_relativePath_resolvesAgainstTheRepositoryRoot() {
        let r = resolve(env: [key: "cfg.json"], existing: ["/repo/cfg.json"])
        XCTAssertEqual(r, .found(URL(fileURLWithPath: "/repo/cfg.json"), source: .environment))
    }

    // MARK: - Blank override behaves as unset

    /// `export NANOTEAMS_CONFIG_PATH=` and a whitespace-only value are the shell
    /// spellings of "not set" — treating them as a named path would turn a bare
    /// wrapper invocation into a hard failure.
    func testEnvironmentOverride_emptyOrWhitespace_fallsBackToTheDefault() {
        for blank in ["", "   ", "\n", "\t "] {
            let r = resolve(env: [key: blank], existing: ["/repo/.nanoteams/headless_task.json"])
            XCTAssertEqual(
                r,
                .found(URL(fileURLWithPath: "/repo/.nanoteams/headless_task.json"),
                       source: .repositoryDefault),
                "\(blank.debugDescription) must read as unset")
        }
    }

    func testEnvironmentOverride_whitespacePadded_isTrimmedNotRejected() {
        let r = resolve(env: [key: "  /elsewhere/cfg.json \n"], existing: ["/elsewhere/cfg.json"])
        XCTAssertEqual(r, .found(URL(fileURLWithPath: "/elsewhere/cfg.json"), source: .environment))
    }

    // MARK: - Repository default

    func testNoOverride_existingDefault_isFound() {
        let r = resolve(env: [:], existing: ["/repo/.nanoteams/headless_task.json"])
        XCTAssertEqual(
            r,
            .found(URL(fileURLWithPath: "/repo/.nanoteams/headless_task.json"),
                   source: .repositoryDefault))
    }

    /// No override and no default is the legitimate "a normal `xcodebuild test`
    /// is running" state — SKIP, and name the path that was checked.
    func testNoOverride_noDefault_isNoneNotFailure() {
        let r = resolve(env: [:], existing: [])
        XCTAssertEqual(r, .none(checked: URL(fileURLWithPath: "/repo/.nanoteams/headless_task.json")))
    }

    /// The default path is the one the train-app skill writes; a rename there
    /// silently orphans every direct `xcodebuild` invocation.
    func testRepositoryDefaultSubpath_isFrozen() {
        XCTAssertEqual(HeadlessConfigLocator.repositoryDefaultSubpath,
                       ".nanoteams/headless_task.json")
        XCTAssertEqual(HeadlessConfigLocator.environmentKey, "NANOTEAMS_CONFIG_PATH")
    }

    /// An unrelated variable must not be mistaken for the override.
    func testUnrelatedEnvironment_isIgnored() {
        let r = resolve(env: ["HOME": "/Users/x"], existing: [])
        XCTAssertEqual(r, .none(checked: URL(fileURLWithPath: "/repo/.nanoteams/headless_task.json")))
    }
}
