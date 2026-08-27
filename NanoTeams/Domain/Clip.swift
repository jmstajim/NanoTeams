import Foundation

// MARK: - Clip

/// A clipped text snippet with a stable identity.
///
/// ## Why the identity is a stored property and not a computed one
///
/// Clips are rendered in `ForEach` and deleted positionally. Every identity derivable
/// from the CONTENT fails one of the two jobs an id has to do: `\.offset` is the
/// position, so deleting index 0 renumbers every survivor and the wrong row animates
/// out; `text` collides whenever the user clips the same snippet twice; and
/// `hashValue` is randomized per process, so it is not even stable across a relaunch
/// (CLAUDE.md #22/#23). The only thing that survives an insert, a delete and a
/// reorder is an id assigned once, at insertion, and carried in the data.
///
/// ## Two ways in, on purpose
///
/// `init(text:)` mints a fresh id and is for the MUTABLE, persisted path — the
/// composer's clip list, `NTMSTask.clippedTexts`. `derived(text:ordinal:seed:)` is
/// for the READ-ONLY path, where clips are re-parsed out of a message body on every
/// feed rebuild and there is no insertion event to hang an id on. A minted id there
/// would be worse than `\.offset`, not better: a new UUID per rebuild churns identity
/// on every event, where the offset at least stayed put. The derived form hashes
/// (seed, ordinal, text) so the same message yields the same ids forever, and two
/// identical clips in one message stay distinct.
///
/// The `text` is carried VERBATIM. It is not always prose: `SkillsPickerButton`
/// appends `SkillClip.encoded()` sentinel strings — a zero-width-space header plus a
/// body — into the same list, and `SkillClip.parse` / `ClipCellPresentation` branch on
/// exactly those bytes. Trimming or normalizing here would silently un-skill a clip.
nonisolated struct Clip: Identifiable, Codable, Hashable, Sendable {

    let id: UUID
    var text: String

    /// A clip the user just added. Fresh identity, carried from here on.
    init(text: String) {
        self.id = UUID()
        self.text = text
    }

    init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }

    /// A clip re-derived from immutable content, with an id that is a pure function of
    /// its inputs — so the same message rebuilds to the same identities.
    ///
    /// `seed` should name the thing the clip was parsed out of (a message id, a step
    /// id). `ordinal` disambiguates two identical clips inside one seed, which is the
    /// case a content-only id gets wrong.
    static func derived(text: String, ordinal: Int, seed: String) -> Clip {
        Clip(id: deterministicID(for: "\(seed)\u{1}\(ordinal)\u{1}\(text)"), text: text)
    }

    /// A UUID that is a pure function of `input`.
    ///
    /// FNV-1a over UTF-8, run twice with different offset bases to fill 16 bytes.
    /// Deliberately not `hashValue`: Swift seeds that per process, which is the exact
    /// property #22 names. Deliberately not CryptoKit either — this is an identity for
    /// a view diff, not a security boundary, and keeping `Domain/` on Foundation alone
    /// is a house rule.
    private static func deterministicID(for input: String) -> UUID {
        var bytes = [UInt8]()
        for base in [UInt64(0xcbf2_9ce4_8422_2325), UInt64(0x9dc5_bb1a_1f4f_2e17)] {
            var hash = base
            for byte in Array(input.utf8) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: hash >> UInt64(shift)))
            }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated extension Array where Element == Clip {

    /// The clip texts, in order — what the prompt builder, the conversation-log
    /// renderer and every other wire-facing consumer actually want. Identity stops at
    /// the view layer on purpose: nothing downstream of the UI has any use for it, and
    /// widening the wire types would have made this a 339-site change instead of a
    /// model one.
    var texts: [String] { map(\.text) }

    /// Wraps plain strings, minting identities. The entry point for legacy decode and
    /// for callers that genuinely have only text.
    static func minting(_ texts: [String]) -> [Clip] { texts.map { Clip(text: $0) } }
}
