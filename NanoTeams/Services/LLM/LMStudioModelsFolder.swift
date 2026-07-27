import Foundation

/// Pure decisions behind LM Studio's filesystem-based model deletion.
///
/// All of the risk in that feature lives here — "is this endpoint actually this
/// machine", "where does LM Studio keep its downloads", and "does this id
/// resolve to a directory we are allowed to move to the Trash" — so it is a
/// dependency-free `nonisolated enum` that can be exhaustively unit-tested
/// without touching a real models folder. `LMStudioDownloadedModelStore` does
/// the I/O and nothing else.
nonisolated enum LMStudioModelsFolder {

    /// Path components under the user's home where LM Studio keeps its state.
    static let settingsRelativePath = ".lmstudio/settings.json"
    static let defaultModelsRelativePath = ".lmstudio/models"

    /// Key in `~/.lmstudio/settings.json` holding the user-chosen models
    /// directory (LM Studio surfaces it as "Models Directory").
    private static let downloadsFolderKey = "downloadsFolder"

    // MARK: - Locality

    /// Whether `baseURLString` addresses THIS machine.
    ///
    /// Deliberately a strict allowlist with no DNS/hostname resolution. The two
    /// failure directions are not symmetric: a false negative only disables the
    /// Remove button (the user can still delete in LM Studio), while a false
    /// positive would move local files to the Trash while the user believes
    /// they are managing a remote host. Erring toward "not local" is the only
    /// safe direction.
    static func isLocalEndpoint(baseURLString: String) -> Bool {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else {
            return false
        }
        // `URL.host` keeps IPv6 literals unbracketed on macOS, but strip them
        // defensively so `[::1]` can't slip past the equality check.
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if normalized == "localhost" || normalized == "::1" || normalized == "0.0.0.0" {
            return true
        }
        // The whole 127.0.0.0/8 block is loopback, not just 127.0.0.1.
        return isLoopbackIPv4(normalized)
    }

    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    // MARK: - Models root

    /// LM Studio's models directory: the `downloadsFolder` it records in its own
    /// settings, falling back to the stock `~/.lmstudio/models`.
    ///
    /// Returns `nil` when neither resolves to an existing directory — the caller
    /// turns that into a user-facing "couldn't find LM Studio's models folder"
    /// rather than guessing a path and walking it.
    static func resolveRoot(home: URL, fileManager: FileManager) -> URL? {
        if let configured = configuredRoot(home: home, fileManager: fileManager),
           isUsableRoot(configured, fileManager: fileManager) {
            return configured
        }
        let fallback = home.appending(path: defaultModelsRelativePath)
        return isUsableRoot(fallback, fileManager: fileManager) ? fallback : nil
    }

    /// An existing directory that isn't the filesystem root.
    ///
    /// The root check is not theoretical paranoia: `downloadsFolder` is a plain
    /// string in someone else's settings file, and `/` is exactly what a
    /// mangled or truncated value degrades into. With `/` accepted, every
    /// `/<dir>/<subdir>` on the machine would list as a deletable "model".
    /// Rejecting it costs nothing — nobody keeps their models at `/`.
    private static func isUsableRoot(_ url: URL, fileManager: FileManager) -> Bool {
        !SandboxPathResolver.addressesFilesystemRoot(url) && isDirectory(url, fileManager: fileManager)
    }

    private static func configuredRoot(home: URL, fileManager: FileManager) -> URL? {
        let settingsURL = home.appending(path: settingsRelativePath)
        guard let data = fileManager.contents(atPath: settingsURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object[downloadsFolderKey] as? String
        else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // LM Studio writes an absolute path, but tolerate a `~` form.
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    // MARK: - Id → directory

    /// Resolves a `<publisher>/<repoDir>` id to the absolute directory it names,
    /// or `nil` if the id is not one we are willing to delete.
    ///
    /// Every rejection here is deliberate:
    /// - exactly two non-empty components — LM Studio's layout is
    ///   `<root>/<publisher>/<repo>`, so one component would target a whole
    ///   publisher and three would target a file inside a model;
    /// - no `.` or `..` component, so an id can't climb out lexically;
    /// - containment re-checked on the SYMLINK-RESOLVED paths, so a symlink
    ///   planted inside the root can't redirect the delete elsewhere. Both
    ///   sides are resolved, which is what keeps a legitimately symlinked
    ///   models root (models on an external drive is a common setup) working;
    /// - strictly deeper than the root, so the root itself is never a target.
    ///
    /// Containment uses the shared `SandboxPathResolver.isWithin`, which
    /// compares path COMPONENTS — a `hasPrefix` check would accept a sibling
    /// directory whose name merely starts with the root's.
    static func resolveModelDirectory(id: String, root: URL) -> URL? {
        let components = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2 else { return nil }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }

        let candidate = root.appending(path: components[0]).appending(path: components[1])

        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard SandboxPathResolver.isWithin(candidate: resolvedCandidate, container: resolvedRoot) else {
            return nil
        }
        guard resolvedCandidate.standardizedFileURL.pathComponents.count
            > resolvedRoot.standardizedFileURL.pathComponents.count
        else { return nil }

        return candidate
    }

    // MARK: - Reference hints

    /// Model identifiers this on-disk folder might be referenced by in settings
    /// or team roles.
    ///
    /// LM Studio's model key is derived from the folder but not equal to it —
    /// its own index maps `unsloth/gpt-oss-20b-GGUF/…` to the key
    /// `unsloth/gpt-oss-20b`. Rather than depend on that undocumented rule for
    /// anything load-bearing, we emit a few candidates and use them ONLY to
    /// decorate the confirmation and to decide whether to unload first. The
    /// delete target is always the exact directory, so an imperfect hint costs
    /// at most a spurious or missing warning.
    static func referenceHints(publisher: String, repoDir: String) -> [String] {
        var hints: [String] = ["\(publisher)/\(repoDir)"]
        for suffix in ["-GGUF", "-gguf"] where repoDir.hasSuffix(suffix) {
            hints.append("\(publisher)/\(String(repoDir.dropLast(suffix.count)))")
        }
        hints.append(repoDir)
        return hints.normalizedUnique()
    }
}
