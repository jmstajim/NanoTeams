import Foundation

/// Autovisor lifecycle: lazily ensures the hidden singleton manager task
/// exists when enabled, and toggles the feature on/off. The manager runs as a
/// normal (but sidebar-hidden) chat-mode task on the built-in "Autovisor"
/// team; everything downstream reuses the existing engine, scheduler, and feed.
extension NTMSOrchestrator {

    /// Ensures the Autovisor team exists in `teams.json` regardless of whether the
    /// feature is enabled, so it's always a (protected) entry in the Settings → Teams
    /// list, AND reconciles its template invariants (Manager icon + mandatory tools +
    /// Auto coordinator) on EVERY open — including when the feature is disabled and the
    /// team already exists. No-op only when there is no real work folder. The diff-based
    /// `mutateWorkFolder` write is skipped when the sync changes nothing.
    func ensureAutovisorTeam() async {
        guard hasRealWorkFolder, snapshot != nil else { return }
        await mutateWorkFolder { proj in
            if !proj.teams.contains(where: { $0.templateID == AutovisorConstants.teamTemplateID }) {
                proj.teams.append(TeamTemplateFactory.autovisor())
            }
            // Keep the hidden team's template invariants in sync (Manager icon +
            // mandatory tools + Auto meeting coordinator) — also normalizes a team a
            // prior build seeded. Returns false on a no-op, so nothing is persisted then.
            _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &proj.teams)
        }
    }

    /// Ensures the Autovisor task exists (creating the team + task lazily on
    /// first enable) and starts an open-time review pass. Idempotent. No-op when
    /// the feature is disabled or there is no real work folder (default storage
    /// has nothing to manage). Safe to call repeatedly from `openWorkFolder` and
    /// from `setAutovisorEnabled(true)`.
    func ensureAutovisorTask() async {
        guard hasRealWorkFolder,
              let snap = snapshot,
              snap.workFolder.settings.autovisorEnabled
        else { return }

        let managerID: Int
        if let existing = snap.workFolder.state.autovisorTaskID,
           snap.tasksIndex.tasks.contains(where: { $0.id == existing }) {
            managerID = existing
            await ensureTaskLoaded(managerID)
            // Re-enable the review recurrence: a prior `setAutovisorEnabled(false)`
            // set `isEnabled = false`, and the existing-task branch otherwise never
            // restores it — so a disable→enable cycle would run only the open-time
            // pass and then never recur. Preserve the user's rule/interval; seed a
            // default if somehow missing.
            await mutateTask(taskID: managerID) { task in
                if task.recurrence == nil {
                    task.recurrence = TaskRecurrence(
                        rule: .interval(seconds: AutovisorConstants.defaultScheduleIntervalSeconds),
                        isEnabled: true
                    )
                } else {
                    task.recurrence?.isEnabled = true
                }
                task.recurrence?.reschedule(after: Date())
            }
        } else if let created = await createAutovisorTask() {
            managerID = created
        } else {
            return
        }

        // Keep the hidden Manager role's icon in sync with its template so an existing
        // (persisted) Autovisor team picks up a template icon rename. Pure logic
        // lives in TeamManagementService (unit-tested); the diff-based persist no-ops
        // when nothing changed.
        await mutateWorkFolder { proj in
            _ = TeamManagementService.syncAutovisorTeamToTemplate(teams: &proj.teams)
        }

        await seedAutovisorDefaultsAndSyncBrief(managerID: managerID)

        // Seed the "seen" set so tasks that already exist at open aren't treated
        // as newly-created by the `onTaskCreated` trigger (the open-time pass below
        // reviews them anyway). Without this every existing task would look new.
        autovisorSeenTaskIDs = Set(autovisorWatchableTasks(excluding: managerID).map(\.id))

        // Mandatory open-time review pass (dive-deeper finding 11): tasks left
        // waiting on the manager after restart would otherwise hang. `startRun`
        // does NOT change `activeTaskID`, so this never steals the user's focus.
        // Supersedes a parked (`wait_for_events`) engine — relevant when this runs
        // from `setAutovisorEnabled(true)` mid-session, not just at folder open.
        await startAutovisorPass(taskID: managerID)
    }

    /// Starts a fresh manager review pass, superseding a parked (`wait_for_events`)
    /// run if present — `startRun`'s re-entry guard bails on `.needsSupervisorInput`,
    /// so the parked engine must be stopped first. The parked conversation is
    /// abandoned by design (events and schedules get a clean pass; only human
    /// messages continue the parked chat). Queued chat messages survive the
    /// supersede — the fresh run drains them on iteration 1.
    func startAutovisorPass(taskID: Int) async {
        if taskEngineStates[taskID] == .needsSupervisorInput {
            stopEngineForTask(taskID)
        }
        await startRun(taskID: taskID)
    }

    /// Seeds the default goal/memory when empty so both fields start populated and
    /// editable (Settings + Watchtower) and the manager's first prompt has the
    /// "explore & wait for a goal" directive. "When empty" == "by default" — a real
    /// goal/memory the user or the manager set is never clobbered. Then syncs the
    /// manager's brief (the "Supervisor Task" artifact, rendered as "## Supervisor
    /// Goal") to the current goal — they are the same thing for the manager — which
    /// also migrates an existing manager whose brief still holds the old hardcoded
    /// "Oversee this work folder…" text. Extracted from `ensureAutovisorTask` so
    /// it's unit-testable without starting the engine. `managerID` must already be loaded.
    func seedAutovisorDefaultsAndSyncBrief(managerID: Int) async {
        await mutateWorkFolder { proj in
            if proj.settings.autovisorGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proj.settings.autovisorGoal = AutovisorConstants.defaultGoal
            }
            if proj.settings.autovisorMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                proj.settings.autovisorMemory = AutovisorConstants.defaultMemory
            }
        }
        // Project the goal (+ clips + attachments) onto the manager's brief via the
        // single mirror seam — also migrates an existing manager whose brief still
        // holds the old hardcoded "Oversee this work folder…" text.
        await syncAutovisorGoalToManagerBrief()
    }

    /// Toggles the Autovisor. Enabling lazily creates the manager task;
    /// disabling stops its engine and disables its recurrence so the scheduler
    /// stops firing it.
    /// Returns whether the requested state took effect: `false` only when an
    /// ENABLE is refused for want of a real work folder (the sole no-op path), so
    /// callers like `AutovisorSetupView.enable` can tell a real enable from a
    /// folder-closed-mid-flight refusal instead of silently assuming success.
    /// Disable always succeeds.
    @discardableResult
    func setAutovisorEnabled(_ enabled: Bool) async -> Bool {
        // Enabling needs a real work folder — `ensureAutovisorTask` /
        // `ensureAutovisorTeam` no-op in default storage, so persisting
        // `enabled = true` would leave a dead toggle reading "ON" with no manager
        // behind it. Refuse the enable and say why. Disabling is always allowed
        // (it clears a possibly-stale persisted `true`). Mirrors the Watchtower
        // pill's visibility gate via the shared `AutovisorPolicy.canEnable`.
        if enabled, !AutovisorPolicy.canEnable(hasRealWorkFolder: hasRealWorkFolder) {
            lastInfoMessage = "Open a work folder to enable the Autovisor."
            return false
        }
        await mutateWorkFolder { $0.settings.autovisorEnabled = enabled }
        if enabled {
            await ensureAutovisorTask()
        } else if let id = snapshot?.workFolder.state.autovisorTaskID {
            stopEngineForTask(id)
            await mutateTask(taskID: id) { $0.recurrence?.isEnabled = false }
        }
        rearmAutovisorAutoDisable()  // arms the sleep timer on enable, clears it on disable
        return true
    }

    /// Whether the Autovisor detail surface should show the first-time SETUP pane
    /// (goal + Enable) instead of the manager chat. Delegates to the pure
    /// `AutovisorPolicy.needsSetup` so the routing decision
    /// (`MainLayoutView.autovisorDetail`), the Watchtower pill's click intercept,
    /// and the sidebar menu label ALL agree. They used to disagree — the detail
    /// pane gated on `autovisorTaskID == nil` while the pill/sidebar gated on the
    /// goal — which stranded a created-then-disabled manager on the chat with no
    /// way to reach setup or re-enable from the pill.
    var autovisorNeedsSetup: Bool {
        AutovisorPolicy.needsSetup(
            taskExists: autovisorTaskID != nil,
            enabled: workFolder?.settings.autovisorEnabled ?? false,
            goalIsUnset: AutovisorPolicy.goalIsUnset(workFolder?.settings.autovisorGoal ?? "")
        )
    }

    // MARK: - Auto-off sleep timer

    /// Re-arms (or clears) the in-memory auto-off deadline from `now`, per the
    /// sleep-timer contract: deadline = now + duration whenever the feature is ON
    /// and the timer is configured; nil otherwise. Total over current state —
    /// derives arm-vs-clear from settings, so callers don't branch on which
    /// transition occurred. Each call RESTARTS the countdown from `now`, so
    /// persist paths receiving the whole struct must gate on an effective-duration
    /// change (see `updateAutovisorActivation`). "Run now" and recurrence fires
    /// deliberately never call this — the countdown runs from enable, not activity.
    func rearmAutovisorAutoDisable(now: Date = Date()) {
        guard hasRealWorkFolder,
              let settings = snapshot?.workFolder.settings,
              settings.autovisorEnabled,
              let duration = settings.autovisorActivation.effectiveAutoDisableAfterSeconds
        else {
            clearAutovisorAutoDisable()
            return
        }
        autovisorAutoDisableAt = now.addingTimeInterval(duration)
    }

    /// Unconditionally drops the in-memory auto-off deadline. The named funnel for
    /// every nil-write (`rearmAutovisorAutoDisable`'s guard, the stale-deadline
    /// self-heal, `openWorkFolder`'s pre-loop clear) so "who writes the deadline"
    /// stays answerable by grepping two method names.
    func clearAutovisorAutoDisable() {
        autovisorAutoDisableAt = nil
    }

    /// Minute-tick check. Must run BEFORE `evaluateDueRecurrences` and
    /// `wakeAutovisorForEvents` in the scheduler tick, so an expired manager
    /// neither fires a final recurrence nor gets woken once more. Past the
    /// deadline → turn the Autovisor off exactly like the manual power toggle,
    /// and announce via the neutral info banner. Up to ~60 s of lag between
    /// deadline and actual off is inherent to the tick (UI copy says
    /// "around HH:mm"); a deadline that passed during macOS sleep fires on the
    /// first tick after wake — correct sleep-timer behavior.
    func evaluateAutovisorAutoDisable(now: Date = Date()) async {
        guard let deadline = autovisorAutoDisableAt, now >= deadline else { return }
        guard snapshot?.workFolder.settings.autovisorEnabled == true else {
            clearAutovisorAutoDisable()   // stale deadline (direct settings write) — self-heal silently
            return
        }
        let errorBaseline = lastErrorMessage
        await setAutovisorEnabled(false)
        // Verify semantic success before announcing (CLAUDE.md §7 — persisted ≠
        // intended; same honest-error pattern as `deleteAutovisor`). The disable
        // makes TWO writes, and announcing over either failure would DISPLACE the
        // error in the single banner slot:
        // • settings flag failed → feature still enabled (the flag check), and the
        //   disable path's rearm re-armed a fresh countdown — an automatic retry
        //   in one full duration;
        // • recurrence persist failed → flag is off but `lastErrorMessage` moved
        //   off the baseline (the on-disk orphan is self-healed by
        //   `fireRecurrence`'s zombie guard).
        guard snapshot?.workFolder.settings.autovisorEnabled == false,
              lastErrorMessage == errorBaseline else { return }
        lastInfoMessage = "Autovisor turned off — its auto-off timer ended."
    }

    /// Fully removes the Autovisor from this folder (sidebar context-menu
    /// "Delete"): deletes its task (disk + index), clears the pinned id, and turns
    /// the feature off. Re-enabling later via `setAutovisorEnabled(true)`
    /// recreates it (the hidden team is reused). `removeTask` runs FIRST — while
    /// `autovisorTaskID` is still set — so the active-task fallback keeps
    /// excluding the manager when picking the next active task.
    func deleteAutovisor() async {
        guard let id = autovisorTaskID else { return }
        await removeTask(id)
        // Only clear the pin once the task is actually gone. `removeTask` swallows a
        // disk failure into `lastErrorMessage` and leaves the task in the index; if we
        // nil the pin anyway, the still-present manager task (hidden only while the pin
        // matches its id, per `TaskService.taskSummaries`) would orphan into the regular
        // sidebar list. On failure we keep the pin so the manager stays hidden and the
        // surfaced error is honest ("delete failed").
        guard snapshot?.tasksIndex.tasks.contains(where: { $0.id == id }) != true else { return }
        await mutateWorkFolder {
            $0.state.autovisorTaskID = nil
            $0.settings.autovisorEnabled = false
        }
        rearmAutovisorAutoDisable()  // feature is now off → clears the sleep-timer deadline
    }

    /// The current Autovisor task ID, if one has been created for this folder.
    var autovisorTaskID: Int? {
        snapshot?.workFolder.state.autovisorTaskID
    }

    /// The Manager role definition (the single non-Supervisor role of the Folder
    /// Manager team), if the team exists. Used by the Settings Model card.
    var autovisorRole: TeamRoleDefinition? {
        snapshot?.workFolder.teams
            .first(where: { $0.templateID == AutovisorConstants.teamTemplateID })?
            .roles.first(where: { !$0.isSupervisor })
    }

    // MARK: - Goal composer attachments + clips

    /// The persisted goal attachments as `StagedAttachment` cards, reconstructed
    /// from `settings.autovisorGoalAttachmentPaths`. Files missing on disk are
    /// skipped (self-heal happens in `syncAutovisorGoalToManagerBrief`).
    /// `isProjectReference` is derived from whether the path lives inside the
    /// app-managed `autovisor/attachments/` store (a copy — deletable) vs a
    /// user file elsewhere in the folder (a reference — never deleted).
    var autovisorGoalAttachments: [StagedAttachment] {
        guard let root = workFolderURL else { return [] }
        let paths = NTMSPaths(workFolderRoot: root)
        return snapshot?.workFolder.settings.autovisorGoalAttachmentPaths.compactMap { rel in
            let url = root.appendingPathComponent(rel, isDirectory: false).standardizedFileURL
            let isRef = !SandboxPathResolver.isWithin(candidate: url, container: paths.autovisorAttachmentsDir)
            return try? StagedAttachment(url: url, stagedRelativePath: rel, isProjectReference: isRef)
        } ?? []
    }

    /// Stages a file for the goal composer and returns its card **synchronously**
    /// (so it appears immediately). In-project files become references (no copy);
    /// everything else is copied into the folder-level `autovisor/attachments/`
    /// store. Persisting the path to settings + the manager re-mirror happen when
    /// the host observes the attachment-list change (via `setAutovisorGoalAttachmentPaths`).
    func stageAutovisorGoalAttachment(url: URL) -> StagedAttachment? {
        guard let root = workFolderURL else {
            lastErrorMessage = "No work folder available for staging attachments."
            return nil
        }
        let standardized = url.standardizedFileURL
        let paths = NTMSPaths(workFolderRoot: root)

        // In-project file (outside .nanoteams/) → reference it directly, no copy.
        if SandboxPathResolver.isWithin(candidate: standardized, container: root)
            && !SandboxPathResolver.isWithin(candidate: standardized, container: paths.nanoteamsDir)
            && fileManager.fileExists(atPath: standardized.path) {
            let rel = paths.relativePathFromProjectRoot(for: standardized)
            do {
                return try StagedAttachment(url: standardized, stagedRelativePath: rel, isProjectReference: true)
            } catch {
                lastErrorMessage = error.localizedDescription
                return nil
            }
        }

        // External file → stage to a throwaway draft dir, finalize into the goal
        // store, discard the draft, and return the finalized copy (deletable).
        let draftID = UUID()
        do {
            let stagedRel = try repository.stageAttachment(at: root, draftID: draftID, sourceURL: url)
            let finalRel = try repository.finalizeAutovisorGoalAttachment(at: root, stagedRelativePath: stagedRel)
            try? repository.cleanupStagedDraft(at: root, draftID: draftID)
            let finalURL = root.appendingPathComponent(finalRel, isDirectory: false).standardizedFileURL
            return try StagedAttachment(url: finalURL, stagedRelativePath: finalRel, isProjectReference: false)
        } catch {
            try? repository.cleanupStagedDraft(at: root, draftID: draftID)
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Deletes a goal attachment's backing file. No-op for project references
    /// (points at the user's real file — never delete it); the path is dropped
    /// from settings by the host's list-change observer.
    func removeAutovisorGoalFile(_ attachment: StagedAttachment) {
        guard !attachment.isProjectReference else { return }
        guard let root = workFolderURL else { return }
        do {
            try repository.removeStagedItem(at: root, relativePath: attachment.stagedRelativePath)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Persists the goal attachment path list, then re-mirrors to the manager brief.
    func setAutovisorGoalAttachmentPaths(_ paths: [String]) async {
        await mutateWorkFolder { $0.settings.autovisorGoalAttachmentPaths = paths }
        await syncAutovisorGoalToManagerBrief()
    }

    /// Persists the goal skill/clip cards, then re-mirrors to the manager brief.
    func setAutovisorGoalClips(_ clips: [String]) async {
        await mutateWorkFolder { $0.settings.autovisorGoalClips = clips }
        await syncAutovisorGoalToManagerBrief()
    }

    /// Toggles whether the Autovisor may assemble a new team on the fly
    /// (`create_managed_task team_id: "generated"`). Gated at both the schema
    /// (`CreateManagedTaskTool.buildSchema`) and runtime (`classifyManagedTeamID`)
    /// layers. Per-folder, no engine restart: the manager's next review pass
    /// rebuilds its tool schema from the fresh setting (schemas are built once per
    /// step in `runStep`), and the runtime gate enforces the change immediately for
    /// a pass already in flight.
    func setAutovisorAllowTeamGeneration(_ allow: Bool) async {
        await mutateWorkFolder { $0.settings.autovisorAllowTeamGeneration = allow }
    }

    /// The single seam that projects the persisted goal (+ clips + attachments)
    /// onto the manager task's brief. Called by `updateAutovisorGoal`,
    /// `seedAutovisorDefaultsAndSyncBrief`, and the attachment/clip setters.
    ///
    /// Embed OFF (default): keeps `supervisorTask == goal` byte-for-byte and lets
    /// `effectiveSupervisorBrief` append clips + the `## Attached Files` path list.
    /// Embed ON: bakes readable file text inline via `AnswerTextBuilder.build`
    /// (mirrors `consumeQueuedSupervisorMessage`); non-embeddable files (images)
    /// stay in `attachmentPaths` as paths.
    func syncAutovisorGoalToManagerBrief() async {
        guard let id = autovisorTaskID else { return }  // no manager yet (pre-Enable) → no-op
        guard let settings = snapshot?.workFolder.settings else { return }

        // Self-heal: drop paths whose files no longer exist, persisting the cleaned
        // list so the schedule/UI stay honest. `autovisorGoalAttachments` already
        // skips missing files, so its paths are the surviving set.
        let surviving = autovisorGoalAttachments
        let survivingPaths = surviving.map(\.stagedRelativePath)
        if survivingPaths != settings.autovisorGoalAttachmentPaths {
            await mutateWorkFolder { $0.settings.autovisorGoalAttachmentPaths = survivingPaths }
        }

        let goal = settings.autovisorGoal
        let clips = settings.autovisorGoalClips
        let embed = configuration.embedFilesInPrompt

        let newSupervisorTask: String
        let newClips: [String]
        let newPaths: [String]
        if embed {
            let built = AnswerTextBuilder.build(
                text: goal, clips: clips, attachments: surviving, embedFiles: true
            )
            newSupervisorTask = built.answer
            newClips = []
            newPaths = surviving
                .filter { !built.embeddedAttachmentIDs.contains($0.id) }
                .map(\.stagedRelativePath)
        } else {
            newSupervisorTask = goal
            newClips = clips
            newPaths = survivingPaths
        }

        await ensureTaskLoaded(id)
        guard loadedTask(id) != nil else { return }  // load error already surfaced
        await mutateTask(taskID: id) { task in
            if task.supervisorTask != newSupervisorTask { task.supervisorTask = newSupervisorTask }
            if task.clippedTexts != newClips { task.clippedTexts = newClips }
            if task.attachmentPaths != newPaths { task.attachmentPaths = newPaths }
        }
    }


    /// Creates the team (if missing) + the hidden manager task, pins its ID, and
    /// seeds its review recurrence. Returns the new task ID, or nil on failure.
    private func createAutovisorTask() async -> Int? {
        // 1. Ensure the Autovisor team exists in teams.json (team must exist
        //    before createTask resolves `preferredTeamID` off disk).
        await ensureAutovisorTeam()
        guard let teamID = snapshot?.workFolder.teams
            .first(where: { $0.templateID == AutovisorConstants.teamTemplateID })?.id
        else {
            // ensureAutovisorTeam should always leave the team present; if it didn't
            // (persist failure / work-folder closed mid-flight) don't fail silently —
            // surface it unless mutateWorkFolder already set a more specific message.
            if lastErrorMessage == nil {
                lastErrorMessage = "Autovisor could not start — its team is missing. Try reopening the work folder."
            }
            return nil
        }

        // 2. Create the hidden manager task (makeActive: false — never steals focus).
        //    The brief IS the goal (rendered as "## Supervisor Goal"); it's kept in
        //    lock-step with `settings.autovisorGoal` by `ensureAutovisorTask`
        //    and `updateAutovisorGoal`. Must be non-empty so `hasInitialInput`
        //    marks the "Supervisor Task" artifact produced and the manager is ready.
        guard let taskID = await createTask(
            title: "Autovisor",
            supervisorTask: AutovisorConstants.defaultGoal,
            preferredTeamID: teamID,
            makeActive: false
        ) else {
            // Loud failure (mirrors the missing-team branch above): the folder
            // would otherwise sit `autovisorEnabled == true` with no manager
            // task — auto-answer stays suppressed for every top-level task
            // while `wakeAutovisorForEvents` bails on the nil `autovisorTaskID`
            // guard, so questions pile up that "Autovisor should have answered"
            // with zero signal about why.
            if lastErrorMessage == nil {
                lastErrorMessage = "Autovisor could not start — its task could not be created. Try toggling Autovisor off and on, or reopening the work folder."
            }
            return nil
        }
        await ensureTaskLoaded(taskID)

        // 3. Pin the ID (single source of truth for sidebar/fallback exclusions).
        //    Goal/memory defaults are seeded by the caller `ensureAutovisorTask`
        //    (one place, covers both fresh creations and existing empty managers).
        await mutateWorkFolder { $0.state.autovisorTaskID = taskID }

        // 4. Seed the review recurrence (enabled). The scheduler picks it up because
        //    the manager is top-level (parentTaskID == nil).
        let rule = RecurrenceRule.interval(seconds: AutovisorConstants.defaultScheduleIntervalSeconds)
        await setTaskRecurrence(taskID: taskID, recurrence: TaskRecurrence(rule: rule, isEnabled: true))

        return taskID
    }
}
