import Foundation
import Security

/// The single definition of "this runner cannot serve the Keychain at all", used
/// by every `catch KeychainError.unhandled(let status) where …` skip guard.
///
/// It exists as ONE function rather than a per-file copy because the set is a
/// RULE, not a convenience: a status listed here turns a red test into a skip,
/// so a file that quietly omits one member fails hard on a runner its sibling
/// skips, and a file that quietly adds one masks a real regression as "skipped".
/// Both directions are silent, which is exactly the kind of divergence this
/// codebase pays for elsewhere (see the `normalizedBaseURL` note in CLAUDE.md).
///
/// Deliberately a free function, not a method: it is consumed from `catch … where`
/// clauses, where capturing `self` would be a question mark.
///
/// The list is narrow on purpose — it names only statuses that mean "the
/// platform refused to serve the Keychain", never ones that would mean "our
/// production code is wrong". `errSecItemNotFound` in particular is absent:
/// legitimate absence is the very thing these tests assert.
func platformIsKeychainUnavailable(_ status: OSStatus) -> Bool {
    status == errSecMissingEntitlement
        || status == errSecInteractionNotAllowed
        || status == errSecAuthFailed
        || status == errSecNotAvailable
}
