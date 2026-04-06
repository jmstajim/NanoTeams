import Foundation

enum Role: Hashable, Codable, Identifiable {
    case supervisor
    case productManager
    case uxResearcher
    case uxDesigner
    case techLead
    case softwareEngineer
    case codeReviewer
    case sre
    case tpm
    case loreMaster
    case npcCreator
    case encounterArchitect
    case rulesArbiter
    case questMaster
    case theAgreeable
    case theOpen
    case theConscientious
    case theExtrovert
    case theNeurotic
    case assistant
    case custom(id: String)

    static var builtInCases: [Role] {
        [.supervisor, .productManager, .uxResearcher, .uxDesigner, .techLead, .softwareEngineer, .codeReviewer, .sre, .tpm, .loreMaster, .npcCreator, .encounterArchitect, .rulesArbiter, .questMaster, .theAgreeable, .theOpen, .theConscientious, .theExtrovert, .theNeurotic, .assistant]
    }

    /// Single source of truth for all built-in role metadata. Adding a new role case
    /// only requires one entry here — both displayName and builtInID are derived from it.
    private struct RoleMetadata {
        let displayName: String
        let builtInID: String
    }

    private static let metadata: [Role: RoleMetadata] = [
        .supervisor:         .init(displayName: "Supervisor",          builtInID: "supervisor"),
        .productManager:     .init(displayName: "Product Manager",     builtInID: "productManager"),
        .uxResearcher:       .init(displayName: "UX Researcher",       builtInID: "uxResearcher"),
        .uxDesigner:         .init(displayName: "UX Designer",         builtInID: "uxDesigner"),
        .techLead:           .init(displayName: "Tech Lead",           builtInID: "techLead"),
        .softwareEngineer:   .init(displayName: "Software Engineer",   builtInID: "softwareEngineer"),
        .codeReviewer:       .init(displayName: "Code Reviewer",       builtInID: "codeReviewer"),
        .sre:                .init(displayName: "SRE",                 builtInID: "sre"),
        .tpm:                .init(displayName: "TPM",                 builtInID: "tpm"),
        .loreMaster:         .init(displayName: "Lore Master",         builtInID: "loreMaster"),
        .npcCreator:         .init(displayName: "NPC Creator",         builtInID: "npcCreator"),
        .encounterArchitect: .init(displayName: "Encounter Architect", builtInID: "encounterArchitect"),
        .rulesArbiter:       .init(displayName: "Rules Arbiter",       builtInID: "rulesArbiter"),
        .questMaster:        .init(displayName: "Quest Master",        builtInID: "questMaster"),
        .theAgreeable:     .init(displayName: "The Agreeable",     builtInID: "theAgreeable"),
        .theOpen:          .init(displayName: "The Open",           builtInID: "theOpen"),
        .theConscientious: .init(displayName: "The Conscientious", builtInID: "theConscientious"),
        .theExtrovert:     .init(displayName: "The Extrovert",     builtInID: "theExtrovert"),
        .theNeurotic:      .init(displayName: "The Neurotic",      builtInID: "theNeurotic"),
        .assistant:        .init(displayName: "Assistant",          builtInID: "assistant"),
    ]

    /// Reverse lookup: builtInID string → Role. O(1) instead of O(n) scan.
    private static let builtInIDReverseLookup: [String: Role] = {
        Dictionary(uniqueKeysWithValues: metadata.compactMap { role, meta in
            (meta.builtInID, role)
        })
    }()

    static var allBuiltInIDs: [String] {
        builtInCases.compactMap { metadata[$0]?.builtInID }
    }

    static func builtInID(_ role: Role) -> String {
        if case .custom(let id) = role { return id }
        return metadata[role]?.builtInID ?? ""
    }

    static func isBuiltInID(_ id: String) -> Bool {
        builtInIDReverseLookup[id] != nil
    }

    static func fromDefinition(_ definition: TeamRoleDefinition) -> Role {
        if let sysID = definition.systemRoleID, let builtIn = builtInRole(for: sysID) {
            return builtIn
        }
        if let builtIn = builtInRole(for: definition.id) {
            return builtIn
        }
        return .custom(id: definition.name)
    }

    static func fromID(_ id: String) -> Role {
        if let builtIn = builtInRole(for: id) {
            return builtIn
        }
        return .custom(id: id)
    }

    static func builtInRole(for id: String) -> Role? {
        builtInIDReverseLookup[id]
    }

    var id: String {
        storageKey
    }

    var baseID: String {
        switch self {
        case .custom(let id): id
        default: Role.builtInID(self)
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    var displayName: String {
        if case .custom(let id) = self {
            // Format custom ID nicely: "camelCase" -> "Camel Case"
            return id.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
        return Self.metadata[self]?.displayName ?? ""
    }

    private var storageKey: String {
        switch self {
        case .custom(let id): "custom:\(id)"
        default: Role.builtInID(self)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        if let builtIn = Role.builtInRole(for: raw) {
            self = builtIn
        } else if raw.hasPrefix("custom:") {
            let id = String(raw.dropFirst("custom:".count))
            self = .custom(id: id)
        } else {
            self = .custom(id: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storageKey)
    }
}
