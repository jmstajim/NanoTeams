import XCTest

@testable import NanoTeams

/// The orchestrator's small, single-statement surfaces: the `LLMStateDelegate`
/// forwarders in `+StepExecution`, the UI-helper setters and derived getters in
/// the core file, and the two pure seams extracted out of
/// `XcodeBuildHelpers.fetchAvailableSchemes`.
///
/// None of these had a test, and each one is the sole implementation of a
/// contract some other subsystem relies on being true — a forwarder that
/// forwards to the wrong slot (`lastErrorMessage` vs `lastInfoMessage`) is a red
/// banner where the design says neutral, and it compiles.
///
/// Everything runs against a temp directory created in `setUp`; nothing touches
/// the network or the developer's real work folder.
@MainActor
final class OrchestratorDelegateSurfaceTests: NTMSOrchestratorTestBase, @unchecked Sendable {

    // MARK: - Banner forwarders (`+StepExecution`)

    func testSetLastErrorMessageForUI_writesTheErrorSlot() {
        sut.setLastErrorMessageForUI("disk is on fire")

        XCTAssertEqual(sut.lastErrorMessage, "disk is on fire")
        XCTAssertNil(sut.lastInfoMessage, "an error must not also raise the neutral banner")
    }

    func testSetLastInfoMessageForUI_writesTheInfoSlot() {
        sut.setLastInfoMessageForUI("model ready")

        XCTAssertEqual(sut.lastInfoMessage, "model ready")
        XCTAssertNil(sut.lastErrorMessage, "an info notice must not render as a red banner")
    }

    // MARK: - `reportPrefixCacheMiss`

    /// The counter always moves; the banner is the reporter's decision. This is
    /// the arm where the reporter declines (the miss belongs to no on-screen
    /// task), and the orchestrator must NOT invent a banner of its own.
    func testReportPrefixCacheMiss_whenReporterDeclines_countsButDoesNotBanner() {
        sut.prefixCacheReporter.onScreenTaskID = nil

        sut.reportPrefixCacheMiss(makeMiss(taskID: 7, runID: 0))

        XCTAssertEqual(sut.prefixCacheReporter.missCount, 1)
        XCTAssertNil(sut.lastErrorMessage)
    }

    /// The arm where the reporter earns a banner: the miss is on the task the
    /// user is looking at, and its text reaches `lastErrorMessage`.
    func testReportPrefixCacheMiss_whenReporterEarnsABanner_surfacesItsText() {
        sut.prefixCacheReporter.onScreenTaskID = 7

        sut.reportPrefixCacheMiss(makeMiss(taskID: 7, runID: 0))

        XCTAssertEqual(sut.prefixCacheReporter.missCount, 1)
        XCTAssertTrue(
            sut.lastErrorMessage?.contains("test-model") == true,
            "the banner names the model that had to re-prefill; got \(sut.lastErrorMessage ?? "nil")")
    }

    /// Repetition is idempotent on the banner (one per task+run+cause) but never
    /// on the count — that asymmetry is the reason the pill exists beside the
    /// 4-second single-slot banner.
    func testReportPrefixCacheMiss_repeated_countsTwiceButBannersOnce() {
        sut.prefixCacheReporter.onScreenTaskID = 7

        sut.reportPrefixCacheMiss(makeMiss(taskID: 7, runID: 0))
        sut.lastErrorMessage = nil
        sut.reportPrefixCacheMiss(makeMiss(taskID: 7, runID: 0))

        XCTAssertEqual(sut.prefixCacheReporter.missCount, 2)
        XCTAssertNil(sut.lastErrorMessage, "second identical miss must not re-banner")
    }

    // MARK: - `recordPrefixChainForTasklessCall`

    /// The taskless registration hop exists so a `.chain` owner (a consultation,
    /// a meeting turn, the delegated Supervisor answer) can detect its own
    /// misses. Its contract is that the chain lands on THIS orchestrator's ledger
    /// — never a process-global one — so a second request with a diverging
    /// prefix has something to be compared against.
    func testRecordPrefixChainForTasklessCall_registersOnThisOrchestratorsLedger() async {
        let owner = LLMCallOwner.chain(id: "consultation-1")
        let config = LLMConfig(baseURLString: "http://127.0.0.1:1234", modelName: "m")

        await sut.recordPrefixChainForTasklessCall(
            owner: owner, config: config,
            messages: [ChatMessage(role: .system, content: "sys")])

        // A second, DIVERGING request on the same owner is the only observation
        // that proves the first one was stored: with nothing recorded, the ledger
        // answers `.firstRequestForOwner`, which is never a miss.
        let observation = await sut.llmExecutionService.prefixLedger.record(
            baseURL: config.baseURLString, model: config.modelName, owner: owner,
            messages: [ChatMessage(role: .system, content: "DIFFERENT")],
            toolSchemaText: "")

        guard case .missed = observation.structural else {
            return XCTFail(
                "expected the first chain to be on the ledger; got \(observation.structural)")
        }
    }

    // MARK: - Core UI helpers

    /// `maxLLMRetries` is a two-way `LLMStateDelegate` slot: the execution
    /// service reads it every retry and the setter must reach the persisted
    /// configuration, not a shadow copy on the orchestrator.
    func testMaxLLMRetries_setterWritesThroughToConfiguration() {
        sut.maxLLMRetries = 4

        XCTAssertEqual(sut.configuration.maxLLMRetries, 4)
        XCTAssertEqual(sut.maxLLMRetries, 4)
    }

    func testSelectRole_armsThePendingSelection() {
        XCTAssertNil(sut.pendingRoleSelection)

        sut.selectRole(roleID: "engineer")

        XCTAssertEqual(sut.pendingRoleSelection, "engineer")
    }

    func testSelectedRunSnapshot_withNoActiveTask_isNil() {
        XCTAssertNil(sut.selectedRunSnapshot)
    }

    func testSelectedRunSnapshot_followsSelectedRunID() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        await sut.switchTask(to: taskID)
        await sut.mutateTask(taskID: taskID) { task in
            task.runs = [Run(id: 0, steps: []), Run(id: 1, steps: [])]
        }

        sut.selectedRunID = 0
        XCTAssertEqual(sut.selectedRunSnapshot?.id, 0)

        sut.selectedRunID = 1
        XCTAssertEqual(sut.selectedRunSnapshot?.id, 1)
    }

    func testHasInFlightRun_withNothingLoaded_isFalse() {
        XCTAssertFalse(sut.hasInFlightRun(forTeamID: NTMSID.from(name: "nobody")))
    }

    /// The Team Editor refuses an edit that would invalidate a live run, so a
    /// false negative here silently corrupts a running task's roster.
    func testHasInFlightRun_withARunningStepPinnedToTheTeam_isTrue() async {
        await sut.openWorkFolder(tempDir)
        guard let taskID = await sut.createTask(title: "t", supervisorTask: "brief") else {
            return XCTFail("task creation failed")
        }
        await sut.switchTask(to: taskID)
        let teamID = NTMSID.from(name: "busy-team")
        await sut.mutateTask(taskID: taskID) { task in
            var run = Run(
                id: 0,
                steps: [
                    StepExecution(id: "r", role: .softwareEngineer, title: "Engineer", status: .running)
                ])
            run.teamID = teamID
            task.runs = [run]
        }

        XCTAssertTrue(sut.hasInFlightRun(forTeamID: teamID))
        XCTAssertFalse(
            sut.hasInFlightRun(forTeamID: NTMSID.from(name: "other-team")),
            "the scan must be scoped to the pinned team, not 'is anything running'")
    }

    // MARK: - `XcodeBuildHelpers` pure seams

    func testListArguments_prefersWorkspaceOverProject() {
        let args = XcodeBuildHelpers.listArguments(
            forDirectoryContents: ["App.xcodeproj", "README.md", "App.xcworkspace"])

        XCTAssertEqual(args, ["-list", "-workspace", "App.xcworkspace"])
    }

    func testListArguments_projectOnly() {
        let args = XcodeBuildHelpers.listArguments(forDirectoryContents: ["App.xcodeproj", "src"])

        XCTAssertEqual(args, ["-list", "-project", "App.xcodeproj"])
    }

    /// `nil`, not `["-list"]`: a bare `xcodebuild -list` in a directory with no
    /// project is a subprocess spawned to learn nothing, and the caller skips the
    /// `Task.detached` entirely on this answer.
    func testListArguments_neitherWorkspaceNorProject_isNil() {
        XCTAssertNil(XcodeBuildHelpers.listArguments(forDirectoryContents: ["README.md", "src"]))
        XCTAssertNil(XcodeBuildHelpers.listArguments(forDirectoryContents: []))
    }

    /// A directory entry that merely *contains* the suffix elsewhere must not
    /// match — `.xcodeproj.bak` is a backup, not a project.
    func testListArguments_suffixMatchIsAnchoredAtTheEnd() {
        XCTAssertNil(
            XcodeBuildHelpers.listArguments(
                forDirectoryContents: ["App.xcodeproj.bak", "notes.xcworkspace.txt"]))
    }

    func testParseSchemes_realXcodebuildListShape() {
        let stdout = """
        Information about project "NanoTeams":
            Targets:
                NanoTeams
                NanoTeamsTests
        
            Build Configurations:
                Debug
                Release
        
            If no build configuration is specified and -scheme is not passed then "Release" is used.
        
            Schemes:
                NanoTeams
                NanoTeamsUITests
        
        """

        XCTAssertEqual(
            XcodeBuildHelpers.parseSchemes(fromListOutput: stdout),
            ["NanoTeams", "NanoTeamsUITests"])
    }

    /// The list ends at the first blank line. Without that stop, every later
    /// section of `-list` output would be reported as a scheme.
    func testParseSchemes_stopsAtTheFirstBlankLineAfterTheHeader() {
        let stdout = """
        Schemes:
            Alpha
        
            Beta
        """

        XCTAssertEqual(XcodeBuildHelpers.parseSchemes(fromListOutput: stdout), ["Alpha"])
    }

    /// A line carrying `:` is another section header, and it ENDS the scheme block.
    ///
    /// This used to skip the header and keep scanning, which returned `["Alpha", "Beta"]`
    /// for the fixture below. That is unsafe in the direction that matters: everything
    /// after a header belongs to that header's section, so on real `-list` output the rule
    /// reports `Debug` and `Release` as schemes — and both callers feed the result to
    /// `xcodebuild -scheme`, where a phantom name fails the build citing a scheme the user
    /// never configured. Stopping can only under-report a shape `xcodebuild` does not emit
    /// (measured: `Schemes:` is its last section).
    ///
    /// RED: restore the skip → `Beta` reappears, and with a realistic fixture so do the
    /// build configurations.
    func testParseSchemes_stopsAtAColonBearingSectionHeader() {
        let stdout = """
        Schemes:
            Alpha
            Targets:
            Beta
        """

        XCTAssertEqual(XcodeBuildHelpers.parseSchemes(fromListOutput: stdout), ["Alpha"])
    }

    /// The failure mode the rule above prevents, on the shape `xcodebuild` really emits when
    /// a section follows the scheme list.
    func testParseSchemes_neverReportsAnotherSectionsContentsAsSchemes() {
        let stdout = """
        Schemes:
            App
            Build Configurations:
                Debug
                Release
        """

        XCTAssertEqual(
            XcodeBuildHelpers.parseSchemes(fromListOutput: stdout), ["App"],
            "Debug/Release are build configurations; passing either to -scheme fails the build")
    }

    func testParseSchemes_noSchemesHeader_isEmpty() {
        XCTAssertTrue(
            XcodeBuildHelpers.parseSchemes(fromListOutput: "Targets:\n    App\n").isEmpty)
        XCTAssertTrue(XcodeBuildHelpers.parseSchemes(fromListOutput: "").isEmpty)
    }

    /// `xcodebuild` indents the header; a `hasPrefix` check would miss it.
    func testParseSchemes_indentedHeaderIsRecognised() {
        XCTAssertEqual(
            XcodeBuildHelpers.parseSchemes(fromListOutput: "        Schemes:\n            Solo\n"),
            ["Solo"])
    }

    /// End-to-end through the orchestrator: a folder with no project must answer
    /// "no schemes" without ever spawning `xcodebuild`.
    func testFetchAvailableSchemes_folderWithNoProject_returnsEmpty() async {
        await sut.openWorkFolder(tempDir)

        let schemes = await sut.fetchAvailableSchemes()

        XCTAssertTrue(schemes.isEmpty)
    }

    // MARK: - Helpers

    private func makeMiss(taskID: Int, runID: Int) -> PrefixCacheMiss {
        PrefixCacheMiss(
            owner: .step(taskID: taskID, stepID: "engineer"),
            runID: runID,
            modelName: "test-model",
            diagnosis: PrefixCachePolicy.Diagnosis(
                cause: .systemPromptChanged,
                commonSegments: 0,
                previousSegments: 12,
                discardedTokens: 9000))
    }
}
