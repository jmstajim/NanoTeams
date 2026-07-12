import XCTest
@testable import NanoTeams

final class AgentSkillsScannerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var projectDir: URL!
    private var homeDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        projectDir = base.appendingPathComponent("project", isDirectory: true)
        homeDir = base.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let parent = projectDir.deletingLastPathComponent()
        restorePermissionsRecursively(at: parent)
        try? fileManager.removeItem(at: parent)
        projectDir = nil
        homeDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ root: URL, _ relPath: String, _ content: String = "body content") throws {
        let fileURL = root.appendingPathComponent(relPath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func writeRaw(_ root: URL, _ relPath: String, _ bytes: Data) throws {
        let fileURL = root.appendingPathComponent(relPath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL)
    }

    private func scan(projectRoot: URL? = nil) -> AgentSkillsSnapshot {
        AgentSkillsScanner.scan(projectRoot: projectRoot ?? projectDir, homeDirectory: homeDir)
    }

    private func restorePermissionsRecursively(at url: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        guard let items = try? fileManager.contentsOfDirectory(atPath: url.path) else { return }
        for item in items {
            let child = url.appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                restorePermissionsRecursively(at: child)
            }
        }
    }

    private func item(_ snap: AgentSkillsSnapshot, name: String, agentID: String) -> AgentSkillsSnapshot.Item? {
        snap.items.first { $0.name == name && $0.agentID == agentID }
    }

    // MARK: - Empty / missing

    func testScan_emptyProject_returnsEmpty() {
        XCTAssertTrue(scan().isEmpty)
    }

    func testScan_missingRoots_noThrow() {
        // Only a stray unrelated dir — no recognized roots.
        try? write(projectDir, "src/main.swift", "code")
        XCTAssertTrue(scan().isEmpty)
    }

    // MARK: - Claude skills

    func testScan_claudeSkill_discovered() throws {
        try write(projectDir, ".claude/skills/review/SKILL.md", "# Review skill")
        let snap = scan()
        let skill = item(snap, name: "review", agentID: "claude-skill")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.origin, .project)
        XCTAssertEqual(skill?.kindLabel, "Skill")
        XCTAssertEqual(skill?.agentLabel, "Claude Code")
    }

    func testScan_claudeSkill_frontmatterNameOverridesDir() throws {
        try write(projectDir, ".claude/skills/dir-name/SKILL.md",
                  "---\nname: fancy-name\ndescription: A fancy skill\n---\nbody")
        let snap = scan()
        XCTAssertNil(item(snap, name: "dir-name", agentID: "claude-skill"))
        let skill = item(snap, name: "fancy-name", agentID: "claude-skill")
        XCTAssertEqual(skill?.description, "A fancy skill")
    }

    func testScan_claudeSkill_dirWithoutSkillFile_ignored() throws {
        try write(projectDir, ".claude/skills/hasfile/SKILL.md", "ok")
        try fileManager.createDirectory(
            at: projectDir.appendingPathComponent(".claude/skills/nofile"),
            withIntermediateDirectories: true)
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "hasfile", agentID: "claude-skill"))
        XCTAssertNil(item(snap, name: "nofile", agentID: "claude-skill"))
    }

    // MARK: - Claude commands (markdown tree, namespacing)

    func testScan_claudeCommands_namespacedByPath() throws {
        try write(projectDir, ".claude/commands/git/commit.md", "commit cmd")
        try write(projectDir, ".claude/commands/top.md", "top cmd")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "git:commit", agentID: "claude-command"))
        XCTAssertNotNil(item(snap, name: "top", agentID: "claude-command"))
    }

    // MARK: - Flat layouts

    func testScan_codexPrompts_flatOnly_ignoresNesting() throws {
        try write(projectDir, ".codex/prompts/flat.md", "flat")
        try write(projectDir, ".codex/prompts/sub/deep.md", "deep")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "flat", agentID: "codex-prompt"))
        XCTAssertNil(item(snap, name: "deep", agentID: "codex-prompt"))
        XCTAssertNil(item(snap, name: "sub:deep", agentID: "codex-prompt"))
    }

    func testScan_copilotPrompts_suffixStripping() throws {
        try write(projectDir, ".github/prompts/deploy.prompt.md", "deploy")
        try write(projectDir, ".github/prompts/plain.md", "plain")  // not a prompt file
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "deploy", agentID: "copilot-prompt"))
        XCTAssertNil(item(snap, name: "plain", agentID: "copilot-prompt"))
        XCTAssertNil(item(snap, name: "plain.md", agentID: "copilot-prompt"))
    }

    func testScan_copilot_noGlobalConvention() throws {
        try write(homeDir, ".github/prompts/x.prompt.md", "x")
        // Copilot has globalSubpath nil → global .github/prompts is never scanned.
        XCTAssertNil(item(scan(), name: "x", agentID: "copilot-prompt"))
    }

    // MARK: - Gemini toml

    func testScan_geminiCommands_tomlDescription() throws {
        try write(projectDir, ".gemini/commands/deploy.toml",
                  "description = \"Deploy the app\"\nprompt = \"do deploy\"\n")
        let snap = scan()
        let cmd = item(snap, name: "deploy", agentID: "gemini-command")
        XCTAssertEqual(cmd?.description, "Deploy the app")
        XCTAssertEqual(cmd?.kindLabel, "Command")
    }

    // MARK: - Origins

    func testScan_projectAndGlobal_sameName_twoDistinctItems() throws {
        try write(projectDir, ".claude/skills/review/SKILL.md", "project review")
        try write(homeDir, ".claude/skills/review/SKILL.md", "global review")
        let snap = scan()
        let matching = snap.items.filter { $0.name == "review" && $0.agentID == "claude-skill" }
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(Set(matching.map(\.origin)), [.project, .global])
        XCTAssertEqual(Set(matching.map(\.id)).count, 2)
    }

    func testScan_globalSkill_discovered() throws {
        try write(homeDir, ".codex/prompts/summarize.md", "summarize")
        let cmd = item(scan(), name: "summarize", agentID: "codex-prompt")
        XCTAssertEqual(cmd?.origin, .global)
        XCTAssertTrue(cmd?.displayPath.hasPrefix("~/") ?? false)
    }

    func testScan_projectRootNil_globalOnly() throws {
        try write(projectDir, ".claude/skills/proj/SKILL.md", "p")
        try write(homeDir, ".claude/skills/glob/SKILL.md", "g")
        let snap = AgentSkillsScanner.scan(projectRoot: nil, homeDirectory: homeDir)
        XCTAssertNil(item(snap, name: "proj", agentID: "claude-skill"))
        XCTAssertNotNil(item(snap, name: "glob", agentID: "claude-skill"))
    }

    // MARK: - Symlinks / walk guards

    func testScan_symlinkedRoot_followed() throws {
        let real = projectDir.appendingPathComponent("real-skills")
        try write(real, "review/SKILL.md", "via symlink")
        try fileManager.createDirectory(
            at: projectDir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: projectDir.appendingPathComponent(".claude/skills"),
            withDestinationURL: real)
        XCTAssertNotNil(item(scan(), name: "review", agentID: "claude-skill"))
    }

    func testScan_symlinkCycle_terminates() throws {
        try write(projectDir, ".claude/commands/real.md", "real")
        // A self-referential cycle inside the recursive command tree.
        try fileManager.createSymbolicLink(
            at: projectDir.appendingPathComponent(".claude/commands/loop"),
            withDestinationURL: projectDir.appendingPathComponent(".claude/commands"))
        let snap = scan()  // must not hang
        XCTAssertNotNil(item(snap, name: "real", agentID: "claude-command"))
    }

    func testScan_depthBound_excludesTooDeep() throws {
        // 7 nested dirs below the root exceeds maxTreeDepth (6).
        try write(projectDir, ".claude/commands/a/b/c/d/e/f/g/deep.md", "deep")
        try write(projectDir, ".claude/commands/a/b/c/shallow.md", "shallow")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "a:b:c:shallow", agentID: "claude-command"))
        XCTAssertNil(item(snap, name: "a:b:c:d:e:f:g:deep", agentID: "claude-command"))
    }

    func testScan_nodeModules_skipped() throws {
        try write(projectDir, ".claude/commands/node_modules/pkg/cmd.md", "junk")
        try write(projectDir, ".claude/commands/keep.md", "keep")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "keep", agentID: "claude-command"))
        XCTAssertTrue(snap.items.allSatisfy { !$0.name.contains("node_modules") })
    }

    func testScan_nonUTF8Skill_skipped() throws {
        try writeRaw(projectDir, ".claude/skills/binary/SKILL.md", Data([0xFF, 0xFE, 0x00, 0x01, 0xC0]))
        XCTAssertNil(item(scan(), name: "binary", agentID: "claude-skill"))
    }

    // MARK: - Ordering

    func testScan_deterministicOrder_tableThenOriginThenName() throws {
        try write(projectDir, ".claude/skills/zeta/SKILL.md", "z")
        try write(projectDir, ".claude/skills/alpha/SKILL.md", "a")
        try write(projectDir, ".codex/prompts/mid.md", "m")
        let items = scan().items
        // Claude skills come before Codex prompts (table order).
        let claudeIdx = items.firstIndex { $0.agentID == "claude-skill" }!
        let codexIdx = items.firstIndex { $0.agentID == "codex-prompt" }!
        XCTAssertLessThan(claudeIdx, codexIdx)
        // Within Claude skills, alpha before zeta (name ascending).
        let names = items.filter { $0.agentID == "claude-skill" }.map(\.name)
        XCTAssertEqual(names, ["alpha", "zeta"])
    }

    // MARK: - More edge cases

    func testScan_skillFileIsDirectory_ignored() throws {
        // A "SKILL.md" that is itself a directory must not count as a skill file.
        try fileManager.createDirectory(
            at: projectDir.appendingPathComponent(".claude/skills/weird/SKILL.md"),
            withIntermediateDirectories: true)
        XCTAssertNil(item(scan(), name: "weird", agentID: "claude-skill"))
    }

    func testScan_emptySkillFile_skipped() throws {
        try write(projectDir, ".claude/skills/blank/SKILL.md", "")
        XCTAssertNil(item(scan(), name: "blank", agentID: "claude-skill"))
    }

    func testScan_flatMatchIsDirectory_ignored() throws {
        // A directory named "foo.md" under a flat root is not a prompt file.
        try fileManager.createDirectory(
            at: projectDir.appendingPathComponent(".codex/prompts/foo.md"),
            withIntermediateDirectories: true)
        XCTAssertNil(item(scan(), name: "foo", agentID: "codex-prompt"))
    }

    func testScan_windsurfWorkflow_projectDiscovered() throws {
        try write(projectDir, ".windsurf/workflows/release.md", "release steps")
        let wf = item(scan(), name: "release", agentID: "windsurf-workflow")
        XCTAssertEqual(wf?.kindLabel, "Workflow")
        XCTAssertEqual(wf?.origin, .project)
    }

    func testScan_opencodeCommand_globalDiscovered() throws {
        try write(homeDir, ".config/opencode/command/build.md", "build")
        let cmd = item(scan(), name: "build", agentID: "opencode-command")
        XCTAssertEqual(cmd?.origin, .global)
    }

    // MARK: - readFullContent

    func testReadFullContent_returnsTrimmedFull() throws {
        try write(projectDir, ".claude/skills/x/SKILL.md", "\n\nfull skill body\n\n")
        let skill = item(scan(), name: "x", agentID: "claude-skill")!
        XCTAssertEqual(AgentSkillsScanner.readFullContent(at: skill.fileURL), "full skill body")
    }

    func testReadFullContent_missingFile_returnsNil() {
        XCTAssertNil(AgentSkillsScanner.readFullContent(at: projectDir.appendingPathComponent("nope.md")))
    }

    // MARK: - Nested skill dirs (recursive discovery)

    func testScan_claudeSkill_nested_discovered() throws {
        try write(projectDir, ".claude/skills/category/deep-skill/SKILL.md", "nested skill")
        let skill = item(scan(), name: "deep-skill", agentID: "claude-skill")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.origin, .project)
    }

    func testScan_claudeSkill_internalNestedSkillFile_notSurfaced() throws {
        // A skill dir with its own example SKILL.md deeper inside: only the outer
        // dir is a skill (stop-at-first rule — never descend into a skill).
        try write(projectDir, ".claude/skills/outer/SKILL.md", "outer skill")
        try write(projectDir, ".claude/skills/outer/examples/inner/SKILL.md", "example")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "outer", agentID: "claude-skill"))
        XCTAssertNil(item(snap, name: "inner", agentID: "claude-skill"))
    }

    // MARK: - Codex skills

    func testScan_codexSkills_hiddenSystemNesting_discovered() throws {
        try write(projectDir, ".codex/skills/.system/skill-creator/SKILL.md", "codex skill")
        let skill = item(scan(), name: "skill-creator", agentID: "codex-skill")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.kindLabel, "Skill")
        XCTAssertEqual(skill?.agentLabel, "Codex")
    }

    // MARK: - Loose project skills (outside .claude/skills)

    func testScan_looseProjectSkill_discovered() throws {
        try write(projectDir, "DesignSystem/SKILL.md",
                  "---\nname: nanoteams-design\ndescription: Brand kit\n---\nbody")
        let skill = item(scan(), name: "nanoteams-design", agentID: "project-skill")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.origin, .project)
        XCTAssertEqual(skill?.description, "Brand kit")
    }

    func testScan_looseProjectSkill_claudeSkillsNotDoubleListed() throws {
        try write(projectDir, ".claude/skills/review/SKILL.md", "review")
        let snap = scan()
        // Discovered once as a claude-skill, never as a loose project-skill.
        XCTAssertNotNil(item(snap, name: "review", agentID: "claude-skill"))
        XCTAssertNil(item(snap, name: "review", agentID: "project-skill"))
    }

    func testScan_looseProjectSkill_nanoteamsAndNodeModulesSkipped() throws {
        try write(projectDir, ".nanoteams/tasks/1/attachments/SKILL.md", "attachment")
        try write(projectDir, "node_modules/pkg/SKILL.md", "vendored")
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "project-skill" })
    }

    func testScan_looseProjectSkill_projectRootNil_notScanned() throws {
        try write(projectDir, "DesignSystem/SKILL.md", "---\nname: brand\n---\nb")
        let snap = AgentSkillsScanner.scan(projectRoot: nil, homeDirectory: homeDir)
        XCTAssertNil(item(snap, name: "brand", agentID: "project-skill"))
    }

    // MARK: - Plugin skills

    private func writeEnabledPlugins(_ root: URL, _ enabled: [String: Bool]) throws {
        let entries = enabled.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        try write(root, ".claude/settings.json", "{\"enabledPlugins\": {\(entries)}}")
    }

    private func writeInstalledPlugins(_ installPaths: [String: String]) throws {
        let entries = installPaths
            .map { "\"\($0.key)\": [{\"installPath\": \"\($0.value)\"}]" }
            .joined(separator: ", ")
        try write(homeDir, ".claude/plugins/installed_plugins.json", "{\"plugins\": {\(entries)}}")
    }

    func testScan_pluginSkills_enabledDiscovered_disabledIgnored() throws {
        let good = homeDir.appendingPathComponent(".claude/plugins/cache/mp/good/1.0.0")
        try write(good, "skills/foo/SKILL.md", "foo skill")
        try write(good, "bar-skill/SKILL.md", "bar skill")          // child of installPath (swiftui-expert shape)
        try write(good, ".agents/skills/baz/SKILL.md", "baz skill")  // hidden .agents nesting
        let bad = homeDir.appendingPathComponent(".claude/plugins/cache/mp/bad/1.0.0")
        try write(bad, "skills/secret/SKILL.md", "disabled skill")

        try writeEnabledPlugins(homeDir, ["good@mp": true, "bad@mp": false])
        try writeInstalledPlugins(["good@mp": good.path, "bad@mp": bad.path])

        let snap = scan()
        for name in ["foo", "bar-skill", "baz"] {
            let it = item(snap, name: name, agentID: "claude-plugin-skill")
            XCTAssertNotNil(it, "expected plugin skill \(name)")
            XCTAssertEqual(it?.origin, .global)
            XCTAssertEqual(it?.kindLabel, "Plugin Skill")
            XCTAssertEqual(it?.agentLabel, "Claude Code")
        }
        XCTAssertNil(item(snap, name: "secret", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSkills_enabledViaProjectSettings() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/pj/1.0.0")
        try write(dir, "skills/proj-plugin/SKILL.md", "p")
        try writeInstalledPlugins(["pj@mp": dir.path])
        try writeEnabledPlugins(projectDir, ["pj@mp": true])   // enabled only in the work folder
        XCTAssertNotNil(item(scan(), name: "proj-plugin", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSkills_missingInstallPath_skippedNoCrash() throws {
        try writeEnabledPlugins(homeDir, ["ghost@mp": true])
        try writeInstalledPlugins(["ghost@mp": homeDir.appendingPathComponent("does/not/exist").path])
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-skill" })
    }

    func testScan_pluginSkills_projectRootNil_usesGlobalSettingsOnly() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/glob/1.0.0")
        try write(dir, "skills/only-global/SKILL.md", "g")
        try writeInstalledPlugins(["glob@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["glob@mp": true])
        try writeEnabledPlugins(projectDir, ["proj-only@mp": true])  // must be ignored when projectRoot is nil

        let snap = AgentSkillsScanner.scan(projectRoot: nil, homeDirectory: homeDir)
        XCTAssertNotNil(item(snap, name: "only-global", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSkills_frontmatterNameWins() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/fm/1.0.0")
        try write(dir, "skills/dirname/SKILL.md", "---\nname: pretty-name\n---\nbody")
        try writeInstalledPlugins(["fm@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["fm@mp": true])
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "pretty-name", agentID: "claude-plugin-skill"))
        XCTAssertNil(item(snap, name: "dirname", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSkills_rootSkillMd_usesPluginName() throws {
        // A single-skill plugin with SKILL.md directly at its installPath root.
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/single/1.0.0")
        try write(dir, "SKILL.md", "single-skill plugin")
        try writeInstalledPlugins(["single@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["single@mp": true])
        let skill = item(scan(), name: "single", agentID: "claude-plugin-skill")
        XCTAssertNotNil(skill)
        XCTAssertEqual(skill?.origin, .global)
    }

    // MARK: - Loose walk skips convention roots

    func testScan_looseWalk_skipsConventionDirs_noDoubleLabel() throws {
        try write(projectDir, ".codex/skills/foo/SKILL.md", "codex skill")
        let snap = scan()
        // Surfaced via the codex-skill source, never as a loose project-skill.
        XCTAssertNotNil(item(snap, name: "foo", agentID: "codex-skill"))
        XCTAssertNil(item(snap, name: "foo", agentID: "project-skill"))
    }

    // MARK: - Plugin commands

    func testScan_pluginCommands_discovered_namespacedByPlugin() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/cmdp/1.0.0")
        try write(dir, "commands/review.md", "---\ndescription: Review the diff\n---\nrun a review")
        try writeInstalledPlugins(["cmdp@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["cmdp@mp": true])
        let cmd = item(scan(), name: "cmdp:review", agentID: "claude-plugin-command")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.origin, .global)
        XCTAssertEqual(cmd?.kindLabel, "Plugin Command")
        XCTAssertEqual(cmd?.agentLabel, "Claude Code")
        XCTAssertEqual(cmd?.description, "Review the diff")
    }

    func testScan_pluginCommands_nestedNamespacing() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/gitp/1.0.0")
        try write(dir, "commands/git/commit.md", "commit cmd")
        try writeInstalledPlugins(["gitp@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["gitp@mp": true])
        XCTAssertNotNil(item(scan(), name: "gitp:git:commit", agentID: "claude-plugin-command"))
    }

    func testScan_pluginCommands_disabledPluginIgnored() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/off/1.0.0")
        try write(dir, "commands/secret.md", "secret")
        try writeInstalledPlugins(["off@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["off@mp": false])
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-command" })
    }

    func testScan_pluginSkillsAndCommands_bothSurface() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/both/1.0.0")
        try write(dir, "skills/helper/SKILL.md", "helper skill")
        try write(dir, "commands/do-thing.md", "do the thing")
        try writeInstalledPlugins(["both@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["both@mp": true])
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "helper", agentID: "claude-plugin-skill"))
        XCTAssertNotNil(item(snap, name: "both:do-thing", agentID: "claude-plugin-command"))
    }

    // MARK: - Plugin manifest edges

    private func writeKnownMarketplaces(_ locations: [String: String]) throws {
        let entries = locations
            .map { "\"\($0.key)\": {\"installLocation\": \"\($0.value)\"}" }
            .joined(separator: ", ")
        try write(homeDir, ".claude/plugins/known_marketplaces.json", "{\(entries)}")
    }

    func testScan_pluginSkills_resolvedViaMarketplaceFallback() throws {
        // No installed_plugins.json → resolve installPath via known_marketplaces.json,
        // trying both <loc>/plugins/<plugin> and <loc>/<plugin> candidate shapes.
        let mpLoc = homeDir.appendingPathComponent(".claude/plugins/marketplaces/mymp")
        try write(mpLoc, "plugins/foo/skills/fooskill/SKILL.md", "foo")   // <loc>/plugins/<plugin>
        let mp2Loc = homeDir.appendingPathComponent(".claude/plugins/marketplaces/mp2")
        try write(mp2Loc, "bar/skills/barskill/SKILL.md", "bar")          // <loc>/<plugin>
        try writeKnownMarketplaces(["mymp": mpLoc.path, "mp2": mp2Loc.path])
        try writeEnabledPlugins(homeDir, ["foo@mymp": true, "bar@mp2": true])
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "fooskill", agentID: "claude-plugin-skill"))
        XCTAssertNotNil(item(snap, name: "barskill", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginInstallPaths_firstMissingSecondExisting_usesExisting() throws {
        let realDir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/multi/2.0.0")
        try write(realDir, "skills/multiskill/SKILL.md", "m")
        let missing = homeDir.appendingPathComponent(".claude/plugins/cache/mp/multi/1.0.0")  // never created
        try write(homeDir, ".claude/plugins/installed_plugins.json",
                  "{\"plugins\": {\"multi@mp\": [{\"installPath\": \"\(missing.path)\"}, {\"installPath\": \"\(realDir.path)\"}]}}")
        try writeEnabledPlugins(homeDir, ["multi@mp": true])
        XCTAssertNotNil(item(scan(), name: "multiskill", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginInstallPaths_emptyInstallPath_skipped() throws {
        try write(homeDir, ".claude/plugins/installed_plugins.json",
                  "{\"plugins\": {\"e@mp\": [{\"installPath\": \"\"}]}}")
        try writeEnabledPlugins(homeDir, ["e@mp": true])
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-skill" })
    }

    func testScan_pluginResolve_noAtKey_notDiscovered() throws {
        try writeEnabledPlugins(homeDir, ["noatkey": true])  // no '@' → no fallback, no installPath
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-skill" })
    }

    func testScan_pluginResolve_absentMarketplace_notDiscovered() throws {
        try writeEnabledPlugins(homeDir, ["p@absent": true])  // no manifest at all
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-skill" })
    }

    func testScan_pluginResolve_marketplaceButNoCandidateDir_notDiscovered() throws {
        let mpLoc = homeDir.appendingPathComponent(".claude/plugins/marketplaces/hollow")
        try fileManager.createDirectory(at: mpLoc, withIntermediateDirectories: true)  // exists but empty
        try writeKnownMarketplaces(["hollow": mpLoc.path])
        try writeEnabledPlugins(homeDir, ["ghost@hollow": true])
        XCTAssertTrue(scan().items.allSatisfy { $0.agentID != "claude-plugin-skill" })
    }

    // MARK: - Settings precedence + lenient decode

    func testScan_pluginSkills_enabledViaLocalSettings() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/loc/1.0.0")
        try write(dir, "skills/localonly/SKILL.md", "l")
        try writeInstalledPlugins(["loc@mp": dir.path])
        try write(projectDir, ".claude/settings.local.json", "{\"enabledPlugins\": {\"loc@mp\": true}}")
        XCTAssertNotNil(item(scan(), name: "localonly", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSkills_localFalseOverridesProjectTrue() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/ov/1.0.0")
        try write(dir, "skills/overridden/SKILL.md", "o")
        try writeInstalledPlugins(["ov@mp": dir.path])
        try writeEnabledPlugins(projectDir, ["ov@mp": true])                                   // project enables
        try write(projectDir, ".claude/settings.local.json", "{\"enabledPlugins\": {\"ov@mp\": false}}")  // local disables
        XCTAssertNil(item(scan(), name: "overridden", agentID: "claude-plugin-skill"))
    }

    func testScan_pluginSettings_nonBoolValue_doesNotPoisonGoodKeys() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/good/1.0.0")
        try write(dir, "skills/goodskill/SKILL.md", "g")
        try writeInstalledPlugins(["good@mp": dir.path])
        // A malformed sibling value (null) must not drop the valid one.
        try write(homeDir, ".claude/settings.json", "{\"enabledPlugins\": {\"good@mp\": true, \"bad@mp\": null}}")
        XCTAssertNotNil(item(scan(), name: "goodskill", agentID: "claude-plugin-skill"))
    }

    // MARK: - Canonical-path dedup

    func testScan_sameFileViaTwoSymlinkedRoots_dedupedByCanonicalPath() throws {
        let real = projectDir.appendingPathComponent("real-skills")
        try write(real, "shared/SKILL.md", "shared skill")
        try fileManager.createDirectory(at: projectDir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectDir.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: projectDir.appendingPathComponent(".claude/skills"), withDestinationURL: real)
        try fileManager.createSymbolicLink(at: projectDir.appendingPathComponent(".codex/skills"), withDestinationURL: real)
        // claude-skill, codex-skill, and the loose walk all resolve to one file.
        XCTAssertEqual(scan().items.filter { $0.name == "shared" }.count, 1)
    }

    // MARK: - Walk boundaries

    func testScan_skillDir_depthBoundary() throws {
        try write(projectDir, ".claude/skills/a/b/c/d/e/atlimit/SKILL.md", "at limit (depth 6)")
        try write(projectDir, ".claude/skills/a/b/c/d/e/f/toodeep/SKILL.md", "too deep (depth 7)")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "atlimit", agentID: "claude-skill"))
        XCTAssertNil(item(snap, name: "toodeep", agentID: "claude-skill"))
    }

    func testScan_skillTreeSymlinkCycle_terminates() throws {
        try write(projectDir, ".claude/skills/real/SKILL.md", "real")
        try fileManager.createDirectory(at: projectDir.appendingPathComponent(".claude/skills/cat"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: projectDir.appendingPathComponent(".claude/skills/cat/loop"),
            withDestinationURL: projectDir.appendingPathComponent(".claude/skills"))
        XCTAssertNotNil(item(scan(), name: "real", agentID: "claude-skill"))  // must not hang
    }

    func testScan_rootLevelSkillMd_notEmitted() throws {
        // A SKILL.md at the walk root (project root, or the .claude/skills root) is
        // never a skill — only descendants are (the plugin-root case is the opposite).
        try write(projectDir, "SKILL.md", "repo root skill")
        try write(projectDir, ".claude/skills/SKILL.md", "skills root file")
        let snap = scan()
        XCTAssertTrue(snap.items.allSatisfy { $0.agentID != "project-skill" && $0.agentID != "claude-skill" })
    }

    // MARK: - Plugin command edges

    func testScan_pluginCommandsPathIsFile_skipsCommandsKeepsSkills() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/filecmd/1.0.0")
        try write(dir, "skills/helper/SKILL.md", "helper")
        try write(dir, "commands", "i am a regular file, not a directory")
        try writeInstalledPlugins(["filecmd@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["filecmd@mp": true])
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "helper", agentID: "claude-plugin-skill"))
        XCTAssertTrue(snap.items.allSatisfy { $0.agentID != "claude-plugin-command" })
    }

    func testScan_pluginCommand_emptyAndBinary_skipped() throws {
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/badcmd/1.0.0")
        try write(dir, "commands/valid.md", "valid cmd")
        try write(dir, "commands/empty.md", "")
        try writeRaw(dir, "commands/bin.md", Data([0xFF, 0xFE, 0x00, 0xC0]))
        try writeInstalledPlugins(["badcmd@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["badcmd@mp": true])
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "badcmd:valid", agentID: "claude-plugin-command"))
        XCTAssertNil(item(snap, name: "badcmd:empty", agentID: "claude-plugin-command"))
        XCTAssertNil(item(snap, name: "badcmd:bin", agentID: "claude-plugin-command"))
    }

    // MARK: - Emit order + loose fallback name

    func testScan_emitOrder_pluginSkillsBeforeCommands_afterTable() throws {
        try write(projectDir, ".claude/skills/localskill/SKILL.md", "local")
        let dir = homeDir.appendingPathComponent(".claude/plugins/cache/mp/ord/1.0.0")
        try write(dir, "skills/pskill/SKILL.md", "ps")
        try write(dir, "commands/pcmd.md", "pc")
        try writeInstalledPlugins(["ord@mp": dir.path])
        try writeEnabledPlugins(homeDir, ["ord@mp": true])
        let items = scan().items
        let localIdx = items.firstIndex { $0.agentID == "claude-skill" }!
        let skillIdx = items.firstIndex { $0.agentID == "claude-plugin-skill" }!
        let cmdIdx = items.firstIndex { $0.agentID == "claude-plugin-command" }!
        XCTAssertLessThan(localIdx, skillIdx)   // table source before plugins
        XCTAssertLessThan(skillIdx, cmdIdx)     // plugin skills before plugin commands
    }

    func testScan_looseProjectSkill_noFrontmatter_usesLeafDirName() throws {
        try write(projectDir, "Design/kit/SKILL.md", "plain body, no frontmatter")
        try write(projectDir, "Widgets/SKILL.md", "top-level plain")
        let snap = scan()
        XCTAssertNotNil(item(snap, name: "kit", agentID: "project-skill"))
        XCTAssertNotNil(item(snap, name: "Widgets", agentID: "project-skill"))
    }
}
