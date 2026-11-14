import Foundation

/// Reason a waiter on `ExternalAutovisorReadinessSignal` was woken.
nonisolated enum ExternalAutovisorWakeReason: String, Codable, Hashable, Sendable {
    case folderChanged = "folder_changed"
    case driverChanged = "driver_changed"
    case autovisorDisabled = "autovisor_disabled"
    case shuttingDown = "shutting_down"
    case readinessChanged = "readiness_changed"
}

/// Readiness of the current work folder's Autovisor seat for an external MCP agent (§4, §6, §8.1).
nonisolated struct ExternalAutovisorReadiness: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable, CaseIterable {
        case ready = "ready"
        case folderTransition = "folder_transition"
        /// The folder is open in another NanoTeams process, so this one opened nothing
        /// (`WorkFolderInstanceLock`, F6 C1 2026-11-12).
        case folderInUse = "folder_in_use"
        case noWorkFolder = "no_work_folder"
        case autovisorDisabled = "autovisor_disabled"
        case builtInDriver = "built_in_driver"

        /// The state as a person reads it on the pane's badge. The raw value is the wire's
        /// (`folder_status` answers with it); until 2026-11-07 the badge showed that uppercased.
        var displayLabel: String {
            switch self {
            case .ready: "Ready"
            case .folderTransition: "Opening folder"
            case .folderInUse: "Open in another NanoTeams"
            case .noWorkFolder: "No work folder"
            case .autovisorDisabled: "Autovisor off"
            case .builtInDriver: "Built-in driver"
            }
        }

        /// The refusal this state answers an external call with — `nil` for `.ready`, the one
        /// state that refuses nothing.
        var refusal: Refusal? {
            switch self {
            case .ready: nil
            case .folderTransition: .folderTransition
            case .folderInUse: .folderInUse
            case .noWorkFolder: .noWorkFolder
            case .autovisorDisabled: .autovisorDisabled
            case .builtInDriver: .builtInDriver
            }
        }
    }

    /// What a state that refuses tells an external call: the fact, then what ends it. Every state
    /// but `.ready` is one (`State.refusal`), and this is where the sentences live — so a caller
    /// that knows which state it is in (`ExternalFolderRefusal`) reads them as `String`s, with no
    /// empty refusal to fall back on. Until 2026-11-08 they were two `String?` switches over all
    /// five states, and the read refusals spelled `?? ""` for a `nil` no refusing state produced.
    enum Refusal: CaseIterable, Hashable, Sendable {
        case folderTransition
        case folderInUse
        case noWorkFolder
        case autovisorDisabled
        case builtInDriver

        /// runtime-prompt
        var reason: String {
            switch self {
            case .folderTransition:
                "A work-folder transition is currently in progress."
            case .folderInUse:
                "This work folder is open in another NanoTeams process, so this NanoTeams does nothing in it."
            case .noWorkFolder:
                "No project work folder is currently open in NanoTeams."
            case .autovisorDisabled:
                "The Autovisor is currently disabled for this work folder."
            case .builtInDriver:
                "This work folder's Autovisor driver is set to the built-in local model rather than an external MCP agent."
            }
        }

        /// runtime-prompt
        var whatThePersonMustDo: String {
            switch self {
            case .folderTransition:
                "Wait a moment for the work folder to finish opening, then call folder_status again."
            case .folderInUse:
                "Quit the other NanoTeams process or close the folder there, then open the folder again in this NanoTeams."
            case .noWorkFolder:
                "Open a project work folder in NanoTeams, then enable the Autovisor with the External MCP Agent driver."
            case .autovisorDisabled:
                "Turn on the Autovisor in NanoTeams for this work folder."
            case .builtInDriver:
                "Switch the Autovisor driver in NanoTeams to External MCP Agent for this work folder."
            }
        }

        /// What an external call is told: the fact, then what ends it. A refused write and a
        /// refused read (`ExternalFolderRefusal`) both answer with this, so one state is never
        /// described two ways.
        var message: String {
            reason + " " + whatThePersonMustDo
        }
    }

    var state: State
    var reason: String?
    var whatThePersonMustDo: String?
    /// When the Autovisor was last switched on or off (ISO 8601) and what switched it —
    /// `person`, `auto_off` or `deleted` — while that switch decides the state: the Autovisor is
    /// on and ready, or off. Absent in every other state, and before the folder's first switch
    /// since 2026-11-09.
    var since: String?
    var changedBy: String?

    var allowsWrites: Bool {
        state == .ready
    }

    /// The sentences this value carries, the fact then the fix — `nil` when it carries none. For a
    /// value `forState` made that is `state.refusal?.message`.
    var refusalMessage: String? {
        let parts = [reason, whatThePersonMustDo].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case state
        case reason
        case whatThePersonMustDo = "what_the_person_must_do"
        case since
        case changedBy = "changed_by"
    }

    /// `Refusal.reason` by state — the seam `RuntimePromptRegistry` renders the fingerprint from.
    static func reason(for state: State) -> String? {
        state.refusal?.reason
    }

    /// `Refusal.whatThePersonMustDo` by state — the registry's seam, as `reason(for:)`.
    static func whatThePersonMustDo(for state: State) -> String? {
        state.refusal?.whatThePersonMustDo
    }

    static func forState(_ state: State) -> ExternalAutovisorReadiness {
        ExternalAutovisorReadiness(
            state: state,
            reason: state.refusal?.reason,
            whatThePersonMustDo: state.refusal?.whatThePersonMustDo
        )
    }

    /// `isFolderInUseByAnotherProcess` is asked right after the transition: an open refused by the
    /// folder's lock commits its URL with nothing loaded, so every later input would describe a
    /// folder this process never read.
    static func evaluate(
        hasRealWorkFolder: Bool,
        isFolderTransitionInProgress: Bool,
        isFolderInUseByAnotherProcess: Bool,
        autovisorEnabled: Bool,
        driver: AutovisorDriver,
        lastSwitch: AutovisorSwitch? = nil
    ) -> ExternalAutovisorReadiness {
        if isFolderTransitionInProgress {
            return forState(.folderTransition)
        }
        if isFolderInUseByAnotherProcess {
            return forState(.folderInUse)
        }
        if !hasRealWorkFolder {
            return forState(.noWorkFolder)
        }
        if !autovisorEnabled {
            return forState(.autovisorDisabled).stamped(with: lastSwitch)
        }
        if driver != .externalAgent {
            return forState(.builtInDriver)
        }
        return forState(.ready).stamped(with: lastSwitch)
    }

    /// This value with the switch that decided it.
    private func stamped(with lastSwitch: AutovisorSwitch?) -> ExternalAutovisorReadiness {
        guard let lastSwitch else { return self }
        var stamped = self
        stamped.since = JSONCoderFactory.iso8601Formatter.string(from: lastSwitch.at)
        stamped.changedBy = lastSwitch.by.rawValue
        return stamped
    }
}

/// Signal that wakes external-agent waiters whenever readiness inputs change (§4, §6, §9).
@MainActor
final class ExternalAutovisorReadinessSignal {
    private var waiters: [UUID: ApprovalWaiter<ExternalAutovisorWakeReason>] = [:]
    var onWakeAll: ((ExternalAutovisorWakeReason) -> Void)?

    var waiterCount: Int { waiters.count }

    func wait() async -> ExternalAutovisorWakeReason {
        let id = UUID()
        let box = ApprovalWaiter<ExternalAutovisorWakeReason>()
        waiters[id] = box
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.attach(continuation)
            }
        } onCancel: { [weak self] in
            box.resolve(.shuttingDown)
            Task { @MainActor [weak self] in
                _ = self?.waiters.removeValue(forKey: id)
            }
        }
    }

    func wakeAll(reason: ExternalAutovisorWakeReason) {
        onWakeAll?(reason)
        let pending = waiters
        waiters.removeAll()
        for (_, box) in pending {
            box.resolve(reason)
        }
    }
}
