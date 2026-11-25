import Foundation
import Testing
@testable import TranscribeMCP

@Suite("MCP: tool arguments")
struct ToolArgumentsTests {
    let tz = Fixture.sydney

    func sydney(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test func dateOnlyMeansLocalDayBounds() throws {
        let a = try ListArguments(["from_date": "2026-11-18", "to_date": "2026-11-18"], timeZone: tz)
        #expect(a.from == sydney(2026, 11, 18))
        #expect(a.to == sydney(2026, 11, 19))
        // Midnight in Sydney is the previous afternoon in UTC.
        #expect(MCPTime.iso(a.from!, timeZone: TimeZone(identifier: "UTC")!) == "2026-11-17T13:00:00+00:00")
        // Across a daylight-saving change the local day still bounds it (Sydney: 5 Apr 2026 is 25 hours long).
        let dst = try ListArguments(["from_date": "2026-04-05", "to_date": "2026-04-05"], timeZone: tz)
        #expect(dst.to!.timeIntervalSince(dst.from!) == 25 * 3600)
    }

    @Test func isoDateTimeParses() throws {
        let withOffset = try ListArguments(["from_date": "2026-11-18T14:31:00+11:00"], timeZone: tz)
        #expect(withOffset.from == sydney(2026, 11, 18, 14, 31))
        let utc = try ListArguments(["from_date": "2026-11-18T03:31:00Z"], timeZone: tz)
        #expect(utc.from == sydney(2026, 11, 18, 14, 31))
        let fractional = try ListArguments(["from_date": "2026-11-18T03:31:00.250Z"], timeZone: tz)
        #expect(fractional.from == sydney(2026, 11, 18, 14, 31).addingTimeInterval(0.25))
        let local = try ListArguments(["from_date": "2026-11-18T14:31", "to_date": "2026-11-18T15:00:00"], timeZone: tz)
        #expect(local.from == sydney(2026, 11, 18, 14, 31))
        #expect(local.to == sydney(2026, 11, 18, 15, 0, 1))   // inclusive of that second
    }

    @Test func badDateIsToolError() {
        for raw in ["18/11/2026", "2026-13-01", "2026-02-31", "yesterday", "", "2026-11-18T25:00"] {
            #expect(throws: ToolError("from_date and to_date must be YYYY-MM-DD or ISO 8601.")) {
                try ListArguments(["from_date": .string(raw)], timeZone: tz)
            }
        }
        #expect(throws: ToolError.badDate) { try ListArguments(["to_date": "soon"], timeZone: tz) }
    }

    @Test func badUUIDIsToolError() throws {
        for args: JSONValue in [["recording_id": "nope"], [:], ["recording_id": 5], ["recording_id": "A0000000-0000"]] {
            #expect(throws: ToolError("recording_id must be an id from list_recordings.")) { try TranscriptArguments(args) }
        }
        #expect(throws: ToolError.badRecordingID) { try TranscriptArguments(nil) }
        #expect(try TranscriptArguments(["recording_id": .string(Fixture.id.uuidString.lowercased())]).id == Fixture.id)
    }

    @Test func limitIsClamped() throws {
        #expect(try ListArguments(nil, timeZone: tz).limit == 20)
        #expect(try ListArguments(["limit": 0], timeZone: tz).limit == 1)
        #expect(try ListArguments(["limit": -5], timeZone: tz).limit == 1)
        #expect(try ListArguments(["limit": 500], timeZone: tz).limit == 50)
        #expect(try ListArguments(["limit": .number(7.0)], timeZone: tz).limit == 7)
        #expect(try ListArguments(["limit": 12], timeZone: tz).limit == 12)
    }

    @Test func endBeforeStartIsToolError() throws {
        let id = JSONValue.string(Fixture.id.uuidString)
        #expect(throws: ToolError("end_seconds must be after start_seconds.")) {
            try TranscriptArguments(["recording_id": id, "start_seconds": 30, "end_seconds": 30])
        }
        #expect(throws: ToolError.endBeforeStart) {
            try TranscriptArguments(["recording_id": id, "start_seconds": .number(12.5), "end_seconds": 3])
        }
        let ok = try TranscriptArguments(["recording_id": id, "start_seconds": 3, "end_seconds": .number(12.5)])
        #expect(ok.start == 3 && ok.end == 12.5 && ok.rangeEnd == 12.5)
        // With a cursor, start and end are ignored.
        let cursor = try TranscriptArguments(["recording_id": id, "cursor": "v1.t3.w0.n9", "start_seconds": 30, "end_seconds": 1])
        #expect(cursor.cursor == TranscriptCursor(turn: 3, word: 0, turnCount: 9) && cursor.start == nil && cursor.end == nil)
    }

    @Test func unknownArgumentsIgnored() throws {
        let list = try ListArguments(["query": "  Budget   REVIEW ", "colour": "blue", "speaker": " kar ", "limit": "ten"], timeZone: tz)
        #expect(list.terms == ["budget", "review"] && list.speaker == "kar" && list.limit == 20 && list.offset == 0)
        #expect(try ListArguments(["speaker": "   "], timeZone: tz).speaker == nil)
        let t = try TranscriptArguments(["recording_id": .string(Fixture.id.uuidString), "format": "srt"])
        #expect(t.id == Fixture.id && t.start == nil && t.end == nil && t.cursor == nil)
    }

    @Test func listCursorRoundTripAndRejectsGarbage() throws {
        let token = ListArguments.cursor(offset: 40)
        #expect(token == "o40")
        #expect(try ListArguments(["cursor": .string(token)], timeZone: tz).offset == 40)
        for bad: JSONValue in ["", "o", "o-1", "40", "o1234567", "x20", "o2a", 20, "o٣"] {
            #expect(throws: ToolError("That cursor isn't valid. Call list_recordings without a cursor to start again.")) {
                try ListArguments(["cursor": bad], timeZone: tz)
            }
        }
    }
}
