import Foundation

/// A saved group label as the resolver sees it.
public struct GroupLabelAnchor: Sendable, Equatable {
    public let id: UUID
    /// The channel of the group it was saved on; it never applies on another channel.
    public let channel: String
    /// The vectors of every member of the group when the label was last saved, in canonical order (sample ids
    /// sorted by `uuidString`), read back bit for bit (`VoiceVector.unpacked`). Empty when unreadable.
    public let vectors: [VoiceVector]
    /// Tie-break only: the later edit shows.
    public let editedAtMillis: Int64
    public init(id: UUID, channel: String, vectors: [VoiceVector], editedAtMillis: Int64) {
        self.id = id; self.channel = channel; self.vectors = vectors; self.editedAtMillis = editedAtMillis
    }
}

/// Where each label shows now.
public struct LabelPlacement: Sendable, Equatable {
    /// Group key → the label it shows; one label per group and one group per label.
    public var placed: [UUID: UUID]
    /// Group key → labels whose best group is this one but lost it, best first. Kept, never shown.
    public var contenders: [UUID: [UUID]]
    /// Labels eligible for no group now, by `id.uuidString`. Kept, never shown; they come back by themselves when
    /// samples like theirs return.
    public var unplaced: [UUID]
    public init(placed: [UUID: UUID] = [:], contenders: [UUID: [UUID]] = [:], unplaced: [UUID] = []) {
        self.placed = placed; self.contenders = contenders; self.unplaced = unplaced
    }
}

/// How well a label fits a group, as integers so that every comparison is exact.
public struct LabelFit: Sendable, Equatable {
    /// How many of the label's saved vectors are bit-for-bit equal to a member of the group now: the labelled
    /// samples still in it.
    public let present: Int
    /// `SampleGrouping.q` of the average-linkage cosine between the label's saved vectors and the group's members.
    public let linkage: Int
    public init(present: Int, linkage: Int) { self.present = present; self.linkage = linkage }
}

/// Attaches saved labels to the groups `SampleGrouping` finds now. Pure; it never writes anything.
///
/// A label L fits a group G on its own channel when every saved vector of L has G's dimension. L is eligible for G
/// when G still holds at least one of L's samples (`present > 0`) or G's members average at least
/// `SampleGroupPolicy.joinCosine` to L's samples (the same rule that joins two clusters). Eligible pairs are ranked by
/// `present`, then `linkage`, both highest first, then the later `editedAtMillis`, then `L.id.uuidString`, then
/// `G.key.uuidString`, and assigned greedily one to one: each label goes on its best-ranked eligible group when that
/// group is still free, and is a contender for it otherwise (it never moves on to a lower-ranked group).
///
/// So a label stays on the group that still holds its samples however loose that group becomes; once its samples
/// have all gone it stays only on a group its samples would have been grouped with, so it never jumps onto a
/// neighbouring group that never joined its own; and when its group splits, the part holding more of its samples
/// keeps it. Input order never changes the result. Label ids are expected to be unique (they are row ids).
public enum GroupLabelResolver {
    /// - Parameter memberVectors: every grouped item's vector by sample id (the items passed to
    ///   `SampleGrouping.group`).
    public static func resolve(groups: [SampleGrouping.Group], memberVectors: [UUID: VoiceVector],
                               labels: [GroupLabelAnchor], policy: SampleGroupPolicy = .default) -> LabelPlacement {
        let joinScore = SampleGrouping.q(Double(policy.joinCosine))
        var pairs: [(label: GroupLabelAnchor, group: SampleGrouping.Group, fit: LabelFit)] = []
        for label in labels {
            for group in groups {
                guard let fit = fit(label, group, memberVectors: memberVectors),
                      fit.present > 0 || fit.linkage >= joinScore else { continue }
                pairs.append((label, group, fit))
            }
        }
        pairs.sort { a, b in
            if a.fit.present != b.fit.present { return a.fit.present > b.fit.present }
            if a.fit.linkage != b.fit.linkage { return a.fit.linkage > b.fit.linkage }
            if a.label.editedAtMillis != b.label.editedAtMillis { return a.label.editedAtMillis > b.label.editedAtMillis }
            if a.label.id != b.label.id { return a.label.id.uuidString < b.label.id.uuidString }
            return a.group.key.uuidString < b.group.key.uuidString
        }

        var placement = LabelPlacement()
        var placedLabels = Set<UUID>()
        var bestGroup: [UUID: UUID] = [:]     // label → its best-ranked eligible group
        var labelOrder: [UUID] = []           // labels in the order of their best pair
        for pair in pairs {
            // Only a label's best pair counts: a label whose best group is taken is a contender for it, never moved
            // on to a lower-ranked group.
            guard bestGroup[pair.label.id] == nil else { continue }
            bestGroup[pair.label.id] = pair.group.key
            labelOrder.append(pair.label.id)
            guard placement.placed[pair.group.key] == nil else { continue }
            placement.placed[pair.group.key] = pair.label.id
            placedLabels.insert(pair.label.id)
        }
        for label in labelOrder where !placedLabels.contains(label) {
            placement.contenders[bestGroup[label]!, default: []].append(label)
        }
        placement.unplaced = labels.map(\.id).filter { bestGroup[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
        return placement
    }

    /// How `label` fits `group`; nil when they are on different channels, the label has no vectors, a dimension
    /// differs, or no member's vector is known.
    public static func fit(_ label: GroupLabelAnchor, _ group: SampleGrouping.Group,
                           memberVectors: [UUID: VoiceVector]) -> LabelFit? {
        let dimension = group.centroid.dimension
        guard label.channel == group.channel, !label.vectors.isEmpty,
              label.vectors.allSatisfy({ $0.dimension == dimension }) else { return nil }
        let members = group.memberIDs.compactMap { memberVectors[$0] }.filter { $0.dimension == dimension }
        guard let linkage = SampleGrouping.averageLinkage(label.vectors, members) else { return nil }
        let memberBytes = Set(members.map(\.packed))
        let present = label.vectors.filter { memberBytes.contains($0.packed) }.count
        return LabelFit(present: present, linkage: SampleGrouping.q(linkage))
    }
}
