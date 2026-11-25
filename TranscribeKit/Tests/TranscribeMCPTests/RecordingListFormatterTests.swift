import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: recording list text")
struct RecordingListFormatterTests {
    let tz = Fixture.sydney

    func summary(_ i: Int, snippet: MCPSnippet? = nil) -> MCPRecordingSummary {
        MCPRecordingSummary(id: Fixture.id, title: "Team sync", createdAt: Fixture.created, duration: 768, folder: "Work",
                            language: "en", device: "Mac",
                            speakers: [Fixture.liam, Fixture.karan,
                                       MCPSpeaker(key: "S3", ordinal: 3, name: "Speaker 3", status: .suggested, suggestedName: "Priya")],
                            snippet: snippet)
    }

    func args(_ a: JSONValue = [:]) throws -> ListArguments { try ListArguments(a, timeZone: tz) }

    @Test func isoDateUsesGivenTimeZone() throws {
        let page = MCPRecordingPage(items: [summary(0)], total: 1)
        let text = RecordingListFormatter.text(page, args: try args(), timeZone: tz)
        #expect(text == """
        1 recording (1 shown). Times are in the user's time zone.

        1. Team sync
           id: 7D1C0A2E-6F7B-4C55-9B1A-2E0F1D3C4B5A
           recorded: 2026-11-18T14:31:00+11:00 · length 12:48 · on Mac · folder: Work · language: en
           speakers: Liam [the user, named] · Karan [recognised automatically, not confirmed] · Speaker 3 [unnamed, Transcribe guesses Priya]
        """)
        let utc = RecordingListFormatter.text(page, args: try args(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(utc.contains("recorded: 2026-11-18T03:31:00+00:00 ·"))
    }

    @Test func nextCursorOnlyWhenMore() throws {
        let three = (0..<3).map { summary($0) }
        let more = RecordingListFormatter.text(MCPRecordingPage(items: three, total: 7), args: try args(["limit": 3]), timeZone: tz)
        #expect(more.hasPrefix("7 recordings (1–3 shown)."))
        #expect(more.hasSuffix("\n\nnext_cursor: o3 (call list_recordings again with this cursor)"))
        let second = RecordingListFormatter.text(MCPRecordingPage(items: three, total: 7),
                                                 args: try args(["limit": 3, "cursor": "o3"]), timeZone: tz)
        #expect(second.hasPrefix("7 recordings (4–6 shown).") && second.contains("\n4. Team sync"))
        #expect(second.hasSuffix("next_cursor: o6 (call list_recordings again with this cursor)"))
        let last = RecordingListFormatter.text(MCPRecordingPage(items: [summary(0)], total: 7),
                                               args: try args(["limit": 3, "cursor": "o6"]), timeZone: tz)
        #expect(last.hasPrefix("7 recordings (7 shown).") && !last.contains("next_cursor"))
    }

    @Test func snippetShownOnlyWithQuery() throws {
        let snippet = MCPSnippet(start: 192.4, speaker: "Karan (auto)", text: "…we should move the budget review to Friday…")
        let page = MCPRecordingPage(items: [summary(0, snippet: snippet)], total: 1)
        let with = RecordingListFormatter.text(page, args: try args(["query": "budget"]), timeZone: tz)
        #expect(with.hasSuffix("\n   match: [3:12] Karan (auto): \"…we should move the budget review to Friday…\""))
        let without = RecordingListFormatter.text(page, args: try args(), timeZone: tz)
        #expect(!without.contains("match:"))
    }

    @Test func emptyResultText() throws {
        #expect(RecordingListFormatter.text(MCPRecordingPage(items: [], total: 0), args: try args(), timeZone: tz)
                == "No finished recordings match.")
    }

    @Test func missingFieldsOmitted() throws {
        let bare = MCPRecordingSummary(id: Fixture.id, title: "Wed 18 Nov · 2:31 pm", createdAt: Fixture.created, duration: 3_723)
        let text = RecordingListFormatter.text(MCPRecordingPage(items: [bare], total: 1), args: try args(), timeZone: tz)
        #expect(text.contains("\n   recorded: 2026-11-18T14:31:00+11:00 · length 1:02:03\n") || text.hasSuffix("length 1:02:03"))
        #expect(!text.contains("folder:") && !text.contains("language:") && !text.contains(" on ") && !text.contains("speakers:"))
    }
}
