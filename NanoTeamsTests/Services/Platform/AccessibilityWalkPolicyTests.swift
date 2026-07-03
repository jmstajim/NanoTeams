import XCTest

@testable import NanoTeams

/// Pure pins for the walk tuning policy: emission-cap retention priority, the web-content
/// retry truth table, and the no-silent-caps warning composition. No live AX.
final class AccessibilityWalkPolicyTests: XCTestCase {

    private func make(
        label: String, web: Bool = false, x: Int = 0
    ) -> AXElementInfo {
        AXElementInfo(role: "AXButton", label: label, x: x, y: 0, w: 10, h: 10,
                      cx: x + 5, cy: 5, web: web)
    }

    // MARK: - capEmission

    func testCapEmission_underLimit_passesThrough() {
        let els = [make(label: "a"), make(label: "", web: true)]
        let out = AccessibilityWalkPolicy.capEmission(els, limit: 5)
        XCTAssertEqual(out.kept, els)
        XCTAssertEqual(out.dropped, 0)
    }

    func testCapEmission_exactlyAtLimit_noTruncation() {
        let els = (0..<4).map { make(label: "l\($0)", x: $0) }
        let out = AccessibilityWalkPolicy.capEmission(els, limit: 4)
        XCTAssertEqual(out.kept, els)
        XCTAssertEqual(out.dropped, 0)
    }

    func testCapEmission_retentionPriority_webLabeledFirst_chromeUnlabeledLast() {
        // One of each tier, limit 2: labeled-web + labeled-chrome survive;
        // unlabeled-web + unlabeled-chrome drop.
        let labeledWeb = make(label: "Post", web: true, x: 0)
        let labeledChrome = make(label: "Share", web: false, x: 10)
        let unlabeledWeb = make(label: "", web: true, x: 20)
        let unlabeledChrome = make(label: "", web: false, x: 30)
        let out = AccessibilityWalkPolicy.capEmission(
            [unlabeledChrome, labeledWeb, unlabeledWeb, labeledChrome], limit: 2)
        XCTAssertEqual(out.kept, [labeledWeb, labeledChrome])
        XCTAssertEqual(out.dropped, 2)
    }

    func testCapEmission_browserOverflow_evictsChromeBeforePageContent() {
        // The incident shape: favorites-bar chrome ("HH", "Zvuk") vs labeled page content —
        // overflow must evict chrome even though every element is labeled.
        let chrome = (0..<3).map { make(label: "fav\($0)", web: false, x: $0) }
        let page = (0..<3).map { make(label: "page\($0)", web: true, x: 100 + $0) }
        let out = AccessibilityWalkPolicy.capEmission(chrome + page, limit: 4)
        XCTAssertEqual(out.kept.filter(\.web).count, 3, "all page content survives")
        XCTAssertEqual(out.kept.filter { !$0.web }.count, 1, "chrome takes the leftover slot")
        XCTAssertEqual(out.dropped, 2)
    }

    func testCapEmission_outputKeepsDocumentOrder_interleaved() {
        // Retention is priority-based, but the OUTPUT must read top-to-bottom against the
        // screenshot — kept elements stay in input (document) order, interleaving preserved.
        let a = make(label: "", web: true, x: 0)       // unlabeled-web (tier 2)
        let b = make(label: "B", web: false, x: 10)    // labeled-chrome (tier 1)
        let c = make(label: "C", web: true, x: 20)     // labeled-web (tier 0)
        let out = AccessibilityWalkPolicy.capEmission([a, b, c], limit: 2)
        XCTAssertEqual(out.kept, [b, c], "kept set = top 2 tiers, order = document order")
    }

    func testCapEmission_withinTier_earlierDocumentOrderWins() {
        let els = (0..<5).map { make(label: "l\($0)", x: $0) }
        let out = AccessibilityWalkPolicy.capEmission(els, limit: 3)
        XCTAssertEqual(out.kept, Array(els.prefix(3)))
        XCTAssertEqual(out.dropped, 2)
    }

    func testCapEmission_allUnlabeled_firstNSurvive() {
        let els = (0..<4).map { make(label: "", x: $0) }
        let out = AccessibilityWalkPolicy.capEmission(els, limit: 2)
        XCTAssertEqual(out.kept, Array(els.prefix(2)))
        XCTAssertEqual(out.dropped, 2)
    }

    func testCapEmission_degenerateLimit_dropsAll() {
        let els = [make(label: "a")]
        let out = AccessibilityWalkPolicy.capEmission(els, limit: 0)
        XCTAssertEqual(out.kept, [])
        XCTAssertEqual(out.dropped, 1)
    }

    func testCapEmission_negativeLimit_dropsAll() {
        let els = [make(label: "a"), make(label: "b", x: 1)]
        let out = AccessibilityWalkPolicy.capEmission(els, limit: -3)
        XCTAssertEqual(out.kept, [])
        XCTAssertEqual(out.dropped, 2)
    }

    func testCapEmission_limitOne_takesHighestPriorityTier_notDocumentFirst() {
        // One slot, chrome first in document order but a labeled-web element later: priority
        // (labeled-web = tier 0) beats position.
        let chrome = make(label: "Share", web: false, x: 0)
        let web = make(label: "Post", web: true, x: 10)
        let out = AccessibilityWalkPolicy.capEmission([chrome, web], limit: 1)
        XCTAssertEqual(out.kept, [web])
        XCTAssertEqual(out.dropped, 1)
    }

    func testCapEmission_labeledWebLastInDocumentOrder_stillSurvives() {
        // Three chrome elements precede a single labeled-web element; cap keeps 1 → the web one
        // survives despite being LAST, and is re-emitted (trivially) in document order.
        let chrome = (0..<3).map { make(label: "c\($0)", web: false, x: $0) }
        let web = make(label: "Post", web: true, x: 100)
        let out = AccessibilityWalkPolicy.capEmission(chrome + [web], limit: 1)
        XCTAssertEqual(out.kept, [web])
        XCTAssertEqual(out.dropped, 3)
    }

    func testCapEmission_withinTierOverLimit_keepsEarliestDocumentIndex() {
        // Two same-tier (labeled-chrome) elements, limit 1 → the earliest document index wins
        // deterministically (matters for prompt-cache stability).
        let first = make(label: "A", web: false, x: 0)
        let second = make(label: "B", web: false, x: 10)
        let out = AccessibilityWalkPolicy.capEmission([first, second], limit: 1)
        XCTAssertEqual(out.kept, [first])
        XCTAssertEqual(out.dropped, 1)
    }

    func testCapEmission_empty_passesThrough() {
        let out = AccessibilityWalkPolicy.capEmission([], limit: 3)
        XCTAssertEqual(out.kept, [])
        XCTAssertEqual(out.dropped, 0)
    }

    // MARK: - shouldRetryForWebContent

    func testShouldRetry_truthTable() {
        // Web area seen but empty → the lazy tree hadn't populated: retry once.
        XCTAssertTrue(AccessibilityWalkPolicy.shouldRetryForWebContent(sawWebArea: true, webElementCount: 0))
        // Web content already collected → no retry.
        XCTAssertFalse(AccessibilityWalkPolicy.shouldRetryForWebContent(sawWebArea: true, webElementCount: 5))
        // Native app (no web area) → never retries, never pays the settle delay.
        XCTAssertFalse(AccessibilityWalkPolicy.shouldRetryForWebContent(sawWebArea: false, webElementCount: 0))
    }

    // MARK: - collectionWarnings

    func testCollectionWarnings_cleanWalk_isSilent() {
        XCTAssertEqual(AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: false, webAreaEmpty: false, visited: 120, kept: 40, totalAfterDedup: 40), [])
    }

    func testCollectionWarnings_truncation_namesCounts() {
        let w = AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: false, webAreaEmpty: false, visited: 500, kept: 140, totalAfterDedup: 210)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("140 of 210"), "no silent caps — the model must see the drop")
        XCTAssertTrue(w[0].contains("narrow scope"))
    }

    func testCollectionWarnings_stoppedEarly_warnsWithNodeCount() {
        let w = AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: true, webAreaEmpty: false, visited: 3000, kept: 90, totalAfterDedup: 90)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("stopped early"))
        XCTAssertTrue(w[0].contains("3000 nodes"))
    }

    func testCollectionWarnings_webAreaEmpty_advisesRecapture() {
        // Browser page detected but content unreadable (lazy tree still loading / retry spent).
        let w = AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: false, webAreaEmpty: true, visited: 120, kept: 30, totalAfterDedup: 30)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("browser page"))
        XCTAssertTrue(w[0].contains("capture again"))
    }

    func testCollectionWarnings_allThree_compose() {
        let w = AccessibilityWalkPolicy.collectionWarnings(
            stoppedEarly: true, webAreaEmpty: true, visited: 3000, kept: 140, totalAfterDedup: 300)
        XCTAssertEqual(w.count, 3)
        XCTAssertTrue(w[0].contains("stopped early"))
        XCTAssertTrue(w[1].contains("140 of 300"))
        XCTAssertTrue(w[2].contains("browser page"))
    }
}
