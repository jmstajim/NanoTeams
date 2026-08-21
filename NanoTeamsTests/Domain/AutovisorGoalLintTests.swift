import XCTest

@testable import NanoTeams

/// `AutovisorGoalLint` — the capability check over Autovisor goal text.
final class AutovisorGoalLintTests: XCTestCase {

    private func tokens(_ findings: [AutovisorGoalLint.Finding]) -> [String] {
        findings.map(\.token).sorted()
    }

    // MARK: - The derived set

    /// Anti-vacuity floor. If `managerDefaultToolIDs` ever widened to
    /// everything, the derived set would empty and the lint would silently pass
    /// any goal — this is the assertion that notices.
    func testUnavailableToolNames_supersetsTheHistoricalHandWrittenList() {
        for name in ["write_file", "edit_file", "delete_file",
                     "delegate_to_team", "ask_supervisor", "bash"] {
            XCTAssertTrue(AutovisorGoalLint.unavailableToolNames.contains(name),
                          "the derivation dropped \(name), which the old literal list caught")
        }
        XCTAssertGreaterThanOrEqual(
            AutovisorGoalLint.unavailableToolNames.count, 20,
            "far fewer gaps than the manager really has — check the subtraction")
    }

    /// The gain over the literal list: tools nobody remembered to add.
    /// `run_xcodebuild` / `run_xcodetests` used to head this list and have been
    /// removed: the manager now carries them (build/test VERIFY the repo's state
    /// rather than change it). Their absence here is covered from the other side by
    /// `testUnavailableToolNames_excludesEveryToolTheManagerActuallyHas`, which
    /// derives from `managerDefaultToolIDs` and so tracks the toolset automatically.
    /// Everything below still mutates the repo or belongs to a worker role.
    func testUnavailableToolNames_coversWhatTheLiteralListMissed() {
        for name in ["git_commit", "git_push", "bash", "bash_output",
                     "write_file", "create_artifact"]
            where ToolNames.allNames.contains(name) {
            XCTAssertTrue(AutovisorGoalLint.unavailableToolNames.contains(name), name)
        }
    }

    func testUnavailableToolNames_excludesEveryToolTheManagerActuallyHas() {
        for name in AutovisorConstants.managerDefaultToolIDs {
            XCTAssertFalse(AutovisorGoalLint.unavailableToolNames.contains(name),
                           "\(name) is in the manager's own toolset")
        }
    }

    // MARK: - Token matching, not substring

    /// The trap substring matching falls into: `git_branch` is denied while
    /// `git_branch_list` is one of the manager's own tools.
    func testGitBranchList_isNotFlaggedByItsDeniedPrefix() {
        XCTAssertTrue(AutovisorGoalLint.scanStrict("Use `git_branch_list` to see branches.").isEmpty)
        XCTAssertEqual(tokens(AutovisorGoalLint.scanStrict("Use `git_branch` to cut one.")),
                       ["git_branch"])
    }

    func testToolNameInsideALongerIdentifier_isNotFlagged() {
        XCTAssertTrue(AutovisorGoalLint.scanStrict("See my_write_file_helper notes.").isEmpty)
        XCTAssertTrue(AutovisorGoalLint.scanStrict("See write_file_helper notes.").isEmpty)
    }

    func testFindingCarriesTheOneIndexedLine() {
        let findings = AutovisorGoalLint.scanStrict("first\nsecond\nthen call write_file")
        XCTAssertEqual(findings.map(\.line), [3])
    }

    // MARK: - The verb exemption

    /// `request_changes` is the `action` value of `manage_role`, which the
    /// manager HAS — every preset writes it legitimately.
    func testRequestChanges_isExemptAsAManageRoleVerb() {
        XCTAssertTrue(
            AutovisorGoalLint.scanStrict("Return it with `manage_role` request_changes.").isEmpty)
    }

    /// Guards the exemption itself: if the verb disappears from `manage_role`,
    /// `request_changes` becomes a plain unavailable tool again and the
    /// exemption must be revisited rather than silently blinding the lint.
    func testManageRoleStillDocumentsTheRequestChangesVerb() throws {
        let schema = ManageRoleTool.schema
        let described = schema.description
            + (schema.parameters.properties ?? [:]).values.compactMap(\.description).joined()
        XCTAssertTrue(described.contains(ToolNames.requestChanges),
                      "manage_role no longer documents the request_changes verb — the "
                          + "AutovisorGoalLint.verbExemptions entry is now hiding a real tool name")
    }

    // MARK: - Invented shell spellings

    /// The literal the model actually reached for in the reported incident.
    func testInventedShellSpelling_isFlagged() {
        XCTAssertEqual(
            tokens(AutovisorGoalLint.scanStrict("Then call run_shell_command with swift build.")),
            ["run_shell_command"])
    }

    /// Ordinary English must not be treated as an invented tool name.
    func testBareEnglishWords_areNotFlagged() {
        for text in ["Write a shell script in the brief.",
                     "Open a terminal window on the build machine.",
                     "Ask the team to make a plan."] {
            XCTAssertTrue(AutovisorGoalLint.scanStrict(text).isEmpty, text)
        }
    }

    // MARK: - Strict vs lenient

    /// The presets are authored here, so they get no suppression.
    func testStrict_doesNotSuppressDelegationLines() {
        let text = "In every brief, tell the worker to call write_file."
        XCTAssertEqual(tokens(AutovisorGoalLint.scanStrict(text)), ["write_file"])
    }

    /// A user goal that names a tool for its WORKERS is correct — workers have
    /// different toolsets — so the dismissible warning must stay quiet.
    func testLenient_suppressesToolNamesOnDelegationLines() {
        for text in ["In every brief, tell the worker to call write_file.",
                     "Each create_managed_task brief must permit edit_file.",
                     "The team may use run_xcodebuild to verify."] {
            XCTAssertTrue(AutovisorGoalLint.scanUserAuthored(text).isEmpty, text)
        }
    }

    /// …but a bare instruction with no delegation cue still warns.
    func testLenient_stillFlagsAnUnqualifiedToolName() {
        XCTAssertEqual(
            tokens(AutovisorGoalLint.scanUserAuthored("Then call write_file on the report.")),
            ["write_file"])
    }

    // MARK: - The phrase rule

    /// The reported incident, verbatim in shape. No identifier appears, so only
    /// this rule can catch it.
    func testSelfDirectedBuildClaim_catchesTheReportedIncident() {
        let findings = AutovisorGoalLint.scanUserAuthored(
            "Run the project's build command yourself and paste its final status line.")
        XCTAssertEqual(findings.map(\.kind), [.selfDirectedBuildClaim])
    }

    /// The rule's whole contract is "warn only about what the manager CANNOT do".
    /// When it gained the Xcode runners in 1.8.4, `buildVerbs` still held
    /// `xcodebuild` — so the lint reported a capability as a gap, on an icon the
    /// user cannot dismiss. Derived from the toolset, so it re-fires if the runners
    /// are ever granted under another spelling.
    func testSelfDirectedBuildClaim_neverWarnsAboutSomethingTheManagerCanRun() {
        XCTAssertTrue(AutovisorConstants.managerDefaultToolIDs.contains(ToolNames.runXcodebuild),
                      "premise: the manager runs Xcode builds")
        for text in ["Run xcodebuild yourself and report the result.",
                     "You run xcodebuild before deciding."] {
            XCTAssertTrue(AutovisorGoalLint.scanUserAuthored(text).isEmpty,
                          "the manager owns run_xcodebuild — warning here is the rule "
                              + "contradicting the toolset: \(text)")
        }
    }

    /// Delegation suppression, in parity with the identifier rule. The canonical
    /// goal the runners were admitted for names a task, and without this the tip
    /// warns about precisely the workflow the feature enables.
    func testSelfDirectedBuildClaim_isSuppressedOnADelegationLine() {
        for text in ["Build the project yourself, then open a task for whatever fails.",
                     "Compile it yourself each pass and delegate the fixes."] {
            XCTAssertTrue(AutovisorGoalLint.scanUserAuthored(text).isEmpty,
                          "a line addressed at the delegation workflow must not warn: \(text)")
        }
        // …and suppression must not swallow the real thing: no delegation cue, still fires.
        XCTAssertEqual(
            AutovisorGoalLint.scanUserAuthored("Run npm build yourself.").map(\.kind),
            [.selfDirectedBuildClaim],
            "the manager has no shell, so npm remains genuinely unreachable")
    }

    func testSelfDirectedBuildClaim_needsBothHalvesInOneSentence() {
        // Build verb, no self-directive.
        XCTAssertTrue(AutovisorGoalLint.scanUserAuthored("Audit the build settings.").isEmpty)
        // Self-directive, no build verb — every preset says this.
        XCTAssertTrue(AutovisorGoalLint.scanUserAuthored("Never fix anything yourself.").isEmpty)
        // Both, but in DIFFERENT sentences: the directive isn't about building.
        XCTAssertTrue(
            AutovisorGoalLint.scanUserAuthored("Never fix anything yourself. Audit the build.")
                .isEmpty)
    }

    /// Strict mode must never run the heuristic — the presets are pinned
    /// deterministically and an English phrase rule has no business there.
    func testStrict_neverEmitsAPhraseFinding() {
        let findings = AutovisorGoalLint.scanStrict(
            "Run the project's build command yourself.")
        XCTAssertTrue(findings.allSatisfy { $0.kind != .selfDirectedBuildClaim })
    }

    // MARK: - Degenerate input

    func testEmptyAndWhitespaceGoals_produceNoFindings() {
        for text in ["", "   ", "\n\n\n"] {
            XCTAssertTrue(AutovisorGoalLint.scanStrict(text).isEmpty)
            XCTAssertTrue(AutovisorGoalLint.scanUserAuthored(text).isEmpty)
        }
    }
}
