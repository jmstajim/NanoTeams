import XCTest

@testable import NanoTeams

/// Pins the typed accessors and the well-known labels on `ModelLoadDetails` — the seam between
/// the two provider clients (writers) and the benchmark record (reader). Pure value types, so the
/// suite is not `@MainActor`.
final class ModelLoadDetailsTests: XCTestCase {

    // MARK: - Typed access

    func testFormatAndQuantization_readTheirWellKnownLabels() {
        let details = ModelLoadDetails(fields: [
            .init(label: "State", value: "Loaded"),
            .init(label: ModelLoadDetails.quantizationLabel, value: "Q4_K_M"),
            .init(label: ModelLoadDetails.formatLabel, value: "gguf"),
        ])
        XCTAssertEqual(details.format, "gguf")
        XCTAssertEqual(details.quantization, "Q4_K_M")
    }

    func testFormatAndQuantization_areNilWhenTheServerReportedNeither() {
        let details = ModelLoadDetails(fields: [.init(label: "State", value: "Loaded")])
        XCTAssertNil(details.format)
        XCTAssertNil(details.quantization)
        XCTAssertNil(ModelLoadDetails(fields: []).format)
    }

    func testValueForLabel_returnsTheFirstMatch() {
        let details = ModelLoadDetails(fields: [
            .init(label: "Residency", value: "first"),
            .init(label: "Residency", value: "second"),
        ])
        XCTAssertEqual(details.value(for: "Residency"), "first")
        XCTAssertNil(details.value(for: "Absent"))
    }

    // MARK: - Label spellings are persistence-frozen

    /// These exact strings are `GenerationBenchmarkRun.serverFields` keys in files already on
    /// disk, and the legacy-decode fallback in `GenerationBenchmarkRun.decode` reads them as
    /// string literals. RED: rename a constant here → this fails BEFORE the rename silently
    /// splits new rows' keys from the fallback's, which would strand historical rows' chips.
    func testWellKnownLabels_keepTheirPersistedSpellings() {
        XCTAssertEqual(ModelLoadDetails.formatLabel, "Format")
        XCTAssertEqual(ModelLoadDetails.quantizationLabel, "Quantization")
        XCTAssertEqual(ModelLoadDetails.modelfileParametersLabel, "Modelfile parameters")
    }
}
