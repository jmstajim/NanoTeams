import XCTest
@testable import NanoTeams

final class ToolArgumentHelpersTests: XCTestCase {

    // MARK: - requiredString

    func testRequiredString_keyPresent_returnsValue() throws {
        let args: [String: Any] = ["name": "hello"]
        XCTAssertEqual(try requiredString(args, "name"), "hello")
    }

    func testRequiredString_keyMissing_throws() {
        let args: [String: Any] = ["other": "value"]
        XCTAssertThrowsError(try requiredString(args, "name")) { error in
            XCTAssertTrue(error is ToolArgumentError)
        }
    }

    func testRequiredString_rawInputFallback_plainString() throws {
        let args: [String: Any] = ["__raw_input__": "plain text content"]
        XCTAssertEqual(try requiredString(args, "content"), "plain text content")
    }

    func testRequiredString_rawInputFallback_jsonString() throws {
        let args: [String: Any] = ["__raw_input__": "{\"path\": \"/src/file.swift\"}"]
        XCTAssertEqual(try requiredString(args, "path"), "/src/file.swift")
    }

    func testRequiredString_rawInputFallback_jsonKeyNotFound_returnsRaw() throws {
        let args: [String: Any] = ["__raw_input__": "{\"other\": \"value\"}"]
        // Key "path" not in JSON, falls back to raw string
        XCTAssertEqual(try requiredString(args, "path"), "{\"other\": \"value\"}")
    }

    // MARK: - optionalString

    func testOptionalString_keyPresent_returnsValue() {
        let args: [String: Any] = ["key": "value"]
        XCTAssertEqual(optionalString(args, "key"), "value")
    }

    func testOptionalString_keyMissing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalString(args, "key"))
    }

    // MARK: - optionalInt

    func testOptionalInt_intValue() {
        let args: [String: Any] = ["count": 42]
        XCTAssertEqual(optionalInt(args, "count"), 42)
    }

    func testOptionalInt_doubleCoercion() {
        let args: [String: Any] = ["count": 42.7]
        XCTAssertEqual(optionalInt(args, "count"), 42)
    }

    func testOptionalInt_missing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalInt(args, "count"))
    }

    func testOptionalInt_wrongType_returnsNil() {
        let args: [String: Any] = ["count": "not a number"]
        XCTAssertNil(optionalInt(args, "count"))
    }

    // MARK: - requiredInt

    func testRequiredInt_intValue() throws {
        let args: [String: Any] = ["line": 10]
        XCTAssertEqual(try requiredInt(args, "line"), 10)
    }

    func testRequiredInt_doubleCoercion() throws {
        let args: [String: Any] = ["line": 10.5]
        XCTAssertEqual(try requiredInt(args, "line"), 10)
    }

    func testRequiredInt_missing_throws() {
        let args: [String: Any] = [:]
        XCTAssertThrowsError(try requiredInt(args, "line")) { error in
            XCTAssertEqual(
                (error as? ToolArgumentError)?.localizedDescription,
                "Missing required argument: line",
                "a genuinely absent key must still report 'Missing'"
            )
        }
    }

    // MARK: - Int coercion from numeric strings
    //
    // Small local models routinely emit `{"start_line": "501"}` — the number as
    // a JSON string. Strict `as? Int` rejection surfaced as the misleading
    // "Missing required argument: start_line" even though the argument was
    // present. Same tolerance the sibling `extractString` already documents.

    func testOptionalInt_numericString_coerces() {
        XCTAssertEqual(optionalInt(["start_line": "501"], "start_line"), 501)
    }

    func testOptionalInt_numericStringWithWhitespace_coerces() {
        XCTAssertEqual(optionalInt(["start_line": " 501 "], "start_line"), 501)
    }

    func testOptionalInt_decimalString_truncatesTowardZero() {
        XCTAssertEqual(optionalInt(["count": "501.9"], "count"), 501)
        XCTAssertEqual(optionalInt(["count": "-501.9"], "count"), -501)
    }

    func testOptionalInt_negativeNumericString_coerces() {
        // `read_lines` uses -1 as the read-to-EOF sentinel; a string "-1" must
        // reach the same branch as the numeric form.
        XCTAssertEqual(optionalInt(["end_line": "-1"], "end_line"), -1)
    }

    func testRequiredInt_numericString_coerces() throws {
        XCTAssertEqual(try requiredInt(["start_line": "501"], "start_line"), 501)
    }

    func testRequiredInt_presentButNotANumber_throwsTypeErrorNotMissing() {
        // The key IS present — reporting "Missing" sends the model hunting for
        // an argument it already sent. Name the real problem instead.
        XCTAssertThrowsError(try requiredInt(["start_line": "abc"], "start_line")) { error in
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "got: \(message)")
            XCTAssertTrue(message.contains("start_line"), "got: \(message)")
            XCTAssertTrue(message.contains("integer"), "got: \(message)")
        }
    }

    // MARK: - Int coercion boundaries (no traps)

    func testOptionalInt_hugeDouble_returnsNilInsteadOfTrapping() {
        // `Int(1e300)` traps. A JSON payload can carry that literal, so the
        // coercion must degrade to nil rather than crash the tool loop.
        XCTAssertNil(optionalInt(["count": 1e300], "count"))
    }

    func testOptionalInt_nonFiniteDouble_returnsNil() {
        XCTAssertNil(optionalInt(["count": Double.infinity], "count"))
        XCTAssertNil(optionalInt(["count": Double.nan], "count"))
    }

    func testOptionalInt_overflowingNumericString_returnsNil() {
        XCTAssertNil(optionalInt(["count": "999999999999999999999999999"], "count"))
    }

    func testRequiredInt_hugeDouble_throwsInsteadOfTrapping() {
        XCTAssertThrowsError(try requiredInt(["line": 1e300], "line")) { error in
            // A bare `is ToolArgumentError` would also accept `.missingRequired` —
            // the misdiagnosis this change exists to remove. The value is present,
            // so the type error is the only correct report.
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "got: \(message)")
            XCTAssertTrue(message.contains("integer"), "got: \(message)")
        }
    }

    func testOptionalInt_emptyString_returnsNil() {
        XCTAssertNil(optionalInt(["count": ""], "count"))
        XCTAssertNil(optionalInt(["count": "   "], "count"))
    }

    // MARK: - String branch: what the Double fallback accepts
    //
    // `Double.init?(String)` is strtod-backed, so the string branch inherits
    // exponent and hex-float notation. That is a deliberate charitable reading
    // (a model writing "1e3" for a line number meant 1000), but nothing pinned
    // it — a later narrowing of that fallback would change tool behavior
    // silently. Pinned in both directions.

    func testOptionalInt_exponentString_coerces() {
        XCTAssertEqual(optionalInt(["count": "1e3"], "count"), 1000)
    }

    func testOptionalInt_hexString_coerces() {
        XCTAssertEqual(optionalInt(["count": "0x1F"], "count"), 31)
    }

    func testOptionalInt_partialNumber_returnsNil() {
        // The initializers require full consumption, so garbage is never
        // silently truncated into a number.
        XCTAssertNil(optionalInt(["count": "501abc"], "count"))
        XCTAssertNil(optionalInt(["count": "1e"], "count"))
        XCTAssertNil(optionalInt(["count": "501 502"], "count"))
        XCTAssertNil(optionalInt(["count": "1_000"], "count"))
    }

    func testOptionalInt_jsonBoolean_coercesToOneAndZero() {
        // `JSONSerialization` yields `__NSCFBoolean`, which bridges to Int.
        // Long-standing behavior, previously unpinned — a model sending
        // `{"start_line": true}` reads as 1 rather than as absent.
        let parsed = try! JSONSerialization.jsonObject(
            with: #"{"t": true, "f": false}"#.data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(optionalInt(parsed, "t"), 1)
        XCTAssertEqual(optionalInt(parsed, "f"), 0)
    }

    // MARK: - JSON null

    func testRequiredInt_jsonNull_reportsMissingNotInvalidType() {
        // `JSONSerialization` maps JSON `null` to `NSNull`, and `ToolRuntime`
        // strips empty KEYS but never null VALUES — so `{"start_line": null}`
        // reaches the helper intact. A nulled argument is an omission, not a
        // malformed value; telling the model its argument "must be an integer"
        // would point at a type it never supplied.
        XCTAssertThrowsError(try requiredInt(["start_line": NSNull()], "start_line")) { error in
            XCTAssertEqual(
                (error as? ToolArgumentError)?.localizedDescription,
                "Missing required argument: start_line",
                "JSON null must be reported as absent, not as a bad type"
            )
        }
    }

    func testOptionalInt_jsonNull_returnsNil() {
        XCTAssertNil(optionalInt(["count": NSNull()], "count"))
    }

    // MARK: - optionalBool

    func testOptionalBool_true() {
        let args: [String: Any] = ["flag": true]
        XCTAssertTrue(optionalBool(args, "flag"))
    }

    func testOptionalBool_false() {
        let args: [String: Any] = ["flag": false]
        XCTAssertFalse(optionalBool(args, "flag"))
    }

    // MARK: - optionalBool coercion
    //
    // A model that quotes its integers quotes its booleans from the same habit,
    // so mixed-quoting payloads are the expected shape. Unlike the int helpers,
    // a rejected bool has no nil for the caller to notice — it silently becomes
    // the handler's default, so the wrong branch runs under a success envelope.

    func testOptionalBool_stringTrue_coerces() {
        XCTAssertTrue(optionalBool(["flag": "true"], "flag"))
        XCTAssertTrue(optionalBool(["flag": "TRUE"], "flag"))
        XCTAssertTrue(optionalBool(["flag": " true "], "flag"))
        XCTAssertTrue(optionalBool(["flag": "yes"], "flag"))
        XCTAssertTrue(optionalBool(["flag": "1"], "flag"))
    }

    func testOptionalBool_stringFalse_coerces() {
        // Every one of these must beat a `default: true` — that is the silent
        // wrong-branch case (e.g. `read_lines include_line_numbers`).
        XCTAssertFalse(optionalBool(["flag": "false"], "flag", default: true))
        XCTAssertFalse(optionalBool(["flag": "False"], "flag", default: true))
        XCTAssertFalse(optionalBool(["flag": " false "], "flag", default: true))
        XCTAssertFalse(optionalBool(["flag": "no"], "flag", default: true))
        XCTAssertFalse(optionalBool(["flag": "0"], "flag", default: true))
    }

    func testOptionalBool_intZeroOne_coerces() {
        XCTAssertTrue(optionalBool(["flag": 1], "flag"))
        XCTAssertFalse(optionalBool(["flag": 0], "flag", default: true))
    }

    func testOptionalBool_ambiguousInt_usesDefault() {
        // 2 is not a boolean in any spelling — stay with the caller's default
        // rather than inventing `!= 0` truthiness for a destructive flag.
        XCTAssertFalse(optionalBool(["flag": 2], "flag", default: false))
        XCTAssertTrue(optionalBool(["flag": 2], "flag", default: true))
    }

    func testOptionalBool_junkString_usesDefault() {
        XCTAssertTrue(optionalBool(["flag": "maybe"], "flag", default: true))
        XCTAssertFalse(optionalBool(["flag": "maybe"], "flag", default: false))
        XCTAssertTrue(optionalBool(["flag": ""], "flag", default: true))
    }

    func testOptionalBool_jsonNull_usesDefault() {
        XCTAssertTrue(optionalBool(["flag": NSNull()], "flag", default: true))
    }

    func testOptionalBool_realBool_stillWins() {
        XCTAssertTrue(optionalBool(["flag": true], "flag", default: false))
        XCTAssertFalse(optionalBool(["flag": false], "flag", default: true))
    }

    func testOptionalBool_missing_usesDefault() {
        let args: [String: Any] = [:]
        XCTAssertFalse(optionalBool(args, "flag"))
        XCTAssertTrue(optionalBool(args, "flag", default: true))
    }

    // MARK: - optionalStringArray

    func testOptionalStringArray_present() {
        let args: [String: Any] = ["paths": ["a.swift", "b.swift"]]
        XCTAssertEqual(optionalStringArray(args, "paths"), ["a.swift", "b.swift"])
    }

    func testOptionalStringArray_missing_returnsNil() {
        let args: [String: Any] = [:]
        XCTAssertNil(optionalStringArray(args, "paths"))
    }

    // MARK: - requiredStringArray

    func testRequiredStringArray_present() throws {
        let args: [String: Any] = ["paths": ["x", "y"]]
        XCTAssertEqual(try requiredStringArray(args, "paths"), ["x", "y"])
    }

    // MARK: - String-array coercion
    //
    // A one-element list emitted as a bare string is the same emission quirk.
    // For `search paths` the strict cast degrades silently — the narrowing
    // constraint is dropped and the search runs over the whole tree while
    // still reporting success.

    func testOptionalStringArray_bareString_wrapsInArray() {
        XCTAssertEqual(optionalStringArray(["paths": "src"], "paths"), ["src"])
        XCTAssertEqual(optionalStringArray(["paths": " src "], "paths"), ["src"])
    }

    func testOptionalStringArray_emptyString_returnsNil() {
        XCTAssertNil(optionalStringArray(["paths": ""], "paths"))
        XCTAssertNil(optionalStringArray(["paths": "   "], "paths"))
    }

    func testOptionalStringArray_numericElements_coerce() {
        // JSON `[1, 2]` does not bridge to [String]; it must not read as absent.
        XCTAssertEqual(optionalStringArray(["ids": [1, 2] as [Any]], "ids"), ["1", "2"])
    }

    func testOptionalStringArray_emptyArray_preserved() {
        // Existing behavior: an explicitly empty list stays empty, not nil.
        XCTAssertEqual(optionalStringArray(["paths": [String]()], "paths"), [])
    }

    func testOptionalStringArray_jsonNull_returnsNil() {
        XCTAssertNil(optionalStringArray(["paths": NSNull()], "paths"))
    }

    func testRequiredStringArray_bareString_wrapsInArray() throws {
        XCTAssertEqual(try requiredStringArray(["participants": "Tech Lead"], "participants"), ["Tech Lead"])
    }

    func testRequiredStringArray_presentButUncoercible_throwsTypeErrorNotMissing() {
        XCTAssertThrowsError(try requiredStringArray(["paths": 5], "paths")) { error in
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "got: \(message)")
            XCTAssertTrue(message.contains("paths"), "got: \(message)")
        }
    }

    func testRequiredStringArray_jsonNull_reportsMissing() {
        XCTAssertThrowsError(try requiredStringArray(["paths": NSNull()], "paths")) { error in
            XCTAssertEqual(
                (error as? ToolArgumentError)?.localizedDescription,
                "Missing required argument: paths"
            )
        }
    }

    // MARK: - Alias chains
    //
    // Tools accept several spellings of the same argument (`paths`/`files`/`path`,
    // `participants`/`members`). Expressing that as `try? requiredStringArray(a)`
    // then `try? requiredStringArray(b)` cannot tell "this key is absent, try the
    // next alias" from "this key is present but malformed", so a malformed first
    // alias falls through and the model is told about a key it never sent.

    func testRequiredStringArrayAliases_usesFirstPresentKey() throws {
        XCTAssertEqual(
            try requiredStringArray(["files": ["a.swift"]], aliases: ["paths", "files"]),
            ["a.swift"]
        )
    }

    func testRequiredStringArrayAliases_prefersEarlierAlias() throws {
        XCTAssertEqual(
            try requiredStringArray(["paths": ["a"], "files": ["b"]], aliases: ["paths", "files"]),
            ["a"]
        )
    }

    func testRequiredStringArrayAliases_bareStringUnderAnyAlias_coerces() throws {
        XCTAssertEqual(
            try requiredStringArray(["path": "a.swift"], aliases: ["paths", "files", "path"]),
            ["a.swift"]
        )
    }

    func testRequiredStringArrayAliases_malformedFirstAlias_namesThatKeyNotTheChain() {
        // The model sent `paths`. Reporting the whole alias list as missing — or
        // worse, naming a later alias it never used — is the misdiagnosis this
        // whole seam exists to remove.
        XCTAssertThrowsError(
            try requiredStringArray(["paths": 5], aliases: ["paths", "files"], display: "paths (or files)")
        ) { error in
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "a present-but-malformed alias is not an omission; got: \(message)")
            XCTAssertTrue(message.contains("paths"), "the error must name the key the model actually sent; got: \(message)")
            XCTAssertFalse(message.contains("files"), "it must not name an alias the model never sent; got: \(message)")
        }
    }

    func testRequiredStringArrayAliases_malformedLaterAlias_stillNamesTheKeySent() {
        XCTAssertThrowsError(
            try requiredStringArray(["files": 5], aliases: ["paths", "files"])
        ) { error in
            let message = (error as? ToolArgumentError)?.localizedDescription ?? ""
            XCTAssertFalse(message.contains("Missing"), "got: \(message)")
            XCTAssertTrue(message.contains("files"), "got: \(message)")
        }
    }

    func testRequiredStringArrayAliases_malformedEarlyButValidLater_succeeds() throws {
        // A usable value anywhere in the chain wins over an unusable one: the
        // model gave us something we can act on, so acting beats complaining.
        XCTAssertEqual(
            try requiredStringArray(["paths": 5, "files": ["b.swift"]], aliases: ["paths", "files"]),
            ["b.swift"]
        )
    }

    func testRequiredStringArrayAliases_allAbsent_reportsDisplayName() {
        XCTAssertThrowsError(
            try requiredStringArray([:], aliases: ["paths", "files"], display: "paths (or files)")
        ) { error in
            XCTAssertEqual(
                (error as? ToolArgumentError)?.localizedDescription,
                "Missing required argument: paths (or files)"
            )
        }
    }

    func testRequiredStringArrayAliases_nullValue_countsAsAbsent() {
        // JSON null is an omission, so it must fall through to the next alias.
        XCTAssertEqual(
            try? requiredStringArray(["paths": NSNull(), "files": ["b"]], aliases: ["paths", "files"]),
            ["b"]
        )
    }

    func testRequiredStringArray_missing_throws() {
        let args: [String: Any] = [:]
        XCTAssertThrowsError(try requiredStringArray(args, "paths"))
    }

    // MARK: - resolveContentString

    func testResolveContentString_exactContentKey() {
        let args: [String: Any] = ["content": "hello world"]
        XCTAssertEqual(resolveContentString(args), "hello world")
    }

    func testResolveContentString_alternativeText() {
        let args: [String: Any] = ["text": "hello text"]
        XCTAssertEqual(resolveContentString(args), "hello text")
    }

    func testResolveContentString_alternativeBody() {
        let args: [String: Any] = ["body": "hello body"]
        XCTAssertEqual(resolveContentString(args), "hello body")
    }

    func testResolveContentString_alternativeFileContent() {
        let args: [String: Any] = ["file_content": "file data"]
        XCTAssertEqual(resolveContentString(args), "file data")
    }

    func testResolveContentString_singleRemainingStringFallback() {
        let args: [String: Any] = ["my_custom_key": "fallback value"]
        XCTAssertEqual(resolveContentString(args), "fallback value")
    }

    func testResolveContentString_multipleRemainingStrings_returnsNil() {
        let args: [String: Any] = ["key1": "val1", "key2": "val2"]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_nonContentKeysExcluded() {
        // "path" is in nonContentKeys, should not be treated as content
        let args: [String: Any] = ["path": "/src/file.swift"]
        XCTAssertNil(resolveContentString(args))
    }

    func testResolveContentString_excludeKeysRespected() {
        let args: [String: Any] = ["custom": "value"]
        XCTAssertNil(resolveContentString(args, excludeKeys: ["custom"]))
    }

    func testResolveContentString_contentKeyTakesPrecedence() {
        let args: [String: Any] = ["content": "primary", "text": "secondary"]
        XCTAssertEqual(resolveContentString(args), "primary")
    }

    func testResolveContentString_emptyArgs_returnsNil() {
        XCTAssertNil(resolveContentString([:]))
    }

    // MARK: - unwrapReentrantEnvelope (Run 6 regression)

    /// Run 6 evidence: CR emitted `create_artifact` with
    /// `{"name":"create_artifact","arguments":{"name":"CalculatorDemo.zip","content":"…"}}`.
    /// Handler took outer `name="create_artifact"` as the artifact name.
    /// Unwrap must return inner args so the handler sees `name="CalculatorDemo.zip"`.
    func testUnwrap_selfReferentialEnvelope_returnsInner() {
        let args: [String: Any] = [
            "name": "create_artifact",
            "arguments": [
                "name": "Code Review",
                "content": "# Review\n- issue 1",
            ] as [String: Any],
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "Code Review")
        XCTAssertEqual(unwrapped["content"] as? String, "# Review\n- issue 1")
    }

    /// Outer name that doesn't match the dispatched tool name — leave alone.
    func testUnwrap_outerNameMismatch_returnsOriginal() {
        let args: [String: Any] = [
            "name": "different_tool",
            "arguments": ["path": "foo.txt"] as [String: Any],
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "different_tool")
        XCTAssertNotNil(unwrapped["arguments"])
    }

    /// No `arguments` key — leave alone (normal `create_artifact` call with outer `name`).
    func testUnwrap_noArgumentsKey_returnsOriginal() {
        let args: [String: Any] = [
            "name": "create_artifact",
            "content": "# Review",
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "create_artifact")
        XCTAssertEqual(unwrapped["content"] as? String, "# Review")
    }

    /// Normal tool args (no `name` key) — pass through untouched.
    func testUnwrap_normalArgs_returnsOriginal() {
        let args: [String: Any] = [
            "content": "hi",
            "format": "md",
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["content"] as? String, "hi")
        XCTAssertEqual(unwrapped["format"] as? String, "md")
    }

    /// Extra outer keys must not block unwrap — the envelope is malformed anyway.
    func testUnwrap_extraOuterKeys_stillUnwraps() {
        let args: [String: Any] = [
            "name": "create_artifact",
            "arguments": ["name": "Plan", "content": "..."] as [String: Any],
            "_extra": "junk",
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "Plan")
        XCTAssertNil(unwrapped["_extra"], "Inner dict must not carry outer extra keys")
    }

    /// Outer `name` carrying a provider prefix (`functions.create_artifact`) must
    /// still unwrap when the dispatched tool is the bare `create_artifact`.
    /// Without canonicalizing both sides this would fail — mirroring the Run 6 bug
    /// in its namespaced form.
    func testUnwrap_prefixedOuterName_unwrapsToInner() {
        let args: [String: Any] = [
            "name": "functions.create_artifact",
            "arguments": ["name": "Plan", "content": "…"] as [String: Any],
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "Plan",
                       "Prefixed outer name must canonicalize and unwrap to inner dict")
    }

    func testUnwrap_repoBrowserPrefix_unwrapsToInner() {
        let args: [String: Any] = [
            "name": "repo_browser.create_artifact",
            "arguments": ["name": "Spec", "content": "…"] as [String: Any],
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "Spec")
    }

    /// Defense-in-depth: even when BOTH sides happen to be prefixed, canonicalization
    /// makes them match rather than forcing a string-equality miss.
    func testUnwrap_bothSidesPrefixed_unwraps() {
        let args: [String: Any] = [
            "name": "functions.create_artifact",
            "arguments": ["name": "Doc"] as [String: Any],
        ]
        let unwrapped = unwrapReentrantEnvelope(args, expectedToolName: "repo_browser.create_artifact")
        XCTAssertEqual(unwrapped["name"] as? String, "Doc")
    }
}
