import SwiftUI

/// Settings-specific layout constants (master-detail, card icons, toggle rows).
enum SettingsLayout {
    /// Width of the list in master-detail views
    static let listWidth: CGFloat = 260
    /// Minimum width for detail panels
    static let detailMinWidth: CGFloat = 400
    /// Card header icon container size (icon-in-rounded-rect)
    static let cardIconSize: CGFloat = 36
    /// Toggle row icon container size (compact icon square)
    static let toggleIconSize: CGFloat = 28
    /// Right-aligned numeric value cell in stepper rows (the "500" / "Unlimited" label).
    /// Wide enough to keep the Stepper from jumping when the value gains/loses a digit.
    static let stepperValueMinWidth: CGFloat = 70
}
