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

    func testSummarizeArguments_editFile_showsPath() {
        let json = """
        {"path": "/src/file.swift", "old_text": "a", "new_text": "b"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.editFile, json: json), "/src/file.swift")
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

    func testSummarizeArguments_runXcodebuild_showsScheme() {
        let json = """
        {"scheme": "NanoTeams"}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeArguments(toolName: TN.runXcodebuild, json: json), "scheme: NanoTeams")
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

    // MARK: - listFiles depth

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

    func testSummarizeResult_readFile_showsSize() {
        let json = """
        {"data": {"size": 1024}}
        """
        XCTAssertEqual(ToolCallSummarizer.summarizeResult(toolName: TN.readFile, json: json), "1024 bytes")
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
}
