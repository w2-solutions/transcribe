import Foundation
import Testing
import TranscribeCore
@testable import TranscribeMCP

@Suite("MCP: transcript pages")
struct TranscriptPagerTests {
    typealias F = Fixture
    static let pageLimit = TranscriptPager.lineBudget + TranscriptPager.headerBudget   // 34,500

    /// Every page from the start, following next_cursor.
    func allPages(_ t: MCPTranscript, _ first: JSONValue = [:]) throws -> [String] {
        var pages = [try F.page(t, first)]
        while let cursor = F.nextCursor(pages.last!) {
            pages.append(try F.page(t, ["cursor": .string(cursor)]))
            if pages.count > 1_000 { Issue.record("cursor loop"); break }
        }
        return pages
    }

    @Test func threeHourTranscriptPagesStayUnderBudget() throws {
        let t = F.threeHours()
        let pages = try allPages(t)
        #expect(pages.count > 1)
        for page in pages {
            #expect(page.count <= Self.pageLimit, "\(page.count)")
            #expect(page.utf16.count <= Self.pageLimit)
        }
        // Every non-empty turn exactly once, in order, as whole lines (no turn here is long enough to split).
        let lines = pages.flatMap(F.lines)
        #expect(lines.count == t.document.turns.count)
        for (line, turn) in zip(lines, t.document.turns) {
            #expect(line.hasSuffix(": " + turn.text), "\(line)")
        }
        #expect(lines.first?.hasPrefix("[0:00:00–0:00:05] Liam: ") == true)
        #expect(pages.last?.hasSuffix("\nEnd of transcript.") == true)
    }

    @Test func everyPageRepeatsSpeakersHeader() throws {
        let pages = try allPages(F.threeHours())
        let header = """
        Team sync
        id: 7D1C0A2E-6F7B-4C55-9B1A-2E0F1D3C4B5A
        recorded: 2026-11-18T14:31:00+11:00 · length 3:00:00 · on Mac · language: en
        speakers:
        - Liam: the user; named by the user
        - Karan (auto): recognised automatically by voice; not confirmed by the user
        Names marked (auto) were recognised automatically and can be wrong.

        Turns 1–
        """
        for page in pages { #expect(page.hasPrefix(header.replacingOccurrences(of: "Turns 1–", with: "Turns "))) }
        #expect(pages[0].hasPrefix(header))
        #expect(pages[0].contains(" of 1800 (0:00:00–"))
    }

    @Test func headerIsCappedAt2500() throws {
        let many = (1...200).map { MCPSpeaker(key: "S\($0)", ordinal: $0, name: "Person number \($0) with a long name",
                                              status: .named) }
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Hello")], speakers: many, title: String(repeating: "Long title ", count: 100))
        let page = try F.page(t, [:])
        let header = page.components(separatedBy: "\n\n[")[0]
        #expect(header.count <= TranscriptPager.headerBudget)
        #expect(page.count - F.lines(page).reduce(0) { $0 + $1.count + 1 } <= TranscriptPager.headerBudget)
        #expect(page.contains("\n- …and ") && page.contains(" more\n"))
        #expect(page.contains("\n- Person number 1 with a long name: named by the user\n"))
        #expect(page.split(separator: "\n").first!.count <= TranscriptPager.titleLimit + 1)
    }

    @Test func singleHugeTurnIsSplitByWords() throws {
        let words = (0..<14_000).map { "word\($0 % 97)" }.joined(separator: " ")   // ~100k characters
        #expect(words.count > 90_000)
        let t = F.transcript([F.turn(0, "S1", 10, 710, words), F.turn(1, "S2", 711, 715, "After that.")])
        let pages = try allPages(t)
        #expect(pages.count >= 4)
        for page in pages { #expect(page.count <= Self.pageLimit) }
        let parts = pages.flatMap(F.lines).filter { $0.contains("Liam") }
        #expect(parts.count >= 4)
        #expect(pages.allSatisfy { F.lines($0).filter { $0.contains("Liam") }.count == 1 })
        #expect(parts.first?.hasPrefix("[0:10–") == true && parts.first?.contains("Liam: word0 ") == true)
        #expect(parts.dropFirst().allSatisfy { $0.contains("] Liam (continued): ") })
        // Each part's times come from its own words, and together they hold every word once.
        let stamps = parts.map { $0.prefix { $0 != "]" } }
        #expect(Set(stamps).count == stamps.count)
        let rebuilt = parts.map { $0.components(separatedBy: ": ").dropFirst().joined(separator: ": ") }.joined(separator: " ")
        #expect(rebuilt == words)
        #expect(pages.flatMap(F.lines).last == "[11:51–11:55] Karan (auto): After that.")
    }

    @Test func rangeSelectsOverlappingTurns() throws {
        let t = F.transcript([F.turn(0, "S1", 0, 10, "zero"), F.turn(1, "S2", 10, 20, "one"), F.turn(2, "S1", 20, 30, "two"),
                              F.turn(3, "S2", 30, 40, "three")])
        let page = try F.page(t, ["start_seconds": 12, "end_seconds": 30])
        #expect(F.lines(page) == ["[0:10–0:20] Karan (auto): one", "[0:20–0:30] Liam: two"])
        #expect(page.contains("Turns 2–3 of 4 (0:10–0:30 of 0:40)."))
        #expect(page.hasSuffix("\nEnd of the requested range."))
        let startOnly = try F.page(t, ["start_seconds": 25])
        #expect(F.lines(startOnly).map { $0.components(separatedBy: ": ").last! } == ["two", "three"])
        let none = try F.page(t, ["start_seconds": 50, "end_seconds": 60])
        #expect(F.lines(none).isEmpty && none.contains("No turns in the requested range."))
    }

    @Test func cursorCarriesEndOfRange() throws {
        let turns = (0..<400).map { F.turn($0, "S1", Double($0) * 10, Double($0) * 10 + 9,
                                            String(repeating: "lorem ipsum dolor sit amet ", count: 20)) }
        let t = F.transcript(turns)
        let first = try F.page(t, ["start_seconds": 5, "end_seconds": 3_000])
        let cursor = try #require(F.nextCursor(first))
        #expect(cursor.hasSuffix(".n400.e3000000"))
        let pages = try allPages(t, ["start_seconds": 5, "end_seconds": 3_000])
        let lines = pages.flatMap(F.lines)
        #expect(lines.count == 300)   // turns 0…299 start before 3,000 s
        #expect(pages.last?.hasSuffix("\nEnd of the requested range.") == true)
    }

    @Test func cursorRoundTrip() throws {
        let c = TranscriptCursor(turn: 58, word: 0, turnCount: 160)
        #expect(c.token == "v1.t58.w0.n160")
        #expect(TranscriptCursor(token: c.token) == c)
        let e = TranscriptCursor(turn: 3, word: 17, turnCount: 9, endMs: 125_500)
        #expect(e.token == "v1.t3.w17.n9.e125500")
        #expect(TranscriptCursor(token: e.token) == e)
    }

    @Test func malformedCursorRejected() throws {
        for bad in ["", "v2.t1.w0.n3", "v1.t1.w0", "v1.t1.w0.n3.x5", "v1.tx.w0.n3", "v1.t-1.w0.n3", "v1.t1.w0.n3.e",
                    "v1.t1234567890.w0.n3", "v1.t1.w0.n3.e1.e2", "o20"] {
            #expect(TranscriptCursor(token: bad) == nil, "\(bad)")
        }
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Hello there"), F.turn(1, "S2", 3, 6, "Hi")])
        for bad in ["nonsense", "v1.t5.w0.n2", "v1.t0.w9.n2"] {
            #expect(throws: ToolError("That cursor isn't valid. Call get_transcript without a cursor to start again.")) {
                try F.page(t, ["cursor": .string(bad)])
            }
        }
        #expect(throws: ToolError.badTranscriptCursor) { try F.page(t, ["cursor": 12]) }
    }

    @Test func cursorFromChangedTranscriptRejected() throws {
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Hello there"), F.turn(1, "S2", 3, 6, "Hi")])
        #expect(throws: ToolError("The transcript changed since that part was read. Call get_transcript without a cursor to start again.")) {
            try F.page(t, ["cursor": "v1.t1.w0.n3"])
        }
    }

    @Test func overrideKeyNamesTheOverrideSpeaker() throws {
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Actually Karan said this", override: "S2")])
        #expect(F.lines(try F.page(t, [:])) == ["[0:00–0:03] Karan (auto): Actually Karan said this"])
    }

    @Test func missingSpeakerIsUnknownSpeaker() throws {
        let t = F.transcript([F.turn(0, "S9", 0, 3, "Who am I")])
        #expect(F.lines(try F.page(t, [:])) == ["[0:00–0:03] Unknown speaker: Who am I"])
    }

    @Test func turnWithoutKeyHasNoLabel() throws {
        let t = F.transcript([F.turn(0, nil, 1, 5, "Just text")])
        #expect(F.lines(try F.page(t, [:])) == ["[0:01–0:05] Just text"])
    }

    @Test func emptyTurnsSkipped() throws {
        var blank = F.turn(1, "S2", 3, 4, "x")
        blank.words = [TimedWord(text: "  ", range: TimeRange(start: 3, end: 4))]
        let t = F.transcript([F.turn(0, "S1", 0, 3, "First"), blank, F.turn(2, "S2", 4, 6, "Third"),
                              F.turn(3, "S1", 6, 7, "")])
        let page = try F.page(t, [:])
        #expect(F.lines(page) == ["[0:00–0:03] Liam: First", "[0:04–0:06] Karan (auto): Third"])
        #expect(page.contains("Turns 1–3 of 4"))
        let empty = try F.page(F.transcript([]), [:])
        #expect(empty.contains("This recording has no transcript text.") && empty.hasSuffix("End of transcript."))
    }

    @Test func longRecordingsUseHours() throws {
        let t = F.transcript([F.turn(0, "S1", 5, 9, "Early"), F.turn(1, "S2", 3_725, 3_730, "Late")])
        #expect(F.lines(try F.page(t, [:])) == ["[0:00:05–0:00:09] Liam: Early", "[1:02:05–1:02:10] Karan (auto): Late"])
        let short = F.transcript([F.turn(0, "S1", 5, 9, "Early"), F.turn(1, "S2", 725, 730, "Later")])
        #expect(F.lines(try F.page(short, [:])) == ["[0:05–0:09] Liam: Early", "[12:05–12:10] Karan (auto): Later"])
    }

    @Test func lastPageSaysEnd() throws {
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Hello")])
        let page = try F.page(t, [:])
        #expect(page.hasSuffix("\n\nEnd of transcript.") && F.nextCursor(page) == nil)
        #expect(try F.page(t, ["end_seconds": 2]).hasSuffix("\n\nEnd of the requested range."))
    }

    @Test func overlapIsMarked() throws {
        let t = F.transcript([F.turn(0, "S2", 0, 3, "Both at once", overlap: true)])
        #expect(F.lines(try F.page(t, [:])) == ["[0:00–0:03] Karan (auto) (overlapping speech): Both at once"])
    }

    @Test func autoLabelledLinesSayAuto() throws {
        let t = F.transcript([F.turn(0, "S1", 0, 3, "Me"), F.turn(1, "S2", 3, 6, "Him"), F.turn(2, "S3", 6, 9, "Guess")],
                             speakers: [F.liam, F.karan, F.guess])
        let page = try F.page(t, [:])
        #expect(F.lines(page) == ["[0:00–0:03] Liam: Me", "[0:03–0:06] Karan (auto): Him", "[0:06–0:09] Speaker 3: Guess"])
        #expect(page.contains("- Speaker 3: unnamed; Transcribe's guess is Priya, not confirmed"))
        #expect(page.contains("Names marked (auto) were recognised automatically and can be wrong."))
        let none = F.transcript([F.turn(0, "S1", 0, 3, "Me")], speakers: [F.liam])
        #expect(!(try F.page(none, [:])).contains("Names marked (auto)"))
    }
}
