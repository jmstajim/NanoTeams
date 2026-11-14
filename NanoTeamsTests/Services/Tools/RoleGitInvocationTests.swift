import XCTest

@testable import NanoTeams

/// F6 S2 (D-M19, 2026-11-12): a role's git TOOLS run git with no hook, no fsmonitor, no
/// submodule recursion, and no external diff driver or textconv filter — measured against a
/// real repository whose hook, fsmonitor and textconv would each leave a marker.
final class RoleGitInvocationTests: XCTestCase {
    private let fileManager = FileManager.default
    private var repo: URL!
    private var marker: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repo = fileManager.temporaryDirectory
            .appendingPathComponent("nt-rolegit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
        marker = repo.appendingPathComponent("RAN")
        try git(["init", "-q"])
        try git(["config", "user.name", "t"])
        try git(["config", "user.email", "t@t"])
    }

    override func tearDownWithError() throws {
        if let repo { try? fileManager.removeItem(at: repo) }
        repo = nil
        marker = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> ProcessRunner.Result {
        try ProcessRunner.runGit(arguments, in: repo)
    }

    private func script(_ name: String, body: String) throws -> URL {
        let url = repo.appendingPathComponent(".git/\(name)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testArguments_startWithTheHardeningOptions_andDiffPrintersTakeNoDrivers() {
        XCTAssertEqual(
            RoleGitInvocation.arguments(["status", "--porcelain"]),
            RoleGitInvocation.hardeningOptions + ["status", "--porcelain"])
        for subcommand in ["diff", "log", "show"] {
            XCTAssertEqual(
                RoleGitInvocation.arguments([subcommand, "--", "a"]),
                RoleGitInvocation.hardeningOptions + [subcommand, "--no-ext-diff", "--no-textconv", "--", "a"],
                subcommand)
        }
        XCTAssertEqual(RoleGitInvocation.arguments([]), RoleGitInvocation.hardeningOptions)
    }

    func testCommit_runsNoHook() throws {
        try fileManager.createDirectory(
            at: repo.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try ProcessRunner.runRoleGit(["add", "a.txt"], in: repo).success)

        let commit = try ProcessRunner.runRoleGit(["commit", "-q", "-m", "one"], in: repo)

        XCTAssertTrue(commit.success, commit.stderr)
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path), "the pre-commit hook must not run")
        let control = try git(["commit", "--allow-empty", "-q", "-m", "two"])
        XCTAssertTrue(control.success)
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path), "control: plain git runs the hook")
    }

    func testStatus_runsNoFsmonitor() throws {
        let monitor = try script("monitor.sh", body: "touch \"\(marker.path)\"")
        try git(["config", "core.fsmonitor", monitor.path])

        XCTAssertTrue(try ProcessRunner.runRoleGit(["status", "--porcelain"], in: repo).success)

        XCTAssertFalse(fileManager.fileExists(atPath: marker.path), "core.fsmonitor must not run")
        _ = try git(["status", "--porcelain"])
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path), "control: plain git runs fsmonitor")
    }

    func testDiff_runsNoTextconvAndNoExternalDriver() throws {
        let conv = try script("conv.sh", body: "touch \"\(marker.path)\"; cat \"$1\"")
        try git(["config", "diff.probe.textconv", conv.path])
        try git(["config", "diff.external", conv.path])
        try "*.txt diff=probe\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "--no-verify", "-m", "one"])
        try "b\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let diff = try ProcessRunner.runRoleGit(["diff", "--", "a.txt"], in: repo)
        _ = try ProcessRunner.runRoleGit(["log", "-p", "-1", "--", "a.txt"], in: repo)

        XCTAssertTrue(diff.stdout.contains("+b"), diff.stdout)
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path), "no textconv or external driver may run")
        _ = try git(["diff", "--", "a.txt"])
        XCTAssertTrue(fileManager.fileExists(atPath: marker.path), "control: plain git runs the driver")
    }

    /// The seam is the only way the git tools reach git: no `Git*Handlers` file calls `runGit`.
    func testEveryGitTool_goesThroughTheRoleSeam() throws {
        let handlers = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NanoTeams/Services/Tools/Handlers", isDirectory: true)
        let files = try fileManager.contentsOfDirectory(atPath: handlers.path)
            .filter { $0.hasPrefix("Git") && $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, "anti-vacuum: the git handler files are found")
        var roleCalls = 0
        for file in files {
            let text = try String(contentsOf: handlers.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("ProcessRunner.runGit("), "\(file) calls runGit around the seam")
            roleCalls += text.components(separatedBy: "ProcessRunner.runRoleGit(").count - 1
        }
        XCTAssertGreaterThanOrEqual(roleCalls, 10, "anti-vacuum: the tools' calls were counted")
    }
}
