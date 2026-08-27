import XCTest

@testable import NanoTeams

/// `Clip`'s two construction paths and the one property that is easy to break silently.
///
/// The determinism of `derived` is not a nicety: the read-only attachment grid re-parses clips
/// out of a message body on every feed rebuild, so a non-deterministic id would churn SwiftUI
/// identity on every event — worse than the `\.offset` it replaced, and invisible except as
/// "the attachment row flickers". Nothing else in the tree would catch that.
final class ClipTests: XCTestCase {

    // MARK: - Minted identity

    func testInitMintsADistinctIdentityPerClip() {
        let a = Clip(text: "same text")
        let b = Clip(text: "same text")
        XCTAssertNotEqual(a.id, b.id, "two clips of identical text are still two clips")
        XCTAssertEqual(a.text, b.text)
    }

    func testMintingWrapsEveryTextInOrder() {
        let clips = [Clip].minting(["a", "b", "c"])
        XCTAssertEqual(clips.texts, ["a", "b", "c"])
        XCTAssertEqual(Set(clips.map(\.id)).count, 3, "identities must not collide")
    }

    func testMintingAnEmptyListYieldsAnEmptyList() {
        XCTAssertTrue([Clip].minting([]).isEmpty)
    }

    // MARK: - Derived identity

    func testDerivedIsDeterministicAcrossCalls() {
        let first = Clip.derived(text: "hello", ordinal: 0, seed: "message-1")
        let second = Clip.derived(text: "hello", ordinal: 0, seed: "message-1")
        XCTAssertEqual(first.id, second.id,
                       "same inputs must yield the same identity, or every rebuild churns rows")
    }

    func testDerivedSeparatesIdenticalTextsByOrdinal() {
        let first = Clip.derived(text: "dup", ordinal: 0, seed: "m")
        let second = Clip.derived(text: "dup", ordinal: 1, seed: "m")
        XCTAssertNotEqual(first.id, second.id,
                          "two identical clips in one message are two rows — a content-only id "
                              + "would merge them")
    }

    func testDerivedSeparatesBySeed() {
        let a = Clip.derived(text: "same", ordinal: 0, seed: "message-1")
        let b = Clip.derived(text: "same", ordinal: 0, seed: "message-2")
        XCTAssertNotEqual(a.id, b.id, "the same clip in two messages is two rows")
    }

    func testDerivedSeparatesByText() {
        let a = Clip.derived(text: "one", ordinal: 0, seed: "m")
        let b = Clip.derived(text: "two", ordinal: 0, seed: "m")
        XCTAssertNotEqual(a.id, b.id)
    }

    /// The field separator is a control character precisely so that a seed ending in a digit
    /// cannot collide with the next ordinal. Without it, ("m1", 0) and ("m", 10) hash the same.
    func testDerivedDoesNotCollideAcrossTheSeedOrdinalBoundary() {
        let a = Clip.derived(text: "x", ordinal: 0, seed: "m1")
        let b = Clip.derived(text: "x", ordinal: 10, seed: "m")
        XCTAssertNotEqual(a.id, b.id, "seed and ordinal must not run together")
    }

    // MARK: - The text is carried verbatim

    /// `SkillsPickerButton` puts `SkillClip.encoded()` sentinel strings — a zero-width-space
    /// header plus a body — into the same list, and `SkillClip.parse` branches on those exact
    /// bytes. Any trimming or normalizing in `Clip` would silently un-skill a clip.
    func testTextIsCarriedVerbatimIncludingASkillSentinel() throws {
        let encoded = SkillClip(name: "Deploy", body: "run it").encoded()
        let clip = Clip(text: encoded)
        XCTAssertEqual(clip.text, encoded)
        let parsed = try XCTUnwrap(SkillClip.parse(clip.text),
                                   "the sentinel must survive the wrapper")
        XCTAssertEqual(parsed.name, "Deploy")
    }

    func testWhitespaceOnlyTextIsPreservedNotTrimmed() {
        XCTAssertEqual(Clip(text: "   \n\t").text, "   \n\t")
    }

    // MARK: - Codable

    func testCodableRoundTripPreservesIdentity() throws {
        let original = [Clip(text: "one"), Clip(text: "two")]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([Clip].self, from: data)
        XCTAssertEqual(decoded, original, "identity must survive persistence, not be re-minted")
        XCTAssertEqual(decoded.map(\.id), original.map(\.id))
    }

    func testEqualityIncludesIdentityNotJustText() {
        let a = Clip(text: "same")
        let b = Clip(id: a.id, text: "same")
        let c = Clip(text: "same")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "two clips with equal text are NOT equal — this is what makes a "
            + "freshly minted expectation an invalid assertion target")
    }

    func testTextsProjectionIsOrderPreserving() {
        let clips = [Clip(text: "z"), Clip(text: "a"), Clip(text: "m")]
        XCTAssertEqual(clips.texts, ["z", "a", "m"])
    }
}
