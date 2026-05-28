import Foundation

/// Orphan-aware normalizer for `team.settings.meetingCoordinatorRoleID`.
///
/// Single source of truth — every reader of the stored designated coordinator
/// ID funnels through `normalize`:
///   * runtime ID resolution (`LLMExecutionService.resolveCoordinatorRole`)
///   * picker UI (`MeetingCoordinatorPickerLogic.normalizedSelection`)
///   * schema-build (`+ToolResolution` step 6)
///   * role-editor badge predicate (`RoleEditorConcludeMeetingPredicate.fromEditorContext`)
///
/// Returns `nil` when stored is nil / empty / orphaned (references a removed
/// role).
///
/// Why this exists: pre-refactor, an orphan stored ID created an asymmetry:
///   * runtime `effectiveCoordinator` self-healed to Auto via initiator fallback
///   * picker UI self-healed to "Auto"
///   * schema-build (`+ToolResolution` step 6) and the badge predicate did NOT
///     self-heal — they read the raw stored ID, ended up in
///     coord-mode-no-match state, and silently denied `conclude_meeting` to
///     every role. The LLM could start a meeting but not close it.
nonisolated enum DesignatedCoordinatorResolver {

    /// Returns the stored coordinator ID iff present in `availableIDs`;
    /// otherwise `nil` (Auto / orphan-collapsed). An empty stored ID is
    /// structurally invalid and falls through naturally because no role can
    /// have an empty id — no defensive `!isEmpty` check that would hide a
    /// future write-side defect by silently collapsing it (CLAUDE.md:
    /// "defensive normalization that hides defect signals is anti-pattern").
    static func normalize(
        storedID: String?,
        availableIDs: [String]
    ) -> String? {
        guard let id = storedID else { return nil }
        return availableIDs.contains(id) ? id : nil
    }
}
