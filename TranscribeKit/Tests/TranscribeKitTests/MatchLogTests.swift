import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("Voice matching log")
@MainActor
struct MatchLogTests {
    @Test func logHasNoNamesTitlesOrVectors() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let id = try h.separatedRecording(turns: SeedContent.conversationA, drafts: [
            WP3Docs.draft("S1", 1, clean: 14.1, vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 44)),
            WP3Docs.draft("S2", 2, clean: 11, vector: SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 45))])
        try h.matchLikeThePipeline(id)
        try h.store.rename(id: id, title: "Budget review with Priya")
        try h.store.rejectSuggestion(recordingID: id, key: "S2")
        _ = try h.store.nameSpeaker(recordingID: Seeds.ID.recordingC, key: "S2", as: .newPerson(name: "Zed"), remember: false)

        let log = try h.store.matchingLog()
        let recordings = try h.context.fetch(FetchDescriptor<Recording>())
        var forbidden = ["Liam", "Karan", "Zed", "Priya", "vectorData", "nameSnapshot", "quote"]
        forbidden += recordings.map(\.displayTitle)
        for word in forbidden { #expect(!log.contains(word), "log contains \(word)") }
        let quotes = try h.context.fetch(FetchDescriptor<VoiceSample>()).compactMap(\.quote)
        for quote in quotes { #expect(!log.contains(quote)) }
        // No packed vector in any form.
        for s in try h.context.fetch(FetchDescriptor<RecordingSpeaker>()) {
            if let data = s.vectorData { #expect(!log.contains(data.base64EncodedString())) }
        }

        let decoded = try MatchLog.decoder().decode(MatchLog.self, from: Data(log.utf8))
        #expect(decoded.version == 1 && decoded.profiles.count == 2)
        #expect(decoded.policy.autoLabelMin == MatchPolicy.default.autoLabelMin && decoded.policy.maxSamplesPerProfile == 12)
        let karan = try #require(decoded.profiles.first { $0.id == Seeds.ID.karan })
        #expect(karan.samples == MatchLog.SampleCounts(trusted: 1, short: 1, automatic: 0) && karan.negatives == 1)
        let liam = try #require(decoded.profiles.first { $0.id == Seeds.ID.liam })
        #expect(liam.isMe && liam.samples == MatchLog.SampleCounts(trusted: 3, short: 0, automatic: 1))
        let matched = try #require(decoded.recordings.first { $0.id == id })
        #expect(matched.speakers.count == 2 && matched.speakers.allSatisfy { $0.trace != nil })
        #expect(matched.speakers.first { $0.key == "S1" }?.trace?.kind == .auto)
        #expect(matched.speakers.first { $0.key == "S2" }?.rejectedProfileIDs == [Seeds.ID.karan])
        #expect(matched.speakers.allSatisfy { $0.coherence == 1 })
        // Seeded recordings were never matched with a trace.
        #expect(decoded.recordings.filter { $0.id != id }.allSatisfy { $0.speakers.allSatisfy { $0.trace == nil } })
    }

    @Test func logListsAtMostFiftyRecordings() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        var made: [UUID] = []
        for i in 0..<55 {
            made.append(try h.readyRecording(turns: SeedContent.conversationA, drafts: [],
                                             createdAt: Seeds.Dates.d.addingTimeInterval(Double(i) * 60)))
        }
        let decoded = try MatchLog.decoder().decode(MatchLog.self, from: Data(try h.store.matchingLog().utf8))
        #expect(decoded.recordings.count == MatchLog.maxRecordings)
        // The newest fifty, newest first: the three seed recordings and the five oldest new ones are left out.
        #expect(decoded.recordings.map(\.id) == Array(made.suffix(50).reversed()))
    }
}
