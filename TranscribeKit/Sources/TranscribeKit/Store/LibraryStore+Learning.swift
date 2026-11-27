import Foundation
import SwiftData
import TranscribeCore

/// Voice learning (§1.2 to §1.10): candidates with trust and negatives, negatives from "not P", positives from
/// "this is P", the cohort of unnamed voices, and sample removal.
extension LibraryStore {
    /// The matcher's view of a profile: samples and negatives on the profile's model, oldest first, with trust
    /// derived from each sample's origin and length and each sample's capture channel (§7). Negatives from every
    /// channel are included. `excludingSpeaker` leaves out samples that speaker fed.
    static func candidate(_ p: VoiceProfile, excludingSpeaker: UUID? = nil, policy: MatchPolicy = .default) -> ProfileCandidate {
        var vectors: [VoiceVector] = [], trusted: [Bool] = [], channels: [String?] = []
        var ids: [UUID] = [], added: [Int64] = []
        for sample in p.sortedSamples where sample.embeddingModelKey == p.embeddingModelKey {
            if let excludingSpeaker, sample.sourceSpeakerID == excludingSpeaker { continue }
            guard let v = sample.vector else { continue }
            vectors.append(v)
            trusted.append(SampleTrust.isTrusted(origin: sample.origin, speechSeconds: sample.speechSeconds, policy: policy))
            channels.append(sample.captureChannel)
            ids.append(sample.id)
            added.append(SyncMillis.millis(sample.addedAt))
        }
        let negatives = sortedNegatives(p).compactMap(\.vector)
        // Sample ids and dates let the matcher group the samples by sound (decision D3) as the voice screen does.
        return ProfileCandidate(id: p.id, name: p.name, samples: vectors, trusted: trusted, channels: channels,
                                negatives: negatives, modelKey: p.embeddingModelKey, autoLabel: p.autoLabel,
                                needsResample: p.needsResample, sampleIDs: ids, addedAtMillis: added)
    }

    /// The capture input of a speaker's recording (`CaptureDetail.input`), copied onto samples and negatives for the
    /// matching log only.
    static func captureInput(of r: Recording?) -> String? {
        CaptureDetail.decode(r?.captureDetailJSON)?.input
    }

    /// The capture input of a speaker's voice: `systemAudio` for a speaker heard through Mac audio (decision D2: the
    /// screen titles a group of such samples "Heard through Mac audio"), else its recording's input.
    static func captureInput(of s: RecordingSpeaker) -> String? {
        s.source == .system ? CaptureDetail.Input.systemAudio : captureInput(of: s.recording)
    }

    /// The profile's negatives on its own model, oldest first (ties by id).
    static func sortedNegatives(_ p: VoiceProfile) -> [VoiceNegative] {
        p.negatives
            .filter { $0.embeddingModelKey == p.embeddingModelKey }
            .sorted { $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// Keeps speaker `s`'s voice as a negative for `p` (§1.9): the user said this voice is not `p`.
    /// Needs a vector on `p`'s model and at least `minLearnSeconds` of clean speech. The cap and the duplicate check
    /// apply per channel (D12): the negative is heard on the speaker's recording's channel, and never evicts a
    /// negative from another channel.
    func addNegative(to p: VoiceProfile, from s: RecordingSpeaker) {
        // A voice heard on both streams is not one voice: nothing is learned from it (decision D2).
        guard s.source != .mixed, let vector = s.vector, let key = s.embeddingModelKey, key == p.embeddingModelKey,
              s.cleanSeconds >= policy.minLearnSeconds else { return }
        let channel = s.recording?.captureChannel
        let existing: [CuratedNegative] = Self.sortedNegatives(p).compactMap { n in
            guard n.captureChannel == channel, let v = n.vector else { return nil }
            return CuratedNegative(id: n.id, vector: v, addedAt: n.addedAt, sourceSpeakerID: n.sourceSpeakerID)
        }
        let new = CuratedNegative(id: UUID(), vector: vector, addedAt: clock.now, sourceSpeakerID: s.id)
        let result = SampleCurator.insertNegative(new, into: existing, policy: policy)
        guard result.added else { return }
        let negative = VoiceNegative(id: new.id, vector: vector, embeddingModelKey: key, addedAt: new.addedAt,
                                     speechSeconds: s.cleanSeconds)
        context.insert(negative)
        if let bytes = s.vectorData { negative.vectorData = bytes }   // the speaker's exact bytes, not a re-normalised copy
        negative.sourceRecordingID = s.recording?.id
        negative.sourceSpeakerID = s.id
        negative.captureChannel = channel
        negative.captureInput = Self.captureInput(of: s)
        negative.profile = p
        deleteNegatives(Set(result.evicted), of: p)
    }

    /// The user said speaker `s` is `p` (§1.10, D14): drop `p`'s negatives from this speaker, then (with Remember on)
    /// the negatives this voice conflicts with, measured before the new sample is added, then store the sample.
    func learnPositive(_ s: RecordingSpeaker, is p: VoiceProfile, origin: SampleOrigin,
                       remember: Bool) -> (stored: Bool, skip: SampleSkipReason?) {
        deleteNegatives(Set(p.negatives.filter { $0.sourceSpeakerID == s.id }.map(\.id)), of: p)
        guard remember else { return (false, .rememberOff) }
        guard s.source != .mixed else { return (false, .mixedSource) }
        if let vector = s.vector, s.embeddingModelKey == p.embeddingModelKey, s.cleanSeconds >= policy.minLearnSeconds {
            let negatives = Self.sortedNegatives(p).compactMap { n in n.vector.map { (id: n.id, vector: $0) } }
            let conflicting = VoiceMatcher.conflictingNegatives(vector, profile: Self.candidate(p, excludingSpeaker: s.id, policy: policy),
                                                                negatives: negatives, probeChannel: s.recording?.captureChannel,
                                                                policy: policy)
            deleteNegatives(Set(conflicting), of: p)
        }
        return addSpeakerSample(s, to: p, origin: origin)
    }

    func deleteNegatives(_ ids: Set<UUID>, of p: VoiceProfile) {
        guard !ids.isEmpty else { return }
        for n in p.negatives where ids.contains(n.id) { context.delete(n) }
        p.negatives.removeAll { ids.contains($0.id) }
    }

    /// Merge (§2.G): `src`'s negatives on `dst`'s model move to `dst` through the curator, except those taken from a
    /// speaker who is now `dst`; then `dst` drops its own negatives taken from a speaker who is now `dst`.
    /// Call after the speakers are repointed. The rest of `src`'s negatives cascade with `src`. A moved negative keeps
    /// its channel and input, and the cap applies per channel (D12).
    func mergeNegatives(from src: VoiceProfile, into dst: VoiceProfile) throws {
        let speakersByID = Dictionary(try allSpeakers().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func isNowDst(_ speakerID: UUID?) -> Bool {
            guard let speakerID else { return false }
            return speakersByID[speakerID]?.profile?.id == dst.id
        }
        var kept: [String?: [CuratedNegative]] = [:]
        for n in Self.sortedNegatives(dst) {
            guard let v = n.vector else { continue }
            kept[n.captureChannel, default: []].append(
                CuratedNegative(id: n.id, vector: v, addedAt: n.addedAt, sourceSpeakerID: n.sourceSpeakerID))
        }
        let moving = src.negatives
            .filter { $0.embeddingModelKey == dst.embeddingModelKey && !isNowDst($0.sourceSpeakerID) }
            .sorted { $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.id.uuidString < $1.id.uuidString }
        func isOlder(_ a: CuratedNegative, _ b: CuratedNegative) -> Bool {
            a.addedAt != b.addedAt ? a.addedAt < b.addedAt : a.id.uuidString < b.id.uuidString
        }
        for n in moving {
            guard let v = n.vector else { continue }
            // A new row on dst: the original cascades with src, so it is never moved in place.
            let copy = CuratedNegative(id: UUID(), vector: v, addedAt: n.addedAt, sourceSpeakerID: n.sourceSpeakerID)
            // The curator never evicts the negative being inserted, which suits a new rejection but not a moved one
            // that keeps its old date. With dst full, a moved negative older than every kept one is the oldest
            // overall, so it is the one to drop: the merged set keeps the newest negatives of both profiles.
            let sameChannel = kept[n.captureChannel, default: []]
            if sameChannel.count >= policy.maxNegativesPerProfile, sameChannel.allSatisfy({ isOlder(copy, $0) }) { continue }
            let result = SampleCurator.insertNegative(copy, into: sameChannel, policy: policy)
            guard result.added else { continue }
            kept[n.captureChannel] = result.keep
            let row = VoiceNegative(id: copy.id, vector: v, embeddingModelKey: n.embeddingModelKey, addedAt: n.addedAt,
                                    speechSeconds: n.speechSeconds)
            context.insert(row)
            row.vectorData = n.vectorData
            row.sourceRecordingID = n.sourceRecordingID
            row.sourceSpeakerID = n.sourceSpeakerID
            row.captureChannel = n.captureChannel
            row.captureInput = n.captureInput
            row.profile = dst
            deleteNegatives(Set(result.evicted), of: dst)
        }
        deleteNegatives(Set(dst.negatives.filter { isNowDst($0.sourceSpeakerID) }.map(\.id)), of: dst)
    }

    /// Unnamed voices of the newest recordings, newest first. The window (`cohortMaxRecordings` recordings,
    /// `cohortMaxVectors` voices) applies per capture channel, so recordings synced from another device never push
    /// this channel's voices out; every channel still counts (D11). One channel gives the same cohort as one window.
    public func matchCohort(modelKey: String, excludingRecording: UUID) throws -> [VoiceVector] {
        let ready = RecordingStage.ready.rawValue
        let recordings = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.stageRaw == ready }))
            .filter { $0.id != excludingRecording }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        var cohort: [VoiceVector] = []
        let maxRecordings = Swift.max(0, policy.cohortMaxRecordings), cap = Swift.max(0, policy.cohortMaxVectors)
        var recordingsTaken: [String?: Int] = [:], vectorsTaken: [String?: Int] = [:]
        for r in recordings {
            let channel = r.captureChannel
            guard recordingsTaken[channel, default: 0] < maxRecordings else { continue }
            recordingsTaken[channel, default: 0] += 1
            for s in r.sortedSpeakers {
                guard vectorsTaken[channel, default: 0] < cap else { break }
                // A mixed voice (heard on both streams) is left out: it is not one voice.
                guard s.label == .unnamed || (s.label == .named && s.profile == nil), s.source != .mixed,
                      s.vectorData != nil, s.embeddingModelKey == modelKey,
                      s.cleanSeconds >= policy.minLearnSeconds, let v = s.vector else { continue }
                cohort.append(v)
                vectorsTaken[channel, default: 0] += 1
            }
        }
        return cohort
    }

    public func removeSample(id: UUID) throws {
        var descriptor = FetchDescriptor<VoiceSample>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let sample = try context.fetch(descriptor).first else { throw StoreError.notFound("sample \(id)") }
        let p = sample.profile
        context.delete(sample)
        if let p {
            p.samples.removeAll { $0.id == id }
            if !p.samples.contains(where: { $0.embeddingModelKey == p.embeddingModelKey }) { p.needsResample = true }
        }
        try context.save()
    }
}
