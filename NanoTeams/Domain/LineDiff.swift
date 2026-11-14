import Foundation

/// A line-by-line comparison of two texts, in reading order: every line of both sides appears
/// once, marked as kept, removed (only in the old text) or added (only in the new one).
///
/// Built on the standard library's `difference(from:)` (Myers), so the work grows with the
/// size of the CHANGE rather than with the product of the two lengths — a server that rewrites
/// one sentence of a long description costs one sentence, not a table over the whole text.
nonisolated enum LineDiff {

    nonisolated enum Kind: Hashable, Sendable {
        case unchanged
        case removed
        case added
    }

    nonisolated struct Line: Hashable, Sendable {
        let kind: Kind
        let text: String
    }

    /// Interleaves the two sides: a removed run is listed before the added run that replaced
    /// it, and the lines both sides share keep their place between them.
    static func between(_ old: [String], _ new: [String]) -> [Line] {
        let difference = new.difference(from: old)
        var removedAt = [Bool](repeating: false, count: old.count)
        var insertedAt = [Bool](repeating: false, count: new.count)
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedAt[offset] = true
            case .insert(let offset, _, _): insertedAt[offset] = true
            }
        }

        // The lines neither side lost are the same sequence, in the same order, on both sides —
        // that is what a difference IS. Walked pair by pair, each kept line is preceded by the
        // old side's removals and the new side's insertions that stand before it; the pair past
        // both ends collects whatever follows the last kept line. `zip` pairs them, so a
        // mismatch the standard library cannot produce reads its unpaired remainder as removed
        // and added instead of indexing past an end — with no branch of its own (until
        // 2026-09-24 that case was a `break` nothing could reach).
        let keptOld = old.indices.filter { !removedAt[$0] }
        let keptNew = new.indices.filter { !insertedAt[$0] }
        var lines: [Line] = []
        lines.reserveCapacity(old.count + new.count)
        var oldIndex = 0
        var newIndex = 0
        for (oldKept, newKept) in zip(keptOld, keptNew) + [(old.count, new.count)] {
            lines += old[oldIndex..<oldKept].map { Line(kind: .removed, text: $0) }
            lines += new[newIndex..<newKept].map { Line(kind: .added, text: $0) }
            if newKept < new.count { lines.append(Line(kind: .unchanged, text: new[newKept])) }
            oldIndex = oldKept + 1
            newIndex = newKept + 1
        }
        return lines
    }

    /// Whether the two sides differ at all.
    static func hasChanges(_ lines: [Line]) -> Bool {
        lines.contains { $0.kind != .unchanged }
    }
}
