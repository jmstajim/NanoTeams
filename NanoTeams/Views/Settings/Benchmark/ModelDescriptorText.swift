import Foundation

/// How a model's file format and its quantization are SPELLED on screen — one rule, whatever draws
/// them.
///
/// Two renderers ask it now: the capsules beside a model name (`ModelChipsRow`, in the sweep list
/// and the Run tab's picker) and the `Format` / `Quantization` columns of both benchmark tables.
/// The rule lives here rather than inside either one because a second copy would drift — the tables
/// would print `gguf` while the sweep printed `GGUF`, and a reader comparing the two surfaces would
/// have no way to know they are the same fact (CLAUDE.md #55).
///
/// Nothing here decides what an ABSENT value looks like. That genuinely differs by renderer: a
/// capsule standing alone is a claim and is simply not drawn, while a table cell sits under a
/// heading that already named the quantity, so its emptiness has to be spelled — `—`, exactly as
/// the Version column already spells a server that reports no version. Both callers get `nil` and
/// answer that question themselves.
nonisolated enum ModelDescriptorText {

    /// Uppercased: GGUF, MLX and SAFETENSORS are initialisms, and that is how the field spells
    /// them regardless of the casing a given server happens to send.
    ///
    /// Trimmed first, so a server answering `" "` renders as nothing rather than as an empty
    /// capsule or a blank cell — an unlabelled gap in a column reads as a rendering bug, and in a
    /// capsule it reads as a value nobody can name.
    static func format(_ raw: String?) -> String? {
        nonEmpty(raw)?.uppercased()
    }

    /// Verbatim — `Q4_K_M`, `4bit`, `nvfp4`, `MXFP4`. Never uppercased and never normalized: these
    /// are exact identifiers, `4BIT` is a spelling no server uses, and a reader who wants to look
    /// one up or match it against another tool's output needs the string the server actually sent.
    static func quantization(_ raw: String?) -> String? {
        nonEmpty(raw)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
