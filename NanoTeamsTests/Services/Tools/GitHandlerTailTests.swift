import XCTest

@testable import NanoTeams

/// The git-handler arms `ToolsGitTests` and `ToolsGitPullMergeTests` never reach.
///
/// Coverage context (measured 2026-08-07): `GitWriteHandlers.swift` 66 uncovered
/// lines, `GitReadHandlers.swift` 51. What the existing suites cover is the happy
/// path of each tool; what they miss is every *failure* arm (`guard result.success
/// else`), every non-default argument branch (`git_log oneline:false`, `git_stash
/// apply/drop/index`, `git_commit amend`, `git_diff max_lines`), and every
/// degenerate repository state (unborn HEAD, detached HEAD, mid-merge conflict).
///
/// Harness copied verbatim in shape from `ToolsGitPullMergeTests`: a REAL temp git
/// repo driven end-to-end through `ToolRuntime.executeAll`, because these tools
/// shell out to `/usr/bin/git` and the thing under test is how their porcelain
/// output is parsed. `.standardizedFileURL` everywhere — `/var` → `/private/var`
/// otherwise breaks `SandboxPathResolver` containment. Anything needing a remote
/// uses a LOCAL BARE REPO as `origin`, so no network is involved.
///
/// Every git behaviour asserted here was measured against the installed git
/// (2.50.1, Apple Git-155) before the assertion was written, not recalled.
final class GitHandlerTailTests: XCTestCase {
    private var tempDir: URL!
    private var remoteDir: URL!
    private var scratchDirs: [URL]!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchDirs = []
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try FileManager.default.createDirectory(
            at: paths.nanoteamsDir, withIntermediateDirectories: true)

        try initRepo(at: tempDir)
        try seedCommit(named: "base.txt", contents: "base\n", message: "base")

        let (_, run) = ToolRegistry.defaultRegistry(
            workFolderRoot: tempDir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        runtime = run
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        if let remoteDir { try? FileManager.default.removeItem(at: remoteDir) }
        for dir in scratchDirs ?? [] { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        remoteDir = nil
        scratchDirs = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - git_add failure + degenerate arms

    /// The `guard result.success else` arm that is NOT the not-a-repo case.
    /// `git add nosuch.txt` exits 128 with `fatal: pathspec … did not match any
    /// files` on stderr, and the handler must pass that reason through — a bare
    /// "git add failed" leaves the model with nothing to correct.
    func testGitAdd_nonexistentPathspec_reportsGitsReasonAndStagesNothing() throws {
        let result = try call(ToolNames.gitAdd, ["paths": ["nosuch.txt"]])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("did not match any files"),
                      "the model needs git's reason, not a generic failure: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("\"staged\""),
                       "a failed add must not report a staged list: \(result.outputJSON)")
    }

    /// Security-adjacent: `relativizePathspec` deliberately returns an
    /// out-of-sandbox path UNCHANGED (it can't resolve it), so the last line of
    /// defence is git itself refusing a pathspec outside the repository. Pinning
    /// the OBSERVABLE consequence — nothing outside the work folder ends up in the
    /// index — rather than the message, so a future move of the rejection into the
    /// resolver keeps this test green.
    func testGitAdd_pathOutsideTheWorkFolder_isRejectedAndTheIndexStaysEmpty() throws {
        let result = try call(ToolNames.gitAdd, ["paths": ["/etc/passwd"]])

        XCTAssertTrue(result.isError,
                      "staging a path outside the work folder must fail: \(result.outputJSON)")
        let staged = try git(["diff", "--cached", "--name-only"], in: tempDir)
        XCTAssertTrue(staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "nothing may be staged, got: \(staged)")
    }

    /// `coerceStringArray` keeps an explicitly empty list empty (rather than
    /// collapsing it to nil), so argv becomes a bare `git add` — which exits 0 with
    /// "Nothing specified, nothing added.". The envelope must at least be HONEST
    /// about having staged nothing; asserted on the raw JSON rather than through
    /// `dataOf` so this stays green if the empty list is later rejected outright.
    /// See `suspectedDefects`: reporting ok:true for a no-op is the same shape as
    /// the `git_pull data.success:false` regression fixed 2026-08-07.
    func testGitAdd_emptyPathsArray_neverClaimsToHaveStagedAnything() throws {
        try Data("x\n".utf8).write(to: tempDir.appendingPathComponent("unstaged.txt"))

        let result = try call(ToolNames.gitAdd, ["paths": [String]()])

        XCTAssertFalse(result.outputJSON.contains("unstaged.txt"),
                       "an empty pathspec list must not name any file: \(result.outputJSON)")
        let staged = try git(["diff", "--cached", "--name-only"], in: tempDir)
        XCTAssertTrue(staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "nothing may be staged, got: \(staged)")
    }

    // MARK: - git_commit

    /// The `amend: true` branch appends `--amend` to argv. A dropped flag fails
    /// SILENTLY — the commit still succeeds, it just adds a commit instead of
    /// rewriting one — so the assertion is on the resulting history shape.
    func testGitCommit_amend_rewritesTheTipInsteadOfAddingACommit() throws {
        try Data("more\n".utf8).write(to: tempDir.appendingPathComponent("extra.txt"))
        try git(["add", "."], in: tempDir)

        let data = try dataOf(ToolNames.gitCommit, ["message": "amended", "amend": true])

        XCTAssertEqual(data["message"] as? String, "amended")
        let log = try git(["log", "--oneline"], in: tempDir)
        let lines = log.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "--amend must not add a second commit; got: \(log)")
        XCTAssertTrue(log.contains("amended"), "got: \(log)")
        XCTAssertFalse(log.contains("base"), "the amended subject must replace the old one: \(log)")
    }

    /// The post-commit `rev-parse HEAD` lookup. The hash is the only handle the
    /// model gets on the commit it just made (for a later `git_diff`/revert), so a
    /// stale or empty one is worse than useless.
    func testGitCommit_reportsTheRealHeadHash() throws {
        try Data("c\n".utf8).write(to: tempDir.appendingPathComponent("committed.txt"))
        try git(["add", "."], in: tempDir)

        let data = try dataOf(ToolNames.gitCommit, ["message": "second"])

        let head = try git(["rev-parse", "HEAD"], in: tempDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(data["hash"] as? String, head)
        // Anti-vacuity: without this the assertion above would also pass if BOTH
        // sides were empty (which is what a failed `rev-parse` produces). Length is
        // deliberately not pinned to 40 — a machine set to sha256 emits 64.
        XCTAssertFalse(head.isEmpty, "rev-parse must have produced a SHA")
    }

    /// Unborn HEAD: a repo with no commits at all. git prints "nothing to commit"
    /// on **stdout** (exit 1), which is exactly why the handler classifies over
    /// `stderr + stdout` — a stderr-only check would misroute this to
    /// COMMAND_FAILED with an empty message.
    func testGitCommit_unbornRepoWithNothingStaged_isClassifiedAsNothingToCommit() throws {
        let scratch = try makeScratchRepo(initializeGit: true)

        let result = try call(
            ToolNames.gitCommit, ["message": "first"],
            runtime: scratch.runtime, context: scratch.context)

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("CONFLICT"), "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("Nothing to commit"), "got: \(result.outputJSON)")
    }

    /// Sibling of the case above with ONE difference: an untracked file exists, so
    /// git says "nothing added to commit but untracked files present" instead of
    /// "nothing to commit". That is the SAME failure class and must carry the same
    /// code — it used to fall through to COMMAND_FAILED, and `ToolErrorNotePolicy.direction`
    /// routes the two codes differently.
    ///
    /// The message must still name the remedy: reclassifying alone would have
    /// replaced git's "use git add" hint with a bare "Nothing to commit".
    func testGitCommit_untrackedOnly_isTheSameFailureClassAndKeepsTheRemedy() throws {
        try Data("u\n".utf8).write(to: tempDir.appendingPathComponent("untracked.txt"))

        let result = try call(ToolNames.gitCommit, ["message": "nope"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        let error = try errorOf(result)
        XCTAssertEqual(error["code"] as? String, "CONFLICT",
                       "untracked-only is the same class as a clean tree: \(result.outputJSON)")
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertTrue(message.contains("git_add"),
                      "the model must be told to stage first: \(message)")
    }

    // MARK: - git_pull

    /// The whole conflict branch — detection over `stdout + stderr`, plus the
    /// `range(of: "in ")` extraction that turns
    /// `CONFLICT (content): Merge conflict in base.txt` into a filename. That
    /// extraction is the only place the model learns WHICH file to fix; a parse
    /// slip yields an empty `details.conflicts` under a correct-looking envelope.
    ///
    /// `pull.rebase` is pinned in the fixture: without it git ≥ 2.34 refuses a
    /// divergent pull outright ("Need to specify how to reconcile"), so the
    /// conflict arm would be unreachable and the test would silently measure a
    /// different failure.
    func testGitPull_conflictingRemote_returnsConflictEnvelopeNamingTheFile() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)
        try pushConflictingCommitFromASecondClone()
        try Data("local side\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        try git(["commit", "-am", "local edit"], in: tempDir)

        let result = try call(ToolNames.gitPull, ["remote": "origin", "branch": "main"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        let error = try errorOf(result)
        XCTAssertEqual(error["code"] as? String, "CONFLICT")
        XCTAssertEqual(error["message"] as? String, "Merge conflicts detected")
        let details = try XCTUnwrap(error["details"] as? [String: Any],
                                    "conflict envelope must carry details: \(result.outputJSON)")
        let conflicts = try XCTUnwrap(details["conflicts"] as? String)
        XCTAssertEqual(conflicts, "base.txt",
                       "the conflicting file must be extracted from git's CONFLICT line")
    }

    /// No arguments at all: `remote` falls back to "origin" and `branch` stays nil,
    /// so argv is a bare `git pull origin` relying on the tracking branch. Both
    /// defaults are load-bearing — the model routinely calls `git_pull {}`.
    func testGitPull_withNoArguments_usesOriginAndTheTrackingBranch() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)
        try pushExtraCommitFromASecondClone()

        let data = try dataOf(ToolNames.gitPull, [:])

        XCTAssertEqual(data["success"] as? Bool, true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("from-remote.txt").path),
            "the fast-forwarded commit's file must be in the working tree")
    }

    /// THE reproducer, transcribed from `git_merge`'s
    /// (`GitBranchingHandlerTailTests.testMerge_fileNamedCONFLICT_isNotMisreadAsAConflict`,
    /// 2026-08-08). The defect was identical and the fix was never swept across — which is
    /// the whole reason this test exists in a second file rather than being folded into the
    /// first.
    ///
    /// It is if anything easier to hit here. `git pull` prints a DIFFSTAT — one line per
    /// file the fast-forward touched — so any incoming commit adding a path containing
    /// `CONFLICT` puts that word into the handler's input, no matter what the local side is
    /// called. The probe ran above `guard result.success`, so a clean fast-forward returned
    /// `{"ok":false,"error":{"code":"CONFLICT"}}`, and with an EMPTY `details.conflicts` at
    /// that: `range(of: "in ")` finds nothing in a diffstat row, so the model was told to
    /// resolve conflicts and not told in which file. In a tree that had merged cleanly.
    ///
    /// A repo documenting its own merge policy is the ordinary way to own such a file.
    ///
    /// RED: move the conflict probe back above `guard result.success` → this fails with
    /// `CONFLICT`.
    func testGitPull_fastForwardOfAFileNamedCONFLICT_isNotMisreadAsAConflict() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)
        try inASecondClone { clone in
            try Data("how we handle merge conflicts\n".utf8)
                .write(to: clone.appendingPathComponent("CONFLICT.md"))
            try git(["add", "."], in: clone)
            try git(["commit", "-m", "document the policy"], in: clone)
        }

        let result = try call(ToolNames.gitPull, ["remote": "origin", "branch": "main"])

        XCTAssertFalse(result.isError,
                       "a clean fast-forward is not a conflict: \(result.outputJSON)")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("CONFLICT.md").path),
            "precondition: the pull must actually have brought the file down, or this test "
                + "passes without exercising the diffstat at all")
        // Stronger anti-vacuity than the line above, which proves the pull ran and not that
        // the marker word reached the handler. `merge.stat` is pinned in `initRepo` for the
        // same reason; this asserts the consequence rather than trusting the setting.
        XCTAssertTrue(result.outputJSON.contains("CONFLICT"),
                      "the diffstat must actually carry the marker word: \(result.outputJSON)")
    }

    /// The mirror of the test above, and the reason the exit status alone is not enough
    /// either. With `merge.autoStash` set, git completes the merge, conflicts applying the
    /// stash, writes conflict markers into the working tree — and exits **0**. Measured on
    /// git 2.50.1: `Applying autostash resulted in conflicts.`, exit 0, `UU f.txt`.
    ///
    /// Reporting `ok: true` there is worse than the false CONFLICT it replaced: the model
    /// proceeds to build or edit a file whose contents are `<<<<<<< Updated upstream`, and
    /// the errors that follow have no explanation anywhere in the tool log.
    ///
    /// RED: delete the `ls-files -u` check in `git_pull`'s success path → `isError` is
    /// false and the envelope reports `conflicts: []` over a conflicted index.
    func testGitPull_autostashPopConflict_isReportedEvenThoughGitExitedZero() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)
        try git(["config", "merge.autoStash", "true"], in: tempDir)
        try inASecondClone { clone in
            try Data("upstream\n".utf8).write(to: clone.appendingPathComponent("base.txt"))
            try git(["commit", "-am", "upstream edit"], in: clone)
        }
        // A local, uncommitted edit to the SAME file — what autostash exists to carry.
        try Data("local\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))

        let result = try call(ToolNames.gitPull, ["remote": "origin", "branch": "main"])

        XCTAssertTrue(
            result.isError,
            "git exits 0 here; the index is the authoritative signal: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("base.txt"),
                      "and the conflicted path must be named: \(result.outputJSON)")
    }

    // MARK: - git_stash

    /// `push` with BOTH optional modifiers (`-u` and `-m`), then `list`, then
    /// `pop`. `include_untracked` is the one that fails silently if dropped: the
    /// tracked change is stashed either way and only the untracked file betrays it.
    func testGitStash_pushWithMessageAndUntracked_thenPopRestoresBoth() throws {
        try Data("modified\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        let untracked = tempDir.appendingPathComponent("brand-new.txt")
        try Data("new\n".utf8).write(to: untracked)

        let pushed = try dataOf(
            ToolNames.gitStash,
            ["action": "push", "message": "wip stash", "include_untracked": true])
        XCTAssertEqual(pushed["action"] as? String, "push")
        XCTAssertEqual(try contents(of: "base.txt"), "base\n",
                       "the tracked change must be stashed away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path),
                       "include_untracked:true must stash the untracked file too")

        let listed = try dataOf(ToolNames.gitStash, ["action": "list"])
        XCTAssertTrue((listed["output"] as? String ?? "").contains("wip stash"),
                      "the stash message must round-trip: \(listed)")

        let popped = try dataOf(ToolNames.gitStash, ["action": "pop"])
        XCTAssertEqual(popped["action"] as? String, "pop")
        XCTAssertEqual(try contents(of: "base.txt"), "modified\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path),
                      "pop must restore the untracked file")
    }

    /// The `apply` and `drop` argv branches, both carrying an explicit `index`
    /// formatted as `stash@{N}`.
    func testGitStash_applyThenDropByIndex_leavesNoStashEntries() throws {
        try Data("modified\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        try git(["stash", "push", "-m", "entry"], in: tempDir)

        let applied = try dataOf(ToolNames.gitStash, ["action": "apply", "index": 0])
        XCTAssertEqual(applied["action"] as? String, "apply")
        XCTAssertEqual(try contents(of: "base.txt"), "modified\n",
                       "apply must restore the working-tree change")

        let dropped = try dataOf(ToolNames.gitStash, ["action": "drop", "index": 0])
        XCTAssertEqual(dropped["action"] as? String, "drop")

        let listed = try dataOf(ToolNames.gitStash, ["action": "list"])
        XCTAssertEqual(listed["output"] as? String, "",
                       "apply+drop must leave the stash empty: \(listed)")
    }

    /// `git_stash`'s failure arm passes `result.stderr` through verbatim — so this
    /// also pins that git puts "No stash entries found." on STDERR. If it ever
    /// moved to stdout the model would get an error envelope with an empty message
    /// and nothing to act on.
    func testGitStash_popWithNoEntries_returnsCommandFailedWithANonEmptyReason() throws {
        let result = try call(ToolNames.gitStash, ["action": "pop"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        let error = try errorOf(result)
        XCTAssertEqual(error["code"] as? String, "COMMAND_FAILED")
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty error message leaves the model nothing to act on")
        XCTAssertTrue(message.contains("No stash entries"), "got: \(message)")
    }

    /// Proves `index` is actually formatted into `stash@{N}` and reaches git, by
    /// DIFFERENTIAL rather than by scraping the message: the fixture holds exactly
    /// one entry, so a dropped argument would make both calls pop `stash@{0}` and
    /// both would succeed. `9` failing and `0` then succeeding is only possible if
    /// the index rides through.
    ///
    /// Deliberately NOT asserting the rejected ref appears in the message — git's
    /// own text is "log for 'stash' only has 1 entries", and `git_stash` passes
    /// stderr through verbatim (pinned above). Echoing the ref would be a new
    /// policy for one action, and the range git reports is the actionable part.
    func testGitStash_index_isFormattedIntoTheStashRef() throws {
        try Data("modified\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        try git(["stash", "push", "-m", "entry"], in: tempDir)

        let outOfRange = try call(ToolNames.gitStash, ["action": "pop", "index": 9])
        XCTAssertTrue(outOfRange.isError, "got: \(outOfRange.outputJSON)")
        let error = try errorOf(outOfRange)
        XCTAssertEqual(error["code"] as? String, "COMMAND_FAILED")
        let message = try XCTUnwrap(error["message"] as? String)
        XCTAssertFalse(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "an empty error message leaves the model nothing to act on")

        let inRange = try call(ToolNames.gitStash, ["action": "pop", "index": 0])
        XCTAssertFalse(inRange.isError,
                       "index 0 addresses the single entry: \(inRange.outputJSON)")
    }

    /// The `default:` arm of the action switch. The message must enumerate the
    /// valid actions — a bare "invalid action" sends a small model guessing.
    func testGitStash_unknownAction_isInvalidArgsAndListsTheValidActions() throws {
        let result = try call(ToolNames.gitStash, ["action": "squash"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        let error = try errorOf(result)
        XCTAssertEqual(error["code"] as? String, "INVALID_ARGS")
        let message = try XCTUnwrap(error["message"] as? String)
        for action in ["push", "pop", "apply", "list", "drop"] {
            XCTAssertTrue(message.contains(action), "must list '\(action)': \(message)")
        }
    }

    // MARK: - git_status parsing

    /// The `...` branch of the branch-line parser. With an upstream configured the
    /// porcelain header is `## main...origin/main`, and the tool must report the
    /// bare local name — `main...origin/main` is not a branch anyone can check out.
    func testGitStatus_withUpstream_reportsTheBareLocalBranchName() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)

        let data = try dataOf(ToolNames.gitStatus, [:])

        XCTAssertEqual(data["branch"] as? String, "main",
                       "the upstream suffix must be stripped: \(data)")
    }

    /// The status-code composition block, which is pure string surgery over
    /// porcelain v1 columns. Three shapes at once so an off-by-one in either
    /// column index is caught: `A  ` (index only), ` D ` (worktree only), `MM `
    /// (both).
    func testGitStatus_stagedAddedDeletedAndBothModified_reportEachCodeAndPath() throws {
        try Data("v1\n".utf8).write(to: tempDir.appendingPathComponent("keep.txt"))
        try Data("d\n".utf8).write(to: tempDir.appendingPathComponent("del.txt"))
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", "tracked files"], in: tempDir)

        try Data("added\n".utf8).write(to: tempDir.appendingPathComponent("added.txt"))
        try git(["add", "added.txt"], in: tempDir)
        try Data("v2\n".utf8).write(to: tempDir.appendingPathComponent("keep.txt"))
        try git(["add", "keep.txt"], in: tempDir)
        try Data("v3\n".utf8).write(to: tempDir.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("del.txt"))

        let data = try dataOf(ToolNames.gitStatus, [:])

        XCTAssertEqual(data["clean"] as? Bool, false)
        let byPath = try statusesByPath(data)
        XCTAssertEqual(byPath["added.txt"], "A", "staged-add is an index-column code: \(byPath)")
        XCTAssertEqual(byPath["del.txt"], "D", "unstaged delete is a worktree-column code: \(byPath)")
        XCTAssertEqual(byPath["keep.txt"], "MM", "both columns must be concatenated: \(byPath)")
    }

    /// Porcelain v1 reports a staged rename as `R  old.txt -> new.txt` in ONE field.
    /// Passing that through verbatim broke the house rule that every path a tool
    /// reports is usable as a `read_file`/`git_add` argument, so `path` now carries
    /// the NEW name and `old_path` the old one — both names still reach the model.
    func testGitStatus_stagedRename_splitsThePathSoBothAreUsable() throws {
        try Data("x\n".utf8).write(to: tempDir.appendingPathComponent("old.txt"))
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", "add old"], in: tempDir)
        try git(["mv", "old.txt", "new.txt"], in: tempDir)

        let data = try dataOf(ToolNames.gitStatus, [:])
        let files = try XCTUnwrap(data["files"] as? [[String: Any]], "files array missing")
        let entry = try XCTUnwrap(
            files.first(where: { ($0["status"] as? String) == "R" }),
            "the rename must appear in the file list: \(files)")

        XCTAssertEqual(entry["path"] as? String, "new.txt",
                       "`path` must be usable verbatim by read_file/git_add: \(entry)")
        XCTAssertEqual(entry["old_path"] as? String, "old.txt",
                       "the old name must survive so the model can see what moved: \(entry)")
    }

    /// Mid-merge state: after a conflicting `git merge`, porcelain reports
    /// `UU base.txt`. Both columns are `U`, so the composed code is `UU` — the one
    /// signal telling the model the tree is unmergeable rather than merely dirty.
    func testGitStatus_duringAMergeConflict_reportsTheUnmergedPath() throws {
        try git(["checkout", "-b", "feature"], in: tempDir)
        try Data("feature side\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        try git(["commit", "-am", "feature edit"], in: tempDir)
        try git(["checkout", "main"], in: tempDir)
        try Data("main side\n".utf8).write(to: tempDir.appendingPathComponent("base.txt"))
        try git(["commit", "-am", "main edit"], in: tempDir)
        _ = gitAllowingFailure(["merge", "feature"], in: tempDir)

        let data = try dataOf(ToolNames.gitStatus, [:])

        let byPath = try statusesByPath(data)
        XCTAssertEqual(byPath["base.txt"], "UU",
                       "an unmerged path must report both U columns: \(byPath)")
        XCTAssertEqual(data["clean"] as? Bool, false)
    }

    /// Unborn HEAD. `git status` still exits 0 here (unlike `git log`), so this is
    /// the success path with an empty file list. The branch string it reports for
    /// this state is called out under `suspectedDefects`; only the parts that are
    /// unambiguously right are asserted.
    func testGitStatus_unbornRepo_succeedsAndReportsClean() throws {
        let scratch = try makeScratchRepo(initializeGit: true)

        let data = try dataOf(
            ToolNames.gitStatus, [:], runtime: scratch.runtime, context: scratch.context)

        XCTAssertEqual(data["clean"] as? Bool, true)
        XCTAssertEqual((data["files"] as? [[String: Any]])?.count, 0, "got: \(data)")
    }

    // MARK: - git_branch_list

    /// `currentBranch` is only ever assigned inside the `isCurrent` branch, so a
    /// regression there reports an empty `current` while the list itself still
    /// looks right.
    func testGitBranchList_marksTheCheckedOutBranchAndReportsItAsCurrent() throws {
        try git(["branch", "sidebar"], in: tempDir)

        let data = try dataOf(ToolNames.gitBranchList, [:])

        XCTAssertEqual(data["current"] as? String, "main")
        let branches = try XCTUnwrap(data["branches"] as? [[String: Any]])
        let names = branches.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.sorted(), ["main", "sidebar"], "got: \(names)")
        let main = try XCTUnwrap(branches.first(where: { ($0["name"] as? String) == "main" }))
        XCTAssertEqual(main["current"] as? Bool, true)
        let sidebar = try XCTUnwrap(branches.first(where: { ($0["name"] as? String) == "sidebar" }))
        XCTAssertEqual(sidebar["current"] as? Bool, false)
    }

    /// The `all: true` argv branch plus the `remotes/` prefix strip. The prefix
    /// matters: `remotes/origin/main` is not a name `git_checkout` accepts, so
    /// forwarding it unstripped would hand the model an unusable ref.
    func testGitBranchList_all_stripsTheRemotesPrefixAndFlagsRemoteBranches() throws {
        try attachBareRemote()
        try git(["push", "-u", "origin", "main"], in: tempDir)

        let data = try dataOf(ToolNames.gitBranchList, ["all": true])

        let branches = try XCTUnwrap(data["branches"] as? [[String: Any]])
        let remote = try XCTUnwrap(
            branches.first(where: { ($0["name"] as? String) == "origin/main" }),
            "expected a stripped remote branch, got: \(branches)")
        XCTAssertEqual(remote["is_remote"] as? Bool, true)
        XCTAssertEqual(remote["current"] as? Bool, false)
        let leaked = branches.contains(where: {
            ($0["name"] as? String)?.hasPrefix("remotes/") == true
        })
        XCTAssertFalse(leaked, "the remotes/ prefix must be stripped: \(branches)")
        let local = try XCTUnwrap(branches.first(where: { ($0["name"] as? String) == "main" }))
        XCTAssertEqual(local["is_remote"] as? Bool, false)
    }

    /// Unborn HEAD: `git branch -v` exits 0 with EMPTY output, so the parse loop
    /// never runs. The tool must report "no branches", not fail.
    func testGitBranchList_unbornRepo_succeedsWithNoBranches() throws {
        let scratch = try makeScratchRepo(initializeGit: true)

        let data = try dataOf(
            ToolNames.gitBranchList, [:], runtime: scratch.runtime, context: scratch.context)

        XCTAssertEqual((data["branches"] as? [[String: Any]])?.count, 0, "got: \(data)")
        XCTAssertEqual(data["current"] as? String, "")
    }

    /// Detached HEAD. `git branch -v` emits `* (HEAD detached at <sha>)`, which the
    /// space-split parser mangles — see `suspectedDefects`. Asserted here: the tool
    /// still succeeds, and the detachment is at least VISIBLE in the payload, which
    /// is true both today and after any reasonable fix.
    func testGitBranchList_detachedHead_succeedsAndTheDetachmentIsVisible() throws {
        let head = try git(["rev-parse", "HEAD"], in: tempDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", head], in: tempDir)

        let result = try call(ToolNames.gitBranchList, [:])

        XCTAssertFalse(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("HEAD"),
                      "a detached HEAD must be discernible from the payload: \(result.outputJSON)")
    }

    // MARK: - git_log

    /// The `oneline: false` argv branch AND the whole `|`-delimited parse that only
    /// runs with it. This is the only way the model gets author/date, and every
    /// field comes from a different split index — so all four are asserted.
    func testGitLog_notOneline_parsesHashMessageAuthorAndDate() throws {
        let data = try dataOf(ToolNames.gitLog, ["oneline": false])

        let commits = try XCTUnwrap(data["commits"] as? [[String: Any]])
        let head = try XCTUnwrap(commits.first, "expected the seeded commit: \(data)")
        let expectedHash = try git(["rev-parse", "HEAD"], in: tempDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head["hash"] as? String, expectedHash)
        XCTAssertEqual(head["message"] as? String, "base")
        XCTAssertEqual(head["author"] as? String, "Test User")
        let date = try XCTUnwrap(head["date"] as? String, "date must be populated: \(head)")
        XCTAssertTrue(date.hasPrefix("20"), "expected an ISO-ish date, got: \(date)")
    }

    /// The `max` argument. NOTE for future readers: the schema key is `max`, NOT
    /// `limit` — `ToolsGitTests.testGitLog_respectsLimit` passes `limit` (ignored)
    /// and its assertions pass under the default of 20 too, so this is the first
    /// test that actually constrains the count.
    func testGitLog_max_limitsTheNumberOfCommitsReturned() throws {
        for i in 1...5 {
            try seedCommit(named: "f\(i).txt", contents: "\(i)\n", message: "commit \(i)")
        }

        let data = try dataOf(ToolNames.gitLog, ["max": 2])

        let commits = try XCTUnwrap(data["commits"] as? [[String: Any]])
        XCTAssertEqual(commits.count, 2, "got: \(commits)")
        let messages = commits.compactMap { $0["message"] as? String }
        XCTAssertEqual(messages, ["commit 5", "commit 4"],
                       "the newest commits must be the ones kept: \(messages)")
    }

    /// Boundary: `max: 0` is a valid `git log -0` (exit 0, no output), so the
    /// parse loop never runs.
    func testGitLog_maxZero_succeedsWithNoCommits() throws {
        let data = try dataOf(ToolNames.gitLog, ["max": 0])

        XCTAssertEqual((data["commits"] as? [[String: Any]])?.count, 0, "got: \(data)")
    }

    /// Degenerate: a negative `max` interpolates into `--2`, which git rejects.
    /// The important half of the contract is that it does NOT silently fall back to
    /// dumping the whole history under a success envelope.
    func testGitLog_negativeMax_isAnErrorRatherThanAnUnboundedLog() throws {
        for i in 1...3 {
            try seedCommit(named: "n\(i).txt", contents: "\(i)\n", message: "commit \(i)")
        }

        let result = try call(ToolNames.gitLog, ["max": -2])

        XCTAssertTrue(result.isError,
                      "a rejected argument must not read as a successful log: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("commit 3"),
                       "no commits may be reported for a rejected argv: \(result.outputJSON)")
    }

    /// Unborn HEAD: `git log` exits 128 with "does not have any commits yet".
    /// The classifier must NOT mistake that for a missing repository — the
    /// not-a-repo envelope tells the model to abandon git for the whole run, which
    /// is exactly the wrong recovery for a repo that just needs a first commit.
    func testGitLog_unbornRepo_reportsNoCommitsNotAMissingRepository() throws {
        let scratch = try makeScratchRepo(initializeGit: true)

        let result = try call(
            ToolNames.gitLog, [:], runtime: scratch.runtime, context: scratch.context)

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("does not have any commits"),
                      "got: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("not a git repository"),
                       "an unborn HEAD is not a missing repo — the recoveries differ: \(result.outputJSON)")
    }

    /// A `|` inside a commit subject collides with the `--format` delimiter. This
    /// pins only that the commit is still IDENTIFIED (hash intact, envelope ok);
    /// the message/author/date mapping is knowingly wrong for this input and is
    /// reported under `suspectedDefects` rather than frozen here.
    func testGitLog_pipeInSubject_stillIdentifiesTheCommit() throws {
        try seedCommit(named: "piped.txt", contents: "p\n", message: "feat: a | b")

        let data = try dataOf(ToolNames.gitLog, ["oneline": false, "max": 1])

        let commits = try XCTUnwrap(data["commits"] as? [[String: Any]])
        XCTAssertEqual(commits.count, 1, "got: \(commits)")
        let expectedHash = try git(["rev-parse", "HEAD"], in: tempDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(commits[0]["hash"] as? String, expectedHash,
                       "the hash must survive a delimiter collision in the subject")
    }

    // MARK: - git_diff

    /// The truncation arm and its `meta.truncated` flag. Truncation without the
    /// flag is the no-silent-caps violation this project keeps re-fixing: the model
    /// would read a half diff as the whole change.
    func testGitDiff_maxLines_truncatesTheDiffAndFlagsIt() throws {
        try seedLargeChangedFile(lineCount: 80)

        let truncatedResult = try call(ToolNames.gitDiff, ["max_lines": 10])
        XCTAssertFalse(truncatedResult.isError, "got: \(truncatedResult.outputJSON)")
        let truncatedEnvelope = try envelopeOf(truncatedResult)
        let meta = try XCTUnwrap(truncatedEnvelope["meta"] as? [String: Any])
        XCTAssertEqual(meta["truncated"] as? Bool, true, "got: \(truncatedEnvelope)")
        let diff = try XCTUnwrap(
            (truncatedEnvelope["data"] as? [String: Any])?["diff"] as? String)
        XCTAssertEqual(diff.split(separator: "\n", omittingEmptySubsequences: false).count, 10,
                       "exactly max_lines lines must survive")

        let fullResult = try call(ToolNames.gitDiff, [:])
        let fullEnvelope = try envelopeOf(fullResult)
        let fullMeta = try XCTUnwrap(fullEnvelope["meta"] as? [String: Any])
        XCTAssertEqual(fullMeta["truncated"] as? Bool, false,
                       "a diff under the default cap must not be flagged: \(fullEnvelope)")
    }

    /// A binary file. git emits `Binary files a/… and b/… differ` instead of a
    /// hunk, so `files_changed` (counted off `diff --git` lines) is the only signal
    /// that anything changed — and the raw bytes must NOT end up in the payload.
    func testGitDiff_binaryFile_reportsTheChangeWithoutItsBytes() throws {
        let binary = tempDir.appendingPathComponent("blob.dat")
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE]).write(to: binary)
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", "add binary"], in: tempDir)
        try Data([0x00, 0x09, 0x08, 0x07, 0xFD, 0xFC]).write(to: binary)

        let data = try dataOf(ToolNames.gitDiff, [:])

        XCTAssertEqual(data["files_changed"] as? Int, 1, "got: \(data)")
        let diff = try XCTUnwrap(data["diff"] as? String)
        XCTAssertTrue(diff.contains("Binary files"), "got: \(diff)")
        XCTAssertTrue(diff.contains("blob.dat"), "got: \(diff)")
        XCTAssertFalse(diff.contains("\u{0}"), "raw binary bytes must not reach the payload")
    }

    /// A staged rename. `cached: true` also skips the untracked probe entirely, so
    /// this covers the branch where `untracked_files` is left empty by design.
    func testGitDiff_stagedRename_reportsRenameFromAndTo() throws {
        try Data("hello\nworld\n".utf8).write(to: tempDir.appendingPathComponent("before.txt"))
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", "add before"], in: tempDir)
        try git(["mv", "before.txt", "after.txt"], in: tempDir)
        try Data("stray\n".utf8).write(to: tempDir.appendingPathComponent("stray.txt"))

        let data = try dataOf(ToolNames.gitDiff, ["cached": true])

        let diff = try XCTUnwrap(data["diff"] as? String)
        XCTAssertTrue(diff.contains("rename from before.txt"), "got: \(diff)")
        XCTAssertTrue(diff.contains("rename to after.txt"), "got: \(diff)")
        XCTAssertEqual(data["files_changed"] as? Int, 1, "a rename is one changed file: \(data)")
        XCTAssertEqual((data["untracked_files"] as? [String])?.count, 0,
                       "a cached diff must skip the untracked probe: \(data)")
    }

    /// Boundary: a clean tree. Empty diff, zero files, and specifically NOT
    /// flagged as truncated — a spurious flag would tell the model to go looking
    /// for changes that do not exist.
    func testGitDiff_cleanTree_returnsAnEmptyUntruncatedDiff() throws {
        let result = try call(ToolNames.gitDiff, [:])

        XCTAssertFalse(result.isError, "got: \(result.outputJSON)")
        let envelope = try envelopeOf(result)
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["diff"] as? String, "")
        XCTAssertEqual(data["files_changed"] as? Int, 0)
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertEqual(meta["truncated"] as? Bool, false, "got: \(envelope)")
    }

    // MARK: - Not-a-repository, read side

    /// `ToolsGitTests` covers the not-a-repo arm for `git_add` only. All four READ
    /// tools carry their own copy of that guard, and the regression it exists for
    /// (run EA190834 — a role gave up after seeing raw `fatal:` stderr) applies
    /// identically to each: the model must get the "skip git, keep working"
    /// guidance and never the raw stderr.
    ///
    /// The assertions match the GUIDANCE, not the phrase "not a git repository" — this test
    /// passed vacuously for `git_diff` for as long as it has existed. `diff` alone reports
    /// `warning: Not a git repository. Use --no-index …`, which the classifier missed, so the
    /// tool returned raw stderr — and raw stderr satisfied BOTH old assertions at once: it
    /// contains the phrase (once lowercased) and it does not contain `fatal:`. Two assertions,
    /// both green, neither testing the branch they were written for.
    ///
    /// RED: restore the single-spelling `isNotARepository` → `git_diff` fails on the
    /// guidance assertion, and `--no-index` shows up in the envelope.
    func testReadTools_inANonGitFolder_allReturnTheSkipGitGuidance() throws {
        let scratch = try makeScratchRepo(initializeGit: false)

        for tool in [
            ToolNames.gitStatus, ToolNames.gitLog, ToolNames.gitDiff, ToolNames.gitBranchList,
        ] {
            let result = try call(
                tool, [:], runtime: scratch.runtime, context: scratch.context)
            XCTAssertTrue(result.isError, "\(tool) must fail outside a repo: \(result.outputJSON)")
            XCTAssertTrue(
                result.outputJSON.contains("Skip all git_* tools for this run"),
                "\(tool) must give the actionable guidance, not git's own words: \(result.outputJSON)")
            XCTAssertFalse(
                result.outputJSON.contains("fatal:"),
                "\(tool) must not surface raw git stderr: \(result.outputJSON)")
            XCTAssertFalse(
                result.outputJSON.contains("--no-index"),
                """
                \(tool) must not offer the model an argument this tool does not have — that \
                reads as a fixable argument error and buys a retry loop: \(result.outputJSON)
                """)
        }
    }

    /// The read tools' OTHER failure arm: git failed for a reason that is not "no repo".
    /// Induced with a corrupt `.git/config`, which every git command rejects before it
    /// looks at the worktree. The reason must reach the model verbatim — a generic
    /// "git status failed" leaves it nothing to act on, and the not-a-repo guidance would
    /// be an actively wrong diagnosis for a repo that exists.
    func testGitStatus_gitFailsForANonRepoReason_passesTheReasonThrough() throws {
        let config = tempDir.appendingPathComponent(".git/config")
        let original = try Data(contentsOf: config)
        defer { try? original.write(to: config) }
        try Data((String(decoding: original, as: UTF8.self) + "[core\nbogus\n").utf8).write(to: config)

        let result = try call(ToolNames.gitStatus, [:])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("bad config"),
                      "git's reason must survive: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("Skip all git_* tools"),
                       "a broken config is not a missing repository: \(result.outputJSON)")
    }

    /// Same arm in `git_branch_list`, induced differently on purpose: an unreadable
    /// `refs/heads` leaves the repo and its config intact, so this proves the branch is the
    /// tool's own guard and not a shared config short-circuit.
    func testGitBranchList_gitFailsForANonRepoReason_passesTheReasonThrough() throws {
        let heads = tempDir.appendingPathComponent(".git/refs/heads")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: heads.path)
        // Restored before tearDown, or the recursive delete of tempDir fails on the
        // unreadable directory and leaks it (CLAUDE.md, 2026-08-08).
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: heads.path)
        }

        let result = try call(ToolNames.gitBranchList, [:])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("COMMAND_FAILED"), "got: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("Skip all git_* tools"),
                       "an unreadable ref is not a missing repository: \(result.outputJSON)")
        XCTAssertFalse(result.outputJSON.contains("\"branches\""),
                       "a failed listing must not report a branch list: \(result.outputJSON)")
    }

    // MARK: - Tool invocation helpers

    private func call(
        _ tool: String,
        _ args: [String: Any],
        runtime overrideRuntime: ToolRuntime? = nil,
        context overrideContext: ToolExecutionContext? = nil
    ) throws -> ToolExecutionResult {
        let payload = try JSONSerialization.data(withJSONObject: args)
        let json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let calls = [StepToolCall(name: tool, argumentsJSON: json)]
        let results = (overrideRuntime ?? runtime!)
            .executeAll(context: overrideContext ?? context!, toolCalls: calls)
        return try XCTUnwrap(results.first, "runtime returned no result for \(tool)")
    }

    private func envelopeOf(_ result: ToolExecutionResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        return try XCTUnwrap(object as? [String: Any], "not an object: \(result.outputJSON)")
    }

    private func errorOf(_ result: ToolExecutionResult) throws -> [String: Any] {
        let envelope = try envelopeOf(result)
        return try XCTUnwrap(envelope["error"] as? [String: Any],
                             "no error in envelope: \(result.outputJSON)")
    }

    private func dataOf(
        _ tool: String,
        _ args: [String: Any],
        runtime overrideRuntime: ToolRuntime? = nil,
        context overrideContext: ToolExecutionContext? = nil
    ) throws -> [String: Any] {
        let result = try call(
            tool, args, runtime: overrideRuntime, context: overrideContext)
        XCTAssertFalse(result.isError, "expected success, got \(result.outputJSON)")
        let envelope = try envelopeOf(result)
        return try XCTUnwrap(envelope["data"] as? [String: Any],
                             "no data in envelope: \(result.outputJSON)")
    }

    /// Flattens `git_status`'s file list into `path -> status` so an assertion can
    /// name one entry without depending on porcelain's ordering.
    private func statusesByPath(_ data: [String: Any]) throws -> [String: String] {
        let files = try XCTUnwrap(data["files"] as? [[String: Any]], "no files in \(data)")
        let pairs = files.compactMap { entry -> (String, String)? in
            guard let path = entry["path"] as? String,
                  let status = entry["status"] as? String
            else { return nil }
            return (path, status)
        }
        // Never `uniqueKeysWithValues` — a duplicate path would trap the process.
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Fixture helpers

    private func initRepo(at directory: URL) throws {
        try git(["init", "-b", "main"], in: directory)
        try git(["config", "user.email", "test@example.com"], in: directory)
        try git(["config", "user.name", "Test User"], in: directory)
        // Pinned so the fixture doesn't inherit the developer's global config:
        // a signing key would fail every commit, and an unset `pull.rebase` makes
        // git >= 2.34 refuse a divergent pull outright ("Need to specify how to
        // reconcile"), which would make the conflict arm unreachable.
        try git(["config", "commit.gpgsign", "false"], in: directory)
        try git(["config", "pull.rebase", "false"], in: directory)
        // The diffstat is what carries a filename into a successful pull's output, so it
        // is the whole payload of the CONFLICT-named-file reproducer. A developer (or a
        // CI image) with `merge.stat false` in their global config silently defuses that
        // test into asserting nothing — the `fileExists` check would still pass, because
        // it proves the pull happened, not that the marker word reached the handler.
        try git(["config", "merge.stat", "true"], in: directory)
    }

    private func makeScratchRepo(initializeGit: Bool) throws
        -> (dir: URL, runtime: ToolRuntime, context: ToolExecutionContext)
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchDirs.append(dir)

        let paths = NTMSPaths(workFolderRoot: dir)
        try FileManager.default.createDirectory(
            at: paths.nanoteamsDir, withIntermediateDirectories: true)
        if initializeGit {
            try initRepo(at: dir)
        }

        let (_, scratchRuntime) = ToolRegistry.defaultRegistry(
            workFolderRoot: dir,
            toolCallsLogURL: paths.toolCallsJSONL(taskID: 0, runID: 0))
        let scratchContext = ToolExecutionContext(
            workFolderRoot: dir, taskID: 0, runID: 0, roleID: "test_role")
        return (dir, scratchRuntime, scratchContext)
    }

    /// A bare repo on disk standing in for a network remote — same git code path,
    /// zero network.
    private func attachBareRemote() throws {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main"], in: remote)
        try git(["remote", "add", "origin", remote.path], in: tempDir)
        remoteDir = remote
    }

    /// Puts a commit on the remote that the work folder does not have, so a pull
    /// actually fast-forwards instead of being a no-op.
    private func pushExtraCommitFromASecondClone() throws {
        try inASecondClone { clone in
            try Data("from remote\n".utf8)
                .write(to: clone.appendingPathComponent("from-remote.txt"))
            try git(["add", "."], in: clone)
            try git(["commit", "-m", "remote commit"], in: clone)
        }
    }

    /// Edits the SAME line the local side will edit, so the pull conflicts.
    private func pushConflictingCommitFromASecondClone() throws {
        try inASecondClone { clone in
            try Data("remote side\n".utf8).write(to: clone.appendingPathComponent("base.txt"))
            try git(["commit", "-am", "remote edit"], in: clone)
        }
    }

    private func inASecondClone(_ body: (URL) throws -> Void) throws {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        scratchDirs.append(clone)
        let remote = try XCTUnwrap(remoteDir, "attachBareRemote() must run first")
        try git(["clone", remote.path, clone.path], in: FileManager.default.temporaryDirectory)
        try git(["config", "user.email", "other@example.com"], in: clone)
        try git(["config", "user.name", "Other User"], in: clone)
        try git(["config", "commit.gpgsign", "false"], in: clone)
        try body(clone)
        try git(["push", "origin", "main"], in: clone)
    }

    private func seedCommit(named name: String, contents: String, message: String) throws {
        try Data(contents.utf8).write(to: tempDir.appendingPathComponent(name))
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", message], in: tempDir)
    }

    /// A file whose every line changes, so the resulting diff comfortably exceeds
    /// any small `max_lines` while staying one `diff --git` entry.
    private func seedLargeChangedFile(lineCount: Int) throws {
        let path = tempDir.appendingPathComponent("big.txt")
        let before = (0..<lineCount).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(before.utf8).write(to: path)
        try git(["add", "."], in: tempDir)
        try git(["commit", "-m", "add big file"], in: tempDir)
        let after = (0..<lineCount).map { "CHANGED \($0)" }.joined(separator: "\n") + "\n"
        try Data(after.utf8).write(to: path)
    }

    private func contents(of name: String) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - Raw git

    /// Runs git and FAILS the test on a non-zero exit — a silently broken fixture
    /// command otherwise surfaces as a baffling assertion failure three steps later.
    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let outcome = gitAllowingFailure(args, in: directory)
        if outcome.exitCode != 0 {
            XCTFail("fixture `git \(args.joined(separator: " "))` failed "
                + "(exit \(outcome.exitCode)): \(outcome.output)")
        }
        return outcome.output
    }

    @discardableResult
    private func gitAllowingFailure(_ args: [String], in directory: URL)
        -> (output: String, exitCode: Int32)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            XCTFail("could not launch git: \(error)")
            return ("", -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
