import CryptoKit
import Foundation

/// The fingerprint a tool is pinned by.
///
/// **What it covers and why that set.** A server can change a tool in two ways that matter:
/// it can change what the tool DOES (the schema, the header parameters, the annotations it
/// claims) or it can change what the tool SAYS it does (the name, the title, the description —
/// the text the model treats as instructions). Both are in. Nothing else is: a server is free
/// to add pagination cursors, `_meta`, icons or extension keys without sending every user back
/// through the review sheet.
///
/// **Why the hash is over the RAW frame, not the projection.** The projection is lossy by
/// design — `MCPSchemaProjection` folds multi-type properties, drops constraints into prose
/// and caps nesting. Two different schemas can project to the same prose, and a server that
/// found such a pair could swap one for the other under an unchanged pin. Hashing what
/// arrived removes the question.
///
/// A consequence worth stating: a semantically-neutral edit — a server spelling out
/// `"readOnlyHint": false` where it previously said nothing — DOES change the hash and does
/// send the tool back for review. That is the correct trade. A hash that tried to be clever
/// about which changes are neutral would be a second, weaker schema interpreter sitting behind
/// the security boundary.
nonisolated enum MCPPinHasher {

    /// The members of a `tools/list` entry the pin covers, in the order they are read (the
    /// canonical JSON sorts them again, so this order is documentation, not protocol).
    static let pinnedKeys = ["name", "title", "description", "inputSchema", "outputSchema", "annotations"]

    /// Hex SHA-256 over the canonical JSON of the pinned members.
    ///
    /// Canonicalisation is what makes the hash stable across the server re-serialising its own
    /// catalogue: `JSONValue.canonicalJSONString()` sorts object keys and prints integral
    /// numbers without a fractional part, so a server that re-orders its `properties` between
    /// two `tools/list` calls does not read as a rug pull.
    static func hash(rawTool: JSONValue) -> String {
        hash(canonicalForm: canonicalForm(rawTool: rawTool))
    }

    /// The exact bytes the hash is taken over. Public so the review sheet can show a changed
    /// tool's two canonical forms side by side instead of two opaque hex strings.
    static func canonicalForm(rawTool: JSONValue) -> String {
        guard case .object(let object) = rawTool else {
            // A non-object entry is not a tool; it still gets a stable hash so the caller can
            // report "changed" rather than crash, and the projection refuses it one layer up.
            return rawTool.canonicalJSONString()
        }
        var pinned: [String: JSONValue] = [:]
        for key in pinnedKeys {
            if let value = object[key] { pinned[key] = value }
        }
        return JSONValue.object(pinned).canonicalJSONString()
    }

    static func hash(canonicalForm: String) -> String {
        SHA256.hash(data: Data(canonicalForm.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
