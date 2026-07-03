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
        capture; prefer ax_elements coordinates over guessing from pixels. To open an app that \
        isn't running, use Spotlight (cmd+space, type its name, return) — the shell cannot launch \
        GUI apps.
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let target = optionalString(args, "target").flatMap { $0.isEmpty ? nil : $0 } ?? "screen"
            let windowTitle = optionalString(args, "window_title").flatMap { $0.isEmpty ? nil : $0 }
            return signalResult(args: args, action: .capture(target: target, windowTitle: windowTitle))
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
        from ax_elements. The result echoes which listed element is under the point; if it \
        isn't the one you meant, re-check coordinates before acting further. If the click \
        changes the UI (a menu/dialog opens or the page navigates), re-capture the screen \
        before the next click — the earlier coordinates and element list are then stale.
        """,
        parameters: JS.object(
            properties: [
                "x": JS.integer("Horizontal coordinate."),
                "y": JS.integer("Vertical coordinate."),
                "button": JS.string("Right for a context-menu click.", enumValues: ["left", "right"]),
                "double": JS.boolean("True for a double-click."),
                "target": JS.string("Application name / bundle id the click is intended for."),
            ],
            required: ["x", "y"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let x = try requiredInt(args, "x")
            let y = try requiredInt(args, "y")
            let button = normalizeButton(optionalString(args, "button"))
            let double = optionalBool(args, "double")
            let target = optionalString(args, "target").flatMap { $0.isEmpty ? nil : $0 }
            return signalResult(args: args, action: .click(x: x, y: y, button: button, double: double, target: target))
        }
    }

    private func normalizeButton(_ raw: String?) -> String {
        (raw?.lowercased() == "right") ? "right" : "left"
    }
}

// MARK: - ui_type

nonisolated struct UITypeTool: ToolHandler {
    static let name = TN.uiType
    static let schema = ToolSchema(
        name: TN.uiType,
        description: """
        Type text into the currently focused field of the front app. Typing does not press \
        Enter or submit. To open a URL in a browser, focus the address bar first (cmd+L), \
        type the URL, then press return.
        """,
        parameters: JS.object(
            properties: [
                "text": JS.string("The text to type."),
                "target": JS.string("Application name / bundle id to type into."),
            ],
            required: ["text"]
        )
    )
    static let category: ToolCategory = .computerUse
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let text = optionalString(args, "text") ?? resolveContentString(args) ?? ""
            guard !text.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "No text provided to type.")
            }
            let target = optionalString(args, "target").flatMap { $0.isEmpty ? nil : $0 }
            return signalResult(args: args, action: .typeText(text: text, target: target))
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
    static let excludedInMeetings = true

    static func makeInstance(dependencies _: ToolHandlerDependencies) -> Self { Self() }

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let keys = optionalString(args, "keys") ?? optionalString(args, "key") ?? ""
            guard !keys.isEmpty else {
                return makeErrorResult(toolName: Self.name, args: args, code: .invalidArgs,
                                       message: "No key combination provided.")
            }
            let target = optionalString(args, "target").flatMap { $0.isEmpty ? nil : $0 }
            return signalResult(args: args, action: .pressKey(keys: keys, target: target))
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

    func handle(context _: ToolExecutionContext, args: [String: Any]) -> ToolExecutionResult {
        ToolErrorHandler.execute(toolName: Self.name, args: args) {
            let x = try requiredInt(args, "x")
            let y = try requiredInt(args, "y")
            let dx = optionalInt(args, "dx") ?? 0
            let dy = optionalInt(args, "dy") ?? 0
            let target = optionalString(args, "target").flatMap { $0.isEmpty ? nil : $0 }
            return signalResult(args: args, action: .scroll(x: x, y: y, dx: dx, dy: dy, target: target))
        }
    }
}

// MARK: - Shared

/// Interim `{status:"pending"}` envelope + the `.computerUse` signal. The service finalizer
/// overwrites the envelope with the real result.
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
