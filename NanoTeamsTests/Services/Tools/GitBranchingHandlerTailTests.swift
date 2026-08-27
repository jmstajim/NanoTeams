import XCTest

@testable import NanoTeams

/// The arms of `GitBranchingHandlers.swift` that no existing suite reaches.
///
/// Coverage context (measured 2026-08-07, `coverage/files.json`): the file was 339
/// of 380 executable lines. `ToolsGitTests` drives only the two happy paths
/// (`git_checkout` switch/create, `git_branch` create/delete) and
/// `ToolsGitPullMergeTests` drives `git_merge` plus the classifier in isolation.
/// What was left: every FAILURE arm of `git_checkout` and `git_branch`, the
/// `rename` action in both its success and its missing-`new_name` rejection, the
/// force-delete (`-D`) branch, the invalid-action guard, `create` with a start
/// point, and `git_merge --no-ff`.
///
/// Harness copied verbatim from `ToolsGitPullMergeTests` (which copied it from
/// `ToolsGitTests`): a real git repo built by this test in its own temp directory
/// and driven through `ToolRuntime`, because these tools shell out to `/usr/bin/git`
/// and the value under test is how git's own stderr maps onto an error envelope.
/// `.standardizedFileURL` is required — `/var` → `/private/var` otherwise breaks
/// `SandboxPathResolver` containment. Nothing here touches the network and nothing
/// here runs git anywhere but `tempDir`.
final class GitBranchingHandlerTailTests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var runtime: ToolRuntime!
    private var context: ToolExecutionContext!

    override func setUp() async throws {
        try await super.setUp()
        try await makeRepo(withInitialCommit: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }
        tempDir = nil
        runtime = nil
        context = nil
        try super.tearDownWithError()
    }

    // MARK: - git_checkout: failure arms

    /// `git checkout no_such_branch` exits non-zero with
    /// `error: pathspec '…' did not match any file(s) known to git`, which the shared
    /// classifier maps to `FILE_NOT_FOUND` — a different recovery from `CONFLICT`.
    func testCheckout_unknownBranch_isFileNotFoundAndNamesTheBranch() async throws {
        let result = try await run(ToolNames.gitCheckout, ["branch": "no_such_branch"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "FILE_NOT_FOUND")
        XCTAssertEqual(try errorMessage(result), "Branch 'no_such_branch' not found",
                       "the message must name the branch the model asked for")
    }

    /// `git checkout -b main` on an existing branch exits non-zero with
    /// `fatal: a branch named 'main' already exists` → `CONFLICT`.
    func testCheckout_createOverAnExistingBranch_isAConflict() async throws {
        let result = try await run(ToolNames.gitCheckout, ["branch": "main", "create": true])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "CONFLICT")
        XCTAssertEqual(try errorMessage(result), "Branch 'main' already exists")
        XCTAssertEqual(try currentBranch(), "main", "a rejected checkout must not move HEAD")
    }

    /// The classifier's fall-through: git failed for a reason none of its four string
    /// probes recognise (`error: Your local changes … would be overwritten by checkout`).
    /// That must still be an ERROR envelope carrying git's own reason, not a success.
    func testCheckout_unrecognisedFailure_fallsThroughToCommandFailedWithGitsReason() async throws {
        try git(["checkout", "-b", "feature"])
        try write("base.txt", "feature side\n")
        try git(["add", "."])
        try git(["commit", "-m", "feature edit"])
        try git(["checkout", "main"])
        // Uncommitted local change on the same file checkout would clobber.
        try write("base.txt", "dirty\n")

        let result = try await run(ToolNames.gitCheckout, ["branch": "feature"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "COMMAND_FAILED")
        XCTAssertFalse(try errorMessage(result).isEmpty,
                       "a COMMAND_FAILED envelope with an empty message tells the model nothing")
        XCTAssertEqual(try currentBranch(), "main")
    }

    /// `branch` is `required` in the schema; omitting it is rejected before any git runs.
    func testCheckout_missingBranchArgument_isInvalidArgs() async throws {
        let result = try await run(ToolNames.gitCheckout, [:])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "INVALID_ARGS")
    }

    // MARK: - git_checkout: create-from and `previous`

    /// `from` is appended ONLY when `create` is set — the new branch must start at the
    /// named commit, not at HEAD.
    func testCheckout_createFromAnEarlierCommit_startsThere() async throws {
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("later.txt", "later\n")
        try git(["add", "."])
        try git(["commit", "-m", "later"])

        let data = try await successData(
            ToolNames.gitCheckout, ["branch": "from-base", "create": true, "from": base])

        XCTAssertEqual(data["branch"] as? String, "from-base")
        XCTAssertEqual(data["previous"] as? String, "main")
        XCTAssertEqual(
            try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            base,
            "`from` must have been passed to git — otherwise the branch starts at the later commit")
        XCTAssertFalse(fileManager.fileExists(atPath: tempDir.appendingPathComponent("later.txt").path))
    }

    /// `from` without `create` used to be dropped SILENTLY. `git checkout <branch> <start>`
    /// means nothing, so not passing it to git is right — but reporting success is not: the
    /// model asked to land on a specific start point, was told it had, and every later read
    /// described a tree it never selected. An argument accepted and ignored is the mirror of
    /// advertise-then-reject.
    func testCheckout_fromWithoutCreate_isRejectedRatherThanSilentlyDropped() async throws {
        try git(["branch", "other"])

        let result = try await run(
            ToolNames.gitCheckout, ["branch": "other", "from": "some_commit"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "INVALID_ARGS")
        XCTAssertTrue(try errorMessage(result).contains("create"),
                      "the message must name the argument that would make `from` legal")
    }

    /// The rejection happens BEFORE git runs, so nothing moved. A tool that errored *after*
    /// switching branches would leave the working tree somewhere the model doesn't know about.
    func testCheckout_rejectedFromArgument_leavesTheBranchUnchanged() async throws {
        try git(["branch", "other"])

        _ = try await run(ToolNames.gitCheckout, ["branch": "other", "from": "some_commit"])

        XCTAssertEqual(try currentBranch(), "main")
    }

    /// The legal shape still works, and `from` still reaches git — the guard must not have
    /// widened into "reject `from` always".
    func testCheckout_fromWithCreate_isStillHonoured() async throws {
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let data = try await successData(
            ToolNames.gitCheckout, ["branch": "from-base", "create": true, "from": base])

        XCTAssertEqual(data["branch"] as? String, "from-base")
        XCTAssertEqual(
            try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            base)
    }

    /// `previous` comes from `git branch --show-current`, which prints NOTHING on a
    /// detached HEAD. The envelope then reports an empty string rather than inventing
    /// a branch name.
    func testCheckout_fromDetachedHead_reportsAnEmptyPreviousBranch() async throws {
        let head = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "--detach", head])

        let data = try await successData(ToolNames.gitCheckout, ["branch": "main"])

        XCTAssertEqual(data["branch"] as? String, "main")
        XCTAssertEqual(data["previous"] as? String, "",
                       "a detached HEAD has no current branch; got \(data)")
    }

    // MARK: - git_branch: rename

    func testBranch_rename_movesTheBranchAndEchoesBothNames() async throws {
        try git(["branch", "old-name"])

        let data = try await successData(
            ToolNames.gitBranch,
            ["action": "rename", "name": "old-name", "new_name": "new-name"])

        XCTAssertEqual(data["action"] as? String, "rename")
        XCTAssertEqual(data["name"] as? String, "old-name")
        XCTAssertEqual(data["new_name"] as? String, "new-name")

        let branches = try capture(["branch", "--format=%(refname:short)"])
        XCTAssertTrue(branches.contains("new-name"), "got: \(branches)")
        XCTAssertFalse(branches.contains("old-name"), "got: \(branches)")
    }

    /// `new_name` is not in the schema's `required` list because it only applies to one
    /// action — so the handler has to reject it itself. Without this arm the tool would
    /// run `git branch -m old` and rename the CURRENT branch to `old`.
    func testBranch_renameWithoutNewName_isRejectedBeforeGitRuns() async throws {
        let before = try capture(["branch", "--format=%(refname:short)"])

        let result = try await run(ToolNames.gitBranch, ["action": "rename", "name": "old-name"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "INVALID_ARGS")
        let message = try errorMessage(result)
        XCTAssertTrue(message.contains("new_name"),
                      "the message must name the missing argument; got \(message)")
        XCTAssertEqual(try capture(["branch", "--format=%(refname:short)"]), before,
                       "nothing may have been renamed")
    }

    // MARK: - git_branch: delete

    /// `-d` refuses to drop a branch whose commits are not merged. That stderr
    /// (`error: the branch 'x' is not fully merged`) matches none of the classifier's
    /// probes, so it exercises the `COMMAND_FAILED` fall-through — and the branch must
    /// survive.
    func testBranch_deleteUnmerged_withoutForce_failsAndKeepsTheBranch() async throws {
        try makeUnmergedBranch(named: "unmerged")

        let result = try await run(ToolNames.gitBranch, ["action": "delete", "name": "unmerged"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "COMMAND_FAILED")
        XCTAssertTrue(try capture(["branch", "--format=%(refname:short)"]).contains("unmerged"),
                      "a refused delete must leave the branch in place")
    }

    /// `force: true` swaps `-d` for `-D`, which is the only way the same branch goes away.
    func testBranch_deleteUnmerged_withForce_succeeds() async throws {
        try makeUnmergedBranch(named: "unmerged")

        let data = try await successData(
            ToolNames.gitBranch, ["action": "delete", "name": "unmerged", "force": true])

        XCTAssertEqual(data["action"] as? String, "delete")
        XCTAssertFalse(try capture(["branch", "--format=%(refname:short)"]).contains("unmerged"),
                       "force delete must actually remove the branch")
    }

    /// git says `error: branch 'x' not found.` → the classifier's `not found` probe.
    func testBranch_deleteUnknownBranch_isFileNotFound() async throws {
        let result = try await run(ToolNames.gitBranch, ["action": "delete", "name": "ghost"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "FILE_NOT_FOUND")
        XCTAssertEqual(try errorMessage(result), "Branch 'ghost' not found")
    }

    // MARK: - git_branch: create

    func testBranch_createFromAStartPoint_pointsAtThatCommit() async throws {
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("later.txt", "later\n")
        try git(["add", "."])
        try git(["commit", "-m", "later"])

        let data = try await successData(
            ToolNames.gitBranch, ["action": "create", "name": "at-base", "from": base])

        XCTAssertEqual(data["name"] as? String, "at-base")
        XCTAssertEqual(
            try capture(["rev-parse", "at-base"]).trimmingCharacters(in: .whitespacesAndNewlines),
            base)
    }

    func testBranch_createOverAnExistingName_isAConflict() async throws {
        let result = try await run(ToolNames.gitBranch, ["action": "create", "name": "main"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "CONFLICT")
        XCTAssertEqual(try errorMessage(result), "Branch 'main' already exists")
    }

    // MARK: - git_branch: argument guards

    /// The `default:` arm of the action switch. The message has to list the legal
    /// actions, or the model has nothing to correct toward.
    func testBranch_unknownAction_isInvalidArgsAndListsTheLegalActions() async throws {
        let result = try await run(ToolNames.gitBranch, ["action": "obliterate", "name": "main"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "INVALID_ARGS")
        let message = try errorMessage(result)
        for legal in ["create", "delete", "rename"] {
            XCTAssertTrue(message.contains(legal), "`\(legal)` missing from: \(message)")
        }
        XCTAssertTrue(message.contains("obliterate"), "the message must echo what was sent: \(message)")
    }

    func testBranch_missingRequiredArguments_areInvalidArgs() async throws {
        let noAction = try await run(ToolNames.gitBranch, ["name": "main"])
        XCTAssertEqual(try errorCode(noAction), "INVALID_ARGS", "got: \(noAction.outputJSON)")

        let noName = try await run(ToolNames.gitBranch, ["action": "create"])
        XCTAssertEqual(try errorCode(noName), "INVALID_ARGS", "got: \(noName.outputJSON)")
    }

    // MARK: - git_branch: `force` reaches every verb that has a use for it

    /// The unbreakable retry loop. `testBranch_createOverAnExistingName_isAConflict` above
    /// pins that git answers "Branch 'main' already exists" — which names `--force` as the
    /// remedy, in git's own words. `force` was read and used ONLY by `delete`, so the model
    /// that took git's advice sent a materially different call and received a byte-identical
    /// failure, for as many iterations as it had. Measured against git: `git branch feat`
    /// over an existing branch exits 128, `git branch --force feat` exits 0.
    ///
    /// RED: drop the `--force` append from the `create` arm → CONFLICT again, and the branch
    /// still points at the old commit.
    func testBranchCreate_force_resetsTheExistingBranch() async throws {
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["branch", "feat", base])
        try write("later.txt", "later\n")
        try git(["add", "."])
        try git(["commit", "-m", "later"])
        let head = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(base, head, "precondition: the branch and HEAD must differ")

        let data = try await successData(
            ToolNames.gitBranch, ["action": "create", "name": "feat", "force": true])

        XCTAssertEqual(data["name"] as? String, "feat")
        XCTAssertEqual(
            try capture(["rev-parse", "feat"]).trimmingCharacters(in: .whitespacesAndNewlines),
            head, "a forced create must move the branch, not report success and leave it")
    }

    /// The rename half of the same argument. `git branch -m old new` fails when `new` exists;
    /// `-M` is `--move --force`. The handler hard-coded `-m`, so a forced rename was a plain
    /// one — and the model was told the target already exists no matter what it sent.
    ///
    /// RED: hard-code `-m` again → CONFLICT, and `old` still exists.
    func testBranchRename_force_overwritesTheExistingTarget() async throws {
        try git(["branch", "old"])
        try git(["branch", "taken"])

        let data = try await successData(
            ToolNames.gitBranch,
            ["action": "rename", "name": "old", "new_name": "taken", "force": true])

        XCTAssertEqual(data["new_name"] as? String, "taken")
        let branches = try capture(["branch", "--format=%(refname:short)"])
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(branches.contains("taken"))
        XCTAssertFalse(branches.contains("old"), "the rename must have happened: \(branches)")
    }

    /// Anti-vacuity for the two above: they pass for a handler that force-everythings. Without
    /// `force`, the same two calls must still be refused — the flag has to be what changed the
    /// outcome, not the fix.
    ///
    /// RED: append `--force`/`-M` unconditionally → both calls succeed and both asserts fail.
    func testBranch_withoutForce_theSameCallsAreStillRefused() async throws {
        try git(["branch", "feat"])
        try git(["branch", "taken"])

        let create = try await run(ToolNames.gitBranch, ["action": "create", "name": "feat"])
        XCTAssertTrue(create.isError, "got: \(create.outputJSON)")

        let rename = try await run(
            ToolNames.gitBranch, ["action": "rename", "name": "feat", "new_name": "taken"])
        XCTAssertTrue(rename.isError, "got: \(rename.outputJSON)")
    }

    // MARK: - git_branch: arguments that belong to another verb

    /// `git_checkout` in this same file already refuses to drop `from` silently, and states the
    /// rule in its comment: an argument accepted and ignored is the mirror of advertise-then-
    /// reject. `git_branch` read `from` and used it only under `create`, so
    /// `git_branch(action: "delete", name: "x", from: "v1.0")` deleted `x` and reported success
    /// — the model asked to operate relative to a start point and was told it had.
    ///
    /// RED: delete the `from` rejection from the `delete` arm → the branch is deleted and the
    /// envelope says ok.
    func testBranch_fromOnDelete_isRejectedRatherThanDropped() async throws {
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["branch", "doomed"])

        let result = try await run(
            ToolNames.gitBranch, ["action": "delete", "name": "doomed", "from": base])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        XCTAssertEqual(try errorCode(result), "INVALID_ARGS")
        let message = try errorMessage(result)
        XCTAssertTrue(message.contains("from"), "must name the argument: \(message)")
        XCTAssertTrue(message.contains("create"), "must name where it applies: \(message)")

        let branches = try capture(["branch", "--format=%(refname:short)"])
        XCTAssertTrue(branches.contains("doomed"), "a rejected call must not have acted")
    }

    /// The same rule for `from` under `rename`, and for `new_name` under the two verbs that
    /// have no use for it. `new_name` under `create` is the one that reads most like a working
    /// call — "create `x` named `y`" — and did nothing of the sort.
    ///
    /// RED: delete any one of the three rejections → that row's `isError` fails.
    func testBranch_argumentsBelongingToAnotherVerb_areEachRejected() async throws {
        try git(["branch", "old"])
        let base = try capture(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let cases: [(String, [String: Any])] = [
            ("from on rename",
             ["action": "rename", "name": "old", "new_name": "fresh", "from": base]),
            ("new_name on create", ["action": "create", "name": "fresh", "new_name": "other"]),
            ("new_name on delete", ["action": "delete", "name": "old", "new_name": "other"]),
        ]

        for (label, args) in cases {
            let result = try await run(ToolNames.gitBranch, args)
            XCTAssertTrue(result.isError, "\(label) was accepted: \(result.outputJSON)")
            XCTAssertEqual(try errorCode(result), "INVALID_ARGS", "\(label)")
        }

        XCTAssertTrue(
            try capture(["branch", "--format=%(refname:short)"]).contains("old"),
            "no rejected call may have acted")
    }

    /// The verb each argument DOES belong to must still work — otherwise the rejections above
    /// are satisfied by refusing the arguments outright. `create`+`from` is already covered by
    /// `testBranch_createFromAStartPoint_pointsAtThatCommit`; this pins the rename half beside
    /// it so both live next to the guard that could break them.
    ///
    /// RED: reject `new_name` unconditionally → the rename fails.
    func testBranch_newNameOnRename_stillWorks() async throws {
        try git(["branch", "old"])

        let data = try await successData(
            ToolNames.gitBranch, ["action": "rename", "name": "old", "new_name": "fresh"])

        XCTAssertEqual(data["new_name"] as? String, "fresh")
        XCTAssertTrue(try capture(["branch", "--format=%(refname:short)"]).contains("fresh"))
    }

    // MARK: - git_merge: --no-ff

    /// The `no_ff` flag is the one `git_merge` argv branch no suite reached. Its whole
    /// observable effect is that a merge which COULD fast-forward creates a merge commit
    /// instead — so assert on the commit graph, not on the envelope.
    func testMerge_noFf_createsAMergeCommitWhereAFastForwardWouldHaveSufficed() async throws {
        try git(["checkout", "-b", "feature"])
        try write("feature.txt", "feature\n")
        try git(["add", "."])
        try git(["commit", "-m", "feature work"])
        try git(["checkout", "main"])

        let data = try await successData(ToolNames.gitMerge, ["branch": "feature", "no_ff": true])

        XCTAssertEqual(data["merged_branch"] as? String, "feature")
        XCTAssertEqual(data["success"] as? Bool, true)
        let parents = try capture(["rev-list", "--parents", "-n", "1", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        XCTAssertEqual(parents.count, 3,
                       "--no-ff must leave HEAD with two parents (a merge commit); got: \(parents)")
    }

    /// THE reproducer. The conflict probe used to scan stdout+stderr for the literal `CONFLICT`
    /// before consulting the exit status — and `git merge` prints a DIFFSTAT, which lists file
    /// names. So a clean merge that touches `CONFLICT.txt` reported `CONFLICT`, and the model
    /// set about resolving conflicts that do not exist in a tree that is already merged.
    ///
    /// Measured, not hypothesised: a fast-forward merge of a branch adding that file prints
    /// ` CONFLICT.txt | 1 +` and exits 0. The file name is ordinary — a repo documenting its own
    /// merge handling has one. An earlier pass looked for the marker in the BRANCH name, which
    /// git does not echo on success, so the concern was recorded as unreachable; the diffstat is
    /// the route that makes it real.
    ///
    /// `git merge` exits non-zero on a real conflict, so the exit status is authoritative and
    /// the text is now read only after git has said it failed.
    func testMerge_fileNamedCONFLICT_isNotMisreadAsAConflict() async throws {
        try git(["checkout", "-b", "adds-conflict-doc"])
        try write("CONFLICT.txt", "how we handle merge conflicts\n")
        try git(["add", "."])
        try git(["commit", "-m", "document merge handling"])
        try git(["checkout", "main"])

        let result = try await run(ToolNames.gitMerge, ["branch": "adds-conflict-doc"])

        XCTAssertFalse(result.isError,
                       "the merge succeeded; the diffstat naming the file is not a conflict. got: \(result.outputJSON)")
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.appendingPathComponent("CONFLICT.txt").path),
                      "the merge really did happen")
    }

    /// `git merge` merges the same way `git pull` does, so it inherits the same trap: with
    /// `merge.autoStash` set, git completes the merge, conflicts applying the stash, writes
    /// markers into the working tree — and exits **0**. The exit status is not proof of a
    /// merged tree; the index is.
    ///
    /// RED: delete the `ls-files -u` check in `git_merge`'s success path -> `isError` is
    /// false and the model is told the branch merged cleanly over a conflicted index.
    func testMerge_autostashPopConflict_isReportedEvenThoughGitExitedZero() async throws {
        try git(["config", "merge.autoStash", "true"])
        try git(["checkout", "-b", "edits-base"])
        try write("base.txt", "branch edit\n")
        try git(["commit", "-am", "branch edit"])
        try git(["checkout", "main"])
        // Uncommitted local edit to the SAME file — what autostash exists to carry.
        try write("base.txt", "local edit\n")

        let result = try await run(ToolNames.gitMerge, ["branch": "edits-base"])

        XCTAssertTrue(
            result.isError,
            "git exits 0 here; the index is the authoritative signal: \(result.outputJSON)")
        XCTAssertTrue(result.outputJSON.contains("base.txt"),
                      "and the conflicted path must be named: \(result.outputJSON)")
    }

    /// Anti-vacuity for the test above, which `fileExists` alone cannot provide: it proves
    /// the merge ran, not that the marker word ever reached the handler. `git_merge`'s
    /// success envelope does not echo git's output, so the precondition is asserted at the
    /// source — the diffstat is the only thing that carries a filename into a clean merge,
    /// and an inherited `merge.stat false` silently removes it, leaving the reproducer
    /// green against the very defect it is named for.
    func testTheMergeReproducer_actuallyPutsTheMarkerWordInGitsOutput() throws {
        XCTAssertEqual(
            try git(["config", "merge.stat"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "true",
            "the fixture must not inherit merge.stat from the developer's global config")

        try git(["checkout", "-b", "probe-conflict-doc"])
        try write("CONFLICT.txt", "how we handle merge conflicts\n")
        try git(["add", "."])
        try git(["commit", "-m", "document merge handling"])
        try git(["checkout", "main"])

        let mergeOutput = try git(["merge", "probe-conflict-doc"])

        XCTAssertTrue(
            mergeOutput.contains("CONFLICT"),
            "git's own output must carry the marker word, or the reproducer proves nothing: "
                + mergeOutput)
    }

    /// A branch name carrying the marker. Weaker than the test above — git does not echo the
    /// branch name on a successful merge — but it pins the other half of the same rule and
    /// costs nothing.
    func testMerge_branchNameContainingCONFLICT_isNotMisreadAsAConflict() async throws {
        try git(["checkout", "-b", "fix-CONFLICT-handling"])
        try write("feature.txt", "feature\n")
        try git(["add", "."])
        try git(["commit", "-m", "resolve CONFLICT markers"])
        try git(["checkout", "main"])

        let result = try await run(ToolNames.gitMerge, ["branch": "fix-CONFLICT-handling"])

        XCTAssertFalse(result.isError,
                       "a merge that succeeded must not report a conflict; got \(result.outputJSON)")
        XCTAssertTrue(fileManager.fileExists(atPath: tempDir.appendingPathComponent("feature.txt").path),
                      "the merge really did happen")
    }

    // MARK: - Corner cases: unborn repo, hostile names, spaces in the root

    /// A repository with zero commits. `git branch --show-current` still prints the
    /// unborn branch name, and `checkout -b` succeeds — so the tool must report a real
    /// `previous`, not fail.
    func testCheckout_createInARepoWithNoCommits_succeeds() async throws {
        try await makeRepo(withInitialCommit: false)

        let data = try await successData(
            ToolNames.gitCheckout, ["branch": "first", "create": true])

        XCTAssertEqual(data["branch"] as? String, "first")
        XCTAssertEqual(data["previous"] as? String, "main",
                       "an unborn HEAD still names its branch; got \(data)")
        XCTAssertEqual(try currentBranch(), "first")
    }

    /// A repo with no commits has no ref to point at, so `create` and `delete` must come
    /// back as ERROR envelopes rather than `ok:true` over a no-op.
    func testBranch_createAndDeleteInARepoWithNoCommits_areErrorEnvelopes() async throws {
        try await makeRepo(withInitialCommit: false)

        for args in [
            ["action": "create", "name": "x"],
            ["action": "delete", "name": "main"],
        ] as [[String: Any]] {
            let result = try await run(ToolNames.gitBranch, args)
            XCTAssertTrue(result.isError,
                          "\(args) must not report success in an unborn repo; got \(result.outputJSON)")
        }
    }

    /// `rename` is the one branch action that DOES work before the first commit — git
    /// rewrites the HEAD symref rather than moving a ref. The envelope has to report
    /// that honestly, which is only checkable against HEAD itself: `git branch` lists
    /// nothing in an unborn repo, so a success envelope here is easy to disbelieve.
    func testBranch_renameInARepoWithNoCommits_succeedsAndMovesHead() async throws {
        try await makeRepo(withInitialCommit: false)

        let data = try await successData(
            ToolNames.gitBranch, ["action": "rename", "name": "main", "new_name": "trunk"])

        XCTAssertEqual(data["new_name"] as? String, "trunk")
        XCTAssertEqual(try currentBranch(), "trunk",
                       "the unborn HEAD must now name the new branch")
    }

    /// Ref names may not contain a space (`git check-ref-format`), so this must be a
    /// loud error — and, critically, the name must reach git as ONE argv token: if it
    /// were split, git would see `git branch my` and silently create a branch called
    /// `my`.
    func testBranch_nameContainingASpace_isRejectedAndCreatesNothing() async throws {
        let result = try await run(ToolNames.gitBranch, ["action": "create", "name": "my branch"])

        XCTAssertTrue(result.isError, "got: \(result.outputJSON)")
        let branches = try capture(["branch", "--format=%(refname:short)"])
        XCTAssertFalse(branches.contains("my"),
                       "the name was split into separate argv tokens; got: \(branches)")
    }

    /// `ProcessRunner` passes an argv array — there is no shell, so a name carrying
    /// shell syntax can neither expand nor execute. Asserted on the filesystem, which
    /// is the property that matters, and which holds whether or not git accepts the
    /// name as a ref.
    func testBranch_nameContainingShellSyntax_isNeverEvaluated() async throws {
        let hostile = "feat/$(touch pwned)-`touch pwned2`"

        _ = try await run(ToolNames.gitBranch, ["action": "create", "name": hostile])

        XCTAssertFalse(fileManager.fileExists(atPath: tempDir.appendingPathComponent("pwned").path),
                       "command substitution ran — the branch name reached a shell")
        XCTAssertFalse(fileManager.fileExists(atPath: tempDir.appendingPathComponent("pwned2").path),
                       "backtick substitution ran — the branch name reached a shell")
    }

    /// The whole work folder sits at a path with spaces in it. Everything downstream —
    /// `currentDirectoryURL`, `SandboxPathResolver` containment — has to survive that.
    func testBranchingTools_workFolderPathContainingSpaces_stillOperate() async throws {
        try await makeRepo(withInitialCommit: true, directoryName: "work folder with spaces")

        let created = try await successData(
            ToolNames.gitBranch, ["action": "create", "name": "spaced"])
        XCTAssertEqual(created["name"] as? String, "spaced")

        let switched = try await successData(ToolNames.gitCheckout, ["branch": "spaced"])
        XCTAssertEqual(switched["previous"] as? String, "main")
        XCTAssertEqual(try currentBranch(), "spaced")
    }

    /// Every branching tool in a folder that is not a repository must return the shared
    /// "skip git for this run" guidance, not a bare git failure.
    func testAllBranchingTools_inANonGitFolder_returnTheSkipGitGuidance() async throws {
        try await makeRepo(withInitialCommit: false, initGit: false)

        let calls: [(String, [String: Any])] = [
            (ToolNames.gitCheckout, ["branch": "main"]),
            (ToolNames.gitMerge, ["branch": "main"]),
            (ToolNames.gitBranch, ["action": "create", "name": "x"]),
        ]
        for (tool, args) in calls {
            let result = try await run(tool, args)
            XCTAssertTrue(result.isError, "\(tool) must fail outside a repo; got \(result.outputJSON)")
            XCTAssertTrue(try errorMessage(result).contains("not a git repository"),
                          "\(tool) lost the actionable guidance; got \(result.outputJSON)")
        }
    }

    // MARK: - Tool invocation helpers

    private func run(_ tool: String, _ args: [String: Any]) async throws -> ToolExecutionResult {
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let calls = [StepToolCall(name: tool, argumentsJSON: json)]
        let results = await runtime.executeAll(context: context, toolCalls: calls)
        return try XCTUnwrap(results.first)
    }

    private func successData(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        let result = try await run(tool, args)
        XCTAssertFalse(result.isError, "expected success, got \(result.outputJSON)")
        return try XCTUnwrap(envelope(result)["data"] as? [String: Any],
                             "no data in envelope: \(result.outputJSON)")
    }

    private func envelope(_ result: ToolExecutionResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func errorCode(_ result: ToolExecutionResult) throws -> String {
        let error = try XCTUnwrap(envelope(result)["error"] as? [String: Any],
                                  "no error in envelope: \(result.outputJSON)")
        return try XCTUnwrap(error["code"] as? String)
    }

    private func errorMessage(_ result: ToolExecutionResult) throws -> String {
        let error = try XCTUnwrap(envelope(result)["error"] as? [String: Any],
                                  "no error in envelope: \(result.outputJSON)")
        return try XCTUnwrap(error["message"] as? String)
    }

    // MARK: - Fixture helpers

    /// Builds a fresh repo in a fresh temp directory and repoints the runtime at it.
    /// Called from `setUp` and again by the tests that need a different starting shape.
    ///
    /// The registry/runtime construction hops to the main actor: `setUp` already runs
    /// there, but an `async` test body runs on the cooperative pool, and building the
    /// handler set off-main crashes the test host. Making the hop explicit lets the
    /// same helper serve both callers.
    private func makeRepo(
        withInitialCommit seedCommit: Bool,
        directoryName: String? = nil,
        initGit: Bool = true
    ) async throws {
        if let tempDir { try? fileManager.removeItem(at: tempDir) }

        var root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        if let directoryName {
            root = root.appendingPathComponent(directoryName, isDirectory: true)
        }
        tempDir = root.standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        if initGit {
            try git(["init", "-b", "main"])
            try git(["config", "user.email", "test@example.com"])
            try git(["config", "user.name", "Test User"])
            // The diffstat is the ONLY thing that carries a filename into a clean merge's
            // output, so `testMerge_fileNamedCONFLICT_isNotMisreadAsAConflict` is asserting
            // nothing at all under an inherited `merge.stat false`. Pin it here rather than
            // trust the developer's global config.
            try git(["config", "merge.stat", "true"])
            if seedCommit {
                try write("base.txt", "base\n")
                try git(["add", "."])
                try git(["commit", "-m", "base"])
            }
        }

        let resolvedRoot = tempDir!
        let logURL = paths.toolCallsJSONL(taskID: 0, runID: 0)
        runtime = await MainActor.run {
            ToolRegistry.defaultRegistry(
                workFolderRoot: resolvedRoot, toolCallsLogURL: logURL).runtime
        }
        context = ToolExecutionContext(
            workFolderRoot: tempDir, taskID: 0, runID: 0, roleID: "test_role")
    }

    /// A branch holding a commit that `main` does not, so `git branch -d` refuses it.
    private func makeUnmergedBranch(named name: String) throws {
        try git(["checkout", "-b", name])
        try write("\(name).txt", "work\n")
        try git(["add", "."])
        try git(["commit", "-m", "work on \(name)"])
        try git(["checkout", "main"])
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(
            to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func currentBranch() throws -> String {
        try capture(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Raw git (test fixture setup only; never runs outside `tempDir`)

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        try capture(arguments)
    }

    private func capture(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = tempDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
