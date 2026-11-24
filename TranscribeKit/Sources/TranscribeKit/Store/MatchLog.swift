import Foundation
import SwiftData
import TranscribeCore

/// The voice matching log (§2.H): numbers for tuning the thresholds on real recordings.
/// It never holds names, name snapshots, titles, transcripts, quotes or vectors.
struct MatchLog: Codable, Equatable {
    struct Policy: Codable, Equatable {
        var autoLabelMin: Float
        var autoLabelMargin: Float
        var askMin: Float
        var strongMatchMin: Float
        var strongMatchMargin: Float
        var minAutoSampleCoherence: Float
        var maxSamplesPerProfile: Int
        var minLearnSeconds: Double
    }
    struct SampleCounts: Codable, Equatable {
        var trusted: Int
        var short: Int
        var automatic: Int
    }
    struct Profile: Codable, Equatable {
        var id: UUID
        var isMe: Bool
        var autoLabel: Bool
        var needsResample: Bool
        var embeddingModelKey: String
        var samples: SampleCounts
        var negatives: Int
        /// v2: samples per capture channel ("unknown" for a sample with no channel).
        var samplesByChannel: [String: Int]?
        /// v2: trusted samples per capture channel; only these can be first place for a probe on that channel.
        var trustedByChannel: [String: Int]?
    }
    struct Speaker: Codable, Equatable {
        var key: String
        var ordinal: Int
        var cleanSeconds: Double
        var coherence: Double?
        var label: String
        var profileID: UUID?
        var suggestedProfileID: UUID?
        var rejectedProfileIDs: [UUID]
        var trace: MatchTrace?
    }
    struct RecordingRow: Codable, Equatable {
        var id: UUID
        var createdAt: Date
        /// v2: the capture channel and input route (`CaptureDetail.input`). Never the device name.
        var channel: String?
        var input: String?
        var speakers: [Speaker]
        /// Speakers "Same as Speaker N" removed: the speaker they became is `movedTo`.
        var movedSpeakers: [MovedSpeakerTrace]
    }

    /// 2: channels per profile and recording, and v2 match traces (§7).
    static let currentVersion = 2
    /// The key for samples with no capture channel.
    static let unknownChannel = "unknown"
    /// Newest ready recordings included.
    static let maxRecordings = 50

    var version: Int
    var generatedAt: Date
    var policy: Policy
    var profiles: [Profile]
    var recordings: [RecordingRow]

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The match trace of a speaker that "Same as Speaker N" removed (D10: a trace is never cleared by edits). These are
/// often wrong auto-labels the user corrected, the most useful rows for tuning. Stored on the recording as JSON.
struct MovedSpeakerTrace: Codable, Equatable {
    var key: String
    var ordinal: Int
    var cleanSeconds: Double
    var coherence: Double?
    /// The speaker whose turns these became (kept current if that speaker is moved on in turn).
    var movedTo: String
    var rejectedProfileIDs: [UUID]
    var trace: MatchTrace

    static func decode(_ data: Data?) -> [MovedSpeakerTrace] {
        data.flatMap { try? JSONDecoder().decode([MovedSpeakerTrace].self, from: $0) } ?? []
    }
}

extension LibraryStore {
    /// Before speaker `s` is removed by a move into `target`: keep its trace on the recording, and repoint the
    /// traces of speakers that were earlier moved into `s`.
    func keepTrace(of s: RecordingSpeaker, movedTo target: SpeakerKey, in r: Recording) {
        var moved = MovedSpeakerTrace.decode(r.movedSpeakerTracesData)
        for i in moved.indices where moved[i].movedTo == s.key { moved[i].movedTo = target }
        if let trace = s.matchTraceData.flatMap({ try? JSONDecoder().decode(MatchTrace.self, from: $0) }) {
            moved.append(MovedSpeakerTrace(key: s.key, ordinal: s.ordinal, cleanSeconds: s.cleanSeconds,
                                           coherence: s.vectorCoherence, movedTo: target,
                                           rejectedProfileIDs: s.rejectedProfileIDs, trace: trace))
        }
        guard !moved.isEmpty else { return }
        r.movedSpeakerTracesData = try? JSONEncoder().encode(moved)
    }

    public func matchingLog() throws -> String {
        let profiles = try allProfiles().map { p in
            let samples = p.samples
            let automatic = samples.filter { $0.origin.isAutomatic }.count
            let trustedSamples = samples.filter { SampleTrust.isTrusted(origin: $0.origin, speechSeconds: $0.speechSeconds, policy: policy) }
            let trusted = trustedSamples.count
            func byChannel(_ rows: [VoiceSample]) -> [String: Int] {
                rows.reduce(into: [:]) { $0[$1.captureChannel ?? MatchLog.unknownChannel, default: 0] += 1 }
            }
            return MatchLog.Profile(id: p.id, isMe: p.isMe, autoLabel: p.autoLabel, needsResample: p.needsResample,
                                    embeddingModelKey: p.embeddingModelKey,
                                    samples: .init(trusted: trusted, short: samples.count - trusted - automatic, automatic: automatic),
                                    negatives: p.negatives.count,
                                    samplesByChannel: byChannel(samples), trustedByChannel: byChannel(trustedSamples))
        }
        let ready = RecordingStage.ready.rawValue
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.stageRaw == ready },
                                                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = MatchLog.maxRecordings
        let recordings = try context.fetch(descriptor).map { r in
            MatchLog.RecordingRow(id: r.id, createdAt: r.createdAt, channel: r.captureChannel,
                                  input: CaptureDetail.decode(r.captureDetailJSON)?.input, speakers: r.sortedSpeakers.map { s in
                MatchLog.Speaker(key: s.key, ordinal: s.ordinal, cleanSeconds: s.cleanSeconds, coherence: s.vectorCoherence,
                                 label: s.labelRaw, profileID: s.profile?.id, suggestedProfileID: s.suggestedProfileID,
                                 rejectedProfileIDs: s.rejectedProfileIDs,
                                 trace: s.matchTraceData.flatMap { try? JSONDecoder().decode(MatchTrace.self, from: $0) })
            }, movedSpeakers: MovedSpeakerTrace.decode(r.movedSpeakerTracesData))
        }
        let log = MatchLog(
            version: MatchLog.currentVersion, generatedAt: clock.now,
            policy: .init(autoLabelMin: policy.autoLabelMin, autoLabelMargin: policy.autoLabelMargin, askMin: policy.askMin,
                          strongMatchMin: policy.strongMatchMin, strongMatchMargin: policy.strongMatchMargin,
                          minAutoSampleCoherence: policy.minAutoSampleCoherence,
                          maxSamplesPerProfile: policy.maxSamplesPerProfile, minLearnSeconds: policy.minLearnSeconds),
            profiles: profiles, recordings: recordings)
        return String(decoding: try MatchLog.encoder().encode(log), as: UTF8.self)
    }
}
