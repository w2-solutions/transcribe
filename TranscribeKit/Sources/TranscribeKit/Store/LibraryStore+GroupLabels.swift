import Foundation
import SwiftData
import TranscribeCore

/// The text rule for a sample group label: trimmed, at most `maxLength` characters (longer input is cut).
public enum GroupLabelText {
    public static let maxLength = 40

    /// `text` trimmed, cut to `maxLength` characters, and trimmed again (a cut can end on a space). Empty means remove.
    public static func normalised(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Sample group labels (voice sample groups §2, §6). Only these two user actions write a label; grouping, eviction,
/// matching and sync never do. Each action touches only the label the group shows: contenders and unplaced labels are
/// kept, since a contender can be the real label of a group that has merged with this one for now.
extension LibraryStore {
    @discardableResult
    public func setGroupLabel(_ ref: SampleGroupRef, text: String) throws -> UUID? {
        let current = try currentGroup(ref)
        let text = GroupLabelText.normalised(text)
        guard !text.isEmpty else {
            if let shown = current.shownLabel {
                deleteGroupLabel(shown, of: current.profile)
                try context.save()
            }
            return nil
        }
        // The anchor is the group as it is now, so a Save also resets any drift.
        let label: VoiceGroupLabel
        if let shown = current.shownLabel {
            label = shown
            label.text = text
            label.editedAt = clock.now
            label.anchorVectorData = VoiceVector.packed(current.anchors)
            label.anchorDimension = current.anchors.first?.dimension ?? 0
        } else {
            label = VoiceGroupLabel(text: text, createdAt: clock.now, embeddingModelKey: current.profile.embeddingModelKey,
                                    captureChannel: ref.channel, anchors: current.anchors)
            context.insert(label)
            label.profile = current.profile
        }
        try context.save()
        return label.id
    }

    public func removeGroupLabel(_ ref: SampleGroupRef) throws {
        let current = try currentGroup(ref)
        guard let shown = current.shownLabel else { return }
        deleteGroupLabel(shown, of: current.profile)
        try context.save()
    }

    /// The group `ref` names, as the screen would draw it now from the same inputs (`GroupingInput`), with the label it
    /// shows and its members' vectors in canonical order (by sample `id.uuidString`), exactly as grouped.
    /// Throws `StoreError.groupChanged` unless a group with `ref.key` exists on `ref.channel` with the same members and
    /// the same shown label.
    private func currentGroup(_ ref: SampleGroupRef) throws
        -> (profile: VoiceProfile, shownLabel: VoiceGroupLabel?, anchors: [VoiceVector]) {
        let p = try profile(ref.profileID)
        guard let dimension = GroupingInput.dimension(ofModelKey: p.embeddingModelKey) else { throw StoreError.groupChanged }
        let split = GroupingInput.split(p, localChannel: localChannel)
        let groups = SampleGrouping.group(split.items, dimension: dimension)
        guard let group = groups.first(where: { $0.key == ref.key && $0.channel == ref.channel }),
              group.memberIDs == ref.memberIDs else { throw StoreError.groupChanged }
        let vectors = Dictionary(split.items.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
        let placement = GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: GroupingInput.anchors(p))
        let shownID = placement.placed[group.key]
        guard shownID == ref.shownLabelID else { throw StoreError.groupChanged }
        let shown = shownID.flatMap { id in p.groupLabels.first { $0.id == id } }
        let anchors = group.memberIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { vectors[$0] }
        return (p, shown, anchors)
    }

    private func deleteGroupLabel(_ label: VoiceGroupLabel, of p: VoiceProfile) {
        let id = label.id
        p.groupLabels.removeAll { $0.id == id }
        context.delete(label)
    }

    /// Profile merge (§2, R3): `src`'s labels on `dst`'s model become new labels of `dst`, with the same text, dates,
    /// channel and anchor. Call after the sample loop, which can re-enrol `dst` on `src`'s model, so the model key is
    /// compared as it is then. The originals cascade with `src`. Anchors are vectors, so the new sample ids do not
    /// matter; `mergeProfiles` keeps each sample's stored bytes, so the copied anchors still match them bit for bit.
    func copyGroupLabels(from src: VoiceProfile, into dst: VoiceProfile) {
        let copied = src.groupLabels
            .filter { !$0.text.isEmpty && $0.embeddingModelKey == dst.embeddingModelKey }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for label in copied {
            let copy = VoiceGroupLabel(text: label.text, createdAt: label.createdAt, embeddingModelKey: label.embeddingModelKey,
                                       captureChannel: label.captureChannel, anchors: [])
            context.insert(copy)
            copy.editedAt = label.editedAt
            copy.anchorVectorData = label.anchorVectorData   // the exact bytes, never decoded and packed again
            copy.anchorDimension = label.anchorDimension
            copy.profile = dst
        }
    }

    /// Re-enrolment on a new voice model (§2): the profile's labels go with its samples, since an anchor in the old
    /// model's vector space can never match again.
    func deleteGroupLabels(of p: VoiceProfile) {
        let labels = p.groupLabels
        p.groupLabels.removeAll()
        for label in labels { context.delete(label) }
    }
}
