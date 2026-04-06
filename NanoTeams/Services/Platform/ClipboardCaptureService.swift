import AppKit
import ApplicationServices

// MARK: - Clipboard Capture Result

/// Result of a smart clipboard capture — may contain text, file URLs, or both.
struct ClipboardCaptureResult {
    var text: String?
    var fileURLs: [URL]
}

// MARK: - Source Context

/// Metadata about the source location of a clipboard capture from a code editor.
struct SourceContext {
    let filePath: String
    let fileName: String
    let lineStart: Int?
    let lineEnd: Int?

    /// Zero-width space sentinel prevents false positives on user code containing `// Source: `.
    private static let headerPrefix = "\u{200B}// Source: "

    /// Splits an enriched clipped text into (sourceLabel, bodyText).
    /// Returns nil if the text doesn't start with `// Source:` or has no body.
    static func parse(_ text: String) -> (source: String, body: String)? {
        guard text.hasPrefix(headerPrefix) else { return nil }
        guard let newlineIndex = text.firstIndex(of: "\n") else { return nil }
        let source = String(text[text.index(text.startIndex, offsetBy: headerPrefix.count)..<newlineIndex])
        let body = String(text[text.index(after: newlineIndex)...])
        guard !body.isEmpty else { return nil }
        return (source: source, body: body)
    }
}

// MARK: - Clipboard Capture Service

/// Captures selected content from the frontmost application by simulating Cmd+C.
/// Returns file URLs (e.g. from Finder) and/or text depending on what the source app places on the pasteboard.
enum ClipboardCaptureService {

    /// Captures the currently selected content from the frontmost application.
    /// When `workFolderRoot` is provided and the source file is within that directory,
    /// the captured text is enriched with a `// Source:` header containing the relative path and line numbers.
    /// - Parameter workFolderRoot: The project's working directory. Pass `nil` to skip source enrichment.
    /// - Returns: A result containing captured text and/or file URLs.
    static func captureSelection(workFolderRoot: URL? = nil) async -> ClipboardCaptureResult {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousContents = snapshotPasteboard(pasteboard)

        // Try simulating Cmd+C if we have Accessibility permissions
        if AXIsProcessTrusted() {
            // Skip capture if NanoTeams itself is frontmost (e.g. user just clicked sidebar) —
            // Cmd+C would have nothing to copy and we'd waste 500ms polling.
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
                return ClipboardCaptureResult(text: nil, fileURLs: [])
            }

            // Detect source BEFORE simulating copy (source app is still frontmost).
            // Step 1: get file path cheaply, check if it's in the project.
            // Step 2: only compute line numbers if the file qualifies.
            var sourceContext: SourceContext?
            if let root = workFolderRoot {
                sourceContext = detectSourceContext(workFolderRoot: root)
            }

            simulateCopy()

            // Poll for pasteboard change (up to 500ms, every 50ms)
            let captured = await pollPasteboardCapture(
                previousChangeCount: previousChangeCount,
                maxAttempts: 10,
                intervalMs: 50
            )

            if var captured {
                // Restore previous clipboard (best-effort)
                restorePasteboard(previous: previousContents)

                // Enrich text with source context (path check already done in detectSourceContext)
                if let text = captured.text, !text.isEmpty,
                   let ctx = sourceContext, let root = workFolderRoot {
                    captured.text = enrichText(text, with: ctx, relativeTo: root)
                }

                return captured
            }
        }

        return ClipboardCaptureResult(text: nil, fileURLs: [])
    }

    /// Prompts the user for Accessibility permissions if not already granted.
    /// Opens System Settings automatically.
    static func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    // MARK: - Source Context Detection

    /// Queries the frontmost application's Accessibility tree to determine the source file
    /// and selected line range. Returns nil if the file is not within `workFolderRoot`.
    /// Checks the file path first (cheap) before computing line numbers (heavier).
    private static func detectSourceContext(workFolderRoot: URL) -> SourceContext? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowRef = windowValue else {
            return nil
        }
        // CF type bridge from AnyObject is guaranteed after .success
        let windowElement = windowRef as! AXUIElement

        // Step 1: Resolve file path (cheap AX query)
        let filePath: String
        let fileName: String

        var docValue: AnyObject?
        if AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &docValue) == .success,
           let docURLString = docValue as? String,
           let docURL = URL(string: docURLString),
           docURL.isFileURL {
            filePath = docURL.path
            fileName = docURL.lastPathComponent
        } else {
            return nil
        }

        // Step 2: Check if file is within project root — bail early if not
        guard SandboxPathResolver.isWithin(candidate: URL(fileURLWithPath: filePath), container: workFolderRoot) else {
            return nil
        }

        // Step 3: Compute line numbers (heavier — reads full text content)
        let lineInfo = detectLineRange(appElement: appElement)

        return SourceContext(
            filePath: filePath,
            fileName: fileName,
            lineStart: lineInfo?.start,
            lineEnd: lineInfo?.end
        )
    }

    /// Detects the line range of the current selection in the focused text element.
    /// Uses UTF-16 offsets (NSString) for correct CFRange mapping.
    private static func detectLineRange(appElement: AXUIElement) -> (start: Int, end: Int)? {
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedRef = focusedValue else {
            return nil
        }
        let focusedElement = focusedRef as! AXUIElement

        // Get selected text range (CFRange with UTF-16 offsets)
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard let rangeRef = rangeValue else { return nil }
        // CF type bridge from AnyObject is guaranteed after .success
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else {
            return nil
        }

        // Get full text to count newlines
        var textValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &textValue) == .success,
              let fullText = textValue as? String else {
            return nil
        }

        // Use NSString for correct UTF-16 offset mapping from CFRange
        let nsText = fullText as NSString
        let safeLocation = min(max(range.location, 0), nsText.length)
        let safeEnd: Int
        let (sum, overflow) = range.location.addingReportingOverflow(range.length)
        safeEnd = overflow ? nsText.length : min(sum, nsText.length)

        let beforeStart = nsText.substring(to: safeLocation)
        let startLine = beforeStart.filter { $0 == "\n" }.count + 1

        let beforeEnd = nsText.substring(to: safeEnd)
        let endLine = beforeEnd.filter { $0 == "\n" }.count + 1

        return (start: startLine, end: endLine)
    }

    // MARK: - Text Enrichment

    /// Prepends a `// Source:` header with relative path and line numbers to the captured text.
    private static func enrichText(_ text: String, with ctx: SourceContext, relativeTo root: URL) -> String {
        // Compute relative path from project root (path already verified by SandboxPathResolver)
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relativePath = ctx.filePath.hasPrefix(rootPath)
            ? String(ctx.filePath.dropFirst(rootPath.count))
            : ctx.fileName

        let lineInfo: String
        if let start = ctx.lineStart, let end = ctx.lineEnd, end > start {
            lineInfo = ":\(start)-\(end)"
        } else if let start = ctx.lineStart {
            lineInfo = ":\(start)"
        } else {
            lineInfo = ""
        }

        return "\u{200B}// Source: \(relativePath)\(lineInfo)\n\(text)"
    }

    // MARK: - Copy Simulation

    private static func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        // Key code 8 = 'c'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func pollPasteboardCapture(
        previousChangeCount: Int,
        maxAttempts: Int,
        intervalMs: UInt64
    ) async -> ClipboardCaptureResult? {
        let pasteboard = NSPasteboard.general

        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .milliseconds(intervalMs))

            if pasteboard.changeCount != previousChangeCount {
                let text = pasteboard.string(forType: .string)
                let fileURLs = (pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: NSNumber(value: true)]
                ) as? [URL]) ?? []

                guard text != nil || !fileURLs.isEmpty else { continue }
                return ClipboardCaptureResult(text: text, fileURLs: fileURLs)
            }
        }

        return nil
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        }
    }

    private static func restorePasteboard(previous: [PasteboardItemSnapshot]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !previous.isEmpty else { return }

        let items = previous.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

private struct PasteboardItemSnapshot {
    let dataByType: [NSPasteboard.PasteboardType: Data]
}
