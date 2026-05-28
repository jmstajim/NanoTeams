import XCTest
@testable import NanoTeams

/// Pins `ArtifactConstants.isValidArtifactName` semantics — file-extension shapes
/// recognised by `create_artifact`'s `format` parameter (md/pdf/rtf/docx) are valid;
/// other extensions (.html/.css/.js/.swift/.py/etc.) are file paths, not artifact
/// names. Conceptual names without extensions are always valid.
///
/// The detector intentionally errs on the side of accepting ambiguous inputs
/// (e.g. "v2.0", "Spec 1.5") so we don't reject legitimate human artifact names
/// just because they contain a period.
final class ArtifactNameValidationTests: XCTestCase {

    // MARK: - Conceptual names (no extension) — always valid

    func testProductRequirements_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Product Requirements"))
    }

    func testCodeReview_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Code Review"))
    }

    func testRussianName_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Отчет о проверке"))
    }

    // MARK: - Allowed-extension shapes — valid

    func testMarkdownExtension_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("report.md"))
    }

    func testPDFExtension_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("summary.pdf"))
    }

    func testRTFExtension_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("notes.rtf"))
    }

    func testDOCXExtension_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Spec.docx"))
    }

    func testExtensionCaseInsensitive() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Spec.PDF"))
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Plan.MD"))
    }

    // MARK: - File-shaped names (the regression we're guarding against) — invalid

    func testHTMLExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("index.html"))
    }

    func testCSSExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("styles.css"))
    }

    func testJSExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("script.js"))
    }

    func testSwiftExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("Calculator.swift"))
    }

    func testPyExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("app.py"))
    }

    func testTSExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("useAuth.ts"))
    }

    func testTSXExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("Component.tsx"))
    }

    func testJSONExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("package.json"))
    }

    // MARK: - Ambiguous shapes — accept (false-positives are worse than false-negatives)

    func testVersionNumber_v2dot0_isValid() {
        // "0" → 1 char digit → not extension shape → valid
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Spec v2.0"))
    }

    func testReportWithVersion_isValid() {
        // "5 final" → contains space → not extension shape → valid
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Report 1.5 final"))
    }

    func testGitignoreLeadingDot_isValid() {
        // ".gitignore" — substring after last "." is "gitignore" (9 chars) — exceeds
        // the 1–5 char extension window, so treated as conceptual name. Acceptable
        // (artifact named .gitignore is unusual but not the file-conflation pattern
        // we're hunting for).
        XCTAssertTrue(ArtifactConstants.isValidArtifactName(".gitignore"))
    }

    // MARK: - Edge cases

    func testEmptyName_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName(""))
    }

    func testWhitespaceOnly_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("   "))
    }

    func testTrailingDot_isValid() {
        // "name." → empty extension → not extension shape → valid
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("name."))
    }

    // MARK: - Multi-dot names — last dot wins

    func testMultiDotMarkdown_isValid() {
        // "v1.2.md" → last token "md" → 2 alpha → allowed → VALID
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("v1.2.md"))
    }

    func testMultiDotPDF_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Report v1.0.final.pdf"))
    }

    func testMultiDotSourceFile_isInvalid() {
        // "calculator.test.swift" → last token "swift" → not allowed → INVALID
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("calculator.test.swift"))
    }

    // MARK: - Non-ASCII basenames

    /// Non-ASCII basename + ASCII extension. The `Спецификация` part contains
    /// no dots; only the trailing `html` matters for the extension check.
    /// `html` is ASCII letters → triggers extension-shape detection → not allowed.
    func testCyrillicBasenameWithHTMLExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("Спецификация.html"))
    }

    /// Cyrillic basename + allowed extension still passes.
    func testCyrillicBasenameWithMDExtension_isValid() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Спецификация.md"))
    }

    /// Mixed-script basename + non-allowed extension.
    func testMixedScriptBasenameWithJSExtension_isInvalid() {
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("Calc-Калькулятор.js"))
    }

    // MARK: - Whitespace handling

    func testLeadingWhitespace_trimmedBeforeCheck() {
        // Leading whitespace must be trimmed; the inner shape determines validity.
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("   Code Review"))
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("   index.html"))
    }

    func testTrailingWhitespace_trimmedBeforeCheck() {
        XCTAssertTrue(ArtifactConstants.isValidArtifactName("Code Review   "))
        XCTAssertFalse(ArtifactConstants.isValidArtifactName("script.js   "))
    }
}
