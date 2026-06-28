import Foundation

/// Single source of truth for resolving `bash` tool arguments from a decoded
/// args dictionary OR the raw arguments JSON.
///
/// SECURITY-CRITICAL: the permission gate (`gateBashCalls`) and the handler
/// (`BashTool.handle`) MUST resolve the command identically. If they diverge, a
/// command supplied under a key the gate doesn't recognize — or a benign decoy in
/// `command` with the real command in `content` — would be *judged* on one string
/// but *executed* as another, bypassing the entire permission layer. Both sides
/// call `command(...)` here so they can never drift.
nonisolated enum BashArguments {

    /// Structural keys that are never the command body — excluded from the
    /// resilient content fallback in `resolveContentString`.
    static let nonCommandKeys: Set<String> = ["timeout", "working_directory", "run_in_background"]

    /// Resolves the shell command EXACTLY as `BashTool` executes it: the resilient
    /// `content`/alias/single-remaining resolver first, then an explicit `command`
    /// key. Returns `nil` when no non-empty command is present.
    static func command(from args: [String: Any]) -> String? {
        if let c = resolveContentString(args, excludeKeys: nonCommandKeys),
           !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c
        }
        if let c = optionalString(args, "command"),
           !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c
        }
        return nil
    }

    /// JSON convenience for the gate (which holds `argumentsJSON`, not a dict).
    static func command(fromJSON argumentsJSON: String) -> String? {
        decode(argumentsJSON).flatMap(command(from:))
    }

    static func workingDirectory(from args: [String: Any]) -> String? {
        optionalString(args, "working_directory").flatMap { $0.isEmpty ? nil : $0 }
    }

    static func workingDirectory(fromJSON argumentsJSON: String) -> String? {
        decode(argumentsJSON).flatMap(workingDirectory(from:))
    }

    /// Validated foreground timeout in SECONDS. Returns `nil` for a non-positive
    /// requested value (caller surfaces `INVALID_ARGS` rather than silently
    /// masking a sign typo). A value above `maxTimeoutMilliseconds` is clamped;
    /// a sub-second value floors to 1s.
    static func resolveTimeoutSeconds(milliseconds: Int?) -> TimeInterval? {
        let ms = milliseconds ?? BashConstants.defaultTimeoutMilliseconds
        guard ms > 0 else { return nil }
        let clamped = min(ms, BashConstants.maxTimeoutMilliseconds)
        return max(Double(clamped) / 1000.0, 1)
    }

    private static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
