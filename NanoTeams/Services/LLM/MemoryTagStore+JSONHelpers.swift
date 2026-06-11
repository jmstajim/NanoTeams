import Foundation

// MARK: - JSON Parsing Helpers

nonisolated extension MemoryTagStore {

    /// Extract "path" from arguments JSON: {"path": "..."}, canonicalized to one
    /// repo-relative spelling when a `workFolderRoot` is set. This keeps dedup,
    /// edit-invalidation, and the MEMORIES index from fragmenting when the model varies
    /// the path form (`src/x` vs `Foo/src/x` vs `./src/x` vs an absolute path). `nil`
    /// `workFolderRoot` → raw passthrough (no work-folder context). Paths that don't
    /// resolve cleanly (relative `..`, absolute-outside-root) hit `relativizePathspec`'s
    /// raw fallback and stay un-canonicalized — harmless, because such tool calls error
    /// upstream and every file processor discards the result via `.passthrough` (the
    /// `!result.isError` guard) before any key is built.
    func extractPath(from argsJSON: String) -> String? {
        guard let raw = extractString(from: argsJSON, key: "path") else { return nil }
        guard let root = workFolderRoot else { return raw }
        return SandboxPathResolver(workFolderRoot: root).relativizePathspec(raw)
    }

    /// Extract a string value from the "data" object of an envelope JSON:
    /// {"ok": true, "data": {"content": "...", ...}, ...}
    func extractDataString(from outputJSON: String, key: String) -> String? {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any],
              let value = data[key] as? String else {
            return nil
        }
        return value
    }

    /// Extract an int value from the "data" object of an envelope JSON.
    func extractDataInt(from outputJSON: String, key: String) -> Int? {
        guard let parsed = parseJSON(outputJSON),
              let data = parsed["data"] as? [String: Any],
              let value = data[key] as? Int else {
            return nil
        }
        return value
    }

    /// Extract a string value from a flat JSON object.
    func extractString(from json: String, key: String) -> String? {
        guard let parsed = parseJSON(json),
              let value = parsed[key] as? String else {
            return nil
        }
        return value
    }

    func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// JSON-escape a string for embedding in JSON output.
    ///
    /// Routes through the wire encoder so forward slashes stay literal (`/`, not
    /// `\/`). `JSONSerialization` always escapes slashes with no opt-out — and the
    /// `\/` sequences in file paths/content confuse small models into emitting
    /// literal backslashes in `edit_file` anchors (see `makeWireEncoder`). The
    /// encoder still escapes literal backslashes correctly (`\` → `\\`), so a path
    /// that genuinely contains a backslash round-trips intact — which a naive
    /// `\/`→`/` post-process would corrupt.
    func jsonEscape(_ string: String) -> String {
        if let data = try? JSONCoderFactory.makeWireEncoder().encode(string),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\(string)\""
    }

    // MARK: - Unchanged Reference

    /// Builds a compact JSON reference for an unchanged resource.
    /// `extras` are additional key-value pairs inserted before the ref/hint fields.
    func buildUnchangedReference(tag: String, extras: [(String, String)] = []) -> String {
        var parts = ["{\"status\":\"unchanged\""]
        for (key, value) in extras {
            parts.append(",\"\(key)\":\(jsonEscape(value))")
        }
        parts.append(",\"ref\":\"\(tag)\",\"_hint\":\"Do NOT re-read. See \(tag) above.\"}")
        return parts.joined()
    }
}
