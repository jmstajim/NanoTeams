import XCTest

@testable import NanoTeams

/// Tests for git-availability tool filtering. When the work folder isn't a git
/// repository, git tools must be stripped from the schemas shown to the LLM so the
/// model doesn't waste iterations calling tools that can only return
/// `not-a-repository` errors. Parallel to `DefaultStorageToolFilterTests`.
@MainActor
final class GitAvailabilityToolFilterTests: XCTestCase {
    private var tempRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempRoot = fm.temporaryDirectory.appendingPathComponent("git-avail-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    private func makeTools() -> [ToolSchema] {
        [
            ToolSchema(name: "read_file", description: "Read", parameters: .object(properties: [:])),
            ToolSchema(name: "write_file", description: "Write", parameters: .object(properties: [:])),
            ToolSchema(name: "ask_supervisor", description: "Ask", parameters: .object(properties: [:])),
            ToolSchema(name: "git_status", description: "Git read", parameters: .object(properties: [:])),
            ToolSchema(name: "git_diff", description: "Git read", parameters: .object(properties: [:])),
            ToolSchema(name: "git_log", description: "Git read", parameters: .object(properties: [:])),
            ToolSchema(name: "git_branch_list", description: "Git read", parameters: .object(properties: [:])),
            ToolSchema(name: "git_add", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_commit", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_checkout", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_merge", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_branch", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_pull", description: "Git write", parameters: .object(properties: [:])),
            ToolSchema(name: "git_stash", description: "Git write", parameters: .object(properties: [:])),
        ]
    }

    // MARK: - isGitRepository

    func testIsGitRepository_returnsTrue_whenDotGitDirExists() throws {
        try fm.createDirectory(at: tempRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertTrue(LLMExecutionService.isGitRepository(at: tempRoot))
    }

    func testIsGitRepository_returnsTrue_whenDotGitIsFile() throws {
        // Submodules and linked worktrees store `.git` as a file (`gitdir: ...`).
        let gitFile = tempRoot.appendingPathComponent(".git")
        try "gitdir: /somewhere/else\n".write(to: gitFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(LLMExecutionService.isGitRepository(at: tempRoot))
    }

    func testIsGitRepository_returnsFalse_whenNoDotGit() {
        XCTAssertFalse(LLMExecutionService.isGitRepository(at: tempRoot))
    }

    // MARK: - filterForGitAvailability

    func testFilter_stripsAllGitToolsWhenNotARepo() {
        let filtered = LLMExecutionService.filterForGitAvailability(makeTools(), workFolderRoot: tempRoot)
        let names = Set(filtered.map(\.name))

        // Non-git tools survive
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        XCTAssertTrue(names.contains("ask_supervisor"))

        // Every git tool is gone — no exceptions. Regression guard: if a new git
        // tool is added, it must be in `ToolHandlerRegistry.gitRead*`/`gitWrite*`
        // so this filter catches it automatically.
        for gitName in ["git_status", "git_diff", "git_log", "git_branch_list",
                        "git_add", "git_commit", "git_checkout", "git_merge",
                        "git_branch", "git_pull", "git_stash"] {
            XCTAssertFalse(names.contains(gitName), "\(gitName) must be stripped when no .git")
        }
    }

    func testFilter_keepsAllGitToolsWhenRepoExists() throws {
        try fm.createDirectory(at: tempRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let filtered = LLMExecutionService.filterForGitAvailability(makeTools(), workFolderRoot: tempRoot)
        XCTAssertEqual(filtered.count, makeTools().count, "All tools pass when .git present")
    }

    func testFilter_coversBothReadAndWriteCategories() {
        // Belt-and-suspenders: confirms the union of gitReadTools + gitWriteTools
        // covers every git tool produced by the registry. If someone adds a new
        // git category later, this test will fail loudly until the filter is
        // updated.
        let allGitFromRegistry = ToolHandlerRegistry.gitReadTools.union(ToolHandlerRegistry.gitWriteTools)
        let allGitTools: Set<String> = [
            "git_status", "git_diff", "git_log", "git_branch_list",
            "git_add", "git_commit", "git_checkout", "git_merge",
            "git_branch", "git_pull", "git_stash",
        ]
        XCTAssertEqual(allGitFromRegistry, allGitTools,
                       "ToolHandlerRegistry git* sets must cover every git tool. "
                     + "If this fails, either a new tool is missing a category or "
                     + "the filter won't catch it.")
    }
}
