import Foundation

/// The envelope's `next` hint, fitted to the HOSTED tool it names before the envelope leaves
/// `executeExternalAutovisorTool` — the one place the external surface is told apart from the
/// local models' in this respect.
///
/// `NextHint` is shared with the local models, so its arguments are strings and carry only what
/// the in-app manager's tools take. An external agent follows the same hint into a hosted tool
/// whose schema requires `folder_id` and types `task_id` as an integer, and the instructions tell
/// it to follow a refused call's next suggestion — so until 2026-11-08 the agent that did exactly
/// that was refused for the `folder_id` the hint never carried, and handed a string where the
/// schema it validates against says integer.
///
/// Two rewrites of `suggested_args`, both read off `HostedMCPCatalog`, which is the authority on
/// what a hosted tool takes:
/// - an argument whose property is `integer` and whose value is a string that reads as one is
///   written as a JSON number; one whose property is `array` and whose value is the JSON text of
///   a list, as that list (a hint carries the `task_ids` the call sent, E1 review R1/R4);
/// - a tool whose input schema requires `folder_id` gets the folder this call PROVED — never one
///   it did not (a call that omitted `folder_id` or failed its check gets none), and never over a
///   `folder_id` the hint already names (`null` names none) — which only a hint that repeats a
///   call nothing judged does, with the folder that call sent (`ExternalNextCall.carriedArguments`).
///
/// Only `suggested_args` is rewritten. The hint is read as a JSON object (`JSONValue`), not as
/// `NextHint`, so every other member of `next` — `NextHint`'s own today, any it gains tomorrow —
/// is written back by value; until 2026-11-08 it was re-encoded through a hand-copied three-field
/// struct, which would have dropped a fourth field from every hint it touched. The rest of the
/// envelope is kept byte for byte (`JSONTopLevelMember`, one scan: the member read is the member
/// written back): `task_result` orders its `data` on purpose. A hint for a tool the catalog does
/// not hold, a `null` or absent `next`, arguments that are no object, or a hint with nothing to
/// rewrite come back exactly as they went in — and once a hint IS rewritten it always goes out,
/// since the rendering (`JSONValue.canonicalJSONString`) and the splice cannot fail.
nonisolated enum HostedMCPNextHintCompletion {

    static func completing(
        _ outputJSON: String,
        provenFolderID: String?,
        tools: [HostedMCPCatalog.ToolDescriptor] = HostedMCPCatalog.allTools
    ) -> String {
        guard let member = JSONTopLevelMember(named: "next", in: outputJSON),
              case .object(var hint)? = JSONValue(json: member.value),
              let command = hint[suggestedCommandKey]?.stringValue,
              let tool = tools.first(where: { $0.name == command })
        else { return outputJSON }

        var arguments: [String: JSONValue]
        switch hint[suggestedArgumentsKey] {
        case nil, .null?:
            arguments = [:]
        case .object(let given)?:
            arguments = given
        default:
            return outputJSON
        }

        let properties = tool.inputSchema.properties ?? [:]
        var rewritten = false
        for (name, value) in arguments {
            guard case .string(let text) = value else { continue }
            switch properties[name]?.type {
            case "integer":
                guard let number = Int(text) else { continue }
                arguments[name] = .int(number)
            case "array":
                guard case .array(let list)? = JSONValue(json: text) else { continue }
                arguments[name] = .array(list)
            default:
                continue
            }
            rewritten = true
        }
        if let provenFolderID,
           (tool.inputSchema.required ?? []).contains(folderIDKey),
           arguments[folderIDKey]?.isNull ?? true {
            arguments[folderIDKey] = .string(provenFolderID)
            rewritten = true
        }
        guard rewritten else { return outputJSON }

        hint[suggestedArgumentsKey] = .object(arguments)
        // Keys sorted, slashes unescaped — the bytes the wire encoder writes for every envelope
        // this server sends and for everything a hint carries — from the one renderer that cannot
        // fail. Until 2026-11-08 this went through `JSONEncoder`, whose `try?` left a branch no
        // input reaches: a hint parsed from text holds nothing the encoder refuses.
        return member.replacingValue(with: JSONValue.object(hint).canonicalJSONString())
    }

    private static let suggestedCommandKey = NextHint.CodingKeys.suggested_cmd.stringValue
    private static let suggestedArgumentsKey = NextHint.CodingKeys.suggested_args.stringValue
    private static let folderIDKey = "folder_id"
}
