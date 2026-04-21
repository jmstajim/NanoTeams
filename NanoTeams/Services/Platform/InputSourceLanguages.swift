import Foundation

/// Maps the user's preferred languages (System Settings → General → Language
/// & Region → Preferred Languages) to speech-recognition locales. Dictation
/// uses this — no manual picker, ordering follows the system's Primary
/// language first.
///
/// This replaced an earlier implementation that enumerated keyboard input
/// sources via Carbon's Text Input Services. That approach was broken in
/// practice: Apple's "ABC" keyboard layout declares ~14 languages in its
/// `kTISPropertyInputSourceLanguages` (en, ca, da, de, es, fr, it, nl, pt,
/// sv, no, id, ms, hi) regardless of what the user actually types in.
/// `Locale.preferredLanguages` gives the real answer directly.
enum InputSourceLanguages {

    /// Returns unique speech-recognition locales derived from the user's
    /// Preferred Languages list. The first entry is the system's Primary.
    /// Empty-result fallback: `[en-US]`.
    static func currentSpeechLocales() -> [Locale] {
        var seen = Set<String>()
        var result: [Locale] = []

        for raw in Locale.preferredLanguages {
            let code = normalize(raw)
            guard !code.isEmpty else { continue }
            guard let locale = speechLocale(for: code) else { continue }
            // Dedup by final speech-locale identifier — several source codes
            // can map to the same locale (e.g. "no" and "nb" → nb-NO).
            guard !seen.contains(locale.identifier) else { continue }
            seen.insert(locale.identifier)
            result.append(locale)
        }

        return result.isEmpty ? [Locale(identifier: "en-US")] : result
    }

    // MARK: - Helpers

    /// Strips region / script suffix so "en-US" and "en-GB" both collapse to
    /// "en". Works on BCP-47 tags like "en-US", "zh-Hans-CN", "uk_UA".
    private static func normalize(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let separator = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(lower[..<separator])
        }
        return lower
    }

    /// Maps a bare language code (e.g. "en") to a concrete speech-recognition
    /// locale. Covers the most common dictation-supported locales; unknown
    /// codes return nil (skipped rather than guessed — wrong locale degrades
    /// recognition quality).
    private static func speechLocale(for code: String) -> Locale? {
        switch code {
        case "en": return Locale(identifier: "en-US")
        case "ru": return Locale(identifier: "ru-RU")
        case "de": return Locale(identifier: "de-DE")
        case "fr": return Locale(identifier: "fr-FR")
        case "es": return Locale(identifier: "es-ES")
        case "it": return Locale(identifier: "it-IT")
        case "pt": return Locale(identifier: "pt-BR")
        case "ja": return Locale(identifier: "ja-JP")
        case "ko": return Locale(identifier: "ko-KR")
        case "zh": return Locale(identifier: "zh-CN")
        case "uk": return Locale(identifier: "uk-UA")
        case "pl": return Locale(identifier: "pl-PL")
        case "nl": return Locale(identifier: "nl-NL")
        case "tr": return Locale(identifier: "tr-TR")
        case "ar": return Locale(identifier: "ar-SA")
        case "cs": return Locale(identifier: "cs-CZ")
        case "sv": return Locale(identifier: "sv-SE")
        case "da": return Locale(identifier: "da-DK")
        case "fi": return Locale(identifier: "fi-FI")
        case "no", "nb": return Locale(identifier: "nb-NO")
        case "he": return Locale(identifier: "he-IL")
        case "th": return Locale(identifier: "th-TH")
        case "vi": return Locale(identifier: "vi-VN")
        case "id": return Locale(identifier: "id-ID")
        case "ms": return Locale(identifier: "ms-MY")
        case "hu": return Locale(identifier: "hu-HU")
        case "ro": return Locale(identifier: "ro-RO")
        case "el": return Locale(identifier: "el-GR")
        case "hr": return Locale(identifier: "hr-HR")
        case "sk": return Locale(identifier: "sk-SK")
        case "ca": return Locale(identifier: "ca-ES")
        case "hi": return Locale(identifier: "hi-IN")
        default: return nil
        }
    }

    // MARK: - Testing seam

    #if DEBUG
    /// Exposes normalization + mapping for unit tests.
    static func _testSpeechLocale(for rawCode: String) -> Locale? {
        speechLocale(for: normalize(rawCode))
    }
    #endif
}
