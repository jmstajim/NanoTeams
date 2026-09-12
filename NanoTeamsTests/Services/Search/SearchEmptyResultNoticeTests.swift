import XCTest
@testable import NanoTeams

/// The sentence a zero-hit content search carries in `meta.warnings` (playbook R1.8.7 — an empty
/// result must be STATED). Pinned as a pure function because the branches it distinguishes are
/// exactly the ones the envelope renders identically: an empty `matches: []` is the same array
/// whether the glob admitted no file, every candidate was unreadable, or the tree genuinely holds
/// no such line — and the three have three different repairs.
///
/// Behaviour through the real envelope (which searches carry it, which do not) is pinned by
/// `SearchToolPlainParityTests`; this file pins the WORDING.
final class SearchEmptyResultNoticeTests: XCTestCase {

    private func notice(
        fileGlob: String? = nil,
        scopedPaths: [String]? = nil,
        filesRead: Int = 0,
        candidates: Int = 0,
        skippedCount: Int = 0,
        binaryCount: Int = 0,
        filenameMatchCount: Int = 0
    ) -> String {
        SearchExecutor.emptyContentNotice(
            fileGlob: fileGlob,
            scopedPaths: scopedPaths,
            filesRead: filesRead,
            candidates: candidates,
            skippedCount: skippedCount,
            binaryCount: binaryCount,
            filenameMatchCount: filenameMatchCount
        )
    }

    // MARK: - The three shapes of "nothing"

    func testNotice_filesWereRead_saysHowMany() {
        XCTAssertEqual(notice(filesRead: 37, candidates: 37),
                       "no line matched in 37 files searched")
    }

    /// Singular, because "1 files" reads as a formatting bug and a model that distrusts the
    /// sentence stops acting on it.
    func testNotice_oneFile_isSingular() {
        XCTAssertEqual(notice(filesRead: 1, candidates: 1),
                       "no line matched in 1 file searched")
    }

    /// A glob that admitted nothing is not a statement about the corpus. Naming the glob back is
    /// what lets the model repair the call instead of re-spelling the query.
    func testNotice_globAdmittedNothing_namesTheGlob() {
        XCTAssertEqual(notice(fileGlob: "*.kt"),
                       "no file was searched: nothing matching file_glob '*.kt'")
    }

    func testNotice_pathsScopeHeldNothing_namesThePaths() {
        XCTAssertEqual(notice(scopedPaths: ["Sources", "Docs"]),
                       "no file was searched: nothing under Sources, Docs")
    }

    func testNotice_wholeFolderHeldNothingReadable_saysSo() {
        XCTAssertEqual(notice(), "no file was searched: the work folder holds no readable file")
    }

    /// Candidates existed but none could be read — distinct from "the glob matched nothing",
    /// because here the file names are right and the CONTENT was unavailable.
    func testNotice_everyCandidateSkipped_separatesScopeFromReadability() {
        XCTAssertEqual(
            notice(fileGlob: "*.png", candidates: 12, binaryCount: 12),
            "no file could be searched matching file_glob '*.png'; 12 files skipped as binary"
        )
    }

    // MARK: - Clauses that point back into the same envelope

    /// The skipped files are listed one field over. A model told only "no match" re-runs the
    /// search; told "2 could not be read", it opens them.
    func testNotice_unreadableFiles_pointAtSkippedFiles() {
        XCTAssertEqual(
            notice(filesRead: 5, candidates: 7, skippedCount: 2),
            "no line matched in 5 files searched; 2 files could not be read — see skipped_files"
        )
    }

    /// Content empty, names matched: the answer is already in the envelope.
    func testNotice_nameHits_pointAtFilenameMatches() {
        XCTAssertEqual(
            notice(filesRead: 9, candidates: 9, filenameMatchCount: 1),
            "no line matched in 9 files searched; 1 file matched by name instead — see filename_matches"
        )
    }

    /// Every clause is conditional — a plain empty search pays for one sentence, not a form with
    /// blank fields.
    func testNotice_quietFactsAreOmitted() {
        let plain = notice(filesRead: 4, candidates: 4)

        XCTAssertFalse(plain.contains("skipped_files"))
        XCTAssertFalse(plain.contains("binary"))
        XCTAssertFalse(plain.contains("filename_matches"))
        XCTAssertFalse(plain.contains("file_glob"))
    }

    /// Both scope levers at once, in the order the caller passed them.
    func testNotice_globAndPaths_appearTogether() {
        XCTAssertEqual(
            notice(fileGlob: "*.swift", scopedPaths: ["Sources"], filesRead: 3, candidates: 3),
            "no line matched in 3 files searched matching file_glob '*.swift' under Sources"
        )
    }

    /// An empty `paths` array is not a scope — it is the absence of one, and claiming otherwise
    /// would print a dangling "under ".
    func testNotice_emptyPathsArray_isNotAScope() {
        XCTAssertEqual(notice(scopedPaths: []),
                       "no file was searched: the work folder holds no readable file")
    }
}
