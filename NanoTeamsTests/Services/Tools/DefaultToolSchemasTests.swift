import XCTest

@testable import NanoTeams

final class DefaultToolSchemasTests: XCTestCase {

    var tools: [ToolSchema]!

    override func setUp() {
        super.setUp()
        tools = ToolHandlerRegistry.allSchemas
    }

    override func tearDown() {
        tools = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func tool(named name: String) -> ToolSchema? {
        tools.first(where: { $0.name == name })
    }

    private func requiredFields(for name: String) -> [String] {
        guard let t = tool(named: name) else { return [] }
        return t.parameters.required ?? []
    }

    private func propertyNames(for name: String) -> Set<String> {
        guard let t = tool(named: name),
            let props = t.parameters.properties
        else { return [] }
        return Set(props.keys)
    }

    private func enumValues(for toolName: String, property: String) -> [String]? {
        guard let t = tool(named: toolName),
            let props = t.parameters.properties,
            let prop = props[property]
        else { return nil }
        return prop.enumValues
    }

    // MARK: - Category Counts

    private func count(in category: ToolCategory) -> Int {
        ToolHandlerRegistry.allTypes.filter { $0.category == category }.count
    }

    func testFileSystemToolsCount() {
        XCTAssertEqual(count(in: .fileRead) + count(in: .fileWrite), 7)
    }

    func testGitToolsCount() {
        XCTAssertEqual(count(in: .gitRead) + count(in: .gitWrite), 11)
    }

    func testXcodeToolsCount() {
        XCTAssertEqual(count(in: .xcode), 2)
    }

    func testSupervisorToolsCount() {
        XCTAssertEqual(count(in: .supervisor), 1)
    }

    func testMemoryToolsCount() {
        XCTAssertEqual(count(in: .memory), 1)
    }

    func testCollaborationToolsCount() {
        XCTAssertEqual(count(in: .collaboration), 5)
    }

    func testArtifactToolsCount() {
        XCTAssertEqual(count(in: .artifact), 1)
    }

    // MARK: - Total Count

    func testDefaultToolsCountIs29() {
        XCTAssertEqual(tools.count, 29)
    }

    /// `create_team` is in the registry (so handler tests can drive it via ToolRuntime),
    /// but must NEVER be offered to a team role's LLM schema — it has a dedicated
    /// invocation path through `TeamGenerationService`.
    func testCreateTeam_unavailableToRoles() {
        XCTAssertTrue(
            ToolHandlerRegistry.unavailableToRoles.contains(ToolNames.createTeam),
            "create_team must be in unavailableToRoles to prevent silent no-op dispatch"
        )
    }

    // MARK: - Registry Invariants

    /// Every signaling tool (one whose runtime result produces a `ToolSignal`) must be
    /// filtered out of meeting turns. Drift between handler metadata and the meeting
    /// coordinator would silently break collaboration tools inside meetings.
    func testMeetingExcluded_coversAllSignalingTools() {
        let requiredSignalingTools: Set<String> = [
            "ask_supervisor",
            "ask_teammate",
            "request_team_meeting",
            "conclude_meeting",
            "request_changes",
            "create_artifact",
            "analyze_image",
        ]
        XCTAssertTrue(
            ToolHandlerRegistry.meetingExcluded.isSuperset(of: requiredSignalingTools),
            "meetingExcluded must contain every signaling tool — missing: \(requiredSignalingTools.subtracting(ToolHandlerRegistry.meetingExcluded))"
        )
    }

    /// `git_diff` must NOT be cacheable (working tree mutates between reads). This
    /// invariant is enforced via `GitDiffTool.isCacheable = false` on the handler
    /// itself, not via a hardcoded subtraction in `ToolHandlerRegistry`.
    func testCacheableTools_excludesGitDiff() {
        XCTAssertFalse(
            ToolHandlerRegistry.cacheableTools.contains("git_diff"),
            "git_diff must not be cacheable — working tree mutates between reads"
        )
    }

    /// Positive pins: file-read and typical git-read tools remain cacheable.
    func testCacheableTools_includesReadTools() {
        XCTAssertTrue(ToolHandlerRegistry.cacheableTools.contains("read_file"))
        XCTAssertTrue(ToolHandlerRegistry.cacheableTools.contains("list_files"))
        XCTAssertTrue(ToolHandlerRegistry.cacheableTools.contains("git_status"))
        XCTAssertTrue(ToolHandlerRegistry.cacheableTools.contains("git_log"))
    }

    /// Write tools must never be cacheable.
    func testCacheableTools_excludesWriteTools() {
        for name in ToolHandlerRegistry.fileWriteTools.union(ToolHandlerRegistry.gitWriteTools) {
            XCTAssertFalse(
                ToolHandlerRegistry.cacheableTools.contains(name),
                "\(name) must not be cacheable")
        }
    }

    // MARK: - Names and Descriptions Non-Empty

    func testAllToolsHaveNonEmptyNames() {
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty, "Tool has empty name")
        }
    }

    func testAllToolsHaveNonEmptyDescriptions() {
        for tool in tools {
            XCTAssertFalse(
                tool.description.isEmpty,
                "Tool '\(tool.name)' has empty description")
        }
    }

    // MARK: - Unique Names

    func testAllToolNamesAreUnique() {
        let names = tools.map(\.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(
            names.count, uniqueNames.count,
            "Duplicate tool names found: \(names.filter { name in names.filter { $0 == name }.count > 1 })"
        )
    }

    // MARK: - Tool Existence by Category

    func testFileSystemToolsExist() {
        let fileSystemTools = [
            "list_files",
            "read_file",
            "read_lines",
            "write_file",
            "delete_file",
            "search",
        ]
        for name in fileSystemTools {
            XCTAssertNotNil(tool(named: name), "File system tool '\(name)' not found")
        }
    }

    func testGitToolsExist() {
        let gitTools = [
            "git_status",
            "git_add",
            "git_commit",
            "git_pull",
            "git_branch_list",
            "git_checkout",
            "git_merge",
            "git_log",
            "git_diff",
            "git_stash",
            "git_branch",
        ]
        for name in gitTools {
            XCTAssertNotNil(tool(named: name), "Git tool '\(name)' not found")
        }
    }

    func testXcodeToolsExist() {
        let xcodeTools = ["run_xcodebuild", "run_xcodetests"]
        for name in xcodeTools {
            XCTAssertNotNil(tool(named: name), "Xcode tool '\(name)' not found")
        }
    }

    func testSupervisorToolsExist() {
        XCTAssertNotNil(tool(named: "ask_supervisor"), "Supervisor tool 'ask_supervisor' not found")
    }

    func testMemoryToolsExist() {
        XCTAssertNotNil(
            tool(named: "update_scratchpad"), "Memory tool 'update_scratchpad' not found")
    }

    func testTeammateToolsExist() {
        let teammateTools = [
            "ask_teammate",
            "request_team_meeting",
            "conclude_meeting",
            "request_changes",
        ]
        for name in teammateTools {
            XCTAssertNotNil(tool(named: name), "Teammate tool '\(name)' not found")
        }
    }

    // MARK: - Required Parameters: File System Tools

    func testReadFileRequiresPath() {
        XCTAssertEqual(requiredFields(for: "read_file"), ["path"])
    }

    func testReadFileRangeRequiresPathStartLineEndLine() {
        let required = Set(requiredFields(for: "read_lines"))
        XCTAssertEqual(required, ["path", "start_line", "end_line"])
    }

    func testWriteFileRequiresPathContent() {
        let required = Set(requiredFields(for: "write_file"))
        XCTAssertEqual(required, ["path", "content"])
    }

    func testDeleteFileRequiresPath() {
        XCTAssertEqual(requiredFields(for: "delete_file"), ["path"])
    }

    func testSearchProjectRequiresQuery() {
        XCTAssertEqual(requiredFields(for: "search"), ["query"])
    }

    func testListDirectoryHasNoRequiredFields() {
        let required = requiredFields(for: "list_files")
        XCTAssertTrue(required.isEmpty)
    }

    // MARK: - Required Parameters: Git Tools

    func testGitAddRequiresPaths() {
        XCTAssertEqual(requiredFields(for: "git_add"), ["paths"])
    }

    func testGitCommitRequiresMessage() {
        XCTAssertEqual(requiredFields(for: "git_commit"), ["message"])
    }

    func testGitCheckoutRequiresBranch() {
        XCTAssertEqual(requiredFields(for: "git_checkout"), ["branch"])
    }

    func testGitMergeRequiresBranch() {
        XCTAssertEqual(requiredFields(for: "git_merge"), ["branch"])
    }

    func testGitStashRequiresAction() {
        XCTAssertEqual(requiredFields(for: "git_stash"), ["action"])
    }

    func testGitBranchRequiresActionAndName() {
        let required = Set(requiredFields(for: "git_branch"))
        XCTAssertEqual(required, ["action", "name"])
    }

    func testGitPullHasNoRequiredFields() {
        let required = requiredFields(for: "git_pull")
        XCTAssertTrue(required.isEmpty)
    }

    func testGitBranchListHasNoRequiredFields() {
        let required = requiredFields(for: "git_branch_list")
        XCTAssertTrue(required.isEmpty)
    }

    func testGitLogHasNoRequiredFields() {
        let required = requiredFields(for: "git_log")
        XCTAssertTrue(required.isEmpty)
    }

    func testGitDiffHasNoRequiredFields() {
        let required = requiredFields(for: "git_diff")
        XCTAssertTrue(required.isEmpty)
    }

    // MARK: - Required Parameters: Supervisor Tools

    func testAskSupervisorRequiresQuestion() {
        XCTAssertEqual(requiredFields(for: "ask_supervisor"), ["question"])
    }

    // MARK: - Required Parameters: Memory Tools

    func testUpdateScratchpadRequiresContent() {
        XCTAssertEqual(requiredFields(for: "update_scratchpad"), ["content"])
    }

    // MARK: - Required Parameters: Teammate Tools

    func testAskTeammateRequiresTeammateAndQuestion() {
        let required = Set(requiredFields(for: "ask_teammate"))
        XCTAssertEqual(required, ["teammate", "question"])
    }

    func testRequestTeamMeetingRequiresTopicAndParticipants() {
        let required = Set(requiredFields(for: "request_team_meeting"))
        XCTAssertEqual(required, ["topic", "participants"])
    }

    func testConcludeMeetingRequiresDecision() {
        XCTAssertEqual(requiredFields(for: "conclude_meeting"), ["decision"])
    }

    func testRequestChangesRequiresTargetRoleChangesReasoning() {
        let required = Set(requiredFields(for: "request_changes"))
        XCTAssertEqual(required, ["target_role", "changes", "reasoning"])
    }

    // MARK: - Enum Values

    func testGitStashActionEnumValues() {
        let values = enumValues(for: "git_stash", property: "action")
        XCTAssertEqual(Set(values ?? []), Set(["push", "pop", "apply", "list", "drop"]))
    }

    func testGitBranchActionEnumValues() {
        let values = enumValues(for: "git_branch", property: "action")
        XCTAssertEqual(Set(values ?? []), Set(["create", "delete", "rename"]))
    }

    // MARK: - Parameterless Tools (Empty Properties)

    func testGitStatusHasEmptyProperties() {
        let props = tool(named: "git_status")?.parameters.properties
        XCTAssertNotNil(props)
        XCTAssertTrue(props?.isEmpty ?? false, "git_status should have empty properties")
    }

    func testRunXcodebuildHasEmptyProperties() {
        let props = tool(named: "run_xcodebuild")?.parameters.properties
        XCTAssertNotNil(props)
        XCTAssertTrue(props?.isEmpty ?? false, "run_xcodebuild should have empty properties")
    }

    func testRunTestsHasEmptyProperties() {
        let props = tool(named: "run_xcodetests")?.parameters.properties
        XCTAssertNotNil(props)
        XCTAssertTrue(props?.isEmpty ?? false, "run_xcodetests should have empty properties")
    }

    // MARK: - Array Parameters

    func testGitAddPathsIsArray() {
        let prop = tool(named: "git_add")?.parameters.properties?["paths"]
        XCTAssertNotNil(prop)
        XCTAssertEqual(prop?.type, "array")
        XCTAssertNotNil(prop?.items, "git_add paths should have items schema")
        XCTAssertEqual(prop?.items?.type, "string")
    }

    func testGitLogPathsIsArray() {
        let prop = tool(named: "git_log")?.parameters.properties?["paths"]
        XCTAssertNotNil(prop)
        XCTAssertEqual(prop?.type, "array")
        XCTAssertNotNil(prop?.items, "git_log paths should have items schema")
        XCTAssertEqual(prop?.items?.type, "string")
    }

    func testGitDiffPathsIsArray() {
        let prop = tool(named: "git_diff")?.parameters.properties?["paths"]
        XCTAssertNotNil(prop)
        XCTAssertEqual(prop?.type, "array")
        XCTAssertNotNil(prop?.items, "git_diff paths should have items schema")
        XCTAssertEqual(prop?.items?.type, "string")
    }

    func testRequestTeamMeetingParticipantsIsArray() {
        let prop = tool(named: "request_team_meeting")?.parameters.properties?["participants"]
        XCTAssertNotNil(prop)
        XCTAssertEqual(prop?.type, "array")
        XCTAssertNotNil(prop?.items, "request_team_meeting participants should have items schema")
        XCTAssertEqual(prop?.items?.type, "string")
    }

    // MARK: - All Parameters Are Object Type

    func testAllToolParametersAreObjectType() {
        for tool in tools {
            XCTAssertEqual(
                tool.parameters.type, "object",
                "Tool '\(tool.name)' parameters should be type 'object', got '\(tool.parameters.type)'"
            )
        }
    }

    // MARK: - Property Type Checks

    func testListDirectoryPropertyTypes() {
        let props = tool(named: "list_files")?.parameters.properties
        XCTAssertEqual(props?["path"]?.type, "string")
        XCTAssertEqual(props?["depth"]?.type, "integer")
    }

    func testReadFilePropertyTypes() {
        let props = tool(named: "read_file")?.parameters.properties
        XCTAssertEqual(props?["path"]?.type, "string")
    }

    func testReadFileRangePropertyTypes() {
        let props = tool(named: "read_lines")?.parameters.properties
        XCTAssertEqual(props?["path"]?.type, "string")
        XCTAssertEqual(props?["start_line"]?.type, "integer")
        XCTAssertEqual(props?["end_line"]?.type, "integer")
    }

    func testWriteFilePropertyTypes() {
        let props = tool(named: "write_file")?.parameters.properties
        XCTAssertEqual(props?["path"]?.type, "string")
        XCTAssertEqual(props?["content"]?.type, "string")
    }

    func testGitCommitPropertyTypes() {
        let props = tool(named: "git_commit")?.parameters.properties
        XCTAssertEqual(props?["message"]?.type, "string")
        XCTAssertEqual(props?["amend"]?.type, "boolean")
    }

    func testGitCheckoutPropertyTypes() {
        let props = tool(named: "git_checkout")?.parameters.properties
        XCTAssertEqual(props?["branch"]?.type, "string")
        XCTAssertEqual(props?["create"]?.type, "boolean")
        XCTAssertEqual(props?["from"]?.type, "string")
    }

    func testGitStashPropertyTypes() {
        let props = tool(named: "git_stash")?.parameters.properties
        XCTAssertEqual(props?["action"]?.type, "string")
        XCTAssertEqual(props?["message"]?.type, "string")
        XCTAssertEqual(props?["index"]?.type, "integer")
        XCTAssertEqual(props?["include_untracked"]?.type, "boolean")
    }

    func testGitBranchPropertyTypes() {
        let props = tool(named: "git_branch")?.parameters.properties
        XCTAssertEqual(props?["action"]?.type, "string")
        XCTAssertEqual(props?["name"]?.type, "string")
        XCTAssertEqual(props?["from"]?.type, "string")
        XCTAssertEqual(props?["new_name"]?.type, "string")
        XCTAssertEqual(props?["force"]?.type, "boolean")
    }

    func testSearchProjectPropertyTypes() {
        let props = tool(named: "search")?.parameters.properties
        XCTAssertEqual(props?["query"]?.type, "string")
        XCTAssertEqual(props?["max_results"]?.type, "integer")
    }

    func testAskTeammatePropertyTypes() {
        let props = tool(named: "ask_teammate")?.parameters.properties
        XCTAssertEqual(props?["teammate"]?.type, "string")
        XCTAssertEqual(props?["question"]?.type, "string")
        XCTAssertEqual(props?["context"]?.type, "string")
    }

    func testRequestChangesPropertyTypes() {
        let props = tool(named: "request_changes")?.parameters.properties
        XCTAssertEqual(props?["target_role"]?.type, "string")
        XCTAssertEqual(props?["changes"]?.type, "string")
        XCTAssertEqual(props?["reasoning"]?.type, "string")
    }

    // MARK: - Property Counts

    func testListDirectoryHasTwoProperties() {
        XCTAssertEqual(propertyNames(for: "list_files").count, 2)
    }

    func testReadFileHasOneProperty() {
        XCTAssertEqual(propertyNames(for: "read_file").count, 1)
    }

    func testReadFileRangeHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "read_lines").count, 3)
    }

    func testWriteFileHasTwoProperties() {
        XCTAssertEqual(propertyNames(for: "write_file").count, 2)
    }

    func testDeleteFileHasTwoProperties() {
        XCTAssertEqual(propertyNames(for: "delete_file").count, 2)
    }

    func testSearchProjectHasTwoProperties() {
        XCTAssertEqual(propertyNames(for: "search").count, 2)
    }

    func testGitCommitHasTwoProperties() {
        XCTAssertEqual(propertyNames(for: "git_commit").count, 2)
    }

    func testGitPullHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "git_pull").count, 3)
    }

    func testGitStashHasFourProperties() {
        XCTAssertEqual(propertyNames(for: "git_stash").count, 4)
    }

    func testGitBranchHasFiveProperties() {
        XCTAssertEqual(propertyNames(for: "git_branch").count, 5)
    }

    func testAskSupervisorHasOneProperty() {
        XCTAssertEqual(propertyNames(for: "ask_supervisor").count, 1)
    }

    func testUpdateScratchpadHasOneProperty() {
        XCTAssertEqual(propertyNames(for: "update_scratchpad").count, 1)
    }

    func testAskTeammateHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "ask_teammate").count, 3)
    }

    func testRequestTeamMeetingHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "request_team_meeting").count, 3)
    }

    func testConcludeMeetingHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "conclude_meeting").count, 3)
    }

    func testRequestChangesHasThreeProperties() {
        XCTAssertEqual(propertyNames(for: "request_changes").count, 3)
    }

    // MARK: - Property Name Sets

    func testListDirectoryPropertyNames() {
        XCTAssertEqual(
            propertyNames(for: "list_files"),
            ["path", "depth"])
    }

    func testSearchProjectPropertyNames() {
        XCTAssertEqual(
            propertyNames(for: "search"),
            ["query", "max_results"])
    }

    func testGitBranchPropertyNames() {
        XCTAssertEqual(
            propertyNames(for: "git_branch"),
            ["action", "name", "from", "new_name", "force"])
    }

    func testConcludeMeetingPropertyNames() {
        XCTAssertEqual(
            propertyNames(for: "conclude_meeting"),
            ["decision", "rationale", "next_steps"])
    }

    // MARK: - Descriptions Contain Expected Text

    func testAskSupervisorDescriptionMentionsSupervisor() {
        let desc = tool(named: "ask_supervisor")?.description ?? ""
        XCTAssertTrue(desc.lowercased().contains("supervisor"), "ask_supervisor description should mention Supervisor")
    }

    func testUpdateScratchpadDescriptionMentionsScratchpad() {
        let desc = tool(named: "update_scratchpad")?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("scratchpad"),
            "update_scratchpad description should mention scratchpad")
    }

    func testAskTeammateDescriptionMentionsTeammate() {
        let desc = tool(named: "ask_teammate")?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("teammate"),
            "ask_teammate description should mention teammate")
    }

    func testRequestTeamMeetingDescriptionMentionsMeeting() {
        let desc = tool(named: "request_team_meeting")?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("meeting"),
            "request_team_meeting description should mention meeting")
    }

    func testConcludeMeetingDescriptionMentionsConclude() {
        let desc = tool(named: "conclude_meeting")?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("conclude"),
            "conclude_meeting description should mention conclude")
    }

    func testRequestChangesDescriptionMentionsChanges() {
        let desc = tool(named: "request_changes")?.description ?? ""
        XCTAssertTrue(
            desc.lowercased().contains("changes"),
            "request_changes description should mention changes")
    }

    // MARK: - Idempotency

    func testDefaultToolsReturnsConsistentResults() {
        let first = ToolHandlerRegistry.allSchemas
        let second = ToolHandlerRegistry.allSchemas
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.description, b.description)
            XCTAssertEqual(a.parameters, b.parameters)
        }
    }

    // MARK: - Tool Names Follow Naming Convention

    func testAllToolNamesUseLowercaseUnderscoreConvention() {
        let validPattern = /^[a-z][a-z0-9_]*$/
        for tool in tools {
            XCTAssertNotNil(
                try? validPattern.firstMatch(in: tool.name),
                "Tool name '\(tool.name)' does not follow lowercase_underscore convention")
        }
    }
}
