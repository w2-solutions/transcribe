import Foundation
import TranscribeCore

// What the MCP tools read (D21). The Mac app fills these from SwiftData (`TranscribeMCPHost.LibraryReader`); tests
// use a fake. Plain Sendable values: no `@Model` object ever reaches this module. Write tools, if ever added, become
// new methods here plus new catalogue entries.

/// How a speaker's name was decided, from `SpeakerLabelState`.
public enum MCPNameStatus: String, Sendable, Equatable { case named, autoLabelled, suggested, unnamed }

public struct MCPSpeaker: Sendable, Equatable {
    public var key: SpeakerKey
    public var ordinal: Int
    public var name: String             // profile name → nameSnapshot → "Speaker N"
    public var status: MCPNameStatus
    public var suggestedName: String?   // .suggested only: VoiceProfile.name for suggestedProfileID
    public var isUser: Bool             // profile?.isMe ?? false
    public init(key: SpeakerKey, ordinal: Int, name: String, status: MCPNameStatus, suggestedName: String? = nil,
                isUser: Bool = false) {
        self.key = key; self.ordinal = ordinal; self.name = name; self.status = status
        self.suggestedName = suggestedName; self.isUser = isUser
    }
}

/// The first transcript line that matched a search, cut to about 160 characters.
public struct MCPSnippet: Sendable, Equatable {
    public var start: Double
    public var speaker: String?
    public var text: String
    public init(start: Double, speaker: String?, text: String) { self.start = start; self.speaker = speaker; self.text = text }
}

public struct MCPRecordingSummary: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double
    public var folder: String?
    public var language: String?
    public var device: String?          // "iPhone"/"iPad"/"Mac"
    public var speakers: [MCPSpeaker]   // ordinal order
    public var snippet: MCPSnippet?
    public init(id: UUID, title: String, createdAt: Date, duration: Double, folder: String? = nil, language: String? = nil,
                device: String? = nil, speakers: [MCPSpeaker] = [], snippet: MCPSnippet? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.duration = duration; self.folder = folder
        self.language = language; self.device = device; self.speakers = speakers; self.snippet = snippet
    }
}

/// `terms` are lowercased; `from` is inclusive and `to` exclusive.
public struct MCPRecordingQuery: Sendable, Equatable {
    public var terms: [String]
    public var speaker: String?
    public var from: Date?
    public var to: Date?
    public var offset: Int
    public var limit: Int
    public init(terms: [String] = [], speaker: String? = nil, from: Date? = nil, to: Date? = nil, offset: Int = 0,
                limit: Int = 20) {
        self.terms = terms; self.speaker = speaker; self.from = from; self.to = to; self.offset = offset; self.limit = limit
    }
}

/// One page of matches, newest first; `total` counts every match, not just this page.
public struct MCPRecordingPage: Sendable {
    public var items: [MCPRecordingSummary]
    public var total: Int
    public init(items: [MCPRecordingSummary], total: Int) { self.items = items; self.total = total }
}

public struct MCPTranscript: Sendable {
    public var summary: MCPRecordingSummary
    public var document: TranscriptDocument
    public init(summary: MCPRecordingSummary, document: TranscriptDocument) { self.summary = summary; self.document = document }
}

/// Read-only access to finished (`.ready`) recordings.
public protocol MCPLibrary: Sendable {
    func recordings(_ q: MCPRecordingQuery) async throws -> MCPRecordingPage
    func transcript(id: UUID) async throws -> MCPTranscript?   // nil: missing or not .ready
}
