import SwiftUI
import AppKit

// MARK: - Prompt Template Editor

/// A visual editor for prompt templates with inline placeholder chips.
/// Placeholders like `{roleName}` are rendered as colored rounded-rect tokens.
/// Parsing and conversion logic delegated to `PlaceholderParser`.
/// Chip rendering delegated to `PlaceholderAttachment`.
struct PromptTemplateEditor: NSViewRepresentable {
    @Binding var template: String
    @Binding var pendingInsertion: String?
    let placeholders: [(key: String, label: String, category: String)]
    /// Observed so `updateNSView` re-stamps NSTextView colors when the user
    /// switches themes. AppKit caches resolved NSColors per `NSAppearance` —
    /// switching between two themes that share a color scheme (e.g. two dark
    /// palettes) does NOT auto-invalidate that cache. Reading this property
    /// makes SwiftUI re-invoke `updateNSView` on every theme change.
    @AppStorage(UserDefaultsKeys.activeTheme) private var activeThemeRaw: String = Theme.defaultTheme.rawValue

    func makeCoordinator() -> Coordinator {
        Coordinator(template: $template, placeholders: placeholders)
    }

    func makeNSView(context: Context) -> NSScrollView {
        return wire(coordinator: context.coordinator)
    }

    /// Shared construction body for `makeNSView` and the `#if DEBUG` test
    /// seam below. The two entry points must stay structurally identical so
    /// `PromptTemplateEditorLagInvariantTests` pins the same wiring SwiftUI
    /// gets in production.
    @MainActor
    private func wire(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // NSClipView defaults to drawing controlBackgroundColor over our layer —
        // disable it so the textView's own backgroundColor shows through.
        scrollView.contentView.drawsBackground = false
        // Intentionally NO `wantsLayer + cornerRadius + masksToBounds` — that
        // combination with a scrolling sublayer forces CoreAnimation to do an
        // offscreen mask pass per frame, producing trackpad-scroll hitches
        // (CLAUDE.md Swift Style #50). The textView's `backgroundColor` fill
        // is AppKit-drawn and stays cheap; the caller can add a SwiftUI
        // `.overlay(strokeBorder)` if a visual frame is wanted.

        // TextKit 1 hard-init — the convenience `NSTextView()` initializer may
        // opt into TextKit 2 (nil `layoutManager`), which breaks height
        // measurement and chip rendering for placeholder attachments.
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = Colors.nsTextPrimary
        textView.backgroundColor = Colors.nsSurfaceCard
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Configure text container for wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        // Load initial content with chips. `textStorage` is non-nil because we
        // attached it via the explicit TextKit 1 init above — a nil here means
        // the hard-init contract broke (e.g. someone reverted to convenience
        // `NSTextView()`); fail loudly in DEBUG so the regression doesn't ship
        // as a silently-empty editor.
        let attributed = PlaceholderParser.attributedString(from: template, placeholders: placeholders)
        guard let initialStorage = textView.textStorage else {
            assertionFailure("PromptTemplateEditor: NSTextView built with explicit container has nil textStorage — TextKit 1 setup broken")
            return scrollView
        }
        initialStorage.setAttributedString(attributed)

        return scrollView
    }

    #if DEBUG
    /// Mirrors `makeNSView` without a SwiftUI `Context`. Tests use this to
    /// drive the production wiring directly — bypassing `NSHostingView` +
    /// subtree-walking, which would silently fall through to an empty
    /// scroll view if SwiftUI's hosting internals change shape.
    @MainActor
    func testHooks_makeNSView(coordinator: Coordinator) -> NSScrollView {
        return wire(coordinator: coordinator)
    }
    #endif

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            assertionFailure("PromptTemplateEditor: scrollView.documentView is not NSTextView — only makeNSView constructs the view")
            return
        }
        // Same TextKit 1 contract as `makeNSView` — every subsequent read of
        // `textStorage` flows through this baseline so the optional chain
        // doesn't get scattered through the function.
        guard let storage = textView.textStorage else {
            assertionFailure("PromptTemplateEditor: NSTextView textStorage nil during update — TextKit 1 setup broken")
            return
        }

        // Sync placeholders — needed when switching between template types
        let placeholdersChanged = context.coordinator.placeholders.map(\.key) != placeholders.map(\.key)
        if placeholdersChanged {
            context.coordinator.placeholders = placeholders
        }

        // Re-stamp colors + rebuild attributed string when the active theme
        // changes. AppKit's NSColor cache keys on `NSAppearance.name`, so a
        // palette swap within the same color scheme (dark→dark) keeps the
        // stale resolved color until we replace the attribute outright.
        let themeChanged = context.coordinator.lastAppliedTheme != activeThemeRaw
        if themeChanged {
            context.coordinator.lastAppliedTheme = activeThemeRaw
            textView.textColor = Colors.nsTextPrimary
            textView.backgroundColor = Colors.nsSurfaceCard
            let selectedRange = textView.selectedRange()
            let attributed = PlaceholderParser.attributedString(from: template, placeholders: placeholders)
            storage.setAttributedString(attributed)
            let maxLen = storage.length
            if selectedRange.location <= maxLen {
                textView.setSelectedRange(NSRange(location: min(selectedRange.location, maxLen), length: 0))
            }
        }

        // Handle pending insertion at cursor position.
        // `pendingInsertion = nil` is deferred via `DispatchQueue.main.async`
        // because SwiftUI state mutations from inside `updateNSView` trip the
        // "Modifying state during view update" runtime warning. The guard
        // inside the async closure protects against the race where a second
        // `pendingInsertion` arrives before the hop runs — we only clear the
        // slot if it still holds the value we already consumed.
        if let insertion = pendingInsertion {
            DispatchQueue.main.async {
                if self.pendingInsertion == insertion {
                    self.pendingInsertion = nil
                }
            }
            context.coordinator.insertAtCursor(insertion, in: textView)
            return
        }

        // Only update if template changed externally (not from our own editing)
        if !context.coordinator.isEditing {
            let currentPlain = PlaceholderParser.plainString(from: textView.attributedString())
            if currentPlain != template || placeholdersChanged {
                let selectedRange = textView.selectedRange()
                let attributed = PlaceholderParser.attributedString(from: template, placeholders: placeholders)
                storage.setAttributedString(attributed)
                // Restore selection if possible
                let maxRange = NSRange(location: 0, length: storage.length)
                if selectedRange.location <= maxRange.length {
                    textView.setSelectedRange(NSRange(
                        location: min(selectedRange.location, maxRange.length),
                        length: 0
                    ))
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var template: Binding<String>
        var placeholders: [(key: String, label: String, category: String)]
        var isEditing = false
        /// Last theme rawValue stamped into the textView — drives the
        /// theme-change branch in `updateNSView`.
        var lastAppliedTheme: String?
        private var debounceTimer: Timer?

        init(template: Binding<String>, placeholders: [(key: String, label: String, category: String)]) {
            self.template = template
            self.placeholders = placeholders
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                assertionFailure("PromptTemplateEditor: textDidChange received a non-NSTextView object — delegate misrouted")
                return
            }
            isEditing = true

            // Debounce: convert typed {placeholder} patterns to chips after 0.5s
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let storage = textView.textStorage else {
                        assertionFailure("PromptTemplateEditor: textStorage nil during chip conversion — TextKit 1 setup broken")
                        return
                    }
                    PlaceholderParser.convertTypedPlaceholders(in: storage, placeholders: self.placeholders)
                    self.syncToBinding(textView: textView)
                    self.isEditing = false
                }
            }

            // Sync immediately (before chip conversion) so binding stays up to date
            syncToBinding(textView: textView)
        }

        private func syncToBinding(textView: NSTextView) {
            let plain = PlaceholderParser.plainString(from: textView.attributedString())
            if plain != template.wrappedValue {
                template.wrappedValue = plain
            }
        }

        // MARK: - Insertion

        /// Insert a placeholder (e.g. `{roleName}`) at the current cursor position as a chip.
        func insertAtCursor(_ text: String, in textView: NSTextView) {
            let selectedRange = textView.selectedRange()

            // Try to parse as a {key} placeholder and insert as chip
            if let chipString = PlaceholderParser.parseChip(from: text, placeholders: placeholders) {
                guard let storage = textView.textStorage else {
                    assertionFailure("PromptTemplateEditor: textStorage nil during insertAtCursor — TextKit 1 setup broken")
                    return
                }
                storage.replaceCharacters(in: selectedRange, with: chipString)
                textView.setSelectedRange(NSRange(location: selectedRange.location + 1, length: 0))
                syncToBinding(textView: textView)
                return
            }

            // Fallback: insert as plain text
            textView.insertText(text, replacementRange: selectedRange)
            syncToBinding(textView: textView)
        }
    }
}
