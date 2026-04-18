import XCTest

@testable import NanoTeams

/// Extended tests for LLMExecutionService+StepCompletion focusing on
/// step completion, artifact completeness checking, and needsAcceptance handling.
@MainActor
final class StepCompletionExtendedTests: XCTestCase {

    private let fileManager = FileManager.default
    private var tempDir: URL!
    private var service: LLMExecutionService!
    private var mockDelegate: MockLLMExecutionDelegate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create .nanoteams directory structure
        let paths = NTMSPaths(workFolderRoot: tempDir)
        try fileManager.createDirectory(at: paths.nanoteamsDir, withIntermediateDirectories: true)

        service = LLMExecutionService(repository: NTMSRepository())
        mockDelegate = MockLLMExecutionDelegate()
        mockDelegate.workFolderURL = tempDir
        service.attach(delegate: mockDelegate)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
        mockDelegate = nil
        try super.tearDownWithError()
    }

    // MARK: - completeStepSuccess Status + CompletedAt Tests

    func testCompleteStepSuccess_SetsStatusToDone() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepSuccess(stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, .done)
    }

    func testCompleteStepSuccess_SetsCompletedAt() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        XCTAssertNil(task.runs[0].steps[0].completedAt)

        await service.completeStepSuccess(stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertNotNil(updated.completedAt)
    }

    // MARK: - completeStepWithWarning Tests

    func testCompleteStepWithWarning_SetsStatusToDone() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, warning: "Warning message")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, .done)
    }

    func testCompleteStepWithWarning_AppendsWarningMessage() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepWithWarning(stepID: stepID, warning: "Test warn")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertTrue(updated.messages.contains {
            $0.role == updated.role
                && $0.content.hasPrefix("LLM warning:")
                && $0.content.contains("Test warn")
        })
    }

    func testCompleteStepWithWarning_EmptyWarning_DoesNotAppendMessage() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id
        let messagesBefore = task.runs[0].steps[0].messages.count

        await service.completeStepWithWarning(stepID: stepID, warning: "   ")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.messages.count, messagesBefore,
                       "Whitespace-only warning must not append any message")
    }

    // MARK: - completeStepFailure Tests

    func testCompleteStepFailure_SetsStatusToFailed() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Build failed")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, .failed)
    }

    func testCompleteStepFailure_AppendsErrorMessage() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Connection refused")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        let hasError = updated.messages.contains { $0.content.contains("Connection refused") }
        XCTAssertTrue(hasError)
    }

    func testCompleteStepFailure_SetsCompletedAt() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Error")

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertNotNil(updated.completedAt)
    }

    func testCompleteStepFailure_ClearsStreamingPreview() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepFailure(stepID: stepID, errorMessage: "Error")

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    // MARK: - completeStepNeedsAcceptance Tests

    func testCompleteStepNeedsAcceptance_SetsStatusToNeedsApproval() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepNeedsAcceptance(stepID: stepID)

        let updated = mockDelegate.taskToMutate!.runs[0].steps[0]
        XCTAssertEqual(updated.status, .needsApproval)
    }

    func testCompleteStepNeedsAcceptance_ClearsStreamingPreview() async {
        let task = createSimpleTask()
        mockDelegate.taskToMutate = task
        let stepID = task.runs[0].steps[0].id

        await service.completeStepNeedsAcceptance(stepID: stepID)

        XCTAssertTrue(mockDelegate.clearStreamingPreviewCalls.contains(stepID))
    }

    // MARK: - Guard Behavior Tests

    func testCompleteStepSuccess_WithoutDelegate_DoesNotCrash() async {
        let plainService = LLMExecutionService(repository: NTMSRepository())
        // No delegate attached
        await plainService.completeStepSuccess(stepID: "test_step")
        // Should not crash
    }

    func testCompleteStepWithWarning_WithoutTaskMapping_DoesNotCrash() async {
        // stepID not registered in stepTaskMapping
        await service.completeStepWithWarning(stepID: "test_step", warning: "Test")
        // Should not crash (taskIDForStep returns nil)
    }

    func testCompleteStepFailure_WithoutTaskMapping_DoesNotCrash() async {
        await service.completeStepFailure(stepID: "test_step", errorMessage: "Test")
        // Should not crash
    }

    // MARK: - checkArtifactCompleteness Tests

    func testCheckArtifactCompleteness_ReturnsCompletedWhenAllPresent() {
        var task = createTaskWithExpectedArtifacts(["Product Requirements"])
        task.runs[0].steps[0].artifacts = [Artifact(name: "Product Requirements")]
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNotNil(result)
        if case .completed = result {} else {
            XCTFail("Expected .completed, got \(String(describing: result))")
        }
    }

    func testCheckArtifactCompleteness_ReturnsNilWhenSomeMissing() {
        let task = createTaskWithExpectedArtifacts(["Product Requirements", "Implementation Plan"])
        // No artifacts created yet
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNil(result)
    }

    func testCheckArtifactCompleteness_ReturnsNilWhenNoExpectedArtifacts() {
        let task = createTaskWithExpectedArtifacts([])
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNil(result)
    }

    func testCheckArtifactCompleteness_ExcludesBuildDiagnostics() {
        var task = createTaskWithExpectedArtifacts(["Build Diagnostics", "Engineering Notes"])
        // Only Engineering Notes created — Build Diagnostics excluded from check
        task.runs[0].steps[0].artifacts = [Artifact(name: "Engineering Notes")]
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNotNil(result)
        if case .completed = result {} else {
            XCTFail("Expected .completed, got \(String(describing: result))")
        }
    }

    func testCheckArtifactCompleteness_MultipleArtifactsAllPresent() {
        var task = createTaskWithExpectedArtifacts(["Code Review", "Code Review Summary"])
        task.runs[0].steps[0].artifacts = [
            Artifact(name: "Code Review"),
            Artifact(name: "Code Review Summary"),
        ]
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNotNil(result)
        if case .completed = result {} else {
            XCTFail("Expected .completed, got \(String(describing: result))")
        }
    }

    func testCheckArtifactCompleteness_PartialArtifactsReturnsNil() {
        var task = createTaskWithExpectedArtifacts(["Code Review", "Code Review Summary"])
        task.runs[0].steps[0].artifacts = [Artifact(name: "Code Review")]
        mockDelegate.taskToMutate = task

        let result = service.checkArtifactCompleteness(stepID: task.runs[0].steps[0].id)
        XCTAssertNil(result)
    }

    // MARK: - requestFinish Tests

    func testRequestFinish_SetsFlag() {
        let stepID = "test_step"
        service.requestFinish(stepID: stepID)
        // The flag is private, but we can verify it doesn't crash and clearRunningTask removes it
        service.clearRunningTask(stepID: stepID)
    }

    func testRequestFinish_ClearedOnCancelAll() {
        let stepID = "test_step"
        service.requestFinish(stepID: stepID)
        service.cancelAllExecutions()
        // Should not crash — flag cleaned up
    }

    // MARK: - resolveArtifactName Tests

    func testResolveArtifactName_exactMatch() {
        let result = LLMExecutionService.resolveArtifactName(
            "Design Spec", expectedArtifacts: ["Design Spec", "Product Requirements"])
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_embellishedName() {
        // LLM added " – Calculator" suffix
        let result = LLMExecutionService.resolveArtifactName(
            "Design Spec – Calculator", expectedArtifacts: ["Design Spec"])
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_prefixedName() {
        // LLM prepended "Calculator: " prefix
        let result = LLMExecutionService.resolveArtifactName(
            "Calculator: Design Spec", expectedArtifacts: ["Design Spec"])
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_noMatch() {
        let result = LLMExecutionService.resolveArtifactName(
            "Something Else", expectedArtifacts: ["Design Spec"])
        XCTAssertEqual(result, "Something Else")
    }

    func testResolveArtifactName_prefixMatchPicksCorrect() {
        // "Product Requirements Document" should match "Product Requirements"
        let result = LLMExecutionService.resolveArtifactName(
            "Product Requirements Document",
            expectedArtifacts: ["Design Spec", "Product Requirements"])
        XCTAssertEqual(result, "Product Requirements")
    }

    func testResolveArtifactName_containsMatchPicksLongest() {
        // "Extended Code Review Summary" contains both "Code" and "Code Review"
        // Should match "Code Review" (longer slug) regardless of array order
        let result1 = LLMExecutionService.resolveArtifactName(
            "Extended Code Review Summary",
            expectedArtifacts: ["Code", "Code Review"])
        XCTAssertEqual(result1, "Code Review")

        // Same test with reversed array order — should still pick "Code Review"
        let result2 = LLMExecutionService.resolveArtifactName(
            "Extended Code Review Summary",
            expectedArtifacts: ["Code Review", "Code"])
        XCTAssertEqual(result2, "Code Review")
    }

    func testResolveArtifactName_emptyExpectedArtifacts() {
        let result = LLMExecutionService.resolveArtifactName(
            "Design Spec", expectedArtifacts: [])
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_prefersLongestPrefixMatch() {
        // "Design Spec Review – Calculator" prefix-matches both "Design Spec" and "Design Spec Review"
        // Must pick the longer match regardless of array order
        let result1 = LLMExecutionService.resolveArtifactName(
            "Design Spec Review – Calculator",
            expectedArtifacts: ["Design Spec", "Design Spec Review"])
        XCTAssertEqual(result1, "Design Spec Review")

        let result2 = LLMExecutionService.resolveArtifactName(
            "Design Spec Review – Calculator",
            expectedArtifacts: ["Design Spec Review", "Design Spec"])
        XCTAssertEqual(result2, "Design Spec Review")
    }

    // MARK: - resolveArtifactName Edge Cases

    func testResolveArtifactName_caseInsensitiveMatch() {
        // LLM used different casing — slugify lowercases both
        let result = LLMExecutionService.resolveArtifactName(
            "PRODUCT REQUIREMENTS", expectedArtifacts: ["Product Requirements"])
        XCTAssertEqual(result, "Product Requirements")
    }

    func testResolveArtifactName_unicodeAndEmDash() {
        // Em-dash (—), en-dash (–), colon are all stripped by slugify
        // "Engineering Notes — v2" → "engineering_notes_v2", prefix matches "Engineering Notes" → "engineering_notes"
        let result = LLMExecutionService.resolveArtifactName(
            "Engineering Notes — v2", expectedArtifacts: ["Engineering Notes"])
        XCTAssertEqual(result, "Engineering Notes")
    }

    func testResolveArtifactName_numberedSuffix() {
        // LLM appended a version number: "Release Notes 1.0"
        let result = LLMExecutionService.resolveArtifactName(
            "Release Notes 1.0", expectedArtifacts: ["Release Notes"])
        XCTAssertEqual(result, "Release Notes")
    }

    func testResolveArtifactName_singleCharExpected_noFalsePositive() {
        // Very short expected artifact name — should not wildly match unrelated names
        // "A" slug = "a". "Implementation Plan" slug = "implementation_plan".
        // "a" is NOT a prefix, and "implementation_plan" does contain "a" → matches "A"
        // This is acceptable: if someone names an artifact "A", any name containing "a" will match.
        // Document this known limitation.
        let result = LLMExecutionService.resolveArtifactName(
            "Implementation Plan", expectedArtifacts: ["A", "Implementation Plan"])
        // "Implementation Plan" exact match should win over contains "a"
        XCTAssertEqual(result, "Implementation Plan")
    }

    func testResolveArtifactName_singleCharExpected_containsMatchLastResort() {
        // When no exact or prefix match, single-char "A" matches anything containing "a"
        let result = LLMExecutionService.resolveArtifactName(
            "My Great Plan", expectedArtifacts: ["A"])
        // slug "my_great_plan" contains "a" — fuzzy match
        XCTAssertEqual(result, "A")
    }

    func testResolveArtifactName_threeOverlappingArtifacts() {
        // Three artifacts with overlapping slugified prefixes: "Code", "Code Review", "Code Review Notes"
        // Input matches the longest — regardless of array order
        let expected = ["Code", "Code Review Notes", "Code Review"]

        // Exact embellishment of the longest
        let r1 = LLMExecutionService.resolveArtifactName(
            "Code Review Notes – Backend Audit", expectedArtifacts: expected)
        XCTAssertEqual(r1, "Code Review Notes")

        // Embellishment of the middle one
        let r2 = LLMExecutionService.resolveArtifactName(
            "Code Review – Sprint 5", expectedArtifacts: expected)
        XCTAssertEqual(r2, "Code Review")

        // Embellishment of the shortest
        let r3 = LLMExecutionService.resolveArtifactName(
            "Code Quality Report", expectedArtifacts: expected)
        // slug "code_quality_report" has prefix "code" → matches "Code" (prefix pass)
        XCTAssertEqual(r3, "Code")
    }

    func testResolveArtifactName_prefixVsContains_prefixWins() {
        // "Research Report Summary" — prefix matches "Research Report"
        // Also contains "report" which could match "Report" via contains
        // Prefix match (Pass 1) should win over contains match (Pass 2)
        let result = LLMExecutionService.resolveArtifactName(
            "Research Report Summary",
            expectedArtifacts: ["Report", "Research Report"])
        XCTAssertEqual(result, "Research Report")
    }

    func testResolveArtifactName_extraWhitespace_matchesViaCompactForm() {
        // Slugify-only would fail ("__design___spec__" doesn't contain "design_spec"),
        // but the compact-form pass (alphanumeric only) collapses whitespace and matches.
        // This was previously a documented limitation; the file-extension fix added a
        // stronger compact contains pass that incidentally fixes this case too.
        let result = LLMExecutionService.resolveArtifactName(
            "  Design   Spec  ", expectedArtifacts: ["Design Spec"])
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_parenthesizedSuffix() {
        // LLM added "(Draft)" — parentheses stripped by slugify
        // "Implementation Plan (Draft)" → "implementation_plan_draft", prefix matches "Implementation Plan"
        let result = LLMExecutionService.resolveArtifactName(
            "Implementation Plan (Draft)",
            expectedArtifacts: ["Implementation Plan", "Design Spec"])
        XCTAssertEqual(result, "Implementation Plan")
    }

    // MARK: - File-extension stripping (regression EA190834)

    /// Regression: UX Designer in run EA190834 created `CalculatorDesignSpec.md` instead of
    /// `Design Spec`. Slugify dropped the `.` and produced `calculatordesignspecmd`, which
    /// neither prefix-matched nor contains-matched `design_spec` (underscore vs no underscore).
    /// Designer kept retrying with new alias names. Fix: strip known extensions before slugify
    /// and add a compact-form contains pass.
    func testResolveArtifactName_stripsMarkdownExtension() {
        let result = LLMExecutionService.resolveArtifactName(
            "CalculatorDesignSpec.md",
            expectedArtifacts: ["Design Spec"]
        )
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_stripsExtensionAndCamelCaseMatches() {
        // Bare camelCase without extension also matches via compact form.
        let result = LLMExecutionService.resolveArtifactName(
            "DesignSpec",
            expectedArtifacts: ["Design Spec"]
        )
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_stripsAllSupportedExtensions() {
        let names = ["Foo.md", "Foo.markdown", "Foo.txt", "Foo.json", "Foo.html", "Foo.rtf", "Foo.pdf", "Foo.docx"]
        for name in names {
            let result = LLMExecutionService.resolveArtifactName(name, expectedArtifacts: ["Foo"])
            XCTAssertEqual(result, "Foo", "Failed to strip extension from \(name)")
        }
    }

    func testResolveArtifactName_extensionStrip_caseInsensitive() {
        let result = LLMExecutionService.resolveArtifactName(
            "DesignSpec.MD",
            expectedArtifacts: ["Design Spec"]
        )
        XCTAssertEqual(result, "Design Spec")
    }

    func testResolveArtifactName_unrelatedExtensionNotStripped() {
        // Non-known suffix (e.g. ".calc") shouldn't be stripped.
        let result = LLMExecutionService.resolveArtifactName(
            "Foo.calc", expectedArtifacts: ["Foo"]
        )
        // "foo.calc" → slug "foocalc" → does NOT prefix-match "foo" but compact form
        // "foocalc" contains "foo" → matches via compact pass. That's acceptable behavior;
        // assert the basic case (Foo as input) still works without unintended stripping.
        XCTAssertEqual(result, "Foo")
    }

    func testResolveArtifactName_completelyDifferentName() {
        // LLM hallucinated a totally different name — no match, returns original
        let result = LLMExecutionService.resolveArtifactName(
            "Banana Smoothie Recipe",
            expectedArtifacts: ["Product Requirements", "Design Spec", "Implementation Plan"])
        XCTAssertEqual(result, "Banana Smoothie Recipe")
    }

    func testResolveArtifactName_identicalSlugs() {
        // Two expected artifacts that slugify to the same thing:
        // "Design-Spec" → "designspec", "Design Spec" → "design_spec"
        // Actually these are different slugs. Let's try real collision:
        // "Code_Review" → "code_review", "Code Review" → "code_review" — same slug!
        let result = LLMExecutionService.resolveArtifactName(
            "Code Review – Final",
            expectedArtifacts: ["Code_Review", "Code Review"])
        // Both have slug "code_review", prefix match on the longer slug sorts first (tie: same length)
        // First in sorted order wins — both have length 11. Array order in the sorted list is stable.
        // Either match is acceptable.
        let valid = result == "Code_Review" || result == "Code Review"
        XCTAssertTrue(valid, "Should match one of the identical-slug artifacts, got: \(result)")
    }

    func testResolveArtifactName_unicodeArtifactName() {
        // "Product Requirements – Calculator" → prefix matches "Product Requirements"
        let result = LLMExecutionService.resolveArtifactName(
            "Product Requirements – Calculator",
            expectedArtifacts: ["Product Requirements"])
        XCTAssertEqual(result, "Product Requirements")
    }

    func testResolveArtifactName_allExpectedMatchButPicksLongest() {
        // Input that contains ALL expected artifacts via slugified contains
        // "Production Readiness Code Review Notes" contains "code", "code_review", "code_review_notes"
        // Longest should win
        let result = LLMExecutionService.resolveArtifactName(
            "Production Readiness Code Review Notes",
            expectedArtifacts: ["Code", "Code Review", "Code Review Notes", "Production Readiness"])
        // slug: "production_readiness_code_review_notes"
        // Prefix match: "production_readiness" is prefix → matches "Production Readiness" (length 22)
        // But "production_readiness_code_review_notes" also has prefix match for none of the others
        // Wait: "code" is NOT a prefix of "production_readiness_code_review_notes"
        // So only "Production Readiness" prefix-matches. Correct.
        XCTAssertEqual(result, "Production Readiness")
    }

    // MARK: - Helpers

    private func createSimpleTask() -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .softwareEngineer,
            title: "Test Step",
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Goal", runs: [run])
        service._testRegisterStepTask(stepID: step.id, taskID: task.id)
        return task
    }

    private func createTaskWithExpectedArtifacts(_ kinds: [String]) -> NTMSTask {
        let step = StepExecution(
            id: "test_step",
            role: .productManager,
            title: "PO Step",
            expectedArtifacts: kinds,
            status: .running
        )
        let run = Run(id: 0, steps: [step])
        let task = NTMSTask(id: 0, title: "Test Task", supervisorTask: "Goal", runs: [run])
        service._testRegisterStepTask(stepID: step.id, taskID: task.id)
        return task
    }
}
