import XCTest
@testable import NanoTeams

/// N19 (2026-11-12): an enclosing repository's patterns, restated for a work folder below it.
final class EnclosingRepositoryIgnoreRulesTests: XCTestCase {

    private func translate(_ line: String, below relative: [String] = ["app"]) -> [String] {
        EnclosingRepositoryIgnoreRules.translateLine(line, relative: relative)
    }

    func testUnanchoredPattern_isKeptAsIs() {
        XCTAssertEqual(translate("node_modules/"), ["node_modules/"])
        XCTAssertEqual(translate("*.log"), ["*.log"])
        XCTAssertEqual(translate("!keep.log"), ["!keep.log"])
    }

    func testAnchoredPatternUnderTheWorkFolder_isReanchoredAtIt() {
        XCTAssertEqual(translate("/app/build/"), ["/build/"])
        XCTAssertEqual(translate("app/src/gen.swift"), ["/src/gen.swift"])
        XCTAssertEqual(translate("!/app/keep"), ["!/keep"])
        XCTAssertEqual(translate("/a*/out"), ["/out"], "a glob component matches the folder's name")
    }

    func testAnchoredPatternElsewhere_isDropped() {
        XCTAssertEqual(translate("/other/"), [])
        XCTAssertEqual(translate("other/x"), [])
        XCTAssertEqual(translate("/b*/out"), [])
    }

    func testDoubleStar_spansComponentsOnBothSides() {
        XCTAssertEqual(
            Set(translate("**/app/build", below: ["x", "app"])),
            ["/build", "/**/app/build"],
            "the ** may end at the work folder or keep going inside it")
        XCTAssertEqual(translate("x/**/gen", below: ["x", "app"]), ["/**/gen"])
        XCTAssertEqual(translate("**/foo", below: ["app"]), ["/**/foo"], "a leading **/ also matches zero levels")
    }

    func testPatternNamingTheWholeFolder_isNotApplied() {
        XCTAssertEqual(translate("/app"), [], "ignores the folder itself")
        XCTAssertEqual(translate("/app/"), [])
        XCTAssertEqual(translate("app/**"), [], "everything in it")
        XCTAssertEqual(translate("/app/*"), [])
        XCTAssertEqual(translate("/app", below: ["app", "deep"]), [], "an ancestor of the folder")
        XCTAssertEqual(translate("*"), [], "a dotfiles repository in the home directory ignores everything")
        XCTAssertEqual(translate("**"), [])
        XCTAssertEqual(translate("*/"), [], "every directory, at every depth")
        XCTAssertEqual(translate("!*"), ["!*"], "a negation only ever shows more")
        XCTAssertEqual(translate("*.swift"), ["*.swift"])
    }

    func testCommentsBlankLinesAndTrailingSpaces() {
        XCTAssertEqual(translate("# comment"), [])
        XCTAssertEqual(translate(""), [])
        XCTAssertEqual(translate("   "), [])
        XCTAssertEqual(translate("*.tmp   "), ["*.tmp"])
        XCTAssertEqual(translate("trail\\ "), ["trail\\ "], "an escaped space is part of the pattern")
        XCTAssertEqual(translate("\\#literal"), ["\\#literal"])
        XCTAssertEqual(translate("crlf\r"), ["crlf"])
        XCTAssertEqual(translate("!"), [])
        XCTAssertEqual(translate("/"), [])
    }

    func testTranslate_wholeFileAndEmptyRelative() {
        let file = "node_modules/\n/app/build/\n/other/\n# x\n"
        XCTAssertEqual(
            EnclosingRepositoryIgnoreRules.translate(file, workFolderBelow: ["app"]),
            ["node_modules/", "/build/"])
        XCTAssertEqual(EnclosingRepositoryIgnoreRules.translate(file, workFolderBelow: []), [])
    }

    func testEnclosingRepositoryRoot_nearestAncestorOnly_andNoneForARepositoryOfItsOwn() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("EnclosingRepo-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer { try? fileManager.removeItem(at: base) }
        let outer = base.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        let work = inner.appendingPathComponent("a/work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outer.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "gitdir: /elsewhere\n".write(
            to: inner.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            EnclosingRepositoryIgnoreRules.enclosingRepositoryRoot(of: work)?.standardizedFileURL.path,
            inner.path, "a gitfile counts, and the nearest wins")

        try fileManager.createDirectory(at: work.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNil(EnclosingRepositoryIgnoreRules.enclosingRepositoryRoot(of: work))

        let lonely = base.appendingPathComponent("lonely", isDirectory: true)
        try fileManager.createDirectory(at: lonely, withIntermediateDirectories: true)
        // Nothing above the temporary directory is a repository on a test host.
        XCTAssertNil(EnclosingRepositoryIgnoreRules.enclosingRepositoryRoot(of: lonely))
    }
}
