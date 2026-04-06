import SwiftUI

// MARK: - Keyboard Shortcuts Sheet View

/// Keyboard shortcuts reference sheet
struct KeyboardShortcutsSheetView: View {
    @Environment(\.dismiss) var dismiss
    var embedInSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !embedInSettings {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding()
                .background(Colors.surfaceCard)
                .overlay(alignment: .bottom) { Divider() }
            }
            
            if embedInSettings {
                shortcutsContent
            } else {
                ScrollView {
                    shortcutsContent
                        .padding()
                }
            }
        }
        .frame(width: embedInSettings ? nil : 400, height: embedInSettings ? nil : 500)
        .background {
            if !embedInSettings {
                Rectangle().fill(Colors.surfaceCard)
            }
        }
    }
    
    private var shortcutsContent: some View {
        VStack(spacing: Spacing.xl) {
            shortcutSection(title: "General", shortcuts: [
                ("Command Palette", "⌘K"),
                ("New Task or Chat", "⌘N"),
                ("Quick Task", "⌃⌥⌘0"),
                ("Context Capture", "⌃⌥⌘K"),
                ("Settings", "⌘,"),
                ("Close Window", "⌘W")
            ])
            
            shortcutSection(title: "Navigation", shortcuts: [
                ("Watchtower", "⌘1"),
                ("All Tasks", "⌘2"),
                ("Active Task", "⌘3")
            ])
            
            shortcutSection(title: "Task Board", shortcuts: [
                ("Run Step", "⌘R"),
                ("Stop/Pause", "⌘."),
                ("Approve Step", "⌘Return")
            ])

            shortcutSection(title: "Text Input", shortcuts: [
                ("Send message", "⌘Return"),
                ("New line", "Return"),
            ])

            Text("When \"Enter sends message\" is enabled in Settings, Enter sends and Shift+Return or Cmd+Return inserts a new line.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
    
    private func shortcutSection(title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            VStack(spacing: 0) {
                ForEach(shortcuts, id: \.0) { (label, key) in
                    HStack {
                        Text(label)
                        Spacer()
                        KeyboardKeysView(shortcut: key)
                    }
                    .padding(.vertical, Spacing.s)
                    .padding(.horizontal, Spacing.m)
                    
                    if label != shortcuts.last?.0 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Colors.surfaceCard)
            )
        }
    }
}

/// Splits a shortcut string like "⌃⌥⌘K" into individual key caps.
struct KeyboardKeysView: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(splitKeys, id: \.self) { key in
                KeyboardKeyView(key: key)
            }
        }
    }

    private var splitKeys: [String] {
        let modifiers: Set<Character> = ["⌘", "⌥", "⌃", "⇧"]
        var keys: [String] = []
        var remainder = ""
        for char in shortcut {
            if modifiers.contains(char) {
                keys.append(String(char))
            } else {
                remainder.append(char)
            }
        }
        if !remainder.isEmpty {
            keys.append(remainder)
        }
        return keys
    }
}

struct KeyboardKeyView: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Colors.surfacePrimary)
                    .shadow(.key)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .strokeBorder(Colors.borderSubtle, lineWidth: 1)
            )
    }
}

#Preview("Standalone") {
    KeyboardShortcutsSheetView()
}

#Preview("Embedded") {
    KeyboardShortcutsSheetView(embedInSettings: true)
        .frame(width: 400, height: 500)
}