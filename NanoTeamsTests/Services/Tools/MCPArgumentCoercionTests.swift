import XCTest

@testable import NanoTeams

/// The seam between what a model emits and what goes on the wire to an external server.
///
/// Two halves are tested for different reasons. The conversions are tested because the server
/// is the one that refuses a wrong-typed value, a round trip later, in its own words — so a
/// conversion that silently does not happen costs a turn and teaches nothing. The header half
/// is tested because it is a security boundary: a value the MODEL chose becomes part of an
/// HTTP request line.
final class MCPArgumentCoercionTests: XCTestCase {

    private func schema(_ properties: [String: JSONSchemaProperty]) -> JSONSchema {
        JSONSchema.object(properties: properties)
    }

    /// The call of a tool whose schema is `properties` and whose header parameters are `headers`
    /// — called differently by era when its schema carries `x-mcp-header`
    /// (`callShapeDependsOnEra`), header parameters or not: by default exactly when it has one,
    /// as the factory builds a modern-listed tool; `dependsOnEra` sets it apart from them, as for
    /// a legacy-listed annotated tool, which has none and still depends on the era.
    private func coerce(
        _ args: [String: Any],
        _ properties: [String: JSONSchemaProperty] = [:],
        headers: [MCPHeaderParam] = [],
        dependsOnEra: Bool? = nil,
        era: MCPProtocolEra = .modern
    ) throws -> MCPArgumentCoercion.Coerced {
        let descriptor = MCPToolDescriptor(
            originalName: "x", modelFacingName: "mcp__folio__x", displayDescription: "x",
            inputSchema: schema(properties), outputSchema: nil, annotations: .specDefaults,
            headerParams: headers, callShapeDependsOnEra: dependsOnEra ?? !headers.isEmpty,
            pinHash: "hash", rawTool: .object([:]), strippedHiddenCharacters: false)
        return try MCPArgumentCoercion.coerce(args: args, descriptor: descriptor, era: era)
    }

    // MARK: - Nothing to do

    func testAnEmptyCallIsTheEmptyObject() throws {
        let coerced = try coerce([:])
        XCTAssertEqual(coerced.arguments, .object([:]))
        XCTAssertTrue(coerced.headerParameters.isEmpty)
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    /// A value that already has the declared type is passed through untouched and unreported
    /// — a warning on every well-formed call would be noise the model learns to skip.
    func testAValueOfTheDeclaredTypeIsNotReported() throws {
        let coerced = try coerce(["limit": 10], ["limit": JSONSchema.integer()])
        XCTAssertEqual(coerced.arguments, .object(["limit": .int(10)]))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    /// The projection is lossy, so "not in the schema" does not mean "not in the server's
    /// schema". An unmentioned property rides through and the server decides.
    func testAPropertyTheSchemaDoesNotMentionIsPassedThrough() throws {
        let coerced = try coerce(["extra": "value"])
        XCTAssertEqual(coerced.arguments, .object(["extra": .string("value")]))
    }

    // MARK: - Conversions

    func testANumberSentAsTextIsReadAsANumber() throws {
        let coerced = try coerce(["limit": "10"], ["limit": JSONSchema.integer()])
        XCTAssertEqual(coerced.arguments, .object(["limit": .int(10)]))
        XCTAssertEqual(coerced.warnings, ["`limit` was read as a number."])
    }

    func testAnIntegralDoubleBecomesAnInteger() throws {
        let coerced = try coerce(["limit": 10.0], ["limit": JSONSchema.integer()])
        XCTAssertEqual(coerced.arguments, .object(["limit": .int(10)]))
    }

    /// Rounding here would change the value the model asked for. It is passed through, and
    /// the server refuses it in its own terms.
    func testAFractionalValueForAnIntegerIsLeftAlone() throws {
        let coerced = try coerce(["limit": 10.5], ["limit": JSONSchema.integer()])
        XCTAssertEqual(coerced.arguments, .object(["limit": .double(10.5)]))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    /// A fractional type is its own arm: `integer` refuses `10.5` on purpose, and a server
    /// that declared `number` is asking for exactly the value `integer` would have rejected.
    func testAFractionalPropertyReadsEverySpellingOfANumber() throws {
        let property = ["ratio": JSONSchemaProperty(
            type: "number", description: nil, properties: nil, required: nil,
            items: nil, enumValues: nil)]
        XCTAssertEqual(
            try coerce(["ratio": "0.5"], property).arguments, .object(["ratio": .double(0.5)]))
        XCTAssertEqual(
            try coerce(["ratio": 2], property).arguments, .object(["ratio": .double(2)]))
        // Already a double: passed through, and NOT reported — a warning on a well-formed
        // call is noise the model learns to skip.
        let already = try coerce(["ratio": 0.25], property)
        XCTAssertEqual(already.arguments, .object(["ratio": .double(0.25)]))
        XCTAssertTrue(already.warnings.isEmpty)
    }

    func testAnUnreadableNumberIsLeftForTheServer() throws {
        let property = ["ratio": JSONSchemaProperty(
            type: "number", description: nil, properties: nil, required: nil,
            items: nil, enumValues: nil)]
        for sent in ["not a number", "NaN", "inf"] {
            XCTAssertEqual(
                try coerce(["ratio": sent], property).arguments,
                .object(["ratio": .string(sent)]), sent)
        }
        XCTAssertEqual(
            try coerce(["ratio": true], property).arguments, .object(["ratio": .bool(true)]))
    }

    /// A header value spells a number the way JSON does, not the way Swift's `description`
    /// does: an integral double reaches a server as `3`, never `3.0`.
    func testAFractionalHeaderValueKeepsItsOwnSpelling() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        XCTAssertEqual(
            try coerce(["n": 0.5], headers: [param]).headerParameters, ["Mcp-Param-N": "0.5"])
    }

    func testBooleansSpelledAsTextAreRead() throws {
        let property = ["flag": JSONSchema.boolean()]
        for (sent, expected) in [("true", true), ("YES", true), ("0", false), ("no", false)] {
            let coerced = try coerce(["flag": sent], property)
            XCTAssertEqual(coerced.arguments, .object(["flag": .bool(expected)]), sent)
        }
    }

    func testAnUnreadableBooleanIsLeftForTheServer() throws {
        let coerced = try coerce(["flag": "maybe"], ["flag": JSONSchema.boolean()])
        XCTAssertEqual(coerced.arguments, .object(["flag": .string("maybe")]))
    }

    func testASingleValueBecomesAOneItemList() throws {
        let property = ["paths": JSONSchema.array(items: JSONSchema.string())]
        let coerced = try coerce(["paths": "src"], property)
        XCTAssertEqual(coerced.arguments, .object(["paths": .array([.string("src")])]))
        XCTAssertEqual(coerced.warnings, ["`paths` was read as a one-item list."])
    }

    /// `null` is the model saying "no value". Wrapping it would send a list containing
    /// nothing, which is a different request.
    func testANullIsNotWrappedInAList() throws {
        let property = ["paths": JSONSchema.array(items: JSONSchema.string())]
        let coerced = try coerce(["paths": NSNull()], property)
        XCTAssertEqual(coerced.arguments, .object(["paths": .null]))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    /// The conversion that earns the file: `JSONSchema` is capped at three levels, so a deep
    /// object reaches the model as a bare `(object)` with its shape in prose — and a model
    /// handed that writes the document as a string about as often as as an object.
    func testAJSONDocumentWrittenAsTextIsReadAsAnObject() throws {
        let property = ["filter": JSONSchema.object("Shape: {field, op, value}")]
        let coerced = try coerce(["filter": #"{"field": "ticker", "op": "eq"}"#], property)
        XCTAssertEqual(
            coerced.arguments,
            .object(["filter": .object(["field": .string("ticker"), "op": .string("eq")])]))
        XCTAssertEqual(coerced.warnings, ["`filter` was read as JSON rather than as text."])
    }

    func testAJSONListWrittenAsTextIsReadAsAList() throws {
        let property = ["items": JSONSchema.array(items: JSONSchema.string())]
        let coerced = try coerce(["items": #"["a", "b"]"#], property)
        XCTAssertEqual(coerced.arguments, .object(["items": .array([.string("a"), .string("b")])]))
    }

    /// A bare `"5"` parses as JSON, and reading it as a number here would undo the very
    /// distinction the declared type is being used to preserve.
    func testTextThatMerelyParsesIsStillText() throws {
        let property = ["filter": JSONSchema.object("Shape: {…}")]
        let coerced = try coerce(["filter": "5"], property)
        XCTAssertEqual(coerced.arguments, .object(["filter": .string("5")]))
    }

    func testMalformedJSONInAnObjectPropertyStaysText() throws {
        let property = ["filter": JSONSchema.object("Shape: {…}")]
        let coerced = try coerce(["filter": "{not json"], property)
        XCTAssertEqual(coerced.arguments, .object(["filter": .string("{not json")]))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    func testANumberWhereTextIsExpectedIsSpelledOut() throws {
        let coerced = try coerce(["ticker": 5], ["ticker": JSONSchema.string()])
        XCTAssertEqual(coerced.arguments, .object(["ticker": .string("5")]))
        XCTAssertEqual(coerced.warnings, ["`ticker` was read as text."])
    }

    /// The warning list rides into the tool result, so it has to be a function of the
    /// arguments rather than of dictionary iteration order.
    func testWarningsAreOrderedByArgumentName() throws {
        let properties = [
            "zeta": JSONSchema.integer(), "alpha": JSONSchema.integer(), "mid": JSONSchema.integer(),
        ]
        let coerced = try coerce(["zeta": "1", "alpha": "2", "mid": "3"], properties)
        XCTAssertEqual(coerced.warnings, [
            "`alpha` was read as a number.", "`mid` was read as a number.",
            "`zeta` was read as a number.",
        ])
    }

    /// Nothing JSON can hold: dropping it is right, doing it silently is not.
    func testAValueJSONCannotHoldIsDroppedAndReported() throws {
        let coerced = try coerce(["when": Date()])
        XCTAssertEqual(coerced.arguments, .object([:]))
        XCTAssertEqual(coerced.warnings, ["`when` could not be represented as JSON and was not sent."])
    }

    // MARK: - Header parameters

    func testAHeaderParameterStaysInTheBodyAndIsMirroredIntoItsHeader() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let coerced = try coerce(["account": "X1", "ticker": "SBER"], headers: [param])
        XCTAssertEqual(coerced.arguments, .object(["account": .string("X1"), "ticker": .string("SBER")]))
        XCTAssertEqual(coerced.headerParameters, ["Mcp-Param-Account": "X1"])
    }

    func testScalarHeaderValuesAreSpelledTheWayJSONWouldSpellThem() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        XCTAssertEqual(try coerce(["n": 7], headers: [param]).headerParameters, ["Mcp-Param-N": "7"])
        XCTAssertEqual(try coerce(["n": true], headers: [param]).headerParameters, ["Mcp-Param-N": "true"])
        XCTAssertEqual(try coerce(["n": 7.0], headers: [param]).headerParameters, ["Mcp-Param-N": "7"])
    }

    func testAnAbsentHeaderParameterSendsNoHeader() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let coerced = try coerce(["ticker": "SBER"], headers: [param])
        XCTAssertTrue(coerced.headerParameters.isEmpty)
    }

    /// A header parameter is a body value like any other — converted by its declared type — and
    /// its header mirrors the CONVERTED value, the one the server compares it with. Until
    /// 2026-10-28 the value was moved out of the body unconverted, and this test pinned the
    /// opposite.
    func testAHeaderParameterIsConvertedInTheBodyAndItsHeaderMirrorsTheConversion() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        let coerced = try coerce(["n": "7"], ["n": JSONSchema.integer()], headers: [param])
        XCTAssertEqual(coerced.arguments, .object(["n": .int(7)]))
        XCTAssertEqual(coerced.headerParameters, ["Mcp-Param-N": "7"])
        XCTAssertEqual(coerced.warnings, ["`n` was read as a number."])
        let flag = try MCPHeaderParam.make(argumentPath: ["f"], rawName: "F")
        let spelled = try coerce(["f": "yes"], ["f": JSONSchema.boolean()], headers: [flag])
        XCTAssertEqual(spelled.arguments, .object(["f": .bool(true)]))
        XCTAssertEqual(spelled.headerParameters, ["Mcp-Param-F": "true"], "the spec's lowercase spelling of a boolean")
    }

    /// A value the spec says to Base64-encode is MIRRORED, not refused: a newline, a carriage
    /// return or a control character in a header value is the transport's to spell as the
    /// `=?base64?…?=` sentinel ("When a value cannot be safely represented as a plain ASCII header
    /// value … clients MUST use Base64 encoding"), which carries it whole and makes an injected
    /// line impossible on the wire. The header here is the value as the server decodes it — the
    /// body's own.
    ///
    /// RED until 2026-10-28: the call was refused, which the spec does not allow.
    func testALineBreakOrAControlCharacterInAHeaderValueIsMirroredForTheSentinel() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        for value in ["X1\r\nAuthorization: Bearer x", "X\u{0007}1", "a\nb", "a\rb", "\ttab"] {
            let coerced = try coerce(["account": value], headers: [param])
            XCTAssertEqual(coerced.headerParameters, ["Mcp-Param-Account": value], value)
            XCTAssertEqual(coerced.arguments, .object(["account": .string(value)]), value)
        }
    }

    func testAListSentForAHeaderParameterFailsTheCall() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        XCTAssertThrowsError(try coerce(["account": ["a", "b"]], headers: [param])) {
            XCTAssertEqual($0 as? MCPArgumentCoercion.Failure, .headerValueNotAScalar(argument: "account"))
        }
    }

    func testEveryFailureNamesThePropertyAndTheRepair() {
        for failure: MCPArgumentCoercion.Failure in [
            .headerValueNotAScalar(argument: "account"),
            .headerValueOutsideSafeIntegerRange(argument: "account"),
        ] {
            XCTAssertTrue(failure.message.contains("`account`"), failure.message)
            XCTAssertEqual(failure.errorDescription, failure.message)
        }
    }

    // MARK: - The era decides the split (2026-10-28)

    /// A LEGACY session has no header channel — the transport writes no `Mcp-Param-*` header in
    /// that era — so a header parameter stays in the body like any other argument, converted by
    /// its declared type, and no header is produced.
    ///
    /// RED until 2026-10-28: the coercion moved the value out of the body whatever the
    /// era, and the legacy transport then sent it nowhere.
    func testInTheLegacyEraAHeaderParameterStaysInTheBodyAndNoHeaderIsSent() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let limit = try MCPHeaderParam.make(argumentPath: ["limit"], rawName: "Limit")
        let coerced = try coerce(
            ["account": "X1", "limit": "10", "ticker": "SBER"], ["limit": JSONSchema.integer()],
            headers: [account, limit], era: .legacy)
        XCTAssertEqual(coerced.arguments, .object([
            "account": .string("X1"), "limit": .int(10), "ticker": .string("SBER"),
        ]))
        XCTAssertTrue(coerced.headerParameters.isEmpty, "\(coerced.headerParameters)")
        XCTAssertEqual(coerced.warnings, ["`limit` was read as a number."])
    }

    /// In the MODERN era the spec MIRRORS an `x-mcp-header` parameter into its header — the body
    /// keeps it, and a server rejects a request whose header is not the body's value (2026-07-28,
    /// Streamable HTTP, "Custom Headers from Tool Parameters"). The body value is converted by its
    /// declared type like any other, and the header spells the converted value.
    ///
    /// RED until 2026-10-28: the value was MOVED out of the body.
    func testInTheModernEraAHeaderParameterIsMirroredIntoItsHeaderAndKeptInTheBody() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let limit = try MCPHeaderParam.make(argumentPath: ["limit"], rawName: "Limit")
        let coerced = try coerce(
            ["account": "X1", "limit": "10", "ticker": "SBER"], ["limit": JSONSchema.integer()],
            headers: [account, limit], era: .modern)
        XCTAssertEqual(coerced.arguments, .object([
            "account": .string("X1"), "limit": .int(10), "ticker": .string("SBER"),
        ]))
        XCTAssertEqual(coerced.headerParameters, ["Mcp-Param-Account": "X1", "Mcp-Param-Limit": "10"])
        XCTAssertEqual(coerced.warnings, ["`limit` was read as a number."])
    }

    /// The spec's own table: a parameter whose value is `null` sends no header — the body keeps
    /// the `null` — and one not in the arguments sends none either.
    ///
    /// RED until 2026-10-28: a `null` failed the call as "not a single value".
    func testANullHeaderParameterSendsNoHeaderAndStaysInTheBody() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let coerced = try coerce(["account": NSNull(), "ticker": "SBER"], headers: [account], era: .modern)
        XCTAssertEqual(coerced.arguments, .object(["account": .null, "ticker": .string("SBER")]))
        XCTAssertTrue(coerced.headerParameters.isEmpty)
    }

    /// An empty string is a value PROVIDED — the spec's table: "Parameter value provided | Client
    /// MUST include the header", and "Client omits header but value is in body | Non-conforming
    /// client | Server MUST reject the request" — so the modern split mirrors it as an empty
    /// header beside the body's empty string. The legacy era has no header channel and sends it
    /// in the body alone. A `null` and an absent value (above) are the cases that send none.
    func testAnEmptyHeaderParameterIsAValueProvidedAndIsMirrored() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let modern = try coerce(["account": ""], headers: [account], era: .modern)
        XCTAssertEqual(modern.headerParameters, ["Mcp-Param-Account": ""])
        XCTAssertEqual(modern.arguments, .object(["account": .string("")]))
        let legacy = try coerce(["account": ""], headers: [account], era: .legacy)
        XCTAssertTrue(legacy.headerParameters.isEmpty)
        XCTAssertEqual(legacy.arguments, .object(["account": .string("")]))
    }

    /// The split names the era it was decided for exactly when the tool's schema carries
    /// `x-mcp-header` (`callShapeDependsOnEra`) — here a tool with a header parameter; a
    /// legacy-listed one with none is the next test — and `nil` otherwise, so a session in
    /// another era refuses only the calls whose shape it changes.
    func testTheSplitNamesItsEraOnlyWhenTheToolDeclaresAHeader() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        for era in MCPProtocolEra.allCases {
            XCTAssertNil(try coerce(["ticker": "SBER"], era: era).era, "\(era): nothing depends on the era")
            XCTAssertEqual(try coerce(["ticker": "SBER"], headers: [account], era: era).era, era)
            XCTAssertEqual(try coerce(["account": "X1"], headers: [account], era: era).era, era)
        }
    }

    /// A tool listed in a LEGACY session with an `x-mcp-header` annotation carries no header
    /// parameter — the keyword is the modern revision's — and its call is still assembled for its
    /// era: the split names `.legacy`, so a session that has since moved to the modern era refuses
    /// the body-only call rather than send one a conforming server rejects.
    ///
    /// RED until 2026-10-28: the era was named only for a tool with header parameters.
    func testALegacyListedHeaderToolsCallNamesItsEra() throws {
        let coerced = try coerce(["account": "X1"], dependsOnEra: true, era: .legacy)
        XCTAssertEqual(coerced.era, .legacy)
        XCTAssertTrue(coerced.headerParameters.isEmpty)
        XCTAssertEqual(coerced.arguments, .object(["account": .string("X1")]))
        XCTAssertNil(try coerce(["account": "X1"], dependsOnEra: false, era: .legacy).era,
                     "a tool called the same in both eras names none")
    }

    /// Every value the spec's Value Encoding sends through the sentinel is mirrored: a line or
    /// paragraph separator, NEL, a ZWNJ inside a Persian name — non-ASCII — a space at either end,
    /// a tab. Nothing that can be sent is refused; the card spells each one out
    /// (`MCPApprovalSurfaceTests`), and the transport encodes it (`StreamableHTTPTransport`).
    ///
    /// RED until 2026-10-28: U+2028, U+2029, NEL and the ZWNJ were refused (corrected by the
    /// spec's own Value Encoding).
    func testEveryValueTheSpecEncodesIsMirroredNotRefused() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        for value in ["alex\u{2028}Mcp-Param-Locale: en", "a\u{2029}b", "x\u{0085}y", "نام\u{200C}خانوادگی",
                      " padded ", "Zürich", "=?base64?literal?="] {
            let coerced = try coerce(["account": value], headers: [account], era: .modern)
            XCTAssertEqual(coerced.headerParameters, ["Mcp-Param-Account": value], value)
            XCTAssertEqual(coerced.arguments, .object(["account": .string(value)]), value)
        }
    }

    /// "Integer values MUST be within the safe range for JavaScript (−2⁵³+1 to 2⁵³−1)": an integer
    /// mirrored into a header outside it cannot be sent as the spec requires, so the call is
    /// refused, naming the property — at either bound, and for an integral double past it. The
    /// bounds themselves go out. The legacy era has no header, and sends the number in the body.
    ///
    /// RED until 2026-10-28: no bound was read.
    func testAnIntegerOutsideTheSafeRangeIsRefused() throws {
        let n = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        let property = ["n": JSONSchema.integer()]
        for value: Any in [9_007_199_254_740_992, -9_007_199_254_740_992, Int.max, 1e20, -1e300] {
            XCTAssertThrowsError(try coerce(["n": value], property, headers: [n]), "\(value)") {
                XCTAssertEqual($0 as? MCPArgumentCoercion.Failure, .headerValueOutsideSafeIntegerRange(argument: "n"))
            }
            XCTAssertNoThrow(try coerce(["n": value], property, headers: [n], era: .legacy), "\(value): the legacy body")
        }
        for value in [9_007_199_254_740_991, -9_007_199_254_740_991, 0] {
            XCTAssertEqual(try coerce(["n": value], property, headers: [n]).headerParameters, ["Mcp-Param-N": String(value)])
        }
        XCTAssertTrue(MCPArgumentCoercion.Failure.headerValueOutsideSafeIntegerRange(argument: "n").message
            .contains("-9007199254740991 and 9007199254740991"))
    }

    /// A NESTED header parameter is read at its path in the body — after the body's own
    /// conversion, so an object sent as JSON text is read as the object — and mirrored; the body
    /// is sent as it is. "If no value is present at that path in the call arguments, the header
    /// is omitted": a missing step, a step that is not an object, or a `null` sends none. A value
    /// at the path that no header can spell refuses the call, naming the path.
    ///
    /// RED until 2026-10-28: only a top-level property was read.
    func testANestedHeaderParameterIsMirroredFromItsPath() throws {
        let region = try MCPHeaderParam.make(argumentPath: ["target", "region"], rawName: "Region")
        let properties = ["target": JSONSchema.object("t")]
        let nested = try coerce(["target": ["region": "eu", "zone": 1], "q": "x"], properties, headers: [region])
        XCTAssertEqual(nested.headerParameters, ["Mcp-Param-Region": "eu"])
        XCTAssertEqual(nested.arguments, .object([
            "target": .object(["region": .string("eu"), "zone": .int(1)]), "q": .string("x"),
        ]))
        let asText = try coerce(["target": #"{"region":"us"}"#], properties, headers: [region])
        XCTAssertEqual(asText.headerParameters, ["Mcp-Param-Region": "us"], "read in the converted body")

        for (label, args) in [
            ("no target", ["q": "x"] as [String: Any]),
            ("no region", ["target": ["zone": 1]]),
            ("target is text", ["target": "eu"]),
            ("target is a list", ["target": [["region": "eu"]]]),
            ("target is null", ["target": NSNull()]),
            ("region is null", ["target": ["region": NSNull()]]),
        ] {
            XCTAssertEqual(try coerce(args, properties, headers: [region]).headerParameters, [:], label)
        }
        XCTAssertThrowsError(try coerce(["target": ["region": ["eu"]]], properties, headers: [region])) {
            XCTAssertEqual($0 as? MCPArgumentCoercion.Failure, .headerValueNotAScalar(argument: "target.region"))
        }
        XCTAssertEqual(try coerce(["target": ["region": "eu"]], properties, headers: [region], era: .legacy)
            .headerParameters, [:], "the legacy era sends it in the body alone")
    }

    /// In the legacy era the same value is an ordinary body value: there is no header for it to
    /// break, and the approval card spells the separator out.
    func testTheLegacyEraSendsALineSeparatorInTheBody() throws {
        let account = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account")
        let coerced = try coerce(["account": "alex\u{2028}x"], headers: [account], era: .legacy)
        XCTAssertEqual(coerced.arguments, .object(["account": .string("alex\u{2028}x")]))
        XCTAssertTrue(coerced.headerParameters.isEmpty)
    }

    // MARK: - The arms a well-formed call never reaches

    /// Each of these is a value the SERVER will refuse in its own words if the coercion lets
    /// it through unchanged, which is the right outcome — this app does not get to decide a
    /// foreign schema's semantics. What it must not do is mangle the value on the way.

    func testAListOrAnObjectWhereTextIsExpectedIsPassedThrough() throws {
        let property = ["ticker": JSONSchema.string()]
        XCTAssertEqual(
            try coerce(["ticker": ["a", "b"]], property).arguments,
            .object(["ticker": .array([.string("a"), .string("b")])]))
        XCTAssertEqual(
            try coerce(["ticker": ["k": "v"]], property).arguments,
            .object(["ticker": .object(["k": .string("v")])]))
    }

    func testAListThatIsAlreadyAListIsNotWrappedAgain() throws {
        let property = ["paths": JSONSchema.array(items: JSONSchema.string())]
        let coerced = try coerce(["paths": ["src", "docs"]], property)
        XCTAssertEqual(coerced.arguments, .object(["paths": .array([.string("src"), .string("docs")])]))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    func testAnUnparseableIntegerIsLeftForTheServer() throws {
        let property = ["limit": JSONSchema.integer()]
        for sent in ["ten", "", "12abc"] {
            XCTAssertEqual(
                try coerce(["limit": sent], property).arguments,
                .object(["limit": .string(sent)]), sent)
        }
        // A boolean is not a number in either direction.
        XCTAssertEqual(
            try coerce(["limit": true], property).arguments, .object(["limit": .bool(true)]))
        XCTAssertEqual(
            try coerce(["limit": ["a"]], property).arguments,
            .object(["limit": .array([.string("a")])]))
    }

    func testBooleansArriveFromEverySpellingAndNoOther() throws {
        let property = ["flag": JSONSchema.boolean()]
        // Already a boolean: through, unreported.
        let already = try coerce(["flag": false], property)
        XCTAssertEqual(already.arguments, .object(["flag": .bool(false)]))
        XCTAssertTrue(already.warnings.isEmpty)
        // The two integers a boolean is commonly written as, and no others.
        XCTAssertEqual(try coerce(["flag": 1], property).arguments, .object(["flag": .bool(true)]))
        XCTAssertEqual(try coerce(["flag": 0], property).arguments, .object(["flag": .bool(false)]))
        XCTAssertEqual(try coerce(["flag": 2], property).arguments, .object(["flag": .int(2)]))
        XCTAssertEqual(
            try coerce(["flag": ["a"]], property).arguments,
            .object(["flag": .array([.string("a")])]))
    }

    func testAFalseHeaderValueIsSpelledFalse() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["n"], rawName: "N")
        XCTAssertEqual(
            try coerce(["n": false], headers: [param]).headerParameters, ["Mcp-Param-N": "false"])
    }

    // MARK: - What is already right is left alone

    /// The coercion is a repair, not a rewrite: a value that already matches its declared type
    /// passes through untouched and reports NOTHING, because a warning on a correct argument
    /// would teach the model to change what was right.
    func testAValueThatAlreadyMatchesItsTypeIsUntouchedAndUnreported() throws {
        let number = JSONSchemaProperty(
            type: "number", description: nil, properties: nil, required: nil,
            items: nil, enumValues: nil)
        let coerced = try coerce(
            ["text": "already text", "shape": ["a": 1], "count": 2.5, "flag": true],
            [
                "text": JSONSchema.string(),
                "shape": JSONSchema.object("s"),
                "count": number,
                "flag": JSONSchema.boolean(),
            ])

        XCTAssertTrue(coerced.warnings.isEmpty, "\(coerced.warnings)")
        XCTAssertEqual(coerced.arguments.objectValue?["text"], .string("already text"))
        XCTAssertEqual(coerced.arguments.objectValue?["flag"], .bool(true))
        XCTAssertNotNil(coerced.arguments.objectValue?["shape"]?.objectValue)
    }

    /// A string that is not a JSON document stays a string under an `object` parameter: the
    /// server is the one that decides it is wrong, and guessing here would send a different
    /// value than the model wrote.
    func testAStringThatIsNotADocumentStaysAStringUnderAnObjectParameter() throws {
        let coerced = try coerce(
            ["shape": "not a document"], ["shape": JSONSchema.object("s")])

        XCTAssertEqual(coerced.arguments.objectValue?["shape"], .string("not a document"))
        XCTAssertTrue(coerced.warnings.isEmpty)
    }

    // MARK: - Enum and numeric bounds (D-M5)

    /// A string parameter with an `enum` or `const` list refuses a value outside the list before
    /// any approval card or outbound request, naming the allowed values so the model can correct
    /// the call in one turn.
    func testAnEnumViolationIsRefusedWithTheAllowedValues() throws {
        let formatProp = JSONSchema.string(enumValues: ["png", "jpg", "svg"])
        XCTAssertEqual(
            try coerce(["format": "png"], ["format": formatProp]).arguments,
            .object(["format": .string("png")]))

        XCTAssertThrowsError(try coerce(["format": "bmp"], ["format": formatProp])) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutsideEnum(argument: "format", value: "bmp", allowed: ["png", "jpg", "svg"]))
            XCTAssertEqual(
                (error as? MCPArgumentCoercion.Failure)?.message,
                #"Invalid value "bmp" for `format`. Allowed values: png, jpg, svg."#)
        }

        // Array items and nested object leaves carrying an enum are checked too.
        let tagsProp = JSONSchema.array(items: JSONSchema.string(enumValues: ["ui", "api"]))
        XCTAssertEqual(
            try coerce(["tags": ["ui", "api"]], ["tags": tagsProp]).arguments,
            .object(["tags": .array([.string("ui"), .string("api")])]))
        XCTAssertThrowsError(try coerce(["tags": ["ui", "db"]], ["tags": tagsProp])) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutsideEnum(argument: "tags", value: "db", allowed: ["ui", "api"]))
        }

        let nestedSchema = try MCPSchemaProjection.project(.object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "state": .object([
                            "type": .string("string"),
                            "enum": .array([.string("open"), .string("closed")]),
                        ]),
                    ]),
                ]),
            ]),
        ]))
        let nestedProps = try XCTUnwrap(nestedSchema.properties)
        XCTAssertEqual(
            try coerce(["filter": ["state": "open"]], nestedProps).arguments,
            .object(["filter": .object(["state": .string("open")])]))
        XCTAssertThrowsError(try coerce(["filter": ["state": "merged"]], nestedProps)) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutsideEnum(argument: "filter.state", value: "merged", allowed: ["open", "closed"]))
        }

        // A `const` string in the raw schema is validated as a one-value enum.
        let constRaw: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "version": .object([
                    "type": .string("string"),
                    "const": .string("v2"),
                ]),
            ]),
        ])
        let constDescriptor = MCPToolDescriptor(
            originalName: "x", modelFacingName: "mcp__folio__x", displayDescription: "x",
            inputSchema: try MCPSchemaProjection.project(constRaw), outputSchema: nil,
            annotations: .specDefaults, headerParams: [], callShapeDependsOnEra: false,
            pinHash: "hash", rawTool: .object(["inputSchema": constRaw]),
            strippedHiddenCharacters: false)
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["version": "v1"], descriptor: constDescriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutsideEnum(argument: "version", value: "v1", allowed: ["v2"]))
        }
    }

    /// Numeric `minimum`, `maximum`, `exclusiveMinimum`, and `exclusiveMaximum` bounds refuse
    /// out-of-range numbers after coercion (including `"0"` coerced to `0`), naming the bound.
    func testANumericBoundViolationIsRefusedWithTheBound() throws {
        let rawSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "scale": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(4),
                ]),
                "ratio": .object([
                    "type": .string("number"),
                    "exclusiveMinimum": .double(0.25),
                    "exclusiveMaximum": .int(1),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "exclusiveMinimum": .int(1),
                ]),
                "cap": .object([
                    "type": .string("integer"),
                    "maximum": .int(10),
                    "exclusiveMaximum": .int(12),
                ]),
                "scores": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(10),
                    ]),
                ]),
                "limits": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "page": .object([
                            "type": .string("integer"),
                            "minimum": .int(1),
                        ]),
                    ]),
                ]),
                "contradictoryOrder": .object([
                    "type": .string("integer"),
                    "minimum": .int(10),
                    "maximum": .int(5),
                ]),
                "contradictoryEqual": .object([
                    "type": .string("integer"),
                    "minimum": .int(5),
                    "exclusiveMaximum": .int(5),
                ]),
            ]),
        ])
        let projected = try MCPSchemaProjection.project(rawSchema)
        let descriptor = MCPToolDescriptor(
            originalName: "x", modelFacingName: "mcp__folio__x", displayDescription: "x",
            inputSchema: projected, outputSchema: nil, annotations: .specDefaults,
            headerParams: [], callShapeDependsOnEra: false,
            pinHash: "hash", rawTool: .object(["inputSchema": rawSchema]),
            strippedHiddenCharacters: false)

        // Exact boundary values are accepted for inclusive bounds.
        XCTAssertEqual(
            try MCPArgumentCoercion.coerce(args: ["scale": 1], descriptor: descriptor, era: .modern).arguments,
            .object(["scale": .int(1)]))
        XCTAssertEqual(
            try MCPArgumentCoercion.coerce(args: ["scale": "4"], descriptor: descriptor, era: .modern).arguments,
            .object(["scale": .int(4)]))

        // Out-of-range values (including coerced strings) are refused with the exact bound.
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["scale": "0"], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "scale", value: "0", requirement: "between 1 and 4"))
            XCTAssertEqual(
                (error as? MCPArgumentCoercion.Failure)?.message,
                "`scale` must be between 1 and 4 (got 0).")
        }
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["scale": 5], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "scale", value: "5", requirement: "between 1 and 4"))
        }

        // Exclusive bounds reject the boundary value itself and accept an interior value.
        XCTAssertEqual(
            try MCPArgumentCoercion.coerce(args: ["ratio": 0.5], descriptor: descriptor, era: .modern).arguments,
            .object(["ratio": .double(0.5)]))
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["ratio": 0.25], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "ratio", value: "0.25", requirement: "greater than 0.25 and less than 1"))
        }
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["ratio": 1.0], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "ratio", value: "1", requirement: "greater than 0.25 and less than 1"))
        }

        // Combined inclusive + exclusive bounds pick the tighter bound.
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["offset": 1], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "offset", value: "1", requirement: "greater than 1"))
        }
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["cap": 11], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "cap", value: "11", requirement: "at most 10"))
        }

        // Array items and nested object leaves enforce their numeric bounds too.
        XCTAssertEqual(
            try MCPArgumentCoercion.coerce(
                args: ["scores": [5], "limits": ["page": 2]], descriptor: descriptor, era: .modern
            ).arguments,
            .object(["scores": .array([.int(5)]), "limits": .object(["page": .int(2)])]))
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["scores": [15]], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "scores", value: "15", requirement: "between 1 and 10"))
        }
        XCTAssertThrowsError(
            try MCPArgumentCoercion.coerce(args: ["limits": ["page": 0]], descriptor: descriptor, era: .modern)
        ) { error in
            XCTAssertEqual(
                error as? MCPArgumentCoercion.Failure,
                .valueOutOfRange(argument: "limits.page", value: "0", requirement: "at least 1"))
        }

        // Contradictory bounds in the server schema are ignored rather than rejecting every call.
        XCTAssertEqual(
            try MCPArgumentCoercion.coerce(
                args: ["contradictoryOrder": 7, "contradictoryEqual": 5],
                descriptor: descriptor, era: .modern
            ).arguments,
            .object(["contradictoryOrder": .int(7), "contradictoryEqual": .int(5)]))
    }

}
