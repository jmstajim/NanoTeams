import XCTest
@testable import NanoTeams

/// The git tools run `/usr/bin/git` in the app's own process, outside Seatbelt and with the
/// person's own rights (#376, review 2026-11-08). Two holes followed from that:
///
/// 1. `relativizePathspec` handed a REFUSED pathspec to git unchanged, so `git_add` staged a
///    hidden file and `git_diff cached:true` printed its content — an agent's bearer, in
///    two calls, with no symlink and no race.
/// 2. A pathspec was not even needed: `git diff` with none is REPOSITORY-wide, and the
///    repository encloses the work folder whenever the person opened a subdirectory of one.
///
/// Every fixture is a throwaway repository under a temporary folder with a FAKE home, so the
/// hidden locations are the fixture's own; nothing here touches the real `~`.
final class GitToolScopeTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var home: URL!
    private var work: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory
            .appendingPathComponent("nt-gitscope-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        home = base.appendingPathComponent("home", isDirectory: true)
        work = home!
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
        base = nil; home = nil; work = nil; runtime = nil; context = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    @discardableResult
    private func git(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.email=t@t", "-c", "user.name=t"] + arguments
        process.currentDirectoryURL = directory ?? work
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ text: String, _ relative: String, under root: URL? = nil) throws {
        let url = (root ?? work).appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The work folder is the fake home and a git repository, with an agent token file
    /// and an SSH key inside it — the dotfiles-repo-as-project case `hiddenLocations` exists for.
    private func makeRepoAtHome(tokenTracked: Bool) throws {
        try write("ntm_a4c36525_SECRET\n", ".config/nanoteams/a4c36525.token")
        try write("PRIVATE-KEY-BYTES", ".ssh/id_ed25519")
        try write("# notes", "README.md")
        try git(["init", "-q", "-b", "main"])
        if tokenTracked {
            try git(["add", "-A"])
        } else {
            try git(["add", "README.md"])
        }
        try git(["commit", "-qm", "init"])
        try makeRuntime(workFolderRoot: work)
    }

    private func makeRuntime(workFolderRoot: URL) throws {
        let paths = NTMSPaths(workFolderRoot: workFolderRoot)
        try fm.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)
        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: workFolderRoot,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0),
            home: home)
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: workFolderRoot, taskID: 0, runID: 0, roleID: "r")
    }

    private func call(_ name: String, _ json: String) async -> ToolExecutionResult {
        await runtime.executeAll(
            context: context, toolCalls: [StepToolCall(name: name, argumentsJSON: json)])[0]
    }

    // MARK: - A pathspec that NAMES a hidden location

    func testGitAdd_ofATokenFile_isRefusedAndStagesNothing() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let result = await call("git_add", #"{"paths":[".config/nanoteams/a4c36525.token"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("FILE_NOT_FOUND"), result.outputJSON)
        XCTAssertFalse(try git(["diff", "--cached", "--name-only"]).contains("a4c36525"))
    }

    func testGitDiff_namingAHiddenPath_isRefused() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let result = await call("git_diff", #"{"paths":[".ssh/id_ed25519"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("PRIVATE-KEY-BYTES"), result.outputJSON)
    }

    func testGitLog_namingAHiddenPath_isRefused() async throws {
        try makeRepoAtHome(tokenTracked: true)
        let result = await call("git_log", #"{"paths":[".config/nanoteams/a4c36525.token"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
    }

    /// `:`-magic can address the repository top, which lies ABOVE the work folder whenever the
    /// repository encloses it — so it is not a path these tools may be given.
    func testPathspecMagic_isRefused() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let result = await call("git_add", #"{"paths":[":/"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("Pathspec magic"), result.outputJSON)
    }

    // MARK: - A pathspec that is broad but legal

    func testGitAddDot_doesNotStageAHiddenLocation() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let result = await call("git_add", #"{"paths":["."]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        let staged = try git(["diff", "--cached", "--name-only"])
        XCTAssertFalse(staged.contains("a4c36525"), staged)
        XCTAssertFalse(staged.contains("id_ed25519"), staged)
    }

    /// Asserts the INDEX, not the envelope: the report said `src/a.txt` while git had staged
    /// nothing, because an `:(exclude)` beside a named UNTRACKED file makes `git add` a silent
    /// no-op on git 2.54 (measured). The excludes now ride only expanding positives.
    func testGitAdd_ofANamedUntrackedFile_actuallyStagesIt() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        let result = await call("git_add", #"{"paths":["src/a.txt"]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("src/a.txt"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("exclude"), "the tool's own rule is not output")
        XCTAssertTrue(
            try git(["diff", "--cached", "--name-only"]).contains("src/a.txt"),
            "the file the caller named must be in the index")
    }

    /// A DIRECTORY positive expands, so it carries the excludes — and still stages what is under
    /// it, which is the combination git serves correctly.
    func testGitAdd_ofADirectory_stagesItsFilesAndSkipsHiddenOnes() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        try write("y", "src/nested/b.txt")
        let result = await call("git_add", #"{"paths":["src"]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        let staged = try git(["diff", "--cached", "--name-only"])
        XCTAssertTrue(staged.contains("src/a.txt"), staged)
        XCTAssertTrue(staged.contains("src/nested/b.txt"), staged)
        XCTAssertFalse(staged.contains("nanoteams"), staged)
    }

    // MARK: - No pathspec at all

    /// A TRACKED token file, rewritten by a reissue: a plain `git_diff` printed both bearers.
    func testGitDiff_withNoPaths_doesNotPrintATrackedTokenFile() async throws {
        try makeRepoAtHome(tokenTracked: true)
        try write("ntm_a4c36525_ROTATED\n", ".config/nanoteams/a4c36525.token")
        try write("# notes, edited", "README.md")
        let result = await call("git_diff", "{}")
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("ntm_a4c36525"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("README.md"), result.outputJSON)
    }

    func testGitStatus_doesNotNameAHiddenLocation() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("# notes, edited", "README.md")
        let result = await call("git_status", "{}")
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("README.md"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("nanoteams/a4c36525"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains(".ssh"), result.outputJSON)
    }

    func testGitDiff_untrackedProbe_doesNotNameAHiddenLocation() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let result = await call("git_diff", "{}")
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("a4c36525"), result.outputJSON)
    }

    /// `git stash push` with no pathspec reaches the whole repository, so it would revert the
    /// token file NanoTeams maintains — and `pop` is not guaranteed.
    func testGitStashPush_leavesAHiddenLocationAlone() async throws {
        try makeRepoAtHome(tokenTracked: true)
        try write("ntm_a4c36525_ROTATED\n", ".config/nanoteams/a4c36525.token")
        try write("# notes, edited", "README.md")
        let result = await call("git_stash", #"{"action":"push"}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        let token = try String(
            contentsOf: work.appendingPathComponent(".config/nanoteams/a4c36525.token"), encoding: .utf8)
        XCTAssertTrue(token.contains("ROTATED"), "the token file must survive a stash: \(token)")
        XCTAssertFalse(
            try String(contentsOf: work.appendingPathComponent("README.md"), encoding: .utf8)
                .contains("edited"),
            "the project's own change is stashed as asked")
    }

    // MARK: - No repository at all

    /// Scoping every read to `.` must not change how a folder with no repository answers.
    func testGitReads_inAFolderWithNoRepository_sayNotARepository() async throws {
        let plain = base.appendingPathComponent("plain", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try write("x", "a.txt", under: plain)
        try makeRuntime(workFolderRoot: plain)
        for (tool, json) in [("git_status", "{}"), ("git_diff", "{}"), ("git_log", "{}")] {
            let result = await call(tool, json)
            XCTAssertTrue(result.isError, "\(tool): \(result.outputJSON)")
            XCTAssertTrue(
                result.outputJSON.lowercased().contains("repositor"), "\(tool): \(result.outputJSON)")
        }
    }

    /// `hasNoRepository` asks git instead of matching a message, so it has to answer for the
    /// case where git cannot run at all — here a working directory that does not exist. "No
    /// repository" would be the wrong answer: it would make every git tool report the one
    /// sentence that is certainly not the problem, and hide the real one.
    ///
    /// RED: `return true` from the `try?` arm → this fails, and a missing work folder starts
    /// reporting itself as "not a git repository".
    func testHasNoRepository_whereGitCannotEvenRun_doesNotClaimThereIsNoRepository() throws {
        let gone = base.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: gone.path), "arrange: the folder must not exist")

        XCTAssertFalse(GitErrorClassifier.hasNoRepository(in: gone))

        // Control: the predicate does say so when git answers that it is not a repository.
        let plain = base.appendingPathComponent("plain-probe", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertTrue(GitErrorClassifier.hasNoRepository(in: plain))
    }

    // MARK: - git's own failure reason survives

    /// `git_diff`'s non-not-a-repository failure arm: git's first line is the fact the model can
    /// act on. Induced with a corrupt `.git/config`, which `git diff` refuses to parse.
    func testGitDiff_aBrokenRepository_reportsGitsOwnReason() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let config = work.appendingPathComponent(".git/config")
        try (String(contentsOf: config, encoding: .utf8) + "[core\nbogus\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let result = await call("git_diff", "{}")
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), result.outputJSON)
        XCTAssertTrue(
            result.outputJSON.lowercased().contains("config"),
            "git's own reason must survive: \(result.outputJSON)")
    }

    /// `git_diff` runs the untracked-files probe beside the diff, and the probe is a SECOND git
    /// invocation that can fail on its own. It must then say so: an empty `untracked_files` list
    /// reads as "there are no new files", which is the one thing the field exists to deny.
    ///
    /// Induced with `core.excludesFile` pointing at a directory — measured on git 2.54, that
    /// fails `ls-files --exclude-standard` (exit 128) while leaving `git diff` untouched, so the
    /// envelope is a SUCCESS carrying the probe's warning. Nothing else reaches this arm: every
    /// other failure takes the diff down with it.
    ///
    /// RED: return `([], [])` from the probe's non-zero arm → the warning is gone and a silent
    /// empty list ships under `ok:true`.
    func testGitDiff_whenOnlyTheUntrackedProbeFails_saysSoInsteadOfReportingNoNewFiles() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("tracked change", "README.md")
        try write("brand new", "src/new.txt")
        let excludes = work.appendingPathComponent("excludes-as-a-folder", isDirectory: true)
        try fm.createDirectory(at: excludes, withIntermediateDirectories: true)
        try git(["config", "core.excludesFile", excludes.path])

        let result = await call("git_diff", "{}")

        XCTAssertFalse(result.isError, "the diff itself is fine: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("untracked_files probe failed"),
                      "the probe's own failure must be stated: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("src/new.txt"),
                       "a probe that failed knows of no files: \(result.outputJSON)")
    }

    // MARK: - Wildcards

    /// A wildcard cannot be served beside the `:(exclude)` list every call carries: measured on
    /// git 2.54, a wildcard positive next to ANY exclude stages NOTHING and exits 0. Refused,
    /// with the repair named — a silent no-op under `ok:true` is the worse answer.
    func testAWildcardPathspec_isRefusedWithTheRepairNamed() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        for pattern in ["src/*.txt", "*", "src/?.txt", "src/[ab].txt", "../*", "/etc/*"] {
            let result = await call("git_add", "{\"paths\":[\"\(pattern)\"]}")
            XCTAssertTrue(result.isError, "\(pattern): \(result.outputJSON)")
            XCTAssertEqual(
                try git(["diff", "--cached", "--name-only"]), "",
                "\(pattern) staged something")
        }
        let wildcard = await call("git_add", #"{"paths":["src/*.txt"]}"#)
        XCTAssertTrue(wildcard.outputJSON.contains("patterns are not accepted"), wildcard.outputJSON)
        // ...and the named file works.
        let named = await call("git_add", #"{"paths":["src/a.txt"]}"#)
        XCTAssertFalse(named.isError, named.outputJSON)
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"]).contains("src/a.txt"))
    }

    // MARK: - The expansion's own failures

    /// The expansion queries are git too: when THEY fail for a reason that is not "no
    /// repository" — a broken `.git/config` — the model gets git's own first line, not an empty
    /// stage reported as success.
    func testGitAdd_whenTheExpansionQueryFails_reportsGitsReason() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        let config = work.appendingPathComponent(".git/config")
        try (String(contentsOf: config, encoding: .utf8) + "[core\nbogus\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let result = await call("git_add", #"{"paths":["src/a.txt"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), result.outputJSON)
        XCTAssertTrue(result.outputJSON.lowercased().contains("config"), result.outputJSON)
    }

    /// And when the staging itself fails after a clean expansion — an index git cannot write —
    /// the reason is git's, not a success with an empty list.
    func testGitAdd_whenStagingFails_reportsGitsReason() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        let gitDir = work.appendingPathComponent(".git")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: gitDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gitDir.path) }
        let result = await call("git_add", #"{"paths":["src/a.txt"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("\"staged\""), result.outputJSON)
    }

    // MARK: - A work folder that IS a credential store

    /// `~/.claude` (or `~/.ssh`) opened as a project: the file tools refuse every path in it, so
    /// the git tools must too — and the dangerous call is the one with NO paths, where
    /// `git_diff` would print the content of every change in it.
    func testEveryGitTool_refusesAWorkFolderThatIsAStore() async throws {
        try write("TOKEN_CONTENT", "mcp-servers.json", under: home.appendingPathComponent(".claude"))
        try write("SETTINGS_CONTENT", "settings.json", under: home.appendingPathComponent(".claude"))
        let client = home.appendingPathComponent(".claude", isDirectory: true)
        try git(["init", "-q", "-b", "main"], in: client)
        try git(["add", "-A"], in: client)
        try git(["commit", "-qm", "init"], in: client)
        try "SETTINGS_CHANGED".write(
            to: client.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try makeRuntime(workFolderRoot: client)

        for (tool, json) in [
            ("git_status", "{}"), ("git_diff", "{}"), ("git_log", "{}"),
            ("git_add", #"{"paths":["."]}"#), ("git_stash", #"{"action":"push"}"#),
        ] {
            let result = await call(tool, json)
            XCTAssertTrue(result.isError, "\(tool) must refuse: \(result.outputJSON)")
            XCTAssertTrue(result.outputJSON.contains("credential store"), "\(tool): \(result.outputJSON)")
            XCTAssertFalse(result.outputJSON.contains("SETTINGS_CHANGED"), "\(tool): \(result.outputJSON)")
        }
    }

    // MARK: - Operands that git would read as OPTIONS

    /// `git pull '--upload-pack=sh -c …' .` runs that text in the app's own process tree,
    /// OUTSIDE Seatbelt, with the person's full rights — measured on git 2.54. Every operand a
    /// caller supplies is refused when it begins with `-` (#382).
    func testGitOperands_beginningWithADash_areRefusedBeforeGitRuns() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let witness = base.appendingPathComponent("PWNED")
        let exec = "--upload-pack=touch \(witness.path)"
        let calls: [(String, String)] = [
            ("git_pull", "{\"remote\":\"\(exec)\",\"branch\":\".\"}"),
            ("git_checkout", "{\"branch\":\"--orphan\"}"),
            ("git_merge", "{\"branch\":\"--no-verify\"}"),
            ("git_branch", "{\"action\":\"create\",\"name\":\"--force\"}"),
        ]
        for (tool, json) in calls {
            let result = await call(tool, json)
            XCTAssertTrue(result.isError, "\(tool): \(result.outputJSON)")
            XCTAssertTrue(result.outputJSON.contains("INVALID_ARGS"), "\(tool): \(result.outputJSON)")
            XCTAssertTrue(
                result.outputJSON.contains("may not begin with"), "\(tool): \(result.outputJSON)")
        }
        XCTAssertFalse(
            fm.fileExists(atPath: witness.path),
            "no operand may reach git as an option — it executes commands")
    }

    // MARK: - The repository's own control directory

    /// `.git/config` configures a client worse than an external one: `core.fsmonitor` is a shell
    /// command git runs on the very next `git status`, in this process, outside Seatbelt
    /// (measured). Readable, never writable by a tool (#382).
    func testTheGitDirectory_isReadableButNotWritable() async throws {
        try makeRepoAtHome(tokenTracked: false)
        let read = await call("read_file", #"{"path":".git/config"}"#)
        XCTAssertFalse(read.isError, "reading the repository's configuration stays allowed: \(read.outputJSON)")

        for (tool, json) in [
            ("write_file", #"{"path":".git/config","content":"[core] fsmonitor = x"}"#),
            ("write_file", #"{"path":".git/hooks/pre-commit","content":"touch /tmp/x"}"#),
            ("delete_file", #"{"path":".git/config"}"#),
        ] {
            let result = await call(tool, json)
            XCTAssertTrue(result.isError, "\(tool) \(json): \(result.outputJSON)")
            XCTAssertTrue(
                result.outputJSON.contains("Nothing inside .git"), "\(tool): \(result.outputJSON)")
        }
        XCTAssertFalse(
            try String(contentsOf: work.appendingPathComponent(".git/config"), encoding: .utf8)
                .contains("fsmonitor"))
    }

    // MARK: - A blank path is not a path

    func testGitAdd_withABlankPath_isRefusedRatherThanStagingEverything() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("x", "src/a.txt")
        for blank in ["", "   "] {
            let result = await call("git_add", "{\"paths\":[\"\(blank)\"]}")
            XCTAssertTrue(result.isError, "\(result.outputJSON)")
            XCTAssertTrue(result.outputJSON.contains("empty path"), result.outputJSON)
        }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
    }

    // MARK: - A file name that holds a bracket

    /// `app/[id]/page.tsx` is a FILE, not a pattern — it staged before this round and must stage
    /// now: every pathspec goes to git as `:(literal)` (#382).
    func testGitAdd_aBracketFileName_stagesAsALiteralPath() async throws {
        try makeRepoAtHome(tokenTracked: false)
        try write("page", "app/[id]/page.tsx")
        let result = await call("git_add", #"{"paths":["app/[id]/page.tsx"]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"]).contains("app/[id]/page.tsx"))
    }

    // MARK: - A directory positive stages what is under it

    /// With `:(exclude)` beside a directory positive, `git add` stages NOTHING for some
    /// directory names and everything for others (measured, git 2.54). `git_add` therefore
    /// expands the positives itself and stages explicit files — so `staged` is what git did.
    func testGitAdd_ofNestedDirectories_stagesEveryFileAndReportsThem() async throws {
        try makeRepoAtHome(tokenTracked: false)
        for path in ["a/b/c/d.txt", "a/b/e.txt", "a/f.txt"] { try write("x", path) }
        let result = await call("git_add", #"{"paths":["a/b/c"]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("a/b/c/d.txt"), result.outputJSON)
        let staged = try git(["diff", "--cached", "--name-only"])
        XCTAssertEqual(staged.trimmingCharacters(in: .whitespacesAndNewlines), "a/b/c/d.txt", staged)
    }

    /// Nothing to stage is said, not reported as a success that staged something.
    func testGitAdd_withNothingToStage_saysSo() async throws {
        try makeRepoAtHome(tokenTracked: true)
        let result = await call("git_add", #"{"paths":["."]}"#)
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("Nothing to stage"), result.outputJSON)
    }

    // MARK: - A repository that ENCLOSES the work folder

    /// The work folder is a subdirectory of a repository: a repo-wide diff reported files the
    /// resolver refuses outright, because they are outside the work folder.
    func testGitDiff_inASubdirectoryOfARepository_staysInsideTheWorkFolder() async throws {
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try write("outside secret", "secrets.txt", under: repo)
        try write("inside", "project/README.md", under: repo)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-qm", "init"], in: repo)
        try write("outside secret CHANGED", "secrets.txt", under: repo)
        try write("inside CHANGED", "project/README.md", under: repo)

        try makeRuntime(workFolderRoot: repo.appendingPathComponent("project", isDirectory: true))
        let result = await call("git_diff", "{}")
        XCTAssertFalse(result.isError, result.outputJSON)
        XCTAssertTrue(result.outputJSON.contains("README.md"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("secrets.txt"), result.outputJSON)
        XCTAssertFalse(result.outputJSON.contains("outside secret"), result.outputJSON)
    }

    /// A `..` pathspec left the work folder entirely — `relativizePathspec` passed it through.
    func testGitAdd_withAParentTraversalPathspec_isRefused() async throws {
        let repo = base.appendingPathComponent("repo2", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try write("outside secret", "secrets.txt", under: repo)
        try write("inside", "project/README.md", under: repo)
        try git(["init", "-q", "-b", "main"], in: repo)

        try makeRuntime(workFolderRoot: repo.appendingPathComponent("project", isDirectory: true))
        let result = await call("git_add", #"{"paths":["../secrets.txt"]}"#)
        XCTAssertTrue(result.isError, result.outputJSON)
        XCTAssertFalse(
            try git(["diff", "--cached", "--name-only"], in: repo).contains("secrets.txt"))
    }
}
