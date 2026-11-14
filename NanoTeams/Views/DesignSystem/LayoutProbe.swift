import SwiftUI

/// Where a layout test reads the geometry of a view it cannot reach from outside: a button
/// inside an approval card, a chip placed by the claimed-chips flow, the tool row a server page
/// composes. Each such view is marked `.layoutProbe(_:)`; in a DEBUG build, while a test has set
/// `LayoutProbe.record`, every layout of a marked view reports its frame in window coordinates
/// under its id. In a release build the modifier is the view unchanged.
///
/// Exists because the alternative a layout test otherwise takes — composing the layout type with
/// probes of its own — pins the type, not the surface: a surface that stopped using the type
/// passed every such test. A test sets `record`, hosts the
/// real surface, and clears `record` in its `tearDown`; a leaked recorder would collect the next
/// suite's layouts too.
enum LayoutProbe {
    #if DEBUG
    /// Set by a test, cleared in its `tearDown`. `nil` in every run that is not a layout test.
    static var record: ((_ id: String, _ frame: CGRect) -> Void)?
    #endif
}

extension View {
    /// Reports this view's frame, under `id`, to a layout test listening on `LayoutProbe.record`
    /// (DEBUG only; nothing in a release build).
    func layoutProbe(_ id: String) -> some View {
        modifier(LayoutProbeModifier(id: id))
    }
}

private struct LayoutProbeModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        #if DEBUG
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            LayoutProbe.record?(id, frame)
        }
        #else
        content
        #endif
    }
}
