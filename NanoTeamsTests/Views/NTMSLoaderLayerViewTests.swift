import SwiftUI
import XCTest

@testable import NanoTeams

/// Pins the Core Animation half of `NTMSLoader`: the script is installed as infinite discrete
/// keyframes, a parent pass with unchanged inputs costs nothing, and a light/dark switch — which
/// reaches the view only as a newly RESOLVED color — re-renders the glyphs.
@MainActor
final class NTMSLoaderLayerViewTests: XCTestCase {

    var sut: NTMSLoaderLayerNSView!

    override func setUp() async throws {
        try await super.setUp()
        sut = NTMSLoaderLayerNSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    private func environment(_ scheme: ColorScheme) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return environment
    }

    private func inputs(
        _ scheme: ColorScheme = .dark,
        color: Color = Colors.textPrimary,
        glitch: Bool = true
    ) -> NTMSLoaderLayerNSView.Inputs {
        NTMSLoaderLayerNSView.Inputs(
            font: Typography.termXs,
            color: color.resolve(in: environment(scheme)),
            glitchEnabled: glitch
        )
    }

    private func keyframes(_ layer: CALayer, _ key: String) -> CAKeyframeAnimation? {
        layer.animation(forKey: key) as? CAKeyframeAnimation
    }

    // MARK: - Animations

    /// RED: drop `repeatCount = .infinity` → the spinner stops after one ~20 s loop.
    /// RED: pass `frameCount` key times → the keyTimes/values relation fails.
    func testUpdate_installsInfiniteDiscreteKeyframes() async {
        sut.update(inputs())
        let contents = keyframes(sut.glyphLayer, NTMSLoaderLayerNSView.contentsAnimationKey)
        XCTAssertNotNil(contents)
        XCTAssertEqual(contents?.repeatCount, .infinity)
        XCTAssertEqual(contents?.calculationMode, .discrete)
        XCTAssertEqual(contents?.keyTimes?.count, (contents?.values?.count ?? 0) + 1)
        XCTAssertGreaterThanOrEqual(contents?.values?.count ?? 0, NTMSLoaderAnimationScript.minimumCycleTicks)
        XCTAssertEqual(contents?.duration ?? 0,
                       Double(contents?.values?.count ?? 0) * NTMSLoaderAnimationScript.tickSeconds,
                       accuracy: 0.000_001)
    }

    /// The model value is the resting glyph, so the spinner still shows a steady stick if the
    /// animations are ever gone.
    func testUpdate_setsTheRestingGlyphAsTheModelValue_andANaturalSize() async throws {
        sut.update(inputs())
        XCTAssertNotNil(sut.glyphLayer.contents)
        let size = try XCTUnwrap(sut.restingGlyphSize)
        // SF Mono 11 pt: line height 12.955, advance 6.8 (MonoCellReferenceGlyphTests).
        XCTAssertEqual(size.height, 12.955, accuracy: 1.5)
        XCTAssertEqual(size.width, 6.8, accuracy: 1.5)
    }

    /// With the effect off there is nothing to split or jitter, so no channel animations.
    func testGlitchDisabled_installsOnlyTheRotation() async {
        sut.update(inputs(glitch: false))
        XCTAssertNotNil(keyframes(sut.glyphLayer, NTMSLoaderLayerNSView.contentsAnimationKey))
        XCTAssertNil(sut.redLayer.animation(forKey: NTMSLoaderLayerNSView.opacityAnimationKey))
        XCTAssertNil(sut.cyanLayer.animation(forKey: NTMSLoaderLayerNSView.contentsAnimationKey))
        XCTAssertNil(sut.shakeLayer.animation(forKey: NTMSLoaderLayerNSView.shakeAnimationKey))
    }

    // MARK: - Re-render decisions

    /// RED: drop the `newInputs != inputs` guard → every parent body pass re-renders every glyph
    /// image and restarts the loop, which is the per-pass cost this view exists to remove.
    func testSameInputs_doNotRerender() async {
        sut.update(inputs())
        sut.update(inputs())
        sut.update(inputs())
        XCTAssertEqual(sut.renderPassCountForTesting, 1)
    }

    /// The theme reaches this view ONLY as a differently resolved color. If resolving a
    /// `Colors.*` token against a dark and a light environment gave the same value, a
    /// light/dark switch would leave the spinner in the old palette — so both halves are pinned.
    func testColorScheme_resolvesDifferently_andRerenders() async {
        let dark = Colors.textPrimary.resolve(in: environment(.dark))
        let light = Colors.textPrimary.resolve(in: environment(.light))
        XCTAssertNotEqual(dark, light, "a dynamic token must resolve per environment, or the spinner never follows the theme")

        sut.update(inputs(.dark))
        sut.update(inputs(.light))
        XCTAssertEqual(sut.renderPassCountForTesting, 2)
        XCTAssertEqual(sut.inputs?.color, light)
    }

    func testGlitchToggle_rerenders() async {
        sut.update(inputs(glitch: true))
        sut.update(inputs(glitch: false))
        XCTAssertEqual(sut.renderPassCountForTesting, 2)
        XCTAssertNil(sut.shakeLayer.animation(forKey: NTMSLoaderLayerNSView.shakeAnimationKey))
    }

    // MARK: - Decoration

    func testIsInvisibleToHitTestingAndAccessibility() async {
        sut.update(inputs())
        XCTAssertNil(sut.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(sut.isAccessibilityElement())
    }

    /// The ±1 pt RGB copies live outside the cell by construction; a clipped layer shaves them.
    func testLayersDoNotClip() async {
        for layer in [sut.shakeLayer, sut.redLayer, sut.cyanLayer, sut.glyphLayer] {
            XCTAssertFalse(layer.masksToBounds)
        }
        XCTAssertEqual(sut.redLayer.frame.minX - sut.glyphLayer.frame.minX, 1)
        XCTAssertEqual(sut.cyanLayer.frame.minX - sut.glyphLayer.frame.minX, -1)
    }
}
