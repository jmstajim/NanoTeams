import Carbon
import SwiftUI

// MARK: - Hotkey Registration

extension QuickCaptureController {

    // MARK: - Hotkey IDs

    private static let openHotkeyID: UInt32 = 1
    private static let clipHotkeyID: UInt32 = 2

    // MARK: - Setup

    /// Registers global hotkeys. Call once from NanoTeamsApp on appear.
    func setup(store: NTMSOrchestrator, dictation: DictationService) {
        self.store = store
        self.dictation = dictation
        guard !didSetupHotkeys else { return }
        didSetupHotkeys = true

        // Ctrl+Opt+Cmd+0 — open overlay (no clip)
        // Key code 29 = '0', modifiers: cmdKey | optionKey | controlKey
        let openRegistered = hotkeyManager.register(
            id: Self.openHotkeyID,
            keyCode: 29,
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            handler: { [weak self] in
                self?.togglePanel()
            }
        )

        // Ctrl+Opt+Cmd+K — capture selection (files → attachments, text → clips) + open overlay
        // Key code 40 = 'k'
        let clipRegistered = hotkeyManager.register(
            id: Self.clipHotkeyID,
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            handler: { [weak self] in
                Task { @MainActor in
                    await self?.showPanel(withClip: true)
                }
            }
        )

        // A combo another app already owns cannot be claimed, and Carbon only says so through
        // this status. Left unreported, the shortcut the Settings sheet advertises just never
        // fires — indistinguishable from the feature being broken. Both failing is reported as
        // one message: `lastErrorMessage` is a single coalescing slot (CLAUDE.md §45), so two
        // writes would show only the second.
        if let message = Self.unclaimedHotkeyMessage(openRegistered: openRegistered,
                                                     clipRegistered: clipRegistered) {
            store.lastErrorMessage = message
        }
    }

    /// Pure: which advertised shortcuts could not be claimed → the one message to surface.
    /// `nil` when both registered. Split out so it is testable without Carbon.
    nonisolated static func unclaimedHotkeyMessage(openRegistered: Bool, clipRegistered: Bool) -> String? {
        var combos: [String] = []
        if !openRegistered { combos.append("⌃⌥⌘0 (Quick Capture)") }
        if !clipRegistered { combos.append("⌃⌥⌘K (Context Capture)") }
        guard !combos.isEmpty else { return nil }
        let list = combos.joined(separator: " and ")
        return "Couldn't register \(list) — another app is already using "
            + (combos.count > 1 ? "those shortcuts." : "that shortcut.")
    }
}
