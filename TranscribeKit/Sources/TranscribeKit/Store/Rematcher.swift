import Foundation
import SwiftData
import TranscribeCore

/// Re-scores unnamed speakers in finished recordings after a profile gains a voice (§5.5 step 6).
///
/// It only ever *suggests*: a match found after the fact becomes "Is this Karan?", never an automatic
/// label, because the user did not see this recording being processed. It runs inside the caller's
/// transaction and never saves.
@MainActor
enum Rematcher {
    /// Returns the number of speakers that gained a suggestion for `changed`.
    @discardableResult
    static func run(changed: VoiceProfile, excludingRecording: UUID?, context: ModelContext,
                    policy: MatchPolicy = .default) throws -> Int {
        let modelKey = changed.embeddingModelKey
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
            .filter { $0.embeddingModelKey == modelKey }
            .sorted(by: LibraryStore.profileOrder)
        let candidates = profiles.map { LibraryStore.candidate($0, policy: policy) }   // trust and negatives: a blocked profile is never suggested
        guard candidates.contains(where: { $0.id == changed.id && !$0.samples.isEmpty && !$0.needsResample }) else { return 0 }

        let ready = RecordingStage.ready.rawValue
        let recordings = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.stageRaw == ready }))
        var suggested = 0
        for r in recordings where r.id != excludingRecording {
            // A person appears at most once per recording.
            let present = r.speakers.contains { $0.profile?.id == changed.id || $0.suggestedProfileID == changed.id }
            guard !present else { continue }
            let open = r.sortedSpeakers.filter {
                $0.label == .unnamed && $0.embeddingModelKey == modelKey && $0.vectorData != nil
                    && !$0.rejectedProfileIDs.contains(changed.id)
            }
            guard !open.isEmpty else { continue }
            // Profiles already in this recording cannot be suggested again; the greedy pass needs them excluded.
            let taken = Set(r.speakers.compactMap { $0.profile?.id ?? $0.suggestedProfileID })
            let probes = open.map { s in
                SpeakerProbe(key: s.key, vector: s.vector, cleanSeconds: s.cleanSeconds,
                             rejectedProfileIDs: Set(s.rejectedProfileIDs).union(taken), channel: r.captureChannel,
                             askOnly: s.source == .mixed)
            }
            let decisions = VoiceMatcher.decide(probes: probes, profiles: candidates, modelKey: modelKey, policy: policy)
            for s in open {
                let score: Float
                switch decisions[s.key] {
                case .autoLabel(let id, let sc, _)? where id == changed.id: score = sc
                case .ask(let id, let sc)? where id == changed.id: score = sc
                default: continue
                }
                s.label = .suggested
                s.suggestedProfileID = changed.id
                s.matchScore = Double(score)
                s.matchMargin = nil
                suggested += 1
                break   // at most one speaker per recording
            }
        }
        return suggested
    }
}
