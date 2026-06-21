import AppKit
import SwiftUI
import XCTest
@testable import NanoTeams

// MARK: - Color resolution test support

/// Compares theme-aware `Color` tokens by RESOLVED VALUE rather than identity.
///
/// After the terminal-theme redesign, the SwiftUI `Colors.*` accessors are
/// computed `static var`s that return a FRESH dynamic color per access (so a
/// `.id(activeTheme)` tree rebuild re-pulls the active palette). Two accesses of
/// the same token therefore never compare `==` — `XCTAssertEqual(sut.color,
/// Colors.purple)` would fail spuriously even when both are `Colors.purple`.
/// Resolve both sides to sRGB components under a fixed appearance and compare
/// those instead. (The AppKit `Colors.ns*` accessors are memoized `static let`s
/// for `NSAttributedString` identity, so those are still compared by `==`
/// directly elsewhere — this helper is only for the SwiftUI `Color` tokens.)
enum ColorResolution {
    /// Resolve a SwiftUI `Color` to `[r, g, b, a]` sRGB components under the
    /// given appearance. The `NSColor` is built INSIDE the appearance block so a
    /// dynamic (catalog) color resolves to the correct dark/light variant.
    static func rgba(_ color: Color, dark: Bool = true) -> [CGFloat] {
        var out: [CGFloat] = [-1, -1, -1, -1]
        let resolve = {
            let ns = NSColor(color)
            guard let srgb = ns.usingColorSpace(.sRGB) else { return }
            out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        }
        if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return out
    }
}

/// Asserts two theme-aware colors resolve to the same sRGB value (dark scheme by
/// default). Use instead of `XCTAssertEqual` for `Colors.*` SwiftUI tokens.
func XCTAssertSameColor(
    _ a: @autoclosure () -> Color,
    _ b: @autoclosure () -> Color,
    dark: Bool = true,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        ColorResolution.rgba(a(), dark: dark),
        ColorResolution.rgba(b(), dark: dark),
        message(), file: file, line: line
    )
}

/// Asserts two theme-aware colors resolve to DIFFERENT sRGB values.
func XCTAssertDifferentColor(
    _ a: @autoclosure () -> Color,
    _ b: @autoclosure () -> Color,
    dark: Bool = true,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNotEqual(
        ColorResolution.rgba(a(), dark: dark),
        ColorResolution.rgba(b(), dark: dark),
        message(), file: file, line: line
    )
}
