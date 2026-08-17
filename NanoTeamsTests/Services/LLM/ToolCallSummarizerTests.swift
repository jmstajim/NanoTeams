import XCTest
@testable import NanoTeams

final class ToolCallSummarizerTests: XCTestCase {

    private typealias TN = ToolNames

    // MARK: - summarizeArguments

    func testSummarizeArguments_readFile_showsPath() {
        let json = """
        {"path": "/src/main.swift"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readFile, json: json), "/src/main.swift")
    }

    /// The summary is the loop detector's identity key
    /// (`ToolCallLoopDetector` groups by `toolName + argumentsSummary` and warns
    /// at three). This used to be the bare path, so three ordinary edits to one
    /// file — how a role actually works — grouped as one repeated call and the
    /// model was told "the state isn't changing, try different arguments or move
    /// on". The anchor is what makes them distinct, and it is the useful thing
    /// to show on the card besides.
    func testSummarizeArguments_editFile_showsPathAndAnchor() {
        let json = """
        {"path": "/src/file.swift", "old_text": "a", "new_text": "b"}
        """
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json),
            "/src/file.swift ‹a›")
    }

    func testSummarizeArguments_editFile_differentAnchorsInOneFileAreDistinct() {
        let a = ToolCallSummarizer.summarizeArguments(
            toolName: TN.editFile,
            json: #"{"path": "/src/file.swift", "old_text": "func alpha()", "new_text": "x"}"#)
        let b = ToolCallSummarizer.summarizeArguments(
            toolName: TN.editFile,
            json: #"{"path": "/src/file.swift", "old_text": "func beta()", "new_text": "y"}"#)
        let c = ToolCallSummarizer.summarizeArguments(
            toolName: TN.editFile,
            json: #"{"path": "/src/file.swift", "old_text": "func gamma()", "new_text": "z"}"#)

        XCTAssertEqual(Set([a, b, c]).count, 3,
                       "three different edits to one file must not group as one repeated call")
    }

    /// A genuinely repeated identical edit still collapses — the detector is
    /// supposed to catch that one.
    func testSummarizeArguments_editFile_identicalCallsStillShareAnIdentity() {
        let json = #"{"path": "/src/file.swift", "old_text": "a", "new_text": "b"}"#
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json),
            ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json))
    }

    /// Anchors are multi-line in practice; the summary is a one-line card label,
    /// so whitespace collapses and the tail is cut.
    func testSummarizeArguments_editFile_multilineAnchorIsSquashedAndCapped() {
        let json = #"{"path": "/a.swift", "old_text": "let x = 1\n\n    let y = 2\n\n    let z = 3456789", "new_text": "q"}"#
        let summary = ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json)

        XCTAssertFalse(summary.contains("\n"), "a card label is one line: \(summary)")
        XCTAssertTrue(summary.hasPrefix("/a.swift ‹let x = 1 let y = 2"), "got: \(summary)")
        XCTAssertLessThanOrEqual(summary.count, "/a.swift ‹›".count + 32)
    }

    /// No anchor to distinguish by — fall back to the path rather than inventing
    /// a discriminator that would make every such call look unique.
    func testSummarizeArguments_editFile_missingOrBlankAnchor_fallsBackToPath() {
        for json in [
            #"{"path": "/src/file.swift", "new_text": "b"}"#,
            #"{"path": "/src/file.swift", "old_text": "", "new_text": "b"}"#,
            #"{"path": "/src/file.swift", "old_text": "   ", "new_text": "b"}"#,
        ] {
            XCTAssertEqual(
                ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json),
                "/src/file.swift", "got a discriminator from: \(json)")
        }
    }

    func testSummarizeArguments_writeFile_showsPath() {
        let json = """
        {"path": "/src/new.swift", "content": "hello"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.writeFile, json: json), "/src/new.swift")
    }

    func testSummarizeArguments_gitCommit_showsMessage() {
        let json = """
        {"message": "fix: resolve null pointer"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.gitCommit, json: json), "fix: resolve null pointer")
    }

    func testSummarizeArguments_gitCommit_truncatesLongMessage() {
        let json = """
        {"message": "This is a very long commit message that exceeds thirty characters"}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.gitCommit, json: json)
        XCTAssertTrue(result.hasSuffix("..."))
        XCTAssertTrue(result.count <= 34) // 30 + "..."
    }

    func testSummarizeArguments_listFiles_showsPath() {
        let json = """
        {"path": "/src"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.listFiles, json: json), "/src")
    }

    func testSummarizeArguments_listFiles_defaultsDot() {
        let json = "{}"
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.listFiles, json: json), ".")
    }

    func testSummarizeArguments_search_showsQuery() {
        let json = """
        {"query": "TODO"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.search, json: json), "\"TODO\"")
    }

    func testSummarizeArguments_search_withPaths() {
        let json = """
        {"query": "import", "paths": ["/a", "/b", "/c"]}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.search, json: json), "\"import\" in 3 paths")
    }

    func testSummarizeArguments_gitAdd_singleFile() {
        let json = """
        {"paths": ["file.swift"]}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.gitAdd, json: json), "file.swift")
    }

    func testSummarizeArguments_gitAdd_multipleFiles() {
        let json = """
        {"paths": ["a.swift", "b.swift", "c.swift"]}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.gitAdd, json: json), "3 files")
    }

    /// RED: re-add a `dict["scheme"]` entry for either Xcode tool → this fires.
    ///
    /// This replaces `testSummarizeArguments_runXcodebuild_showsScheme`, which asserted
    /// `{"scheme":"NanoTeams"}` → `"scheme: NanoTeams"` against an input no caller can
    /// produce: `RunXcodebuildTool.schema` is `JS.object(properties: [:])`
    /// (`XcodeHandlers.swift:13`), and the scheme is resolved from `settings.json` by
    /// `XcodeBuildRunner.resolveSchemes` — never from an argument. The old entry could
    /// therefore never fire, so both cards always rendered bare while a green test said
    /// otherwise. Pinning the fixture the tool actually receives (`{}`) is what makes the
    /// membership in `toolsWithoutArgumentSummary` honest.
    func testSummarizeArguments_xcodeRunners_takeNoArgumentsAndSayNothing() {
        for tool in [TN.runXcodebuild, TN.runXcodetests] {
            XCTAssertEqual(
                ToolCallSummarizer.summarizeArguments(toolName: tool, json: "{}"), "",
                "\(tool) declares no parameters — there is nothing to summarize")
            XCTAssertFalse(
                ToolCallSummarizer.hasArgumentSummarizer(for: tool),
                "\(tool) must have no entry, not an entry that cannot fire")
            XCTAssertTrue(ToolCallSummarizer.toolsWithoutArgumentSummary.contains(tool))
        }
    }

    func testSummarizeArguments_createArtifact_returnsEmpty() {
        let json = """
        {"name": "Requirements Doc", "content": "..."}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.createArtifact, json: json), "")
    }

    // MARK: - readLines

    func testSummarizeArguments_readLines_showsPathAndRange() {
        let json = """
        {"path": "index.html", "start_line": 1, "end_line": 573}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "index.html 1:573")
    }

    func testSummarizeArguments_readLines_startOnly() {
        let json = """
        {"path": "file.swift", "start_line": 10}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "file.swift 10:")
    }

    func testSummarizeArguments_readLines_endOnly() {
        let json = """
        {"path": "file.swift", "end_line": 50}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "file.swift :50")
    }

    func testSummarizeArguments_readLines_pathOnly() {
        let json = """
        {"path": "file.swift"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "file.swift")
    }

    // MARK: - Bool / array args in the identity key
    //
    // Same hazard as the string-encoded ranges below: once the handler coerces
    // a quoted bool or a bare-string list, a summarizer still on the strict cast
    // drops that argument, and two calls that differ only in it collapse to one
    // loop-detector identity.

    func testSummarizeArguments_uiClick_stringEncodedDouble_distinguishesFromSingle() {
        let single = """
        {"x": 10, "y": 20}
        """
        let double = """
        {"x": 10, "y": 20, "double": "true"}
        """
        let s = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: single)
        let d = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: double)
        XCTAssertTrue(d.contains("double"), "string-encoded double must show in the summary. Got: \(d)")
        XCTAssertNotEqual(s, d, "a double-click must not share an identity with a single click")
    }

    func testSummarizeArguments_search_bareStringPath_isScoped() {
        let json = """
        {"query": "target", "paths": "src"}
        """
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.search, json: json),
            "\"target\" in 1 paths"
        )
    }

    func testSummarizeArguments_gitAdd_bareStringPath_namesTheFile() {
        let json = """
        {"paths": "a.swift"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.gitAdd, json: json), "a.swift")
    }

    func testSummarizeArguments_gitAdd_bareStringPaths_distinctPerFile() {
        let a = ToolCallSummarizer.summarizeArguments(toolName: TN.gitAdd, json: "{\"paths\": \"a.swift\"}")
        let b = ToolCallSummarizer.summarizeArguments(toolName: TN.gitAdd, json: "{\"paths\": \"b.swift\"}")
        XCTAssertNotEqual(a, b, "staging different files must not share one identity")
    }

    func testSummarizeArguments_requestTeamMeeting_bareStringParticipant_counted() {
        let json = """
        {"topic": "", "participants": "Tech Lead"}
        """
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json),
            "1 participants"
        )
    }

    // MARK: - readLines: string-encoded bounds (loop-detector identity)
    //
    // `TrackedCall.argumentsSummary` IS the loop detector's identity key
    // (`ToolCallLoopDetector` groups by `toolName + argumentsSummary`). The
    // handler coerces string-encoded numerics, so the summarizer must too —
    // otherwise every page of a paginated read collapses to the bare path and
    // distinct calls are counted as a repetition loop. Same hazard the
    // `ui_click` / `ui_scroll` entries already guard against.

    func testSummarizeArguments_readLines_stringEncodedRange_showsRange() {
        let json = """
        {"path": "doc.md", "start_line": "501", "end_line": "754"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "doc.md 501:754")
    }

    func testSummarizeArguments_readLines_paginatedStringPages_haveDistinctIdentities() {
        let page1 = """
        {"path": "doc.md", "start_line": "1", "end_line": "500"}
        """
        let page2 = """
        {"path": "doc.md", "start_line": "501", "end_line": "1000"}
        """
        let s1 = ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: page1)
        let s2 = ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: page2)
        XCTAssertNotEqual(s1, s2, "legitimate pagination must not collapse into one loop-detector identity")
    }

    func testSummarizeArguments_readLines_fractionalBounds_matchHandlerTruncation() {
        // The handler truncates toward zero; the summary must show the same
        // number the tool actually read.
        let json = """
        {"path": "doc.md", "start_line": 10.9, "end_line": 20.9}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readLines, json: json), "doc.md 10:20")
    }

    // MARK: - listFiles depth

    func testSummarizeArguments_listFiles_stringEncodedDepth_showsDepth() {
        let json = """
        {"path": "/src", "depth": "2"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.listFiles, json: json), "/src depth:2")
    }

    func testSummarizeArguments_listFiles_showsDepth() {
        let json = """
        {"path": "/src", "depth": 2}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.listFiles, json: json), "/src depth:2")
    }

    func testSummarizeArguments_listFiles_emptyPathDefaultsDot() {
        let json = """
        {"path": "", "depth": 1}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.listFiles, json: json), ". depth:1")
    }

    // MARK: - askTeammate

    func testSummarizeArguments_askTeammate_builtInRole() {
        let json = """
        {"teammate": "softwareEngineer", "question": "How?"}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.askTeammate, json: json)
        XCTAssertEqual(result, "Software Engineer")
    }

    func testSummarizeArguments_askTeammate_unknownFallsBackToID() {
        let json = """
        {"teammate": "some_custom_id", "question": "How?"}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.askTeammate, json: json)
        XCTAssertEqual(result, "some_custom_id")
    }

    func testSummarizeArguments_askTeammate_withResolver() {
        let json = """
        {"teammate": "custom_uuid_123", "question": "How?"}
        """
        let result = ToolCallSummarizer.summarizeArguments(
            toolName: TN.askTeammate, json: json,
            resolveRoleName: { _ in "My Custom Role" }
        )
        XCTAssertEqual(result, "My Custom Role")
    }

    // MARK: - requestChanges

    func testSummarizeArguments_requestChanges_builtInRole() {
        let json = """
        {"target_role": "softwareEngineer", "changes": "fix bug"}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestChanges, json: json)
        XCTAssertEqual(result, "Software Engineer")
    }

    func testSummarizeArguments_requestChanges_withResolver() {
        let json = """
        {"target_role": "faang_team_swe", "changes": "fix bug"}
        """
        let result = ToolCallSummarizer.summarizeArguments(
            toolName: TN.requestChanges, json: json,
            resolveRoleName: { _ in "Backend Engineer" }
        )
        XCTAssertEqual(result, "Backend Engineer")
    }

    // MARK: - requestTeamMeeting

    func testSummarizeArguments_requestTeamMeeting_topicAndCount() {
        let json = """
        {"topic": "Design review", "participants": ["pm", "techLead", "softwareEngineer"]}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json)
        XCTAssertEqual(result, "Design review · 3")
    }

    func testSummarizeArguments_requestTeamMeeting_topicOnly_noParticipants() {
        let json = """
        {"topic": "Sync", "participants": []}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json)
        XCTAssertEqual(result, "Sync")
    }

    func testSummarizeArguments_requestTeamMeeting_longTopicTruncated() {
        let longTopic = String(repeating: "x", count: 60)
        let json = """
        {"topic": "\(longTopic)", "participants": ["pm"]}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json)
        // 40 chars + "..." + " · 1"
        XCTAssertEqual(result, String(repeating: "x", count: 40) + "... · 1")
    }

    func testSummarizeArguments_requestTeamMeeting_missingTopic_showsCountOnly() {
        let json = """
        {"participants": ["pm", "techLead"]}
        """
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json)
        XCTAssertEqual(result, "2 participants")
    }

    func testSummarizeArguments_requestTeamMeeting_empty() {
        let json = "{}"
        let result = ToolCallSummarizer.summarizeArguments(toolName: TN.requestTeamMeeting, json: json)
        XCTAssertEqual(result, "")
    }

    // MARK: - resolveRoleName does not affect other tools

    func testSummarizeArguments_resolverIgnoredForNonRoleTools() {
        let json = """
        {"path": "/src/main.swift"}
        """
        let result = ToolCallSummarizer.summarizeArguments(
            toolName: TN.readFile, json: json,
            resolveRoleName: { _ in "SHOULD NOT APPEAR" }
        )
        XCTAssertEqual(result, "/src/main.swift")
    }

    func testSummarizeArguments_bash_showsCommand() {
        let json = """
        {"command": "ls -la /src"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.bash, json: json), "ls -la /src")
    }

    func testSummarizeArguments_bash_collapsesMultilineCommand() {
        let json = """
        {"command": "echo a &&\\n  echo b"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.bash, json: json), "echo a && echo b")
    }

    func testSummarizeArguments_bash_resolvesAliasKey() {
        // The gate + handler resolve the command via BashArguments.command(from:),
        // which honors alias keys; the card must show the same command.
        let json = """
        {"text": "git status"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.bash, json: json), "git status")
    }

    func testSummarizeArguments_bash_missingCommand_returnsEmpty() {
        let json = """
        {"timeout": 1000}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.bash, json: json), "")
    }

    func testSummarizeArguments_unknownTool_returnsEmpty() {
        let json = """
        {"foo": "bar"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: "unknown_tool", json: json), "")
    }

    func testSummarizeArguments_invalidJSON_returnsQuestionMark() {
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.readFile, json: "broken"), "?")
    }

    // MARK: - summarizeResult

    func testSummarizeResult_gitStatus_clean() {
        let json = """
        {"data": {"branch": "main", "clean": true}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.gitStatus, json: json), "clean on main")
    }

    func testSummarizeResult_gitStatus_dirty() {
        let json = """
        {"data": {"branch": "feature", "clean": false}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.gitStatus, json: json), "dirty on feature")
    }

    func testSummarizeResult_runXcodebuild_success() {
        let json = """
        {"data": {"success": true, "error_count": 0}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.runXcodebuild, json: json), "success")
    }

    func testSummarizeResult_runXcodebuild_failure() {
        let json = """
        {"data": {"success": false, "error_count": 3}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.runXcodebuild, json: json), "failed (3 errors)")
    }

    func testSummarizeResult_readFile_showsLineRange_whenTruncated() {
        let json = """
        {"data": {"end_line": 100, "total_lines": 250}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.readFile, json: json), "lines 1–100 of 250")
    }

    func testSummarizeResult_readFile_showsTotalLines_whenComplete() {
        let json = """
        {"data": {"end_line": 50, "total_lines": 50}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.readFile, json: json), "50 lines")
    }

    func testSummarizeResult_gitCommit_returnsCommitted() {
        let json = """
        {"ok": true}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.gitCommit, json: json), "committed")
    }

    func testSummarizeResult_errorInResult_showsErrorMessage() {
        let json = """
        {"error": {"message": "File not found at path"}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.readFile, json: json), "error: File not found at path")
    }

    func testSummarizeResult_unknownTool_okTrue() {
        let json = """
        {"ok": true}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: "unknown_tool", json: json), "ok")
    }

    func testSummarizeResult_unknownTool_okFalse() {
        let json = """
        {"ok": false}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: "unknown_tool", json: json), "failed")
    }

    func testSummarizeResult_unknownTool_noOkField() {
        let json = """
        {"data": "something"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: "unknown_tool", json: json), "ok")
    }

    func testSummarizeResult_invalidJSON_returnsParseError() {
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.readFile, json: "broken"), "parse error")
    }

    // MARK: - Computer-use arguments (identity keys for loop detection)

    /// These summaries double as `ToolCallTracker`'s identity key — with no entry they were
    /// all "", and clicks at DIFFERENT coordinates counted as an identical-arguments loop.

    func testSummarizeArguments_uiClick_encodesCoordinatesButtonAndTarget() {
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"x": 834, "y": 250}"#),
            "(834, 250)")
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(
                toolName: TN.uiClick,
                json: #"{"x": 10, "y": 20, "button": "right", "double": true, "target": "Safari"}"#),
            "(10, 20) right double → Safari")
    }

    func testSummarizeArguments_uiClick_differentCoordinates_differentSummaries() {
        // The D4 regression pin: distinct clicks must produce distinct identity keys.
        let a = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"x": 1257, "y": 55}"#)
        let b = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"x": 1257, "y": 90}"#)
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testSummarizeArguments_uiClick_fractionalCoordinates_coercedNotCollapsedToQuestionMark() {
        // The handler truncates fractional NSNumber coords and RUNS the click; the summarizer
        // must share that coercion or distinct fractional clicks all collapse to "?" and
        // re-open the identical-loop misfire. optionalInt coerces Double the same way requiredInt does.
        let a = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"x": 834.5, "y": 250.2}"#)
        let b = ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"x": 640.7, "y": 212.9}"#)
        XCTAssertEqual(a, "(834, 250)")
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("?"))
    }

    func testSummarizeArguments_uiKey_showsKeys_honorsAliasKey() {
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiKey, json: #"{"keys": "cmd+s"}"#), "cmd+s")
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiKey, json: #"{"key": "return"}"#), "return")
    }

    func testSummarizeArguments_uiType_truncatesAt60() {
        let long = String(repeating: "a", count: 80)
        let out = ToolCallSummarizer.summarizeArguments(toolName: TN.uiType, json: #"{"text": "\#(long)"}"#)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertEqual(out.count, 61)
    }

    func testSummarizeArguments_uiScroll_encodesPointAndDelta() {
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(
                toolName: TN.uiScroll, json: #"{"x": 5, "y": 6, "dy": -3}"#),
            "(5, 6) d(0, -3)")
    }

    func testSummarizeArguments_uiClick_missingCoordinate_returnsQuestionMark() {
        // Guard path: a malformed click (missing x or y) must not crash or emit a partial key
        // that would false-collide in the loop-detector identity.
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: #"{"y": 5}"#), "?")
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiClick, json: "{}"), "?")
    }

    func testSummarizeArguments_uiScroll_missingCoordinate_returnsQuestionMark() {
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiScroll, json: #"{"dx": 3}"#), "?")
    }

    func testSummarizeArguments_uiType_emptyText_returnsEmptyNotQuestionMark() {
        // Empty typed text is a valid, non-loop identity — distinct from the "?" malformed marker.
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiType, json: #"{"text": ""}"#), "")
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.uiType, json: "{}"), "")
    }

    func testSummarizeArguments_screenCapture_showsTargetAndTitle() {
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(toolName: TN.screenCapture, json: "{}"),
            "screen")
        XCTAssertEqual(
            ToolCallSummarizer.summarizeArguments(
                toolName: TN.screenCapture, json: #"{"target": "Safari", "window_title": "LinkedIn"}"#),
            "Safari · LinkedIn")
    }
}
