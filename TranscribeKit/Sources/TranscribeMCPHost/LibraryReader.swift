import Foundation
import SwiftData
import TranscribeCore
import TranscribeKit
import TranscribeMCP
#if canImport(Darwin)
import Darwin
#endif

/// The library as the MCP tools see it (D12): finished recordings only, as Sendable DTOs.
///
/// A plain actor, not `@ModelActor`: a `@ModelActor` made from `@MainActor` code can end up running on the main
/// queue. Its own `ModelContext` is created lazily inside the actor, so it is never made on (or used from) the main
/// thread. It only reads, never saves, and so sees what the app has saved (`LibraryStore` saves after every change).
/// No `@Model` object leaves the actor.
public actor LibraryReader: MCPLibrary {
    private let container: ModelContainer
    private var context: ModelContext?
    /// For `fetchRunsOffMainThread`: whether the context was created on the main thread.
    private(set) var contextMadeOnMainThread: Bool?

    public init(container: ModelContainer) { self.container = container }

    public func recordings(_ q: MCPRecordingQuery) async throws -> MCPRecordingPage {
        let context = readContext()
        let profiles = try profileNames(context)
        let speakerNeedle = q.speaker.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let matches = try readyRecordings(context).filter { r in
            if let from = q.from, r.createdAt < from { return false }
            if let to = q.to, r.createdAt >= to { return false }
            if !q.terms.isEmpty {
                let title = r.displayTitle.lowercased()
                guard q.terms.allSatisfy({ r.searchText.contains($0) || title.contains($0) }) else { return false }
            }
            if let speakerNeedle {
                let spoke = r.speakers.contains { s in
                    (s.label == .named || s.label == .autoLabelled)
                        && s.displayName.range(of: speakerNeedle, options: .caseInsensitive) != nil
                }
                guard spoke else { return false }
            }
            return true
        }
        let offset = max(0, q.offset), limit = max(0, q.limit)
        let pageItems = offset < matches.count ? Array(matches[offset..<min(matches.count, offset + limit)]) : []
        let items = pageItems.map { r in
            var summary = Self.summary(r, profiles: profiles)
            if !q.terms.isEmpty, let doc = r.transcript {
                let byKey = Dictionary(summary.speakers.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                summary.snippet = Snippet.first(in: doc, terms: q.terms, speakers: byKey)
            }
            return summary
        }
        return MCPRecordingPage(items: items, total: matches.count)
    }

    public func transcript(id: UUID) async throws -> MCPTranscript? {
        let context = readContext()
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let r = try context.fetch(descriptor).first, r.stage == .ready else { return nil }
        let document = r.transcript ?? TranscriptDocument(words: [], turns: [], asrModelID: r.asrModelID ?? "")
        return MCPTranscript(summary: Self.summary(r, profiles: try profileNames(context)), document: document)
    }

    // MARK: Reading

    private func readContext() -> ModelContext {
        if let context { return context }
        let made = ModelContext(container)
        made.autosaveEnabled = false
        contextMadeOnMainThread = _isOnMainThread()
        context = made
        return made
    }

    /// `.ready` recordings, newest first; equal dates are ordered by id so pages are stable.
    private func readyRecordings(_ context: ModelContext) throws -> [Recording] {
        let ready = RecordingStage.ready.rawValue
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.stageRaw == ready },
                                                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try context.fetch(descriptor).sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
        }
    }

    /// One fetch for every saved voice: names for suggestions ("Transcribe guesses Priya").
    private func profileNames(_ context: ModelContext) throws -> [UUID: (name: String, isMe: Bool)] {
        var names: [UUID: (name: String, isMe: Bool)] = [:]
        for p in try context.fetch(FetchDescriptor<VoiceProfile>()) { names[p.id] = (p.name, p.isMe) }
        return names
    }

    private static func summary(_ r: Recording, profiles: [UUID: (name: String, isMe: Bool)]) -> MCPRecordingSummary {
        MCPRecordingSummary(id: r.id, title: r.displayTitle, createdAt: r.createdAt, duration: r.duration,
                            folder: r.folder?.name, language: r.languageRaw,
                            device: DevicePlatform(channel: r.captureChannel)?.noun,
                            speakers: r.sortedSpeakers.map { speaker($0, profiles: profiles) })
    }

    private static func speaker(_ s: RecordingSpeaker, profiles: [UUID: (name: String, isMe: Bool)]) -> MCPSpeaker {
        let status: MCPNameStatus = switch s.label {
        case .named: .named
        case .autoLabelled: .autoLabelled
        case .suggested: .suggested
        case .unnamed: .unnamed
        }
        let suggested = status == .suggested ? s.suggestedProfileID.flatMap { profiles[$0]?.name } : nil
        return MCPSpeaker(key: s.key, ordinal: s.ordinal, name: s.displayName, status: status, suggestedName: suggested,
                          isUser: s.profile?.isMe ?? false)
    }

    /// For the test that the reader never runs on the main thread.
    internal func _isOnMainThread() -> Bool { pthread_main_np() != 0 }
}
