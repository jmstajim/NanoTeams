import Foundation

/// Snapshot of agent skills / slash-commands discovered from well-known
/// AI-agent convention directories, in the open work folder and under the
/// user's home dir.
nonisolated struct AgentSkillsSnapshot: Codable, Hashable, Sendable {
    nonisolated struct Item: Codable, Hashable, Sendable, Identifiable {
        /// Collision-proof across agents, origins, and roots:
        /// `"<agentID>|<origin>|<relPathUnderRoot>"`. A project skill and a global
        /// skill with the same name are distinct items (origin differs).
        let id: String
        let name: String
        let description: String?
        let agentID: String
        let agentLabel: String
        let kindLabel: String
        let origin: AgentSkillOrigin
        /// Absolute URL of the file to read at pick time.
        let fileURL: URL
        /// Human-friendly path shown in the picker tooltip
        /// (`.claude/skills/x/SKILL.md` or `~/.codex/prompts/x.md`).
        let displayPath: String
    }

    let items: [Item]
    var isEmpty: Bool { items.isEmpty }
}

/// Targeted discovery of agent skills / commands. Unlike `AgentInstructionsScanner`
/// (a whole-tree walk for files that can live at any depth), skills live only
/// under a fixed set of dot-dir roots, so this probes those roots directly — plus
/// two manifest/tree-shaped sources that don't fit the fixed-subpath table:
/// enabled Claude Code **plugin** skills (`~/.claude/plugins`, resolved via the
/// installed-plugins manifest) and **loose** `SKILL.md` files anywhere in the open
/// work folder (e.g. a `DesignSystem/SKILL.md` outside `.claude/skills`).
///
/// **Deliberate delta from `AgentInstructionsScanner`: no symlink-escape guard.**
/// That guard exists because the sandboxed `read_file` tool would refuse a path
/// resolving outside the work folder. Here the *app* reads the file and inlines
/// its content at pick time — the LLM never dereferences the path — and dotfile
/// setups routinely symlink `~/.claude` → `~/dotfiles/claude`, so enforcing
/// containment would silently hide legitimate skills.
nonisolated enum AgentSkillsScanner {

    /// One well-known source convention. Extensible: adding an agent = appending
    /// a literal here.
    nonisolated struct SourceSpec: Sendable {
        enum Layout: Sendable {
            case skillDirectories            // recursive: any `<dir>/SKILL.md` below the root
            case markdownTree                // recursive **/*.md, "/"→":" names
            case flatFiles(suffix: String)   // top-level *<suffix>
            case tomlTree                    // recursive **/*.toml, "/"→":" names
        }
        let agentID: String
        let agentLabel: String
        let kindLabel: String
        /// Path relative to the work-folder root; nil = no project convention.
        let projectSubpath: String?
        /// Path relative to the home dir; nil = no global convention.
        let globalSubpath: String?
        let layout: Layout
    }

    static let sources: [SourceSpec] = [
        .init(agentID: "claude-skill", agentLabel: "Claude Code", kindLabel: "Skill",
              projectSubpath: ".claude/skills", globalSubpath: ".claude/skills",
              layout: .skillDirectories),
        .init(agentID: "claude-command", agentLabel: "Claude Code", kindLabel: "Command",
              projectSubpath: ".claude/commands", globalSubpath: ".claude/commands",
              layout: .markdownTree),
        .init(agentID: "codex-prompt", agentLabel: "Codex", kindLabel: "Prompt",
              projectSubpath: ".codex/prompts", globalSubpath: ".codex/prompts",
              layout: .flatFiles(suffix: ".md")),
        .init(agentID: "codex-skill", agentLabel: "Codex", kindLabel: "Skill",
              projectSubpath: ".codex/skills", globalSubpath: ".codex/skills",
              layout: .skillDirectories),
        .init(agentID: "cursor-command", agentLabel: "Cursor", kindLabel: "Command",
              projectSubpath: ".cursor/commands", globalSubpath: ".cursor/commands",
              layout: .flatFiles(suffix: ".md")),
        .init(agentID: "gemini-command", agentLabel: "Gemini CLI", kindLabel: "Command",
              projectSubpath: ".gemini/commands", globalSubpath: ".gemini/commands",
              layout: .tomlTree),
        .init(agentID: "copilot-prompt", agentLabel: "GitHub Copilot", kindLabel: "Prompt",
              projectSubpath: ".github/prompts", globalSubpath: nil,
              layout: .flatFiles(suffix: ".prompt.md")),
        .init(agentID: "windsurf-workflow", agentLabel: "Windsurf", kindLabel: "Workflow",
              projectSubpath: ".windsurf/workflows",
              globalSubpath: ".codeium/windsurf/global_workflows",
              layout: .flatFiles(suffix: ".md")),
        .init(agentID: "opencode-command", agentLabel: "OpenCode", kindLabel: "Command",
              projectSubpath: ".opencode/command", globalSubpath: ".config/opencode/command",
              layout: .flatFiles(suffix: ".md")),
    ]

    /// Max directory depth below any recursive root (`skillDirectories` /
    /// `markdownTree` / `tomlTree` / plugin + loose-project walks).
    private static let maxTreeDepth = 6
    /// Bytes probed for metadata — frontmatter/TOML keys sit at the top of the file.
    private static let probeBytes = 8192

    /// AgentIDs for the non-table (manifest/tree) sources.
    private static let pluginAgentID = "claude-plugin-skill"
    private static let pluginCommandAgentID = "claude-plugin-command"
    private static let looseProjectAgentID = "project-skill"

    /// Discovers skills. `projectRoot == nil` (default-storage mode) scans only
    /// the global roots (plus plugins enabled at the user level). `homeDirectory`
    /// is injectable for tests. Ordering is deterministic: sources-table order →
    /// project before global → name ascending; then loose project skills, then
    /// enabled plugin skills. A physical file is never listed twice (dedup by id
    /// and by canonical file path).
    static func scan(
        projectRoot: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> AgentSkillsSnapshot {
        var items: [AgentSkillsSnapshot.Item] = []
        var seenIDs: Set<String> = []
        var seenFileURLs: Set<String> = []

        func appendUnique(_ newItems: [AgentSkillsSnapshot.Item]) {
            for item in newItems {
                let canon = item.fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard !seenIDs.contains(item.id), !seenFileURLs.contains(canon) else { continue }
                seenIDs.insert(item.id)
                seenFileURLs.insert(canon)
                items.append(item)
            }
        }

        // 1. Fixed-subpath convention sources (project before global within each).
        for spec in sources {
            for origin in [AgentSkillOrigin.project, .global] {
                let base: URL?
                let subpath: String?
                switch origin {
                case .project: base = projectRoot; subpath = spec.projectSubpath
                case .global: base = homeDirectory; subpath = spec.globalSubpath
                }
                guard let base, let subpath else { continue }

                let rootURL = base.appendingPathComponent(subpath).standardizedFileURL
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

                appendUnique(collect(spec: spec, origin: origin, rootURL: rootURL, subpath: subpath, fileManager: fileManager))
            }
        }

        // 2. Loose SKILL.md anywhere in the open work folder (outside .claude/skills).
        if let projectRoot {
            appendUnique(collectLooseProjectSkills(projectRoot: projectRoot, fileManager: fileManager))
        }

        // 3. Skills + commands from enabled Claude Code plugins (~/.claude/plugins).
        appendUnique(collectClaudePluginItems(projectRoot: projectRoot, homeDirectory: homeDirectory, fileManager: fileManager))

        return AgentSkillsSnapshot(items: items)
    }

    /// Reads a picked skill's FULL content, fresh and uncapped (no size limit —
    /// per-product preference). Returns nil for a missing / non-UTF-8 / empty file.
    static func readFullContent(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Per-source collection

    private static func collect(
        spec: SourceSpec,
        origin: AgentSkillOrigin,
        rootURL: URL,
        subpath: String,
        fileManager: FileManager
    ) -> [AgentSkillsSnapshot.Item] {
        var items: [AgentSkillsSnapshot.Item] = []
        for entry in enumerateFiles(layout: spec.layout, rootURL: rootURL, fileManager: fileManager) {
            let displayPath = origin == .project ? "\(subpath)/\(entry.relPath)" : "~/\(subpath)/\(entry.relPath)"

            switch spec.layout {
            case .skillDirectories:
                if let item = buildSkillItem(
                    fileURL: entry.fileURL, relPath: entry.relPath, fallbackName: leafDirName(entry.relPath),
                    agentID: spec.agentID, agentLabel: spec.agentLabel, kindLabel: spec.kindLabel,
                    origin: origin, displayPath: displayPath, fileManager: fileManager
                ) {
                    items.append(item)
                }

            case .flatFiles, .markdownTree, .tomlTree:
                // Non-UTF-8 / empty candidates are not real skills — skip.
                guard let probe = probeText(at: entry.fileURL) else { continue }
                let name: String
                let description: String?
                switch spec.layout {
                case .flatFiles(let suffix):
                    name = String(entry.relPath.dropLast(suffix.count))
                    description = SkillMetadataExtractor.frontmatterFields(["description"], in: probe)["description"]
                case .markdownTree:
                    name = namespacedName(entry.relPath, ext: ".md")
                    description = SkillMetadataExtractor.frontmatterFields(["description"], in: probe)["description"]
                case .tomlTree:
                    name = namespacedName(entry.relPath, ext: ".toml")
                    description = SkillMetadataExtractor.tomlDescription(in: probe)
                case .skillDirectories:
                    continue  // handled above
                }
                guard !name.isEmpty else { continue }
                items.append(.init(
                    id: "\(spec.agentID)|\(origin.rawValue)|\(entry.relPath)",
                    name: name, description: description, agentID: spec.agentID,
                    agentLabel: spec.agentLabel, kindLabel: spec.kindLabel, origin: origin,
                    fileURL: entry.fileURL, displayPath: displayPath
                ))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Builds a skill item from a `SKILL.md`: probes the leading bytes, prefers a
    /// frontmatter `name`, else `fallbackName`. Returns nil for a non-UTF-8 / empty
    /// file or an empty resolved name.
    private static func buildSkillItem(
        fileURL: URL, relPath: String, fallbackName: String,
        agentID: String, agentLabel: String, kindLabel: String,
        origin: AgentSkillOrigin, displayPath: String, fileManager: FileManager
    ) -> AgentSkillsSnapshot.Item? {
        guard let probe = probeText(at: fileURL) else { return nil }
        let fm = SkillMetadataExtractor.frontmatterFields(["name", "description"], in: probe)
        let name = fm["name"] ?? fallbackName
        guard !name.isEmpty else { return nil }
        return .init(
            id: "\(agentID)|\(origin.rawValue)|\(relPath)",
            name: name, description: fm["description"], agentID: agentID,
            agentLabel: agentLabel, kindLabel: kindLabel, origin: origin,
            fileURL: fileURL, displayPath: displayPath
        )
    }

    private struct Entry {
        let relPath: String   // relative to the source root
        let fileURL: URL
    }

    private static func enumerateFiles(layout: SourceSpec.Layout, rootURL: URL, fileManager: FileManager) -> [Entry] {
        switch layout {
        case .skillDirectories:
            return walkSkillDirs(rootURL: rootURL, fileManager: fileManager)

        case .flatFiles(let suffix):
            guard let children = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return [] }
            var entries: [Entry] = []
            let lowerSuffix = suffix.lowercased()
            for name in children.sorted() where !WalkSkipRules.shouldSkip(name: name) {
                guard name.lowercased().hasSuffix(lowerSuffix) else { continue }
                let fileURL = rootURL.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                entries.append(Entry(relPath: name, fileURL: fileURL))
            }
            return entries

        case .markdownTree:
            return walkTree(rootURL: rootURL, ext: ".md", fileManager: fileManager)
        case .tomlTree:
            return walkTree(rootURL: rootURL, ext: ".toml", fileManager: fileManager)
        }
    }

    /// Recursively finds skill directories below `rootURL`. A directory that
    /// directly contains a regular-file `SKILL.md` **is** a skill — it is emitted
    /// and NOT descended into (so a skill's own internal example/resource
    /// `SKILL.md` never surfaces). The root itself is never a skill; only its
    /// descendants. Hidden convention dirs (`.system`, `.agents`) are traversed —
    /// they are not in `WalkSkipRules`. Bounded depth + symlink-cycle guard.
    /// `extraSkips` are directory names skipped at every level (used by the
    /// loose-project walk to exclude `.claude` / `.nanoteams`).
    private static func walkSkillDirs(rootURL: URL, extraSkips: Set<String> = [], fileManager: FileManager) -> [Entry] {
        var results: [Entry] = []
        var visited: Set<String> = []

        func recurse(_ dir: URL, _ relPrefix: String, _ depth: Int) {
            guard depth <= maxTreeDepth else { return }
            let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard !visited.contains(canonical) else { return }
            visited.insert(canonical)

            if !relPrefix.isEmpty {
                let skillFile = dir.appendingPathComponent("SKILL.md")
                var fIsDir: ObjCBool = false
                if fileManager.fileExists(atPath: skillFile.path, isDirectory: &fIsDir), !fIsDir.boolValue {
                    results.append(Entry(relPath: "\(relPrefix)/SKILL.md", fileURL: skillFile))
                    return  // this dir is a skill — stop descending
                }
            }

            guard let children = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
            for name in children.sorted()
                where !WalkSkipRules.shouldSkip(name: name) && !extraSkips.contains(name) {
                let childURL = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let rel = relPrefix.isEmpty ? name : "\(relPrefix)/\(name)"
                recurse(childURL, rel, depth + 1)
            }
        }
        recurse(rootURL, "", 0)
        return results
    }

    /// Recursive collection of files ending in `ext`, bounded depth + symlink-cycle guard.
    private static func walkTree(rootURL: URL, ext: String, fileManager: FileManager) -> [Entry] {
        var results: [Entry] = []
        var visited: Set<String> = []
        let lowerExt = ext.lowercased()

        func recurse(_ dir: URL, _ relPrefix: String, _ depth: Int) {
            guard depth <= maxTreeDepth else { return }
            let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
            guard !visited.contains(canonical) else { return }
            visited.insert(canonical)

            guard let children = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
            for name in children.sorted() where !WalkSkipRules.shouldSkip(name: name) {
                let childURL = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: childURL.path, isDirectory: &isDir) else { continue }
                let rel = relPrefix.isEmpty ? name : "\(relPrefix)/\(name)"
                if isDir.boolValue {
                    recurse(childURL, rel, depth + 1)
                } else if name.lowercased().hasSuffix(lowerExt) {
                    results.append(Entry(relPath: rel, fileURL: childURL))
                }
            }
        }
        recurse(rootURL, "", 0)
        return results
    }

    // MARK: - Loose project skills

    /// Recursively finds `SKILL.md` files anywhere in the open work folder that
    /// aren't already covered by the `.claude/skills` source — e.g. a
    /// `DesignSystem/SKILL.md`. Skips `.claude` (its skills come from source #1)
    /// and `.nanoteams` wholesale (task attachments must never become skills, the
    /// same rule `AgentInstructionsScanner` applies). `WalkSkipRules` already
    /// excludes `node_modules`, `.build`, `DerivedData`, `Pods`, `vendor`, etc.
    private static func collectLooseProjectSkills(projectRoot: URL, fileManager: FileManager) -> [AgentSkillsSnapshot.Item] {
        // Skip every convention root (their skills come from the table sources) plus
        // .nanoteams — the loose walk exists only for SKILL.md outside those.
        var skips: Set<String> = [".nanoteams"]
        for spec in sources {
            if let top = spec.projectSubpath?.split(separator: "/").first { skips.insert(String(top)) }
        }

        var items: [AgentSkillsSnapshot.Item] = []
        for entry in walkSkillDirs(rootURL: projectRoot, extraSkips: skips, fileManager: fileManager) {
            if let item = buildSkillItem(
                fileURL: entry.fileURL, relPath: entry.relPath, fallbackName: leafDirName(entry.relPath),
                agentID: looseProjectAgentID, agentLabel: "Claude Code", kindLabel: "Skill",
                origin: .project, displayPath: entry.relPath, fileManager: fileManager
            ) {
                items.append(item)
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Claude plugin skills + commands

    /// Surfaces skills AND slash-commands from **enabled** Claude Code plugins.
    /// Mirrors Claude Code's own resolution instead of a blind `find`: read the
    /// enabled-plugins set from `.claude/settings.json` (work folder + user),
    /// resolve each plugin's already-version-pinned `installPath` from
    /// `installed_plugins.json` (so cache version-duplicates never double-list),
    /// then walk that plugin dir for `SKILL.md` (skills) and `commands/**/*.md`
    /// (commands, namespaced `<plugin>:<path>` so same-named commands across
    /// plugins stay distinct — the clip format keys staged-detection on name).
    /// Returns skills first, then commands, each name-sorted.
    private static func collectClaudePluginItems(
        projectRoot: URL?, homeDirectory: URL, fileManager: FileManager
    ) -> [AgentSkillsSnapshot.Item] {
        let enabled = enabledPluginKeys(projectRoot: projectRoot, homeDirectory: homeDirectory)
        guard !enabled.isEmpty else { return [] }

        let installPaths = pluginInstallPaths(homeDirectory: homeDirectory, fileManager: fileManager)
        let marketplaces = marketplaceLocations(homeDirectory: homeDirectory)

        var skills: [AgentSkillsSnapshot.Item] = []
        var commands: [AgentSkillsSnapshot.Item] = []

        for key in enabled.sorted() {
            guard let pluginDir = resolvePluginDir(key: key, installPaths: installPaths, marketplaces: marketplaces, fileManager: fileManager) else { continue }
            let pluginShort = String(key.split(separator: "@").first ?? Substring(key))

            // Skills — SKILL.md at the plugin root (single-skill plugin) or below.
            func appendPluginSkill(fileURL: URL, relSuffix: String, fallbackName: String) {
                if let item = buildSkillItem(
                    fileURL: fileURL, relPath: "\(key)/\(relSuffix)", fallbackName: fallbackName,
                    agentID: pluginAgentID, agentLabel: "Claude Code", kindLabel: "Plugin Skill",
                    origin: .global, displayPath: "~/.claude/plugins/\(key)/\(relSuffix)", fileManager: fileManager
                ) {
                    skills.append(item)
                }
            }
            let rootSkill = pluginDir.appendingPathComponent("SKILL.md")
            var rootIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: rootSkill.path, isDirectory: &rootIsDir), !rootIsDir.boolValue {
                appendPluginSkill(fileURL: rootSkill, relSuffix: "SKILL.md", fallbackName: pluginShort)
            }
            for entry in walkSkillDirs(rootURL: pluginDir, fileManager: fileManager) {
                appendPluginSkill(fileURL: entry.fileURL, relSuffix: entry.relPath, fallbackName: leafDirName(entry.relPath))
            }

            // Commands — commands/**/*.md, namespaced by plugin to stay unique.
            let commandsDir = pluginDir.appendingPathComponent("commands")
            var cmdIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: commandsDir.path, isDirectory: &cmdIsDir), cmdIsDir.boolValue else { continue }
            for entry in walkTree(rootURL: commandsDir, ext: ".md", fileManager: fileManager) {
                guard let probe = probeText(at: entry.fileURL) else { continue }
                let relPath = "\(key)/commands/\(entry.relPath)"
                commands.append(.init(
                    id: "\(pluginCommandAgentID)|\(AgentSkillOrigin.global.rawValue)|\(relPath)",
                    name: "\(pluginShort):\(namespacedName(entry.relPath, ext: ".md"))",
                    description: SkillMetadataExtractor.frontmatterFields(["description"], in: probe)["description"],
                    agentID: pluginCommandAgentID, agentLabel: "Claude Code", kindLabel: "Plugin Command",
                    origin: .global, fileURL: entry.fileURL, displayPath: "~/.claude/plugins/\(relPath)"
                ))
            }
        }

        let byName: (AgentSkillsSnapshot.Item, AgentSkillsSnapshot.Item) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return skills.sorted(by: byName) + commands.sorted(by: byName)
    }

    /// `enabledPlugins` keys resolved to `true` across the settings files, merged
    /// with Claude Code's precedence (low → high: user-global `~/.claude/settings.json`
    /// → work-folder `settings.json` → `settings.local.json`), so a plugin turned
    /// OFF in a higher-precedence file overrides an ON in a lower one. Keys are
    /// `"<plugin>@<marketplace>"`. Read leniently per-key: a non-bool value (stray
    /// hand-edit / `null`) skips that one key, never drops the whole file.
    private static func enabledPluginKeys(projectRoot: URL?, homeDirectory: URL) -> Set<String> {
        var files: [URL] = [homeDirectory.appendingPathComponent(".claude/settings.json")]
        if let projectRoot {
            files.append(projectRoot.appendingPathComponent(".claude/settings.json"))
            files.append(projectRoot.appendingPathComponent(".claude/settings.local.json"))
        }

        var merged: [String: Bool] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plugins = object["enabledPlugins"] as? [String: Any] else { continue }
            for (key, value) in plugins {
                if let flag = value as? Bool { merged[key] = flag }  // later file overrides earlier
            }
        }
        return Set(merged.filter { $0.value }.map(\.key))
    }

    /// `"<plugin>@<marketplace>"` → the (first existing) version-pinned install dir
    /// from `~/.claude/plugins/installed_plugins.json`.
    private static func pluginInstallPaths(homeDirectory: URL, fileManager: FileManager) -> [String: URL] {
        let url = homeDirectory.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONCoderFactory.makeWireDecoder().decode(InstalledPluginsDTO.self, from: data) else { return [:] }

        var result: [String: URL] = [:]
        for (key, records) in decoded.plugins ?? [:] {
            for record in records {
                guard let path = record.installPath, !path.isEmpty else { continue }
                let dir = URL(fileURLWithPath: path)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    result[key] = dir
                    break
                }
            }
        }
        return result
    }

    /// Marketplace name → its `installLocation` (fallback plugin-dir resolution
    /// when a plugin isn't in `installed_plugins.json`).
    private static func marketplaceLocations(homeDirectory: URL) -> [String: URL] {
        let url = homeDirectory.appendingPathComponent(".claude/plugins/known_marketplaces.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONCoderFactory.makeWireDecoder().decode([String: MarketplaceDTO].self, from: data) else { return [:] }

        var result: [String: URL] = [:]
        for (name, entry) in decoded {
            if let loc = entry.installLocation, !loc.isEmpty { result[name] = URL(fileURLWithPath: loc) }
        }
        return result
    }

    private static func resolvePluginDir(
        key: String, installPaths: [String: URL], marketplaces: [String: URL], fileManager: FileManager
    ) -> URL? {
        if let dir = installPaths[key] { return dir }
        // Fallback: "<plugin>@<marketplace>" → marketplace location + plugin subdir.
        let parts = key.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let mpDir = marketplaces[String(parts[1])] else { return nil }
        let plugin = String(parts[0])
        for candidate in [mpDir.appendingPathComponent("plugins/\(plugin)"), mpDir.appendingPathComponent(plugin)] {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate }
        }
        return nil
    }

    // MARK: - Manifest DTOs

    private nonisolated struct InstalledPluginsDTO: Decodable {
        let plugins: [String: [Record]]?
        nonisolated struct Record: Decodable { let installPath: String? }
    }

    private nonisolated struct MarketplaceDTO: Decodable {
        let installLocation: String?
    }

    // MARK: - Helpers

    private static func namespacedName(_ relPath: String, ext: String) -> String {
        var s = relPath
        if s.lowercased().hasSuffix(ext.lowercased()) { s = String(s.dropLast(ext.count)) }
        return s.replacingOccurrences(of: "/", with: ":")
    }

    /// The leaf directory name of a `.../SKILL.md` relPath — the skill's default
    /// name when it has no frontmatter `name` (e.g. `cat/name/SKILL.md` → `name`).
    private static func leafDirName(_ relPath: String) -> String {
        let dir = relPath.hasSuffix("/SKILL.md") ? String(relPath.dropLast("/SKILL.md".count)) : relPath
        return dir.split(separator: "/").last.map(String.init) ?? dir
    }

    /// Reads the leading `probeBytes` as tolerant UTF-8 (drops up to 3 trailing
    /// bytes cut mid-character). Returns nil for a binary or empty file.
    private static func probeText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let prefix = (try? handle.read(upToCount: probeBytes)) ?? Data()
        try? handle.close()
        var slice = prefix
        for _ in 0...3 {
            if let s = String(data: slice, encoding: .utf8) {
                return s.isEmpty ? nil : s
            }
            guard !slice.isEmpty else { return nil }
            slice = slice.dropLast()
        }
        return nil
    }
}
