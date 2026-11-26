import Foundation
import TranscribeCore

/// The one place that turns a voice's samples and labels into the plain inputs of `SampleGrouping` and
/// `GroupLabelResolver`. The screen and the store both use it, so the store checks a label action against exactly the
/// groups the screen drew.
@MainActor
public enum GroupingInput {
    /// Why a sample is listed but not grouped.
    public enum UngroupedReason: Sendable, Equatable {
        /// Its embedding model is not the profile's (an older voice model), or the profile's model names no dimension.
        case olderModel
        /// On the profile's model, but its vector is not readable at the model's dimension yet: a synced sample whose
        /// fields have not all arrived (its placeholder vector has one value).
        case stillSyncing
    }

    /// A sample left out of grouping, still shown in its channel.
    public struct Ungrouped: Sendable, Equatable {
        public let id: UUID
        /// The sample's capture channel, or this device's when it has none (as for grouped samples).
        public let channel: String
        public let reason: UngroupedReason
        public init(id: UUID, channel: String, reason: UngroupedReason) {
            self.id = id; self.channel = channel; self.reason = reason
        }
    }

    /// A profile's samples split into grouping items and the rest. Plain values only, so the pure code that builds
    /// the screen needs no store.
    public struct Split: Sendable, Equatable {
        public var items: [SampleGrouping.Item]
        /// Oldest first, as `VoiceProfile.sortedSamples`.
        public var ungrouped: [Ungrouped]
        public init(items: [SampleGrouping.Item], ungrouped: [Ungrouped]) {
            self.items = items; self.ungrouped = ungrouped
        }
    }

    /// Samples whose model key is the profile's and whose vector decodes at the model's dimension are items: channel
    /// `captureChannel ?? localChannel`, age `SyncValue.millis(addedAt)` (what every device agrees on), and the vector
    /// as `VoiceSample.vector` decodes it (so a label's anchor, packed from these vectors, compares bit for bit).
    /// Every other sample is ungrouped, with its reason. Both lists follow `sortedSamples`.
    public static func split(_ profile: VoiceProfile, localChannel: String) -> Split {
        let dimension = dimension(ofModelKey: profile.embeddingModelKey)
        var items: [SampleGrouping.Item] = [], ungrouped: [Ungrouped] = []
        for sample in profile.sortedSamples {
            let channel = sample.captureChannel ?? localChannel
            guard let dimension, sample.embeddingModelKey == profile.embeddingModelKey else {
                ungrouped.append(Ungrouped(id: sample.id, channel: channel, reason: .olderModel))
                continue
            }
            guard let vector = sample.vector, vector.dimension == dimension else {
                ungrouped.append(Ungrouped(id: sample.id, channel: channel, reason: .stillSyncing))
                continue
            }
            items.append(SampleGrouping.Item(id: sample.id, vector: vector, channel: channel,
                                             addedAtMillis: SyncValue.millis(sample.addedAt)))
        }
        return Split(items: items, ungrouped: ungrouped)
    }

    /// The profile's labels that can show: non-empty text, the profile's model key, and an anchor that decodes. Ordered
    /// by id (the resolver does not depend on the order).
    public static func anchors(_ profile: VoiceProfile) -> [GroupLabelAnchor] {
        profile.groupLabels
            .filter { !$0.text.isEmpty && $0.embeddingModelKey == profile.embeddingModelKey }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .compactMap { label in
                let vectors = label.anchors
                guard !vectors.isEmpty else { return nil }
                return GroupLabelAnchor(id: label.id, channel: label.captureChannel, vectors: vectors,
                                        editedAtMillis: SyncValue.millis(label.editedAt))
            }
    }

    /// The vector dimension an embedding model key names (`EmbeddingModelID.key`, "name@revision#256"); nil when it
    /// names none, and then nothing is grouped.
    public nonisolated static func dimension(ofModelKey key: String) -> Int? {
        guard let hash = key.lastIndex(of: "#"), let d = Int(key[key.index(after: hash)...]), d > 0 else { return nil }
        return d
    }
}
