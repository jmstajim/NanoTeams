import Foundation

private typealias TN = ToolNames
private typealias JS = JSONSchema

// MARK: - screen_capture

nonisolated struct ScreenCaptureTool: ToolHandler {
    static let name = TN.screenCapture
    static let schema = ToolSchema(
        name: TN.screenCapture,
        description: """
        Capture the display or one app's window. Returns the image plus ax_elements — UI elements \
        with image-pixel coordinates: cx/cy is the point to click, w/h the element size. Elements \
        marked "web":true are page content inside a browser; unmarked elements in a browser \
        capture are the browser's own chrome. Coordinates are valid only for the most recent \
        capture; prefer ax_elements coordinates over guessing from pixels.
        """,
        parameters: JS.object(
            properties: [
                "target": JS.string("\"screen\", or an application name / bundle id."),
                "window_title": JS.string("Substring of the window title to narrow which window."),
            ],
            required: ["target"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            try signalResult(tool: Self.name, args: args)
        }
    }
}

// MARK: - ui_click

nonisolated struct UIClickTool: ToolHandler {
    static let name = TN.uiClick
    static let schema = ToolSchema(
        name: TN.uiClick,
        description: """
        Click at (x, y) in image pixels from the most recent capture. Use an element's cx/cy \
        from ax_elements. The result echoes which listed element is under the point.
        """,
        parameters: JS.object(
            properties: [
                "x": JS.integer("Horizontal coordinate."),
                "y": JS.integer("Vertical coordinate."),
                "button": JS.string("Right for a context-menu click.", enumValues: ["left", "right"]),
                "double": JS.boolean(),
                "target": JS.string("Application name / bundle id the click is intended for."),
            ],
            required: ["x", "y"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            try signalResult(tool: Self.name, args: args)
        }
    }

}

// MARK: - ui_type

nonisolated struct UITypeTool: ToolHandler {
    static let name = TN.uiType
    static let schema = ToolSchema(
        name: TN.uiType,
        description: """
        Type text into the currently focused field of the front app. Typing does not press \
        Enter or submit.
        """,
        parameters: JS.object(
            properties: [
                "text": JS.string(),
                "target": JS.string("Application name / bundle id to type into."),
            ],
            required: ["text"]
        )
    )
    static let category: ToolCategory = .computerUse
    /// The body names models send text under, and `content` — but never `text` itself, which
    /// is declared. Before 2026-11-09 a resolver inside the handler took these and then any
    /// single remaining string, while the approval gate took them with the structural keys
    /// excluded: two readings of one call.
    static let undeclaredArguments = ToolArgumentVocabulary.aliases(
        ["content"] + ToolArgumentVocabulary.bodyAlternatives.filter { $0 != "text" }, of: "text")
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            try signalResult(tool: Self.name, args: args)
        }
    }
}

// MARK: - ui_key

nonisolated struct UIKeyTool: ToolHandler {
    static let name = TN.uiKey
    static let schema = ToolSchema(
        name: TN.uiKey,
        description: "Press a key or key combination in the front app.",
        parameters: JS.object(
            properties: [
                "keys": JS.string("Key or combo, e.g. \"return\", \"tab\", \"escape\", \"cmd+s\", \"cmd+shift+4\"."),
                "target": JS.string("Application name / bundle id to send the keys to."),
            ],
            required: ["keys"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let undeclaredArguments = ToolArgumentVocabulary.aliases(["key"], of: "keys")
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            try signalResult(tool: Self.name, args: args)
        }
    }
}

// MARK: - ui_scroll

nonisolated struct UIScrollTool: ToolHandler {
    static let name = TN.uiScroll
    static let schema = ToolSchema(
        name: TN.uiScroll,
        description: "Scroll at (x, y) in image pixels from the most recent capture.",
        parameters: JS.object(
            properties: [
                "x": JS.integer("Horizontal coordinate to scroll at."),
                "y": JS.integer("Vertical coordinate to scroll at."),
                "dx": JS.integer("Horizontal scroll amount in pixels."),
                "dy": JS.integer("Vertical scroll amount in pixels (positive = up)."),
                "target": JS.string("Application name / bundle id to scroll."),
            ],
            required: ["x", "y"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) async -> ToolExecutionResult {
        await ToolErrorHandler.execute(toolName: Self.name, args: args) {
            try signalResult(tool: Self.name, args: args)
        }
    }
}

// MARK: - Shared

/// Interim `{status:"pending"}` envelope + the `.computerUse` signal. The service finalizer
/// overwrites the envelope with the real result.
///
/// The action comes from `ComputerUseArguments` — the resolver the approval gate judges with —
/// so the handler emits exactly what was approved. A missing argument throws its own name
/// (`ToolArgumentError.missingRequired`), which is the refusal the model reads.
nonisolated private func signalResult(tool: String, args: [String: Any]) throws -> ToolExecutionResult {
    guard let action = try ComputerUseArguments.action(canonicalName: tool, args: args) else {
        preconditionFailure("\(tool) is a computer-use tool")
    }
    return signalResult(args: args, action: action)
}

nonisolated private func signalResult(args: [String: Any], action: ComputerUseAction) -> ToolExecutionResult {
    ToolExecutionResult(
        toolName: action.toolNameForSignal,
        argumentsJSON: encodeArgsToJSON(args),
        outputJSON: makeSuccessEnvelope(data: ["status": "pending"]),
        isError: false,
        signal: .computerUse(action)
    )
}

private extension ComputerUseAction {
    nonisolated var toolNameForSignal: String {
        switch self {
        case .capture: ToolNames.screenCapture
        case .click: ToolNames.uiClick
        case .typeText: ToolNames.uiType
        case .pressKey: ToolNames.uiKey
        case .scroll: ToolNames.uiScroll
        }
    }
}
