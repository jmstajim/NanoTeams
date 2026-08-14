import XCTest

@testable import NanoTeams

final class ToolCallLoopDetectorTests: XCTestCase {
    private typealias TN = ToolNames

    override func setUp() {
        super.setUp()
        MonotonicClock.shared.reset()
    }

    /// `epoch` is the information epoch the call was made in — production stamps every
    /// call with `ToolCallTracker.informationEpoch`, which advances when a queued
    /// Supervisor turn is delivered. Fixtures therefore raise it on the boundary call AND
    /// on everything after it, exactly as the tracker would.
    private func makeCall(
        _ toolName: String,
        args: String = "args",
        successful: Bool = true,
        epoch: Int = 0
    ) -> ToolCallTracker.TrackedCall {
        ToolCallTracker.TrackedCall(
            toolName: toolName,
            argumentsSummary: args,
            argumentsIdentity: ToolCallTracker.argumentsIdentity(forJSON: args),
            resultSummary: "result",
            resultJSON: "{}",
            wasSuccessful: successful,
            informationEpoch: epoch
        )
    }

    // MARK: - Tests

    func testDetectLoopPattern_returnsNilWhenFewerThan6Calls() {
        let calls = (0..<5).map { _ in makeCall(TN.readFile) }
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// Six DISTINCT reads are exploration, not a loop. This is the shipped opening of
    /// essentially every task — `list_files` then a handful of `read_file`s to orient in
    /// the work folder — and the planning-phase brief INSTRUCTS exactly this sequence.
    /// The deleted `.readOnlyLoop` arm was a pure tool-CATEGORY predicate (no argument
    /// identity at all), so it fired on this window every time and, standing first, also
    /// masked the identity-aware `.repetitiveTool` for all-read windows.
    ///
    /// RED: restore `if recentCalls.allSatisfy({ readOnlyTools.contains($0.toolName) })
    /// { return .readOnlyLoop }` as the first branch → this and both tests below go red.
    func testDetectLoopPattern_sixDistinctReads_areNotALoop() {
        let calls = [
            makeCall(TN.listFiles, args: #"{"path":"MeditationApp"}"#),
            makeCall(TN.readFile, args: #"{"path":"ContentView.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"Meditation.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"meditations.json"}"#),
            makeCall(TN.readFile, args: #"{"path":"MeditationPlayerModel.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"PlayerView.swift"}"#),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "six distinct reads are prescribed exploration, not a loop")
    }

    /// One file read TWICE among otherwise-distinct reads is still not a loop — a repeat
    /// count of 2 is below `repetitionMinIdenticalToolCalls` (3), and going back to one
    /// file once is ordinary work, not being stuck.
    func testDetectLoopPattern_oneRepeatAmongDistinctReads_isNotALoop() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"ContentView.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"Meditation.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"PlayerView.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"MeditationPlayerModel.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"MeditationPlayerModel.swift"}"#),
            makeCall(TN.listFiles, args: #"{"path":"MeditationApp"}"#),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    /// The unmasking side of the `.readOnlyLoop` removal: an all-read window now reaches
    /// the identity-aware branch, so the SAME read repeated 3× is reported as what it is
    /// — with the honest "identical arguments" advice instead of "were all reads".
    /// The run sits at the TAIL — the window state production fires on, since the check
    /// runs every iteration and catches the run as its third member lands.
    ///
    /// (The former sibling `testDetectLoopPattern_detectsRepetitiveTool` — 4 identical
    /// writes INTERLEAVED with a read, asserting a fire — was deleted with the frequency
    /// count: interleaved repeats are a workflow, not a loop, and its fixture was
    /// production-unreachable anyway — the identical-write rejection errors the repeats,
    /// and errored calls never counted.)
    func testDetectLoopPattern_identicalReadsInAllReadWindow_areARepetitiveToolLoop() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"b.swift"}"#),
            makeCall(TN.search, args: #"{"query":"foo"}"#),
            makeCall(TN.listFiles, args: #"{"path":"."}"#),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count) = result {
            XCTAssertEqual(tool, TN.readFile)
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected repetitiveTool for 3x identical read, got \(String(describing: result))")
        }
    }

    func testDetectLoopPattern_excludesScratchpadFromRepetition() {
        let calls = [
            makeCall(TN.updateScratchpad), makeCall(TN.updateScratchpad),
            makeCall(TN.updateScratchpad), makeCall(TN.updateScratchpad),
            makeCall(TN.readFile), makeCall(TN.writeFile),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        XCTAssertNil(result, "update_scratchpad should be excluded from repetitive tool detection")
    }

    // MARK: - Identity-based loop detection (regression EA190834)

    /// Regression: SWE made 7 `write_file` calls in a row, each writing a DIFFERENT path
    /// (package.json → vite.config.ts → tsconfig.json → public/index.html → src/main.tsx →
    /// src/evaluate.ts → src/components/Display.tsx). The previous detector counted only
    /// by tool name and falsely flagged this legitimate scaffolding as a loop. SWE saw
    /// the warning and gave up before completing the UI.
    func testDetectLoopPattern_doesNotFlagSameToolWithDifferentArguments() {
        let calls = [
            makeCall(TN.writeFile, args: "package.json"),
            makeCall(TN.writeFile, args: "vite.config.ts"),
            makeCall(TN.writeFile, args: "tsconfig.json"),
            makeCall(TN.writeFile, args: "public/index.html"),
            makeCall(TN.writeFile, args: "src/main.tsx"),
            makeCall(TN.writeFile, args: "src/evaluate.ts"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        XCTAssertNil(
            result,
            "write_file across distinct paths is normal scaffolding, not a loop"
        )
    }

    /// Positive case for new identity check: same tool + same args 3+ times IN A ROW
    /// → real loop. (Run at the tail — where production fires.)
    func testDetectLoopPattern_flagsIdenticalCallsRepeated() {
        let calls = [
            makeCall(TN.readFile, args: "elsewhere.swift"),
            makeCall(TN.gitStatus, args: "_"),
            makeCall(TN.search, args: "foo"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count) = result {
            XCTAssertEqual(tool, TN.writeFile)
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected repetitiveTool for 3x identical write, got \(String(describing: result))")
        }
    }

    // MARK: - Computer-use identity + advice (regression: LinkedIn run 2026-07-02)

    /// Regression: 4 `ui_click` calls at DIFFERENT coordinates ((1257,55), (1257,90),
    /// (1257,60), (1408,126)) were flagged as "identical arguments 4 times" — the summarizer
    /// had no ui_click entry, every argumentsSummary was "", and all clicks collapsed onto
    /// one identity key. The model was then told to "try different arguments" while it
    /// already was. Distinct coordinates must not be a loop.
    func testDetectLoopPattern_uiClicksAtDifferentCoordinates_notALoop() {
        let coords = ["(1257, 55)", "(1257, 90)", "(1257, 60)", "(1408, 126)", "(587, 61)", "(834, 190)"]
        let calls = coords.map { makeCall(TN.uiClick, args: $0) }
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    func testDetectLoopPattern_identicalUIClicks_adviseRecapture_notDifferentArguments() {
        // For GUI tools the cure for a true identical-click loop is a fresh screenshot —
        // the model is probing a UI it can no longer see. Run at the tail.
        let calls = [
            makeCall(TN.uiKey, args: "return"),
            makeCall(TN.uiType, args: "hello"),
            makeCall(TN.uiScroll, args: "(5, 5) d(0, -3)"),
            makeCall(TN.uiClick, args: "(100, 200)"),
            makeCall(TN.uiClick, args: "(100, 200)"),
            makeCall(TN.uiClick, args: "(100, 200)"),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        guard case .repetitiveTool(let tool, _) = result else {
            return XCTFail("Expected repetitiveTool, got \(String(describing: result))")
        }
        XCTAssertEqual(tool, TN.uiClick)
        // The ADVICE is asserted at the layer that now owns it. It used to live on the
        // detection value, where nothing knew the role's schema — which is how the same
        // function came to append "change the arguments" immediately after the GUI advice
        // that exists to say the opposite.
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: result!, allowedToolNames: [TN.uiClick, TN.screenCapture])
        XCTAssertTrue(message.contains("screen_capture"), "GUI loop advice must be re-capture")
        XCTAssertFalse(message.lowercased().contains("change the arguments"), message)
    }

    /// Regression: re-capturing the same target is the PRESCRIBED workflow (UI changes between
    /// calls). Counting screen_capture flagged the canonical capture→click→capture loop AND made
    /// the nudge advise the very action it flagged. It must be excluded like update_scratchpad.
    func testDetectLoopPattern_repeatedScreenCapture_notALoop() {
        let calls = [
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(10, 20)"),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(30, 40)"),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.uiClick, args: "(50, 60)"),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    func testDetectLoopPattern_nonGUITool_keepsDifferentArgumentsAdvice() {
        let calls = [
            makeCall(TN.readFile, args: "a"), makeCall(TN.readFile, args: "b"),
            makeCall(TN.search, args: "foo"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
            makeCall(TN.writeFile, args: "src/App.tsx"),
        ]
        guard let result = ToolCallLoopDetector.detectLoopPattern(in: calls),
              case .repetitiveTool = result else {
            return XCTFail("Expected repetitiveTool")
        }
        let message = LLMExecutionService.loopWarningMessage(
            loopDetection: result, allowedToolNames: [TN.writeFile, TN.readFile])
        XCTAssertTrue(message.contains("Change the arguments"), message)
        XCTAssertFalse(message.contains("screen_capture"), message)
    }

    // MARK: - Tail-anchored consecutive run (regression: edit→build cycle, 2026-08-11)

    private static let buildArgs = #"{"scheme":"MeditationApp"}"#

    /// Regression (2026-08-11 screenshot): a coding role alternating `edit_file` (a
    /// DIFFERENT change each time) with `run_xcodebuild` (identical arguments — build
    /// args are naturally constant) was told "you've called 'run_xcodebuild' with
    /// identical arguments 3 times and the state isn't changing". Both halves were
    /// false: every build followed a successful edit, and edit→verify-build is the
    /// PRESCRIBED coding workflow. A repeat the model RETURNS to after doing something
    /// else is a workflow; only a repeat with nothing between is a loop.
    ///
    /// RED: restore the frequency count (`Dictionary(grouping:)` + max-bucket ≥ 3 over
    /// the window) in `detectLoopPattern` → this test, the moved-past test, the
    /// run-breaking test, the bash_output test and the run-length count test go red.
    func testDetectLoopPattern_editBuildCycles_areNotALoop() {
        let calls = [
            makeCall(TN.editFile, args: #"{"path":"OnboardingStore.swift","old_text":"v0","new_text":"v1"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.editFile, args: #"{"path":"OnboardingStore.swift","old_text":"v1","new_text":"v2"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.editFile, args: #"{"path":"MeditationAppApp.swift","old_text":"v0","new_text":"v1"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "edit→build cycles are the prescribed coding workflow, not a loop")
    }

    /// A loop is ACTIVE only while it reaches the tail. A window whose identical run
    /// sits at the HEAD followed by three distinct calls describes a loop the model
    /// already left — and since the check runs every iteration, production fires at the
    /// run's own tail; this window shape only exists AFTER that moment.
    func testDetectLoopPattern_identicalRunTheModelMovedPast_isNotALoop() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"b.swift"}"#),
            makeCall(TN.search, args: #"{"query":"foo"}"#),
            makeCall(TN.editFile, args: #"{"path":"b.swift","old_text":"x","new_text":"y"}"#),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "a run the model already moved past is not an active loop")
    }

    /// A FAILED call between identical repeats does not break the run: it changed
    /// nothing, so identical rebuilds around it still describe an unchanged state
    /// honestly. (Counterpart: `testDetectLoopPattern_differentSuccessfulCallBreaksTheRun`.)
    ///
    /// RED: count failed calls as run-breakers (drop the `wasSuccessful` term from the
    /// filter so failed calls become visible) → this test goes red.
    func testDetectLoopPattern_failedCallInsideIdenticalRun_doesNotBreakTheRun() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"b.swift"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.editFile, args: #"{"path":"gone.swift","old_text":"x","new_text":"y"}"#, successful: false),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count) = result {
            XCTAssertEqual(tool, TN.runXcodebuild)
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("3 identical builds around a FAILED edit are a live loop, got \(String(describing: result))")
        }
    }

    /// A different SUCCESSFUL call between identical repeats breaks the run — it could
    /// have changed the state, so the repeat that follows it is justified re-verification.
    func testDetectLoopPattern_differentSuccessfulCallBreaksTheRun() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.readFile, args: #"{"path":"b.swift"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.readFile, args: #"{"path":"c.swift"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "a different successful call between repeats breaks the run")
    }

    /// EXCLUDED calls (`update_scratchpad`, `screen_capture`) are invisible in both
    /// directions: they don't count toward a run AND they don't break one. Noting
    /// results in the scratchpad or re-capturing the screen between identical builds
    /// changes no world state — the builds are still "3 times in a row".
    ///
    /// RED: make excluded calls run-breakers (filter only on `wasSuccessful`) → this
    /// test goes red.
    func testDetectLoopPattern_excludedCallsInsideIdenticalRun_doNotBreakTheRun() {
        let calls = [
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.updateScratchpad, args: #"{"content":"build attempt 1 failed"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count) = result {
            XCTAssertEqual(tool, TN.runXcodebuild)
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("excluded calls must not break the run, got \(String(describing: result))")
        }
    }

    /// `bash_output` polling is the contract `bash` itself prescribes: a background
    /// command's success envelope hands the model `bash_output` + the same command_id,
    /// and every read returns NEW incremental output — identical arguments are the
    /// tool's own documented usage, and "the state isn't changing" would be false.
    ///
    /// RED: drop `TN.bashOutput` from `excludedFromRepetition` → this test goes red.
    func testDetectLoopPattern_bashOutputPolling_isNotALoop() {
        let poll = #"{"command_id":"cmd-1"}"#
        let calls = [
            makeCall(TN.bash, args: #"{"command":"xcodebuild build","run_in_background":true}"#),
            makeCall(TN.bashOutput, args: poll),
            makeCall(TN.bashOutput, args: poll),
            makeCall(TN.bashOutput, args: poll),
            makeCall(TN.bashOutput, args: poll),
            makeCall(TN.bashOutput, args: poll),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "polling a background command with its own command_id is prescribed usage")
    }

    /// `count` is the TRAILING run length — how many times in a row the model just
    /// repeated itself — not the identity's frequency in the window.
    func testDetectLoopPattern_countIsTheTrailingRunLength() {
        let calls = [
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.readFile, args: #"{"path":"a.swift"}"#),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
            makeCall(TN.runXcodebuild, args: Self.buildArgs),
        ]
        let result = ToolCallLoopDetector.detectLoopPattern(in: calls)
        if case .repetitiveTool(let tool, let count) = result {
            XCTAssertEqual(tool, TN.runXcodebuild)
            XCTAssertEqual(count, 4, "the run was broken by the read at index 1 — 5 in the window, 4 in a row")
        } else {
            XCTFail("Expected repetitiveTool, got \(String(describing: result))")
        }
    }

    /// A full window whose every call is failed or excluded (but NOT all-scratchpad —
    /// that window belongs to `.repetitivePlanning`) has no visible calls to judge.
    /// Covers the empty-filtered-sequence branch. RED: none against production — the
    /// old frequency count returned nil here too (empty dictionary); this pins the new
    /// `guard let` branch for the coverage ratchet.
    func testDetectLoopPattern_windowWithNoVisibleCalls_isNotALoop() {
        let calls = [
            makeCall(TN.updateScratchpad, args: #"{"content":"plan v1"}"#),
            makeCall(TN.updateScratchpad, args: #"{"content":"plan v2"}"#),
            makeCall(TN.updateScratchpad, args: #"{"content":"plan v3"}"#),
            makeCall(TN.screenCapture, args: "Safari"),
            makeCall(TN.editFile, args: #"{"path":"a.swift","old_text":"x","new_text":"y"}"#, successful: false),
            makeCall(TN.editFile, args: #"{"path":"a.swift","old_text":"x2","new_text":"y2"}"#, successful: false),
        ]
        XCTAssertNil(ToolCallLoopDetector.detectLoopPattern(in: calls))
    }

    // MARK: - Information epoch (regression: Autovisor mid-review event notice, 2026-08-11)

    private static let poll = #"{"task_id":12}"#

    /// Regression (2026-08-11 screenshot): the Autovisor manager re-checked task #12
    /// because an event notice told it the task was waiting for an answer — and was told
    /// "identical arguments 3 times and the state isn't changing" one call after being
    /// told the state changed. A tool call is not the only way information reaches the
    /// model; an injected Supervisor turn carries none of its own.
    ///
    /// RED: drop the `call.informationEpoch == lastCall.informationEpoch` guard in
    /// `detectLoopPattern` → this test and the two boundary tests go red, and the count
    /// test reports 6.
    func testDetectLoopPattern_informationArrivedMidRun_breaksTheRun() {
        func window(afterInfo: Bool) -> [ToolCallTracker.TrackedCall] {
            [
                makeCall(TN.listTasks, args: "{}"),
                makeCall(TN.listFiles, args: #"{"path":"MeditationApp"}"#),
                makeCall(TN.search, args: #"{"query":"onboarding"}"#),
                makeCall(TN.taskStatus, args: Self.poll),
                makeCall(TN.taskStatus, args: Self.poll),
                makeCall(TN.taskStatus, args: Self.poll, epoch: afterInfo ? 1 : 0),
            ]
        }
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: window(afterInfo: true)),
            "a re-check prompted by an injected Supervisor turn is a reaction, not a loop")
        // Anti-vacuum: the SAME window without the boundary is still a loop, so the test
        // above proves the epoch did the work rather than the fixture being harmless.
        XCTAssertNotNil(
            ToolCallLoopDetector.detectLoopPattern(in: window(afterInfo: false)),
            "with nothing arriving between them, three identical polls are a loop")
    }

    /// The boundary resets the count; it does not grant immunity. A model that receives
    /// an event and then repeats one call three times anyway is looping — which matters
    /// because the actor events arrive for (the Autovisor manager) is exactly the actor
    /// the detector must still police.
    func testDetectLoopPattern_informationBeforeTheRun_stillFires() {
        let calls = [
            makeCall(TN.listTasks, args: "{}"),
            makeCall(TN.listFiles, args: #"{"path":"MeditationApp"}"#),
            makeCall(TN.search, args: #"{"query":"onboarding"}"#),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
        ]
        guard case .repetitiveTool(let tool, let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("three identical polls AFTER the event are still a loop") }
        XCTAssertEqual(tool, TN.taskStatus)
        XCTAssertEqual(count, 3, "the flagged call opens the epoch and belongs to the run")
    }

    /// The likeliest move right after an event is recording what was learned — and
    /// `update_scratchpad` is EXCLUDED from repetition, so a "this call opened an epoch"
    /// FLAG on it would be filtered away with the call. Stamping the epoch as an ordinal
    /// on every call makes the change visible on the next counted one for free.
    func testDetectLoopPattern_boundaryOnAnExcludedCall_stillBreaksTheRun() {
        let calls = [
            makeCall(TN.listTasks, args: "{}"),
            makeCall(TN.search, args: #"{"query":"onboarding"}"#),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.updateScratchpad, args: #"{"content":"noted"}"#, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "an excluded call between epochs must not hide the change from the run")
    }

    /// Same rule for a FAILED call: it is invisible to the run, so a flag on it would
    /// vanish with it — the ordinal survives on the calls that follow.
    func testDetectLoopPattern_boundaryOnAFailedCall_stillBreaksTheRun() {
        let calls = [
            makeCall(TN.listTasks, args: "{}"),
            makeCall(TN.search, args: #"{"query":"onboarding"}"#),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.messageTask, args: #"{"task_id":12,"message":"go"}"#,
                     successful: false, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
        ]
        XCTAssertNil(
            ToolCallLoopDetector.detectLoopPattern(in: calls),
            "a failed call between epochs must not hide the change from the run")
    }

    /// `count` is the run length WITHIN the current epoch — the number of times the model
    /// repeated itself knowing what it knows now, which is what the warning claims.
    func testDetectLoopPattern_countStopsAtTheEpochBoundary() {
        let calls = [
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
            makeCall(TN.taskStatus, args: Self.poll, epoch: 1),
        ]
        guard case .repetitiveTool(_, let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("six identical polls are a loop in any epoch") }
        XCTAssertEqual(count, 4, "counts back to the boundary, not through it")
    }

    // MARK: - epochOfTrailingRun (what the warn-once gate keys on)

    /// It reports the epoch of the newest call the detector can SEE — not the tracker's
    /// current epoch, which advances the moment a Supervisor turn is delivered and so
    /// moves while the run is still entirely pre-arrival.
    ///
    /// RED: return the last call's epoch without the visibility filter → the excluded and
    /// failed cases below report 1, and the loop-warning gate re-states an identical
    /// warning about a run made before the news.
    func testEpochOfTrailingRun_ignoresInvisibleCalls() {
        let preArrivalRun = [
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll),
            makeCall(TN.taskStatus, args: Self.poll),
        ]
        XCTAssertEqual(ToolCallLoopDetector.epochOfTrailingRun(in: preArrivalRun), 0)

        let thenAnExcludedCall = preArrivalRun
            + [makeCall(TN.updateScratchpad, args: #"{"content":"noted"}"#, epoch: 1)]
        XCTAssertEqual(
            ToolCallLoopDetector.epochOfTrailingRun(in: thenAnExcludedCall), 0,
            "an excluded call is not the run moving into the new epoch")

        let thenAFailedCall = preArrivalRun
            + [makeCall(TN.readFile, args: "x.swift", successful: false, epoch: 1)]
        XCTAssertEqual(
            ToolCallLoopDetector.epochOfTrailingRun(in: thenAFailedCall), 0,
            "a failed call is not the run moving into the new epoch")

        let thenARealCall = preArrivalRun + [makeCall(TN.taskStatus, args: Self.poll, epoch: 1)]
        XCTAssertEqual(
            ToolCallLoopDetector.epochOfTrailingRun(in: thenARealCall), 1,
            "a visible call under the new information IS the run moving")
    }

    func testEpochOfTrailingRun_noVisibleCalls_isZero() {
        XCTAssertEqual(ToolCallLoopDetector.epochOfTrailingRun(in: []), 0)
        XCTAssertEqual(
            ToolCallLoopDetector.epochOfTrailingRun(
                in: [makeCall(TN.updateScratchpad, args: "{}", epoch: 3)]),
            0)
    }

    /// The epoch bounds `.repetitiveTool` and NOTHING ELSE. `.repetitivePlanning` returns
    /// from an earlier arm and is deliberately unbounded: six consecutive scratchpad
    /// rewrites are a role re-planning instead of acting no matter what arrived while it
    /// did so — being told something is a reason to act on it, not to re-plan six times.
    ///
    /// The arm is also unreachable from the epoch code by construction, since
    /// `update_scratchpad` is in `excludedFromRepetition`; this pins the DECISION so a
    /// future "make the boundary uniform" edit has to argue with a test.
    ///
    /// RED: move the epoch bound above the planning arm, or apply it there → this fails.
    func testDetectLoopPattern_planningRun_isNotBoundedByTheEpoch() {
        var calls = (0..<ToolCallLoopDetector.windowSize).map { i in
            makeCall(TN.updateScratchpad, args: "plan-\(i)")
        }
        for i in (ToolCallLoopDetector.windowSize - 2)..<ToolCallLoopDetector.windowSize {
            calls[i] = makeCall(TN.updateScratchpad, args: "plan-\(i)", epoch: 1)
        }
        guard case .repetitivePlanning(let count)? =
            ToolCallLoopDetector.detectLoopPattern(in: calls)
        else { return XCTFail("an all-scratchpad window is re-planning regardless of the epoch") }
        XCTAssertEqual(count, ToolCallLoopDetector.windowSize,
                       "the planning arm counts the whole window, not back to a boundary")
    }
}
