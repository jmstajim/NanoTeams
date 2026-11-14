import XCTest

@testable import NanoTeams

/// D-M19 (S2, S3 of the F6 acceptance, 2026-11-12), measured against the REAL profile under the
/// real `sandbox-exec`: what a role's `bash` may not do to the repository it works in and to the
/// work folder itself.
///
/// - S2: besides `.git/hooks` and `.git/config` (`SeatbeltSandboxTests`), every other place git
///   reads a command or another repository from is closed — `config.worktree`, `commondir`,
///   `modules/`, `worktrees/`, `info/{exclude,attributes,sparse-checkout,grafts}`,
///   `objects/info/{alternates,http-alternates}` — and the `.git` node itself cannot be created
///   (a gitfile `gitdir: <elsewhere>` would point the next git at another repository). The rest
///   of `.git` stays writable: `bash`'s own `git commit` still commits.
/// - S3: the work folder and each of its ancestors cannot be renamed or removed — Seatbelt
///   matches paths, so a moved work folder leaves every rule naming it behind.
///
/// Each test writes a marker the profile must refuse and then checks the marker is absent, beside
/// a control write the profile allows (the test reads the command's own `DONE`, so a profile that
/// refused everything would not pass).
final class SeatbeltRepositoryChannelTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard fileManager.isExecutableFile(atPath: BashConstants.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec unavailable on this host")
        }
        root = fileManager.temporaryDirectory
            .appendingPathComponent("nt-sbrepo-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("parent/work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
        root = nil
        work = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func runSandboxed(_ command: String) throws -> String {
        let profile = SeatbeltSandbox.profile(
            workFolderRoot: work, permissions: BashSandboxPermissions(), guardedLoopbackPorts: [])
        let (exe, args) = SeatbeltSandbox.wrap(profile: profile, shell: "/bin/zsh", command: command)
        let out = try ProcessRunner.run(
            executable: exe, arguments: args, currentDirectory: work, timeout: 30).stdout
        XCTAssertTrue(out.contains("DONE"), "the command ran to its end: \(out)")
        return out
    }

    private func gitInit() throws {
        let res = try ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["init", "-q", work.path], currentDirectory: root)
        XCTAssertEqual(res.exitCode, 0, res.stderr)
    }

    private func exists(_ relative: String) -> Bool {
        fileManager.fileExists(atPath: work.appendingPathComponent(relative).path)
    }

    // MARK: - S2

    func testRepositoryRedirectsAndCommandSources_areNotWritable() throws {
        try gitInit()
        let channels = [
            ".git/config.worktree", ".git/commondir",
            ".git/info/exclude", ".git/info/attributes", ".git/info/sparse-checkout", ".git/info/grafts",
            ".git/objects/info/alternates", ".git/objects/info/http-alternates",
        ]
        let before = try channels.map { path -> String? in
            let url = work.appendingPathComponent(path)
            return fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
        }
        try runSandboxed(
            channels.map { "echo PLANTED > \($0) 2>/dev/null; " }.joined()
                + "mkdir -p .git/modules/m .git/worktrees/w 2>/dev/null; "
                + "echo PLANTED > .git/modules/m/config 2>/dev/null; "
                + "echo PLANTED > .git/worktrees/w/gitdir 2>/dev/null; "
                + "echo ok > plain.txt; echo DONE")

        for (index, path) in channels.enumerated() {
            let url = work.appendingPathComponent(path)
            let after = fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
            XCTAssertEqual(after, before[index], "\(path) must not be writable from bash")
        }
        XCTAssertFalse(exists(".git/modules/m/config"), ".git/modules must not be writable")
        XCTAssertFalse(exists(".git/worktrees/w/gitdir"), ".git/worktrees must not be writable")
        XCTAssertTrue(exists("plain.txt"), "control: the work folder stays writable")
    }

    func testGitNode_cannotBeCreated_neitherAsADirectoryNorAsAGitfile() throws {
        try runSandboxed(
            "mkdir .git 2>/dev/null; echo 'gitdir: /tmp/elsewhere' > .git 2>/dev/null; "
                + "echo ok > plain.txt; echo DONE")
        XCTAssertFalse(exists(".git"), "a role must not create the .git node")
        XCTAssertTrue(exists("plain.txt"))
    }

    func testOrdinaryGitWork_stillCommits() throws {
        try gitInit()
        let out = try runSandboxed(
            "echo one > a.txt && git add a.txt && "
                + "git -c user.name=t -c user.email=t@t commit -q -m one && "
                + "echo two > a.txt && git -c user.name=t -c user.email=t@t commit -q -am two && "
                + "git branch b && git checkout -q b && git log --oneline | wc -l | tr -d ' '; echo DONE")
        XCTAssertTrue(out.contains("2\n"), "two commits on the new branch: \(out)")
    }

    // MARK: - S3

    func testWorkFolderAndItsAncestors_cannotBeRenamedOrRemoved() throws {
        let parent = work.deletingLastPathComponent()
        try runSandboxed(
            "mv \"$PWD\" \"$PWD-moved\" 2>/dev/null; "
                + "mv \(parent.path) \(parent.path)-moved 2>/dev/null; "
                + "rmdir \"$PWD\" 2>/dev/null; "
                + "echo ok > plain.txt; echo DONE")
        XCTAssertTrue(fileManager.fileExists(atPath: work.path), "the work folder must not move")
        XCTAssertTrue(fileManager.fileExists(atPath: parent.path), "an ancestor must not move")
        XCTAssertFalse(fileManager.fileExists(atPath: work.path + "-moved"))
        XCTAssertFalse(fileManager.fileExists(atPath: parent.path + "-moved"))
        XCTAssertTrue(exists("plain.txt"))
    }

    func testEntriesInsideTheWorkFolder_stillMoveAndGo() throws {
        try fileManager.createDirectory(at: work.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try runSandboxed("mv dir dir2 && echo x > f && rm f && rmdir dir2; echo DONE")
        XCTAssertFalse(exists("dir"))
        XCTAssertFalse(exists("dir2"))
    }
}
