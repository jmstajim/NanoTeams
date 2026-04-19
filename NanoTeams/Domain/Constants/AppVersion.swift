import Foundation

/// Helpers for comparing app versions.
///
/// Used by:
/// - `NTMSRepository+Bootstrap` to trigger the version-bump reconcile pass when
///   `WorkFolderState.lastAppliedAppVersion` is older than the running binary's
///   `CFBundleShortVersionString`.
/// - `AppUpdateChecker`/`AppUpdateState` to decide whether a fetched GitHub
///   release tag is newer than the installed app.
///
/// Version strings follow a relaxed semver: `[v]N(.N)*(<non-numeric suffix>)?`.
/// Any `v`/`V` prefix is stripped; dot-separated numeric components are compared
/// lexicographically as integers; a trailing non-numeric component is ignored
/// (so `1.0.0-beta` and `1.0.0` compare equal).
enum AppVersion {
    /// Current app version from `Info.plist` (`CFBundleShortVersionString`).
    /// Falls back to `"0.0.0"` when the key is missing, which makes
    /// `shouldReconcile(from: <anything>, to: current)` return `false` in test
    /// harnesses that don't set the bundle key.
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Empty `stored` always triggers reconcile (first-open). Downgrade is a
    /// no-op — we never regress bundled content on a rollback install.
    static func shouldReconcile(from stored: String, to current: String) -> Bool {
        if stored.isEmpty { return true }
        return compare(stored, current) < 0
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let lhs = numericComponents(of: a)
        let rhs = numericComponents(of: b)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func numericComponents(of version: String) -> [Int] {
        var stripped = version
        if let first = stripped.first, first == "v" || first == "V" {
            stripped.removeFirst()
        }
        // Drop everything from the first semver pre-release / build-metadata
        // marker onward. `1.0.0-rc.1` and `1.0.0+sha1` both collapse to `1.0.0`,
        // matching user-visible "same version" expectation.
        if let dashRange = stripped.firstIndex(of: "-") {
            stripped = String(stripped[..<dashRange])
        }
        if let plusRange = stripped.firstIndex(of: "+") {
            stripped = String(stripped[..<plusRange])
        }
        return stripped.split(separator: ".").map { segment -> Int in
            var digits = ""
            for ch in segment {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            return Int(digits) ?? 0
        }
    }
}
