import SwiftUI

fileprivate enum DisplayMode: String, CaseIterable, Identifiable {
    case pretty, raw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pretty: return "Pretty"
        case .raw: return "Raw"
        }
    }
}

fileprivate struct DisplayModePills: View {
    @Binding var mode: DisplayMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DisplayMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Text(option.label)
                        .font(Typography.caption.weight(.medium))
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, 6)
                        .foregroundStyle(mode == option ? Colors.textPrimary : Colors.textSecondary)
                        .background {
                            if mode == option {
                                RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceElevated)
                            }
                        }
                        .contentShape(RoundedRectangle.squircle(CornerRadius.small))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.xxs)
        .background(RoundedRectangle.squircle(CornerRadius.small).fill(Colors.surfaceCard))
    }
}

fileprivate func prettyPrintJSON(_ source: String) -> String? {
    guard let data = source.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let formatted = String(data: pretty, encoding: .utf8)
    else { return nil }
    return formatted
}

/// Standalone window content for "open in new window" Activity Feed details.
/// Renders the full untruncated payload — every previously inline expandable
/// section funnels into one of the cases here.
struct ActivityDetailWindowView: View {
    let detail: ActivityDetailWindow

    @Environment(NTMSOrchestrator.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch detail {
            case .thinking(_, let roleName, let text):
                textBody(eyebrow: "Thinking", title: roleName, text: text)
            case .meetingThinking(_, let roleName, let text):
                textBody(eyebrow: "Meeting Thinking", title: roleName, text: text)
            case .supervisorThinking(_, let roleName, let text):
                textBody(eyebrow: "Thinking", title: roleName, text: text)
            case .toolCall(_, let toolName, let argumentsJSON, let resultJSON, let isError, let createdAt):
                ToolCallDetailBody(
                    toolName: toolName,
                    argumentsJSON: argumentsJSON,
                    resultJSON: resultJSON,
                    isError: isError,
                    createdAt: createdAt
                )
            case .artifact(_, let artifactName, let mimeType, let relativePath, let createdAt):
                ArtifactDetailBody(
                    artifactName: artifactName,
                    mimeType: mimeType,
                    relativePath: relativePath,
                    createdAt: createdAt,
                    workFolderURL: store.workFolderURL
                )
            case .meetingTool(_, let summary):
                MeetingToolDetailBody(summaries: [summary])
            case .meetingTools(_, let summaries):
                MeetingToolDetailBody(summaries: summaries)
            case .systemNotice(_, let label, let text):
                textBody(eyebrow: "System", title: label, text: text)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Colors.surfacePrimary)
        // Hidden Cancel-action button so Escape closes the window. Without
        // this macOS' WindowGroup has no default Esc behaviour.
        .background {
            Button("", action: { dismissWindow() })
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Plain text body (thinking / meeting thinking / supervisor thinking)

    @ViewBuilder
    private func textBody(eyebrow: String, title: String, text: String) -> some View {
        DetailWindow(
            eyebrow: eyebrow,
            title: title,
            metadata: nil,
            leadingIcon: nil,
            trailing: nil
        ) {
            Text(text)
                .font(Typography.termBase)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.standard)
        }
    }
}

// MARK: - Detail window shell

/// Unified shell shared by every detail window kind: compact `DetailHeader`
/// stacked over a `ScrollView` of caller-supplied content. No divider between
/// the two — the typographic whitespace of `DetailHeader` already separates
/// header from body.
private struct DetailWindow<Content: View>: View {
    let eyebrow: String
    let title: String
    let metadata: String?
    let leadingIcon: DetailHeader.LeadingIcon?
    let trailing: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(
                eyebrow: eyebrow,
                title: title,
                metadata: metadata,
                leadingIcon: leadingIcon,
                trailing: trailing
            )
            ScrollView {
                content()
            }
        }
    }
}

// MARK: - Header

/// Single-line header shared by every detail window kind: leading status icon,
/// uppercase eyebrow, bold title, muted metadata, and trailing controls — all
/// baseline-aligned on one row. Title gets `layoutPriority(1)` so eyebrow and
/// metadata truncate first when window width is tight.
private struct DetailHeader: View {
    struct LeadingIcon {
        let systemName: String
        let color: Color
    }

    let eyebrow: String
    let title: String
    let metadata: String?
    let leadingIcon: LeadingIcon?
    let trailing: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if let leadingIcon {
                Image(systemName: leadingIcon.systemName)
                    .foregroundStyle(leadingIcon.color)
            }
            Text(eyebrow)
                .font(Typography.caption2.weight(.semibold))
                .foregroundStyle(Colors.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
            Text(title)
                .font(Typography.termLg)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .layoutPriority(1)
            if let metadata, !metadata.isEmpty {
                Text(metadata)
                    .font(Typography.caption)
                    .foregroundStyle(Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Spacing.s)
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.s)
    }
}

// MARK: - Tool call detail

/// Two-section view: `Arguments` and `Result` (when non-nil). The header
/// hosts the Pretty/Raw toggle when at least one section has a JSON form
/// distinct from raw — Pretty pretty-prints via `JSONSerialization`, Raw
/// shows the original wire string verbatim. Sections that aren't valid
/// JSON show their raw form regardless of mode.
private struct ToolCallDetailBody: View {
    let toolName: String
    let argumentsJSON: String
    let resultJSON: String?
    let isError: Bool
    let createdAt: Date

    @State private var displayMode: DisplayMode = .pretty

    private var hasPrettyRendering: Bool {
        if prettyPrintJSON(argumentsJSON) != nil { return true }
        if let resultJSON, prettyPrintJSON(resultJSON) != nil { return true }
        return false
    }

    var body: some View {
        DetailWindow(
            eyebrow: "Tool Call",
            title: toolName,
            metadata: createdAt.formatted(date: .abbreviated, time: .standard),
            leadingIcon: .init(
                systemName: isError ? "xmark.circle" : "checkmark.circle",
                color: isError ? Colors.error : Colors.success
            ),
            trailing: hasPrettyRendering ? AnyView(DisplayModePills(mode: $displayMode)) : nil
        ) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                section(title: "Arguments", json: argumentsJSON, isError: false)
                if let result = resultJSON {
                    section(title: "Result", json: result, isError: isError)
                }
            }
            .padding(Spacing.standard)
        }
    }

    @ViewBuilder
    private func section(title: String, json: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textSecondary)
            Text(rendered(json))
                .font(Typography.termBase)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(isError ? Colors.errorTint : Colors.surfaceOverlay)
                )
        }
    }

    /// Pretty mode: pretty-print if valid JSON, otherwise fall back to raw.
    /// Raw mode: always raw (the wire string verbatim).
    private func rendered(_ json: String) -> String {
        if displayMode == .pretty, let pretty = prettyPrintJSON(json) {
            return pretty
        }
        return json
    }
}

// MARK: - Artifact detail (loads from disk)

/// Loads artifact content from `<workFolderURL>/.nanoteams/<relativePath>` off
/// the main actor in `.task(id: relativePath)`. `loadContent` clears state
/// up-front on every (re-)fire so a fresh failure surfaces via
/// `ContentUnavailableView` instead of being masked by a prior successful
/// payload. In practice `relativePath` doesn't mutate within a window's
/// lifetime (dedup key includes it) but `.task(id:)` is defensive.
///
/// Pretty / Raw toggle in the header lets the user flip between rendered view
/// and the on-disk source. Pretty handles markdown (rendered via
/// `Text(.init:)`), JSON (pretty-printed via `JSONSerialization`), and HTML
/// (stripped of markup for display only — `read_file` keeps source verbatim
/// by design; this viewer is the deliberately-opposite philosophy because
/// the user is reading rather than editing). Binary side-cars (PDF/DOCX/RTF
/// produced by `create_artifact(format:)`) are routed via
/// `ArtifactContentDecoder` to a "Reveal in Finder" affordance instead of
/// failing the UTF-8 decode. Other text-like types fall back to proportional
/// `Text`. Raw is always monospaced source.
private struct ArtifactDetailBody: View {
    let artifactName: String
    let mimeType: String
    let relativePath: String?
    let createdAt: Date
    let workFolderURL: URL?

    @State private var content: String?
    @State private var binaryInfo: (byteCount: Int, fileURL: URL)?
    @State private var loadError: String?
    @State private var displayMode: DisplayMode = .pretty

    private var isMarkdown: Bool {
        mimeType == "text/markdown" || artifactName.lowercased().hasSuffix(".md")
    }

    private var isHTML: Bool {
        mimeType == "text/html"
            || artifactName.lowercased().hasSuffix(".html")
            || artifactName.lowercased().hasSuffix(".htm")
    }

    private var isJSONLike: Bool {
        mimeType == "application/json" || artifactName.lowercased().hasSuffix(".json")
    }

    /// `true` when the artifact has any prettified rendering distinct from raw
    /// monospaced source — drives whether the toggle is shown.
    private var hasPrettyRendering: Bool {
        guard let content, !content.isEmpty else { return false }
        if isMarkdown || isHTML || isJSONLike { return true }
        // Try sniffing JSON from contents even when extension/mimeType doesn't say so.
        return prettyPrintJSON(content) != nil
    }

    var body: some View {
        DetailWindow(
            eyebrow: "Artifact",
            title: artifactName,
            metadata: "\(mimeType) · \(createdAt.formatted(date: .abbreviated, time: .shortened))",
            leadingIcon: nil,
            trailing: hasPrettyRendering ? AnyView(DisplayModePills(mode: $displayMode)) : nil
        ) {
            if let content {
                contentView(for: content)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.m)
            } else if let binaryInfo {
                binaryAffordance(byteCount: binaryInfo.byteCount, fileURL: binaryInfo.fileURL)
            } else if let loadError {
                NTMSEmptyState(
                    title: "Couldn't load artifact",
                    message: loadError,
                    systemImage: "exclamationmark.triangle"
                )
                .padding(Spacing.xl)
            } else {
                HStack(spacing: Spacing.s) {
                    NTMSLoader(.small)
                    Text("Loading…")
                        .font(Typography.termBase)
                        .foregroundStyle(Colors.textSecondary)
                }
                .padding(Spacing.xl)
            }
        }
        .task(id: relativePath) {
            await loadContent()
        }
    }

    @ViewBuilder
    private func binaryAffordance(byteCount: Int, fileURL: URL) -> some View {
        let formattedSize = ByteCountFormatter.string(
            fromByteCount: Int64(byteCount), countStyle: .file
        )
        NTMSEmptyState(
            title: "Binary artifact",
            message: "\(formattedSize) — open the file in Finder to view it.",
            systemImage: "doc",
            action: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) },
            actionLabel: "Reveal in Finder"
        )
        .padding(Spacing.xl)
    }

    // MARK: - Content rendering

    @ViewBuilder
    private func contentView(for content: String) -> some View {
        if displayMode == .raw || !hasPrettyRendering {
            Text(content)
                .font(Typography.termBase)
        } else if isMarkdown {
            Text(.init(content))
        } else if isHTML, let attributed = Self.renderHTML(content) {
            Text(attributed)
        } else if let prettyJSON = prettyPrintJSON(content) {
            Text(prettyJSON)
                .font(Typography.termBase)
        } else {
            // Fallback (shouldn't hit because hasPrettyRendering would be false).
            Text(content)
        }
    }

    private static func renderHTML(_ source: String) -> AttributedString? {
        guard let data = source.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return AttributedString(ns)
    }

    private func loadContent() async {
        // Clear stale state up-front. Without this, the body's `if let content`
        // ladder keeps showing the previous successful load when a re-fire
        // (different `relativePath` triggering `.task(id:)`) hits a failure —
        // the new error sets `loadError` but the prior `content` masks it.
        content = nil
        binaryInfo = nil
        loadError = nil

        guard let relativePath, !relativePath.isEmpty else {
            loadError = "Artifact has no on-disk path — it may not have been persisted yet."
            return
        }
        guard let projectURL = workFolderURL else {
            loadError = "Open a work folder to view artifact content."
            return
        }
        let fileURL = projectURL
            .appendingPathComponent(".nanoteams")
            .appendingPathComponent(relativePath)
        let mime = mimeType
        let ext = fileURL.pathExtension
        let result: Result<ArtifactRenderDecision, Error> = await Task.detached {
            do {
                let data = try Data(contentsOf: fileURL)
                return .success(ArtifactContentDecoder.decide(
                    data: data, mimeType: mime, fileExtension: ext
                ))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(.text(let text)):
            content = text
        case .success(.binary(let byteCount, _)):
            binaryInfo = (byteCount: byteCount, fileURL: fileURL)
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Meeting tool(s) detail

/// Renders one or more `MeetingToolSummary` blocks: each shows tool name +
/// status + full untruncated `arguments` and `result` text. Used for both the
/// `.meetingTool` (single) and `.meetingTools` (multiple) cases — same view,
/// different array length.
private struct MeetingToolDetailBody: View {
    let summaries: [MeetingToolSummary]

    @State private var displayMode: DisplayMode = .pretty

    private var hasPrettyRendering: Bool {
        summaries.contains { summary in
            (!summary.arguments.isEmpty && prettyPrintJSON(summary.arguments) != nil)
                || (!summary.result.isEmpty && prettyPrintJSON(summary.result) != nil)
        }
    }

    var body: some View {
        DetailWindow(
            eyebrow: summaries.count == 1 ? "Meeting Tool Call" : "Meeting Tool Calls",
            title: summaries.count == 1
                ? (summaries.first?.toolName ?? "Tool Call")
                : "\(summaries.count) calls",
            metadata: nil,
            leadingIcon: .init(systemName: "wrench.and.screwdriver", color: Colors.purple),
            trailing: hasPrettyRendering ? AnyView(DisplayModePills(mode: $displayMode)) : nil
        ) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                ForEach(summaries) { summary in
                    toolBlock(summary)
                }
            }
            .padding(Spacing.standard)
        }
    }

    @ViewBuilder
    private func toolBlock(_ summary: MeetingToolSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Spacing.xs) {
                StatusGlyph(
                    glyph: summary.isError ? TerminalGlyph.failed : TerminalGlyph.done,
                    color: summary.isError ? Colors.error : Colors.success
                )
                Text(summary.toolName)
                    .font(Typography.subheadlineSemibold)
                Spacer()
                Text(summary.createdAt.formatted(date: .omitted, time: .standard))
                    .font(Typography.term2xs)
                    .foregroundStyle(Colors.textTertiary)
            }
            if !summary.arguments.isEmpty {
                labelledBlock(title: "Arguments", text: summary.arguments, isError: false)
            }
            if !summary.result.isEmpty {
                labelledBlock(title: "Result", text: summary.result, isError: summary.isError)
            }
        }
    }

    @ViewBuilder
    private func labelledBlock(title: String, text: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.captionSemibold)
                .foregroundStyle(Colors.textSecondary)
            Text(rendered(text))
                .font(Typography.termBase)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(
                    RoundedRectangle.squircle(CornerRadius.small)
                        .fill(isError ? Colors.errorTint : Colors.surfaceOverlay)
                )
        }
    }

    /// Pretty mode: pretty-print if valid JSON, otherwise raw. Raw mode: always raw.
    private func rendered(_ text: String) -> String {
        if displayMode == .pretty, let pretty = prettyPrintJSON(text) {
            return pretty
        }
        return text
    }
}
