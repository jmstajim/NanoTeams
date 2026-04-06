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

    func makeCoordinator() -> Coordinator {
        Coordinator(template: $template, placeholders: placeholders)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = CornerRadius.medium
        scrollView.layer?.masksToBounds = true

        let textView = NSTextView()
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
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Configure text container for wrapping
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Load initial content with chips
        let attributed = PlaceholderParser.attributedString(from: template, placeholders: placeholders)
        textView.textStorage?.setAttributedString(attributed)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Sync placeholders — needed when switching between template types
        let placeholdersChanged = context.coordinator.placeholders.map(\.key) != placeholders.map(\.key)
        if placeholdersChanged {
            context.coordinator.placeholders = placeholders
        }

        // Handle pending insertion at cursor position
        if let insertion = pendingInsertion {
            DispatchQueue.main.async {
                self.pendingInsertion = nil
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
                textView.textStorage?.setAttributedString(attributed)
                // Restore selection if possible
                let maxRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
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
        weak var textView: NSTextView?
        var isEditing = false
        private var debounceTimer: Timer?

        init(template: Binding<String>, placeholders: [(key: String, label: String, category: String)]) {
            self.template = template
            self.placeholders = placeholders
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true

            // Debounce: convert typed {placeholder} patterns to chips after 0.5s
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let storage = textView.textStorage else { return }
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
                textView.textStorage?.replaceCharacters(in: selectedRange, with: chipString)
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
