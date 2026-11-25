import Foundation
import TranscribeCore
@testable import TranscribeMCP

/// Builders for transcripts and a fake library.
enum Fixture {
    static let id = UUID(uuidString: "7D1C0A2E-6F7B-4C55-9B1A-2E0F1D3C4B5A")!
    static let sydney = TimeZone(identifier: "Australia/Sydney")!
    /// 2026-11-18 14:31:00 in Sydney (+11:00).
    static let created = Date(timeIntervalSince1970: 1_794_972_660)

    static let liam = MCPSpeaker(key: "S1", ordinal: 1, name: "Liam", status: .named, isUser: true)
    static let karan = MCPSpeaker(key: "S2", ordinal: 2, name: "Karan", status: .autoLabelled)
    static let guess = MCPSpeaker(key: "S3", ordinal: 3, name: "Speaker 3", status: .suggested, suggestedName: "Priya")

    /// Words timed evenly across `range`.
    static func turn(_ index: Int, _ key: SpeakerKey?, _ start: Double, _ end: Double, _ text: String,
                     overlap: Bool = false, override: SpeakerKey? = nil) -> Turn {
        let tokens = text.split(separator: " ").map(String.init)
        let slice = tokens.isEmpty ? 0 : (end - start) / Double(tokens.count)
        let words = tokens.enumerated().map { i, t in
            TimedWord(text: t, range: TimeRange(start: start + Double(i) * slice, end: start + Double(i + 1) * slice))
        }
        return Turn(id: Turn.stableID(index: index), speakerKey: key, range: TimeRange(start: start, end: end), words: words,
                    hasOverlap: overlap, speakerKeyOverride: override)
    }

    static func transcript(_ turns: [Turn], duration: Double? = nil, speakers: [MCPSpeaker] = [liam, karan],
                           title: String = "Team sync") -> MCPTranscript {
        let summary = MCPRecordingSummary(id: id, title: title, createdAt: created,
                                          duration: duration ?? (turns.last?.range.end ?? 0), folder: "Work",
                                          language: "en", device: "Mac", speakers: speakers)
        return MCPTranscript(summary: summary, document: TranscriptDocument(words: turns.flatMap(\.words), turns: turns,
                                                                            asrModelID: "test"))
    }

    /// About 1,800 turns of about 15 words across three hours.
    static func threeHours() -> MCPTranscript {
        let vocabulary = ["budget", "review", "Friday", "supplier", "quotes", "client", "report", "photos", "captions",
                          "finance", "rates", "meeting", "Thursday", "safety", "checklist", "Wednesday", "project", "list"]
        var turns: [Turn] = []
        for i in 0..<1_800 {
            let start = Double(i) * 6, count = 12 + i % 7
            let text = (0..<count).map { vocabulary[($0 * 7 + i) % vocabulary.count] }.joined(separator: " ") + "."
            turns.append(turn(i, i % 3 == 0 ? "S1" : "S2", start, start + 5.5, text))
        }
        return transcript(turns, duration: 10_800)
    }

    static func page(_ t: MCPTranscript, _ args: JSONValue) throws -> String {
        var a = args
        if case .object(var o) = a { o["recording_id"] = .string(id.uuidString); a = .object(o) }
        return try TranscriptPager.page(t, args: TranscriptArguments(a), timeZone: sydney)
    }

    /// The `next_cursor` token at the end of a page, if any.
    static func nextCursor(_ page: String) -> String? {
        guard let line = page.split(separator: "\n").last, line.hasPrefix("next_cursor: ") else { return nil }
        return String(line.dropFirst("next_cursor: ".count).prefix { $0 != " " })
    }

    /// The transcript lines of a page (those starting with "[").
    static func lines(_ page: String) -> [String] {
        page.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("[") }.map(String.init)
    }
}

/// A library with fixed contents.
struct FakeLibrary: MCPLibrary {
    var page = MCPRecordingPage(items: [], total: 0)
    var transcripts: [UUID: MCPTranscript] = [:]
    func recordings(_ q: MCPRecordingQuery) async throws -> MCPRecordingPage { page }
    func transcript(id: UUID) async throws -> MCPTranscript? { transcripts[id] }
}

extension Data {
    var json: JSONValue { (try? JSONValue.decode(self)) ?? .null }
}

extension MCPReply {
    var json: JSONValue {
        switch self {
        case .message(let d), .badRequest(let d): d.json
        case .accepted: .null
        }
    }
}

func request(_ id: Int64, _ method: String, _ params: JSONValue? = nil) -> Data {
    var o: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
    if let params { o["params"] = params }
    return JSONValue.object(o).encoded()
}
