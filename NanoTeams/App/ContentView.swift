import SwiftUI

// MARK: - App Appearance

/// System appearance setting with user preference override
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    private static let displayNameMap: [AppAppearance: String] = [
        .system: "System",
        .light: "Light",
        .dark: "Dark"
    ]

    private static let colorSchemeMap: [AppAppearance: ColorScheme?] = [
        .system: nil,
        .light: .light,
        .dark: .dark
    ]

    var displayName: String { Self.displayNameMap[self] ?? rawValue }
    var colorScheme: ColorScheme? { Self.colorSchemeMap[self] ?? nil }
}
