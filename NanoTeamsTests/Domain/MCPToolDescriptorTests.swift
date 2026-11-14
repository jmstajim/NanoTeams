import XCTest

@testable import NanoTeams

/// What a server says about its own tools, and what this client does with the claim. The
/// defaults are the security content: a tool that says nothing is assumed to write, to
/// destroy and to reach the open world.
final class MCPToolDescriptorTests: XCTestCase {

    // MARK: - Annotations

    func testAbsentAnnotationsMeanTheSpecDefaults() {
        let none = MCPToolAnnotations(raw: nil)
        XCTAssertEqual(none, .specDefaults)
        XCTAssertFalse(none.readOnlyHint)
        XCTAssertTrue(none.destructiveHint)
        XCTAssertFalse(none.idempotentHint)
        XCTAssertTrue(none.openWorldHint)
    }

    func testAnnotationsThatAreNotAnObjectFallBackToTheDefaults() {
        XCTAssertEqual(MCPToolAnnotations(raw: .string("read-only, trust me")), .specDefaults)
        XCTAssertEqual(MCPToolAnnotations(raw: .array([.bool(true)])), .specDefaults)
        XCTAssertEqual(MCPToolAnnotations(raw: .null), .specDefaults)
    }

    func testReadsTheFieldsAServerActuallySent() {
        let annotations = MCPToolAnnotations(raw: .object([
            "title": .string("Get portfolio"),
            "readOnlyHint": .bool(true),
            "destructiveHint": .bool(false),
            "idempotentHint": .bool(true),
            "openWorldHint": .bool(false),
        ]))
        XCTAssertEqual(annotations.title, "Get portfolio")
        XCTAssertTrue(annotations.readOnlyHint)
        XCTAssertFalse(annotations.destructiveHint)
        XCTAssertTrue(annotations.idempotentHint)
        XCTAssertFalse(annotations.openWorldHint)
    }

    /// A string `"false"` is not a boolean. Reading it as one would let a server disable a
    /// guard through a type confusion — and `destructiveHint` is the guard that matters.
    func testAFieldOfTheWrongTypeDoesNotLowerFriction() {
        let confused = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .string("true"),
            "destructiveHint": .string("false"),
            "openWorldHint": .int(0),
        ]))
        XCTAssertFalse(confused.readOnlyHint)
        XCTAssertTrue(confused.destructiveHint)
        XCTAssertTrue(confused.openWorldHint)
    }

    /// The title reaches a person's eyes, so it goes through the same sanitizer as every other
    /// server string — a title with a zero-width payload is a title that reads differently in
    /// two places.
    func testTitleIsSanitisedAndABlankOneIsDropped() {
        XCTAssertEqual(MCPToolAnnotations(raw: .object(["title": .string("a\u{200B}b\nc")])).title, "ab c")
        XCTAssertNil(MCPToolAnnotations(raw: .object(["title": .string("   ")])).title)
        XCTAssertNil(MCPToolAnnotations(raw: .object(["title": .int(3)])).title)
    }

    // MARK: - What a person reads (F31, F54)

    /// A server that says nothing about a tool claimed nothing: the spec's defaults are what the
    /// policy assumes, and they are shown as that — never as the server's claims.
    ///
    /// RED until 2026-09-24: all three were shown as claims, under "Claims, not facts".
    func testAbsentAnnotationsAreLabelledAsDefaultsNotClaims() {
        let chips = MCPToolAnnotations(raw: nil).chips
        XCTAssertEqual(chips.claimed, [])
        XCTAssertTrue(chips.statedNothing)
        XCTAssertEqual(chips.assumed, ["writes", "destructive", "open world"])
        XCTAssertEqual(chips.assumedLine, "The server claimed nothing — treated as: writes, destructive, open world")
        XCTAssertFalse(chips.isContradictory)
        XCTAssertNil(chips.contradictionNote)
        XCTAssertEqual(MCPToolAnnotations.specDefaults.chips, chips)
    }

    /// A tool that claims read-only AND destructive contradicts itself, and the policy counts
    /// the harsher claim — that pair is exactly why the call is on the card. Both chips show,
    /// and the pair is named.
    ///
    /// RED until 2026-09-24: the chips read "read-only" alone.
    func testContradictoryReadOnlyDestructiveShowsDestructiveChip() {
        let chips = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(true),
        ])).chips
        XCTAssertEqual(chips.claimed.map(\.label), ["read-only", "destructive"])
        XCTAssertEqual(chips.assumed, ["open world"])
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: open world")
        XCTAssertTrue(chips.isContradictory)
        XCTAssertEqual(
            chips.contradictionNote,
            "Read-only and destructive at once — the destructive reading is the one that counts.")
    }

    /// The spec reads `destructiveHint` only when `readOnlyHint` is false: its `true` default is
    /// the default for a tool that WRITES. A server that states read-only and leaves destructive
    /// out — the usual pair; GitHub's MCP server marks its read tools exactly so — has made no
    /// destructive claim, and none is assumed for it: destructive reads false and stays NOT
    /// stated, shown neither as a claim nor as an assumption. Nothing is contradicted, so no
    /// note.
    ///
    /// RED until 2026-09-24: destructive read `true` from the default. A trusted server's read
    /// tools never cleared a call, the card printed "treated as: destructive", and the model was
    /// told the server marked the tool read-only and destructive at once.
    func testAStatedReadOnlyClaimIsNotReadAsDestructive() {
        let annotations = MCPToolAnnotations(raw: .object(["readOnlyHint": .bool(true)]))
        XCTAssertTrue(annotations.readOnlyHint)
        XCTAssertFalse(annotations.destructiveHint)
        XCTAssertEqual(annotations.statedHints, [.readOnly], "destructive does not apply — it is not stated")

        let chips = annotations.chips
        XCTAssertEqual(chips.claimed.map(\.label), ["read-only"])
        XCTAssertEqual(chips.assumed, ["open world"], "nothing is assumed about destructive")
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: open world")
        XCTAssertFalse(chips.isContradictory)
        XCTAssertNil(chips.contradictionNote)
    }

    /// A read-only claim stated FALSE, or no read-only claim at all, is a tool that writes, and
    /// the destructive default is exactly the spec's default for it.
    func testAToolThatDoesNotStateReadOnlyKeepsTheDestructiveDefault() {
        let writes = MCPToolAnnotations(raw: .object(["readOnlyHint": .bool(false)]))
        XCTAssertFalse(writes.readOnlyHint)
        XCTAssertTrue(writes.destructiveHint)
        XCTAssertEqual(writes.statedHints, [.readOnly])
        XCTAssertEqual(writes.chips.claimed.map(\.label), ["writes"])
        XCTAssertEqual(writes.chips.assumed, ["destructive", "open world"])

        let silent = MCPToolAnnotations(raw: .object(["openWorldHint": .bool(false)]))
        XCTAssertTrue(silent.destructiveHint)
        XCTAssertEqual(silent.chips.assumed, ["writes", "destructive"])
    }

    /// An annotations object with nothing in it says what an absent one says.
    func testAnEmptyAnnotationsObjectMeansTheSpecDefaults() {
        XCTAssertEqual(MCPToolAnnotations(raw: .object([:])), .specDefaults)
        XCTAssertEqual(MCPToolAnnotations(raw: .object(["title": .string("T")])).statedHints, [])
    }

    /// The reading is the TYPE's, not the decoder's: a value built in code that states read-only
    /// and nothing about destruction reads exactly as one read from a server — every consumer
    /// (the policy, the chips, the editor's runs-unattended answer) reads the same four booleans.
    ///
    /// RED until 2026-09-24 (as a value built with `statedHints: [.readOnly]`, the parameter the
    /// designated initializer's `stated:` replaced): destructive kept the `true` it was given.
    func testAValueBuiltInCodeReadsAStatedReadOnlyTheSameWay() {
        let built = MCPToolAnnotations(title: nil, stated: [.readOnly: true])
        XCTAssertEqual(built, MCPToolAnnotations(raw: .object(["readOnlyHint": .bool(true)])))
        XCTAssertFalse(built.destructiveHint)
        XCTAssertEqual(built.statedHints, [.readOnly])
    }

    /// Every combination a server can send — each hint absent, stated true or stated false —
    /// read through the one designated initializer: a hint left out holds its spec default, the
    /// destructive default does not apply beside a stated read-only, and the contradiction is
    /// exactly the two STATED true.
    func testEveryCombinationAServerCanSendReadsOneWay() {
        let choices: [Bool?] = [nil, true, false]
        var seen = 0
        for readOnly in choices {
            for destructive in choices {
                for idempotent in choices {
                    for openWorld in choices {
                        var stated: [MCPToolAnnotations.Hint: Bool] = [:]
                        stated[.readOnly] = readOnly
                        stated[.destructive] = destructive
                        stated[.idempotent] = idempotent
                        stated[.openWorld] = openWorld
                        let a = MCPToolAnnotations(title: nil, stated: stated)
                        let label = "\(stated)"
                        seen += 1
                        XCTAssertEqual(a.statedHints, Set(stated.keys), label)
                        XCTAssertEqual(a.readOnlyHint, readOnly ?? false, label)
                        XCTAssertEqual(a.destructiveHint, destructive ?? (readOnly != true), label)
                        XCTAssertEqual(a.idempotentHint, idempotent ?? false, label)
                        XCTAssertEqual(a.openWorldHint, openWorld ?? true, label)
                        XCTAssertEqual(a.chips.isContradictory, readOnly == true && destructive == true, label)
                        XCTAssertEqual(a.chips.contradictionNote != nil, a.chips.isContradictory, label)
                        XCTAssertEqual(
                            a.chips.assumed.contains("destructive"), destructive == nil && readOnly != true, label)
                        // One chip per STATED hint, in the spec's order — a hint stated false
                        // is a claim too — and the lead says "claimed nothing" only when
                        // nothing was stated.
                        XCTAssertEqual(
                            a.chips.claimed.map(\.hint),
                            MCPToolAnnotations.Hint.allCases.filter { stated[$0] != nil }, label)
                        XCTAssertEqual(a.chips.statedNothing, stated.isEmpty, label)
                        if let line = a.chips.assumedLine {
                            XCTAssertEqual(line.hasPrefix("The server claimed nothing"), stated.isEmpty, label)
                        }
                        XCTAssertEqual(a, MCPToolAnnotations(raw: .object(stated.reduce(into: [:]) {
                            $0[$1.key.rawValue + "Hint"] = .bool($1.value)
                        })), label)
                    }
                }
            }
        }
        XCTAssertEqual(seen, 81, "anti-vacuum: every combination walked")
    }

    /// A read-only claim the server backs with `destructiveHint: false` is the one pair the
    /// policy's trusted bypass reads, and it needs no note. Both halves are the server's
    /// claims, and both are shown as such.
    func testAReadOnlyClaimThatAlsoStatesNotDestructiveCarriesNoNote() {
        let chips = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false),
        ])).chips
        XCTAssertEqual(chips.claimed.map(\.label), ["read-only", "not destructive"])
        XCTAssertFalse(chips.isContradictory)
        XCTAssertNil(chips.contradictionNote)
    }

    /// A tool that states it writes contradicts nothing, whether destructive was stated or
    /// assumed.
    func testAWritingToolCarriesNoContradictionNote() {
        for raw: JSONValue in [
            .object(["readOnlyHint": .bool(false)]),
            .object(["readOnlyHint": .bool(false), "destructiveHint": .bool(true)]),
        ] {
            let chips = MCPToolAnnotations(raw: raw).chips
            XCTAssertFalse(chips.isContradictory, "\(raw)")
            XCTAssertNil(chips.contradictionNote, "\(raw)")
        }
    }

    /// Every hint stated: nothing is assumed, and every statement is shown — the ones stated
    /// `false` included. The one that names a risk (it writes) is drawn in the caution tone;
    /// the three that lower concern are neutral.
    ///
    /// RED until 2026-10-28: the chips read "writes · idempotent" — the server's "not
    /// destructive" and "closed world" were shown nowhere.
    func testEveryHintStatedLeavesNothingAssumedAndShowsEveryStatement() {
        let chips = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .bool(false), "destructiveHint": .bool(false),
            "idempotentHint": .bool(true), "openWorldHint": .bool(false),
        ])).chips
        XCTAssertEqual(chips.claimed.map(\.label), ["writes", "not destructive", "idempotent", "closed world"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.caution, .neutral, .neutral, .neutral])
        XCTAssertEqual(chips.assumed, [])
        XCTAssertNil(chips.assumedLine)
        XCTAssertFalse(chips.isContradictory)
        XCTAssertNil(chips.contradictionNote)

        let reading = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false),
            "idempotentHint": .bool(false), "openWorldHint": .bool(true),
        ])).chips
        XCTAssertEqual(reading.claimed.map(\.label), ["read-only", "not destructive", "not idempotent", "open world"])
        XCTAssertEqual(reading.claimed.map(\.tone), [.neutral, .neutral, .neutral, .caution])
        XCTAssertNil(reading.assumedLine)
    }

    /// Only a boolean under a hint's own key is a statement — the same rule that keeps a
    /// string "false" from lowering friction keeps it from reading as a claim.
    func testOnlyAHintOfTheRightTypeCountsAsStated() {
        let confused = MCPToolAnnotations(raw: .object([
            "readOnlyHint": .string("true"), "openWorldHint": .int(0),
        ]))
        XCTAssertEqual(confused.statedHints, [])
        XCTAssertEqual(
            MCPToolAnnotations(raw: .object(["idempotentHint": .bool(false)])).statedHints, [.idempotent])
        XCTAssertEqual(MCPToolAnnotations.specDefaults.statedHints, [])
    }

    /// A value built in code states exactly the hints it is given, each shown as a claim.
    /// (Moved off the four-`Bool` initializer that marked every hint stated, which nothing in
    /// the app called — deleted 2026-10-28.)
    func testEveryHintGivenInCodeIsStated() {
        let spelled = MCPToolAnnotations(title: nil, stated: [
            .readOnly: true, .destructive: false, .idempotent: true, .openWorld: false,
        ])
        XCTAssertEqual(spelled.statedHints, Set(MCPToolAnnotations.Hint.allCases))
        XCTAssertEqual(spelled.chips.claimed.map(\.label), ["read-only", "not destructive", "idempotent", "closed world"])
        XCTAssertEqual(spelled.chips.assumed, [])
    }

    // MARK: - Every stated hint is shown as a claim (2026-10-28)

    private func chips(_ sent: [String: JSONValue]) -> MCPAnnotationChips {
        MCPToolAnnotations(raw: .object(sent)).chips
    }

    /// `{"destructiveHint": false}` is the usual way to mark a write tool that destroys
    /// nothing. It is the server's claim, and it is shown as one — in the neutral tone, since it
    /// LOWERS concern — while what it left out is "not stated", never "claimed nothing".
    ///
    /// RED until 2026-10-28: no chip was drawn, and the card read "The server claimed nothing —
    /// treated as: writes, open world" — the claim appeared nowhere and the lead denied it.
    func testAStatedNotDestructiveIsShownAsTheServersClaim() {
        let chips = chips(["destructiveHint": .bool(false)])
        XCTAssertEqual(chips.claimed.map(\.label), ["not destructive"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.neutral])
        XCTAssertEqual(chips.assumed, ["writes", "open world"])
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: writes, open world")
        XCTAssertFalse(chips.statedNothing)
        XCTAssertNil(chips.contradictionNote)
    }

    /// RED until 2026-10-28: "The server claimed nothing — treated as: writes, destructive".
    func testAStatedClosedWorldIsShownAsTheServersClaim() {
        let chips = chips(["openWorldHint": .bool(false)])
        XCTAssertEqual(chips.claimed.map(\.label), ["closed world"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.neutral])
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: writes, destructive")
    }

    /// A claim that names a risk is drawn in the caution tone: annotations only ever RAISE
    /// friction, so the policy takes it at its word.
    func testAStatedWritesIsACautionClaim() {
        let chips = chips(["readOnlyHint": .bool(false)])
        XCTAssertEqual(chips.claimed.map(\.label), ["writes"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.caution])
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: destructive, open world")
    }

    func testAStatedIdempotentIsANeutralClaimBesideEveryDefault() {
        let chips = chips(["idempotentHint": .bool(true)])
        XCTAssertEqual(chips.claimed.map(\.label), ["idempotent"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.neutral])
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: writes, destructive, open world")
    }

    /// An empty annotations object states nothing: no chip, and the one lead that says so.
    func testAnEmptyAnnotationsObjectClaimsNothing() {
        let chips = chips([:])
        XCTAssertEqual(chips.claimed, [])
        XCTAssertTrue(chips.statedNothing)
        XCTAssertEqual(chips.assumedLine, "The server claimed nothing — treated as: writes, destructive, open world")
    }

    /// The stated pair: both claims shown, the reassuring one neutral and the one that names
    /// the risk in the caution tone, and the contradiction named.
    func testTheStatedPairShowsBothClaimsInTheirOwnTones() {
        let chips = chips(["readOnlyHint": .bool(true), "destructiveHint": .bool(true)])
        XCTAssertEqual(chips.claimed.map(\.label), ["read-only", "destructive"])
        XCTAssertEqual(chips.claimed.map(\.tone), [.neutral, .caution])
        XCTAssertNotNil(chips.contradictionNote)
        XCTAssertEqual(chips.assumedLine, "Not stated — treated as: open world")
    }

    /// Every hint in both polarities, one table. A chip that LOWERS concern — read-only, not
    /// destructive, idempotent, closed world — is never in the caution tone; the three that name
    /// a risk the spec's defaults assume — writes, destructive, open world — always are; "not
    /// idempotent" says a repeat is not harmless, which no policy reads, and stays neutral.
    func testEveryChipReadsAtAGlanceInItsOwnTone() {
        let table: [(MCPToolAnnotations.Hint, Bool, String, MCPAnnotationChips.Chip.Tone)] = [
            (.readOnly, true, "read-only", .neutral), (.readOnly, false, "writes", .caution),
            (.destructive, true, "destructive", .caution), (.destructive, false, "not destructive", .neutral),
            (.idempotent, true, "idempotent", .neutral), (.idempotent, false, "not idempotent", .neutral),
            (.openWorld, true, "open world", .caution), (.openWorld, false, "closed world", .neutral),
        ]
        for (hint, value, label, tone) in table {
            let chip = MCPToolAnnotations(title: nil, stated: [hint: value]).chips.claimed
            XCTAssertEqual(chip.map(\.hint), [hint], "\(hint)=\(value)")
            XCTAssertEqual(chip.map(\.label), [label], "\(hint)=\(value)")
            XCTAssertEqual(chip.map(\.tone), [tone], "\(hint)=\(value)")
        }
        XCTAssertEqual(table.count, MCPToolAnnotations.Hint.allCases.count * 2, "anti-vacuum: both polarities of every hint")
    }

    // MARK: - The note beside the claims (2026-10-28)

    /// The note that qualifies the claims rides in their row, right after the last chip — and
    /// only where there is a chip for it to qualify.
    ///
    /// RED until 2026-10-28: the approval card drew it beside the whole block, where it floated
    /// mid-card or at its far right.
    func testTheNoteRidesInTheClaimedRowAndOnlyBesideAClaim() throws {
        let claimed = chips(["readOnlyHint": .bool(true)])
        let row = try XCTUnwrap(claimed.claimedRow(note: "the server's own claim"))
        XCTAssertEqual(row.chips, claimed.claimed)
        XCTAssertEqual(row.note, "the server's own claim")
        XCTAssertNil(try XCTUnwrap(claimed.claimedRow(note: nil)).note)

        XCTAssertNil(chips([:]).claimedRow(note: "the server's own claim"), "no claim, no row, no note")
        XCTAssertNil(MCPToolAnnotations.specDefaults.chips.claimedRow(note: nil))
    }

    // MARK: - Header parameters

    /// The client owns the prefix. A server naming the header outright could write
    /// `Authorization`, or overwrite the session id it was given.
    func testHeaderParameterNamesAlwaysCarryTheClientsPrefix() throws {
        let param = try MCPHeaderParam.make(argumentPath: ["account"], rawName: "Account-Id")
        XCTAssertEqual(param.headerName, "Mcp-Param-Account-Id")
        XCTAssertEqual(param.argumentPath, ["account"])
        XCTAssertEqual(try MCPHeaderParam.make(argumentPath: ["target", "region"], rawName: "Region").argumentName,
                       "target.region", "a nested property is named by its path")
    }

    /// The name is the spec's `1*tchar` (RFC 9110 §5.1; 2026-07-28 Streamable HTTP, "Schema
    /// Extension": "MUST match HTTP field-name token syntax") — every name it accepts is accepted,
    /// whatever its length: the ABNF has no bound.
    ///
    /// RED until 2026-10-28: only letters, digits and "-" were accepted, so a spec-valid
    /// `Tenant_Id` excluded its whole tool, and so did a name past 64 characters.
    func testEveryNameTheSpecsTokenAllowsIsAccepted() throws {
        let tchar = "!#$%&'*+-.^_`|~"
        for name in ["Tenant_Id", "Region", "x1", "a.b", "A~b", tchar, "0", String(repeating: "a", count: 200)]
            + tchar.map(String.init) {
            XCTAssertEqual(try MCPHeaderParam.make(argumentPath: ["arg"], rawName: name).headerName,
                           "Mcp-Param-" + name, name)
        }
    }

    /// And every name it refuses is refused, naming the property: anything outside `tchar` — a
    /// separator, a space anywhere (nothing is trimmed away: " Tenant" is not a token), a
    /// control character, anything that is not ASCII — and the empty name ("MUST NOT be empty").
    ///
    /// RED until 2026-10-28 for a space at either end: it was trimmed, and the name taken.
    func testEveryNameTheSpecsTokenRefusesIsRefusedAndNamesTheProperty() {
        let refused = ["Authorization\r\nX-Evil: 1", "a b", "x:y", "«", " Tenant", "Tenant ", "  Tenant  ", "   ",
                       "a/b", "a(b)", "a\"b", "a,b", "a;b", "a<b>", "a=b", "a?b", "a@b", "a[b]", "a\\b", "a{b}",
                       "\t", "é", "a\u{7F}"]
        for hostile in refused {
            XCTAssertThrowsError(try MCPHeaderParam.make(argumentPath: ["arg"], rawName: hostile), hostile) { error in
                XCTAssertEqual(error as? MCPHeaderParamError, .illegalCharacters(argument: "arg"), hostile)
                XCTAssertTrue((error as? MCPHeaderParamError)?.errorDescription?.contains("arg") == true, hostile)
            }
        }
        XCTAssertThrowsError(try MCPHeaderParam.make(argumentPath: ["arg"], rawName: "")) { error in
            XCTAssertEqual(error as? MCPHeaderParamError, .emptyName(argument: "arg"))
        }
    }

    // MARK: - Descriptor

    func testDescriptorKeepsTheThreeNamesApart() {
        let descriptor = Self.makeDescriptor(
            originalName: "GetPortfolio",
            modelFacingName: "mcp__trade_room__getportfolio",
            annotations: MCPToolAnnotations(raw: .object(["title": .string("Portfolio")])))
        XCTAssertEqual(descriptor.originalName, "GetPortfolio", "the wire name is never folded")
        XCTAssertEqual(descriptor.modelFacingName, "mcp__trade_room__getportfolio")
        XCTAssertEqual(descriptor.displayTitle, "Portfolio")
        XCTAssertEqual(descriptor.id, descriptor.modelFacingName)
    }

    func testDisplayTitleFallsBackToTheServersOwnName() {
        XCTAssertEqual(Self.makeDescriptor().displayTitle, "get_metadata")
    }

    /// The server's name is foreign text: the label is built from it cleaned and on one line,
    /// and a name made of nothing a person can read falls back to the model-facing name.
    func testDisplayTitleNeverShowsTheServersRawName() {
        XCTAssertEqual(Self.makeDescriptor(originalName: "send\u{202E}eteled").displayTitle, "sendeteled")
        XCTAssertEqual(Self.makeDescriptor(originalName: "get\nmetadata\u{E0041}").displayTitle, "get metadata")
        XCTAssertEqual(
            Self.makeDescriptor(originalName: "\u{200B}\u{202E}", modelFacingName: "mcp__folio__x").displayTitle,
            "mcp__folio__x")
        // A title the server gave is already cleaned when it is read (`MCPToolAnnotations`).
        XCTAssertEqual(Self.makeDescriptor(
            originalName: "raw\u{202E}", annotations: MCPToolAnnotations(raw: .object(["title": .string("T")]))
        ).displayTitle, "T")
    }

    func testSummaryLineFlattensAMultiParagraphDescription() {
        let descriptor = Self.makeDescriptor(description: "Reads metadata.\n\nReturns a JSON blob.")
        XCTAssertEqual(descriptor.summaryLine, "Reads metadata. Returns a JSON blob.")
    }

    // MARK: - Helper

    static func makeDescriptor(
        originalName: String = "get_metadata",
        modelFacingName: String = "mcp__folio__get_metadata",
        description: String = "Reads metadata.",
        annotations: MCPToolAnnotations = .specDefaults,
        pinHash: String = "hash",
        strippedHiddenCharacters: Bool = false
    ) -> MCPToolDescriptor {
        MCPToolDescriptor(
            originalName: originalName,
            modelFacingName: modelFacingName,
            displayDescription: description,
            inputSchema: JSONSchema(type: "object"),
            outputSchema: nil,
            annotations: annotations,
            headerParams: [],
            callShapeDependsOnEra: false,
            pinHash: pinHash,
            rawTool: .object(["name": .string(originalName)]),
            strippedHiddenCharacters: strippedHiddenCharacters)
    }

}
