import Foundation

/// Pure tuning + decision layer for `AccessibilityInspector.collectElements` — the walk budgets
/// and every decision-shaped step (emission cap, web-content retry, no-silent-caps warnings)
/// split out of the live-AX walk so they are unit-testable without an accessibility tree
/// (same split as `PlanningPhasePolicy` / `LoopScanner`).
nonisolated enum AccessibilityWalkPolicy {

    /// Web DOMs nest far deeper than native AppKit trees: the AXWebArea sits ~4–6 levels below
    /// the app root and page controls commonly sit another 10–20 AXGroup levels down. The old
    /// cap of 12 was exhausted before reaching any interactive web element (observed: LinkedIn
    /// feed → zero web elements advertised, model clicked pixels blind).
    static let maxDepth = 30

    /// Visited-node budget per walk attempt. A feed-style page exposes thousands of AX nodes;
    /// at ~2–3 AX IPC round-trips per node the wall-clock deadline below — not this cap — is
    /// the effective bound on slow apps, while fast apps finish well under it.
    static let maxVisitedNodes = 3000

    /// Emission cap on the wire list. ~25–40 tokens per element puts the ceiling at ~4–5k
    /// tokens per capture; native apps stay far below it. First candidate to tune DOWN if
    /// capture turns start crowding the model's context.
    static let maxEmittedElements = 140

    /// Per-attempt wall-clock budget for one walk. Kept so the worst case (walk + settle +
    /// retry walk = 2×1200 + 400 = 2.8 s) stays under `LLMConstants.cancelHandlerTimeoutSeconds`
    /// (3 s) — a Pause landing during a capture must not blow the bounded-wait budget. The whole
    /// pipeline runs off the main actor and is additionally cancellation-responsive.
    static let walkDeadlineMilliseconds = 1200

    /// WebKit/Chromium populate the web-content AX subtree lazily AFTER an assistive client
    /// announces itself (`AXEnhancedUserInterface`) — give the target a moment before the
    /// one-shot retry. Native apps never pay this (retry fires only when a web area exists).
    static let webSettleMilliseconds = 400

    /// Per-IPC messaging timeout set on the app element. The wall-clock deadline only fires
    /// BETWEEN nodes, so a single hung `AXUIElementCopyAttributeValue` against a busy target
    /// would otherwise block ~6 s (the AX default). Bounds one round-trip to a fraction of the
    /// deadline so the deadline stays enforceable.
    static let axMessagingTimeoutSeconds = 0.5

    /// Retention priority under the emission cap: labeled-web > labeled-chrome > unlabeled-web
    /// > unlabeled-chrome. In a browser capture the overflow should evict the browser's own
    /// chrome (favorites-bar noise like two-letter bookmark buttons) before page content, and
    /// unlabeled glyph controls before anything the model can identify by name. Output keeps
    /// document order (the list must still read top-to-bottom against the screenshot).
    static func capEmission(_ elements: [AXElementInfo], limit: Int) -> (kept: [AXElementInfo], dropped: Int) {
        guard limit > 0 else { return ([], elements.count) }
        guard elements.count > limit else { return (elements, 0) }
        func tier(_ e: AXElementInfo) -> Int {
            switch (e.label.isEmpty, e.web) {
            case (false, true): return 0
            case (false, false): return 1
            case (true, true): return 2
            case (true, false): return 3
            }
        }
        let keptIndices = elements.indices
            .sorted { a, b in
                let ta = tier(elements[a]), tb = tier(elements[b])
                return ta != tb ? ta < tb : a < b   // stable within a tier by document order
            }
            .prefix(limit)
            .sorted()
        return (keptIndices.map { elements[$0] }, elements.count - limit)
    }

    /// One-shot retry decision: a web area was reached but yielded no web elements — the
    /// subtree existed but hadn't populated yet (lazy AX tree, see `webSettleMilliseconds`).
    /// A walk that saw no web area (native app) or already got web content never retries.
    static func shouldRetryForWebContent(sawWebArea: Bool, webElementCount: Int) -> Bool {
        sawWebArea && webElementCount == 0
    }

    /// No-silent-caps composition for the capture envelope's `meta.warnings`: the model must be
    /// able to tell "this list covers everything" from "the scan was cut short", otherwise a
    /// missing target reads as "not on screen" and it falls back to guessing pixels.
    /// `stoppedEarly` folds every budget cut (node cap, wall-clock deadline, depth cap) — each is
    /// a place the walk abandoned a subtree, so all must surface. `webAreaEmpty` is the distinct
    /// "a browser page was present but its content wasn't readable" signal (lazy AX tree still
    /// populating, or a retry that couldn't complete).
    static func collectionWarnings(
        stoppedEarly: Bool, webAreaEmpty: Bool, visited: Int,
        kept: Int, totalAfterDedup: Int
    ) -> [String] {
        var warnings: [String] = []
        if stoppedEarly {
            warnings.append(
                "UI element scan stopped early (node/time/depth budget) after \(visited) nodes — some "
                    + "elements may be missing from ax_elements; capture a specific window to narrow scope.")
        }
        if kept < totalAfterDedup {
            warnings.append(
                "ax_elements truncated to \(kept) of \(totalAfterDedup) (labeled page content kept "
                    + "first) — scroll or capture a specific window to narrow scope.")
        }
        if webAreaEmpty {
            warnings.append(
                "A browser page was detected but its content could not be read yet (it may still be "
                    + "loading) — only browser chrome is listed; capture again in a moment for page elements.")
        }
        return warnings
    }
}
