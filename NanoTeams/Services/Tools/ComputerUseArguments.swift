import Foundation

/// The computer-use action a call's arguments describe — ONE function for the approval gate
/// that judges it (`LLMExecutionService.gateComputerUseCalls`) and the handler that emits it
/// (`ComputerUseHandlers`), both fed the same dictionary (`ToolCallArguments.prepare`).
///
/// Until 2026-11-09 the two sides each resolved the arguments their own way: the gate dropped a
/// blank `text` / `keys` and excluded the structural keys from the content fallback, the handler
/// did neither; the gate normalised a scroll's `target`, the handler did not. Every divergence
/// traced failed closed, but "the human approved X, the handler did Y" is a property to hold by
/// construction, not by tracing.
nonisolated enum ComputerUseArguments {

    /// The action `args` describe for the tool `canonicalName`, or `nil` for a tool that is not
    /// a computer-use tool. Throws the argument whose absence keeps it from being an action —
    /// the handler's refusal; the gate reads a throw as "cannot be judged" and denies.
    static func action(canonicalName: String, args: [String: Any]) throws -> ComputerUseAction? {
        switch canonicalName {
        case ToolNames.screenCapture:
            return .capture(
                target: nonEmpty(optionalString(args, "target")) ?? "screen",
                windowTitle: nonEmpty(optionalString(args, "window_title")))
        case ToolNames.uiClick:
            let (x, y) = try point(args)
            return .click(
                x: x, y: y,
                button: ComputerUseAction.normalizedButton(optionalString(args, "button")),
                double: optionalBool(args, "double"),
                target: target(args))
        case ToolNames.uiType:
            guard let text = typedText(args) else { throw ToolArgumentError.missingRequired("text") }
            return .typeText(text: text, target: target(args))
        case ToolNames.uiKey:
            // `key` arrives here as `keys` (`UIKeyTool.undeclaredArguments`); an empty value is
            // no keys.
            guard let keys = nonEmpty(optionalString(args, "keys"))
            else { throw ToolArgumentError.missingRequired("keys") }
            return .pressKey(keys: keys, target: target(args))
        case ToolNames.uiScroll:
            let (x, y) = try point(args)
            return .scroll(
                x: x, y: y, dx: optionalInt(args, "dx") ?? 0, dy: optionalInt(args, "dy") ?? 0,
                target: target(args))
        default:
            return nil
        }
    }

    /// The declared `text` only — its other spellings arrive renamed to it
    /// (`UITypeTool.undeclaredArguments`), and an OS action is never recovered from a document
    /// that failed to parse (`__raw_input__` is not read here).
    private static func typedText(_ args: [String: Any]) -> String? {
        nonEmpty(optionalString(args, "text"))
    }

    /// Both coordinates. `requiredInt` tells a missing coordinate from one the coercion cannot
    /// read — the runtime's type gate refuses the second before any handler runs, but a
    /// handler called directly must still not report an argument the model SENT as missing.
    private static func point(_ args: [String: Any]) throws -> (Int, Int) {
        (try requiredInt(args, "x"), try requiredInt(args, "y"))
    }

    private static func target(_ args: [String: Any]) -> String? {
        ComputerUseAction.normalizedTargetSpec(optionalString(args, "target"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
