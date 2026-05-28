import AppKit
import SwiftUI

// MARK: - Resolved Prompt View

/// Read-only display of an already-built `NSAttributedString`. Pure SwiftUI
/// `Text(AttributedString)` inside `ScrollView` — NSTextView's layer-backed
/// compositing path blocked the main thread on `CAContext::waitForCommitId`
/// per Instruments. No `NSTextAttachment` support — wire previews resolve all
/// placeholders to text, no attachments materialize.
struct ResolvedPromptView: View {
    let attributed: NSAttributedString

    /// `AttributedString(NSAttributedString)` is a conversion that walks every
    /// attribute range. Cache it keyed by the source string's identity so
    /// parent re-renders that pass the same `@State`-cached instance reuse
    /// the converted value instead of re-converting on every body eval.
    @State private var displayString: AttributedString = AttributedString()

    var body: some View {
        ScrollView {
            Text(displayString)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
        .scrollIndicators(.automatic)
        .task(id: ObjectIdentifier(attributed)) {
            displayString = AttributedString(attributed)
        }
    }
}
