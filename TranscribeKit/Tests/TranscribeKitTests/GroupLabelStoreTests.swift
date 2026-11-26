import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Building blocks for the group label tests: Tom, whose samples sound like two settings.
///
/// Every voice is `mix([(.stranger, 0.6)], setting: (axis, 0.7), variant: v)`, so two voices of one setting are 0.85
/// apart and two of different settings 0.36: each setting is one sound group.
enum GroupVoices {
    static let close = 57, far = 58, speaker = 59
    static func voice(_ axis: Int, _ variant: Int) -> VoiceVector {
        SyntheticVoices.mix([(.stranger, 0.6)], setting: (axis, 0.7), variant: variant)
    }
}

/// Every field of a label, to show that something left it alone.
struct LabelBytes: Equatable {
    let id: UUID, text: String, createdAt: Date, editedAt: Date, modelKey: String, channel: String
    let anchor: Data, dimension: Int, profileID: UUID?
    init(_ l: VoiceGroupLabel) {
        id = l.id; text = l.text; createdAt = l.createdAt; editedAt = l.editedAt; modelKey = l.embeddingModelKey
        channel = l.captureChannel; anchor = l.anchorVectorData; dimension = l.anchorDimension; profileID = l.profile?.id
    }
}

@MainActor
extension WP3Harness {
    /// Tom on the fake model: three Close samples (variants 30–32) and three Far ones (33–35) on this harness's
    /// channel, a minute apart from `Seeds.Dates.c`.
    func tom() throws -> (profile: VoiceProfile, close: [VoiceSample], far: [VoiceSample]) {
        let p = VoiceProfile(name: "Tom", colourSlot: 2, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.c)
        context.insert(p)
        let close = (0..<3).map { groupSample(p, GroupVoices.voice(GroupVoices.close, 30 + $0), minute: $0) }
        let far = (0..<3).map { groupSample(p, GroupVoices.voice(GroupVoices.far, 33 + $0), minute: 3 + $0) }
        try context.save()
        return (p, close, far)
    }

    /// A confirmed 12 s sample, written directly (the store API needs a recording).
    @discardableResult
    func groupSample(_ p: VoiceProfile, _ v: VoiceVector, minute: Int, channel: String? = nil,
                     modelKey: String = EmbeddingModelID.fake.key) -> VoiceSample {
        let s = VoiceSample(vector: v, embeddingModelKey: modelKey, origin: .confirmed,
                            addedAt: Seeds.Dates.c.addingTimeInterval(Double(minute) * 60), speechSeconds: 12)
        context.insert(s)
        s.captureChannel = channel ?? store.localChannel
        s.profile = p
        return s
    }

    /// A label row written directly, anchored on `samples` as decoded for grouping (canonical order).
    @discardableResult
    func insertLabel(_ p: VoiceProfile, _ text: String, on samples: [VoiceSample], channel: String? = nil,
                     edited: Date = Seeds.Dates.c, modelKey: String = EmbeddingModelID.fake.key) throws -> VoiceGroupLabel {
        let anchors = samples.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap(\.vector)
        let l = VoiceGroupLabel(text: text, createdAt: edited, embeddingModelKey: modelKey,
                                captureChannel: channel ?? store.localChannel, anchors: anchors)
        context.insert(l)
        l.profile = p
        try context.save()
        return l
    }

    /// The groups and label placement as the screen draws them now.
    func drawn(_ p: VoiceProfile) -> (groups: [SampleGrouping.Group], placement: LabelPlacement) {
        let split = GroupingInput.split(p, localChannel: store.localChannel)
        let groups = SampleGrouping.group(split.items, dimension: GroupingInput.dimension(ofModelKey: p.embeddingModelKey) ?? 0)
        let vectors = Dictionary(split.items.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
        return (groups, GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: GroupingInput.anchors(p)))
    }

    /// The ref the screen would hand back for the group holding `sample`.
    func groupRef(_ p: VoiceProfile, holding sample: VoiceSample) throws -> SampleGroupRef {
        let now = drawn(p)
        let group = try #require(now.groups.first { $0.memberIDs.contains(sample.id) })
        return SampleGroupRef(profileID: p.id, channel: group.channel, key: group.key, memberIDs: group.memberIDs,
                              shownLabelID: now.placement.placed[group.key])
    }

    func labels() throws -> [VoiceGroupLabel] {
        try context.fetch(FetchDescriptor<VoiceGroupLabel>()).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func labelBytes() throws -> [LabelBytes] { try labels().map(LabelBytes.init) }
    func label(_ id: UUID?) throws -> VoiceGroupLabel? { try labels().first { $0.id == id } }
}

@Suite("Voice sample groups: label store")
@MainActor
struct GroupLabelStoreTests {
    @Test func setCreatesLabelAnchoredOnItsMembers() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let ref = try h.groupRef(tom.profile, holding: tom.close[0])
        #expect(ref.shownLabelID == nil && Set(ref.memberIDs) == Set(tom.close.map(\.id)))

        let id = try #require(try h.store.setGroupLabel(ref, text: "  Close \n"))
        let label = try #require(try h.label(id))
        #expect(try h.labels().count == 1)
        #expect(label.text == "Close" && label.captureChannel == CaptureChannel.iphone)
        #expect(label.embeddingModelKey == EmbeddingModelID.fake.key && label.profile?.id == tom.profile.id)
        #expect(label.createdAt == Seeds.Dates.d && label.editedAt == Seeds.Dates.d)
        // The anchor is every member's vector, as grouped, in canonical order: bit for bit.
        let members = tom.close.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap(\.vector)
        #expect(label.anchorDimension == SyntheticVoices.dimension)
        #expect(label.anchorVectorData == VoiceVector.packed(members))
        #expect(label.anchors.map(\.packed) == members.map(\.packed))

        // It shows on that group, and only there.
        let placement = h.drawn(tom.profile).placement
        #expect(placement.placed == [ref.key: id] && placement.contenders.isEmpty && placement.unplaced.isEmpty)
        #expect(try h.groupRef(tom.profile, holding: tom.close[2]).shownLabelID == id)
        #expect(try h.groupRef(tom.profile, holding: tom.far[0]).shownLabelID == nil)
        #expect(!h.context.hasChanges)
    }

    @Test func textIsTrimmedAndCutToFortyCharacters() throws {
        #expect(GroupLabelText.normalised("  Far \t") == "Far")
        #expect(GroupLabelText.normalised(" \n ").isEmpty)
        #expect(GroupLabelText.normalised(String(repeating: "a", count: 50)) == String(repeating: "a", count: 40))
        // A cut that ends on a space leaves no trailing space.
        #expect(GroupLabelText.normalised(String(repeating: "b", count: 39) + "  cc") == String(repeating: "b", count: 39))

        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let id = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]),
                                           text: "On the far side of the kitchen, by the window")
        #expect(try h.label(id)?.text == "On the far side of the kitchen, by the w")
    }

    @Test func editRefreshesTextAndAnchor() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let id = try #require(try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
        // A fourth Close sample joins; the label stays on the group (its samples are still there).
        let joined = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.close, 36), minute: 10)
        try h.context.save()
        let ref = try h.groupRef(tom.profile, holding: joined)
        #expect(ref.shownLabelID == id && ref.memberIDs.count == 4)

        let later = try WP3Harness(now: Seeds.Dates.g, container: h.container, paths: h.paths)
        #expect(try later.store.setGroupLabel(ref, text: "Near") == id)
        let label = try #require(try h.label(id))
        #expect(try h.labels().count == 1)
        #expect(label.text == "Near" && label.createdAt == Seeds.Dates.d && label.editedAt == Seeds.Dates.g)
        let members = (tom.close + [joined]).sorted { $0.id.uuidString < $1.id.uuidString }.compactMap(\.vector)
        #expect(label.anchorVectorData == VoiceVector.packed(members) && label.anchors.count == 4)
        #expect(h.drawn(tom.profile).placement.placed == [ref.key: id])
    }

    @Test func emptyTextRemoves() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close")
        #expect(try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "  \n") == nil)
        #expect(try h.labels().isEmpty && tom.profile.groupLabels.isEmpty)
        // On a group that shows no label it does nothing.
        #expect(try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]), text: "") == nil)
        #expect(try h.labels().isEmpty && !h.context.hasChanges)
        try h.store.removeGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]))   // nothing shown: nothing to do
        #expect(try h.labels().isEmpty)
    }

    @Test func staleRefThrowsGroupChanged() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let unlabelled = try h.groupRef(tom.profile, holding: tom.close[0])

        // Another label now shows on the group: the screen's "no label" is stale.
        let id = try #require(try h.store.setGroupLabel(unlabelled, text: "Close"))
        let saved = try h.labelBytes()
        #expect(throws: StoreError.groupChanged) { try h.store.setGroupLabel(unlabelled, text: "Other") }
        #expect(throws: StoreError.groupChanged) { try h.store.removeGroupLabel(unlabelled) }
        // A label the group does not show.
        let wrongLabel = SampleGroupRef(profileID: unlabelled.profileID, channel: unlabelled.channel, key: unlabelled.key,
                                        memberIDs: unlabelled.memberIDs, shownLabelID: UUID())
        #expect(throws: StoreError.groupChanged) { try h.store.removeGroupLabel(wrongLabel) }
        // Another channel, or a key that is not a group's.
        let labelled = try h.groupRef(tom.profile, holding: tom.close[0])
        #expect(labelled.shownLabelID == id)
        let otherChannel = SampleGroupRef(profileID: labelled.profileID, channel: CaptureChannel.mac, key: labelled.key,
                                          memberIDs: labelled.memberIDs, shownLabelID: id)
        #expect(throws: StoreError.groupChanged) { try h.store.setGroupLabel(otherChannel, text: "Other") }
        let notAKey = SampleGroupRef(profileID: labelled.profileID, channel: labelled.channel, key: labelled.memberIDs[1],
                                     memberIDs: labelled.memberIDs, shownLabelID: id)
        #expect(throws: StoreError.groupChanged) { try h.store.setGroupLabel(notAKey, text: "Other") }

        // The members changed: a sample joined, then the key sample was removed.
        h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.close, 36), minute: 10)
        try h.context.save()
        #expect(throws: StoreError.groupChanged) { try h.store.setGroupLabel(labelled, text: "Other") }
        #expect(throws: StoreError.groupChanged) { try h.store.removeGroupLabel(labelled) }
        let afterJoin = try h.groupRef(tom.profile, holding: tom.close[0])
        try h.store.removeSample(id: afterJoin.key)
        #expect(throws: StoreError.groupChanged) { try h.store.removeGroupLabel(afterJoin) }
        #expect(try h.labelBytes() == saved)   // nothing was written by a refused action

        // A voice that no longer exists is not a changed group.
        let gone = SampleGroupRef(profileID: UUID(), channel: labelled.channel, key: labelled.key,
                                  memberIDs: labelled.memberIDs, shownLabelID: id)
        #expect(throws: StoreError.notFound("profile \(gone.profileID)")) { try h.store.removeGroupLabel(gone) }
    }

    @Test func saveAndRemoveTouchOnlyTheShownLabel() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        // L1 holds two of the Close samples and shows; L2 holds the third and is its contender; L3's samples sound like
        // nothing Tom has now (unplaced); L4 was saved on the iPad's Close group, which is not on this device.
        let l1 = try h.insertLabel(tom.profile, "Close", on: Array(tom.close[0...1]))
        let l2 = try h.insertLabel(tom.profile, "Near", on: [tom.close[2]], edited: Seeds.Dates.d)
        let gone = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.speaker, 37), minute: 20)
        let l3 = try h.insertLabel(tom.profile, "Speaker", on: [gone])
        tom.profile.samples.removeAll { $0.id == gone.id }
        h.context.delete(gone)
        let l4 = try h.insertLabel(tom.profile, "iPad close", on: tom.close, channel: CaptureChannel.ipad)
        try h.context.save()
        let ref = try h.groupRef(tom.profile, holding: tom.close[0])
        var placement = h.drawn(tom.profile).placement
        #expect(ref.shownLabelID == l1.id)
        #expect(placement.contenders == [ref.key: [l2.id]])
        #expect(placement.unplaced == [l3.id, l4.id].sorted { $0.uuidString < $1.uuidString })
        let others = try h.labelBytes().filter { $0.id != l1.id }

        // Save updates the shown label only.
        #expect(try h.store.setGroupLabel(ref, text: "Close up") == l1.id)
        #expect(l1.text == "Close up" && l1.anchors.count == 3)
        #expect(try h.labelBytes().filter { $0.id != l1.id } == others)

        // Remove deletes the shown label only; the contender may then show, which is accepted.
        try h.store.removeGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]))
        #expect(try h.labelBytes() == others)
        placement = h.drawn(tom.profile).placement
        #expect(placement.placed == [ref.key: l2.id])
    }

    @Test func mergeCopiesLabelsWithNewIDs() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let closeID = try #require(try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
        let oldModel = try h.insertLabel(tom.profile, "Old model", on: tom.far, modelKey: "old-embedder@1#256")
        let original = try #require(try h.labelBytes().first { $0.id == closeID })
        // Thomas is Tom: one Far sample, with his own label.
        let thomas = VoiceProfile(name: "Thomas", colourSlot: 3, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.c)
        h.context.insert(thomas)
        let thomasFar = h.groupSample(thomas, GroupVoices.voice(GroupVoices.far, 36), minute: 30)
        try h.context.save()
        let farID = try #require(try h.store.setGroupLabel(try h.groupRef(thomas, holding: thomasFar), text: "Far"))

        try h.store.mergeProfiles(source: tom.profile.id, into: thomas.id)
        let copies = thomas.groupLabels.filter { $0.id != farID }
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(copy.id != closeID && copy.profile?.id == thomas.id)
        #expect(copy.text == original.text && copy.createdAt == original.createdAt && copy.editedAt == original.editedAt)
        #expect(copy.captureChannel == original.channel && copy.embeddingModelKey == original.modelKey)
        #expect(copy.anchorVectorData == original.anchor && copy.anchorDimension == original.dimension)
        // The originals went with Tom; the other model's label was not copied.
        #expect(try h.labels().map(\.id).sorted { $0.uuidString < $1.uuidString } == [farID, copy.id].sorted { $0.uuidString < $1.uuidString })
        #expect(try h.label(oldModel.id) == nil)
        // The copy shows on the merged Close group, and Thomas's own label on the merged Far group.
        let now = h.drawn(thomas)
        let closeGroup = try #require(now.groups.first { $0.memberIDs.count == 3 && !$0.memberIDs.contains(thomasFar.id) })
        let farGroup = try #require(now.groups.first { $0.memberIDs.contains(thomasFar.id) })
        #expect(now.groups.count == 2 && farGroup.memberIDs.count == 4)
        #expect(now.placement.placed == [closeGroup.key: copy.id, farGroup.key: farID])
    }

    /// R3: the labels are copied after the samples, so a target that the sample loop re-enrols on the source's model
    /// takes the source's labels (and loses its own old-model ones with its old samples).
    @Test func mergeCopiesLabelsAfterTheTargetReEnrols() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let closeID = try #require(try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close"))
        let legacy = "old-embedder@1#256"
        let thomas = VoiceProfile(name: "Thomas", colourSlot: 3, embeddingModelKey: legacy, now: Seeds.Dates.c)
        h.context.insert(thomas)
        let thomasOld = try h.insertLabel(thomas, "Old far", on: [], modelKey: legacy)
        thomasOld.anchorVectorData = VoiceVector.packed([GroupVoices.voice(GroupVoices.far, 36)])
        thomasOld.anchorDimension = SyntheticVoices.dimension
        try h.context.save()

        try h.store.mergeProfiles(source: tom.profile.id, into: thomas.id)
        #expect(thomas.embeddingModelKey == EmbeddingModelID.fake.key && thomas.samples.count == 6)
        let labels = try h.labels()
        #expect(labels.count == 1)
        let copy = try #require(labels.first)
        #expect(copy.id != closeID && copy.id != thomasOld.id && copy.text == "Close" && copy.profile?.id == thomas.id)
        #expect(h.drawn(thomas).placement.placed.values.map { $0 } == [copy.id])
    }

    /// A merge keeps each sample's stored bytes, so a copied label's anchor still finds every one of its samples bit
    /// for bit (`present`), even for vectors whose bits change when they are normalised once more.
    @Test func mergeKeepsSampleBytesSoCopiedAnchorsStayPresent() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        // Close voices whose decoded vector changes bits when it is normalised again: a merge that re-packed the
        // decoded vector would store different bytes.
        let awkward = (30..<400).lazy.map { GroupVoices.voice(GroupVoices.close, $0) }.filter { v in
            guard let decoded = VoiceVector(packed: v.packed), let again = VoiceVector(packed: decoded.packed) else { return false }
            return again.packed != decoded.packed
        }
        let voices = Array(awkward.prefix(3))
        try #require(voices.count == 3)
        let tom = VoiceProfile(name: "Tom", colourSlot: 2, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.c)
        h.context.insert(tom)
        let close = voices.enumerated().map { h.groupSample(tom, $0.element, minute: $0.offset) }
        try h.context.save()
        _ = try #require(try h.store.setGroupLabel(try h.groupRef(tom, holding: close[0]), text: "Close"))
        let thomas = VoiceProfile(name: "Thomas", colourSlot: 3, embeddingModelKey: EmbeddingModelID.fake.key, now: Seeds.Dates.c)
        h.context.insert(thomas)
        h.groupSample(thomas, GroupVoices.voice(GroupVoices.far, 36), minute: 30)
        try h.context.save()
        let sourceBytes = Set(close.map(\.vectorData))

        try h.store.mergeProfiles(source: tom.id, into: thomas.id)
        #expect(sourceBytes.isSubset(of: Set(thomas.samples.map(\.vectorData))))
        let copy = try #require(GroupingInput.anchors(thomas).first)
        #expect(copy.vectors.count == 3)
        let split = GroupingInput.split(thomas, localChannel: h.store.localChannel)
        let groups = SampleGrouping.group(split.items, dimension: SyntheticVoices.dimension)
        let vectors = Dictionary(split.items.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
        let merged = try #require(groups.first { $0.memberIDs.count == 3 })
        #expect(GroupLabelResolver.fit(copy, merged, memberVectors: vectors)?.present == 3)
    }

    @Test func forgetDeletesLabels() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close")
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]), text: "Far")
        #expect(try h.labels().count == 2)
        try h.store.forgetProfile(tom.profile.id)
        #expect(try h.labels().isEmpty && h.count(VoiceSample.self) == 0)
    }

    @Test func reEnrolDeletesLabels() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close")
        // Removing every sample is not a re-enrolment: the label stays, quietly unplaced.
        for s in tom.close + tom.far { try h.store.removeSample(id: s.id) }
        #expect(try tom.profile.needsResample && h.labels().count == 1)
        #expect(h.drawn(tom.profile).placement.unplaced.count == 1)

        // A sample on a new voice model re-enrols the profile; the old model's labels go with its samples.
        let next = "next-embedder@2#256"
        #expect(h.store.insertSample(into: tom.profile, vector: GroupVoices.voice(GroupVoices.close, 36), modelKey: next,
                                     origin: .named, speechSeconds: 12, sourceRecordingID: nil, sourceSpeakerID: nil,
                                     clip: nil, quote: nil, channel: CaptureChannel.iphone, input: nil))
        try h.context.save()
        #expect(tom.profile.embeddingModelKey == next && tom.profile.samples.count == 1)
        #expect(try h.labels().isEmpty && tom.profile.groupLabels.isEmpty)
    }

    /// Processing, eviction, removal, rollback and a recording delete never write a label.
    @Test func onlyUserActionsWriteLabels() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close")
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]), text: "Far")
        let saved = try h.labelBytes()
        #expect(saved.count == 2)

        // Processing: Tom is auto-labelled in a new recording (which may add an automatic sample).
        let rec = try h.readyRecording(
            turns: SeedContent.conversationB,
            drafts: [WP3Docs.draft("S1", 1, clean: 12, vector: GroupVoices.voice(GroupVoices.close, 38))],
            decisions: ["S1": .autoLabel(profileID: tom.profile.id, score: 0.85, margin: 0.6)])
        #expect(try h.recording(rec).speaker("S1")?.profile?.id == tom.profile.id)
        #expect(try h.labelBytes() == saved)

        // Eviction: Close samples past the cap of 12 on this channel.
        for v in 39..<47 {
            h.store.insertSample(into: tom.profile, vector: GroupVoices.voice(GroupVoices.close, v), modelKey: EmbeddingModelID.fake.key,
                                 origin: .confirmed, speechSeconds: 12, sourceRecordingID: nil, sourceSpeakerID: nil, clip: nil,
                                 quote: nil, channel: CaptureChannel.iphone, input: nil)
        }
        try h.context.save()
        #expect(tom.profile.samples.count == MatchPolicy.default.maxSamplesPerProfile)
        #expect(try h.labelBytes() == saved)

        // Removal of a sample.
        try h.store.removeSample(id: try #require(tom.profile.sortedSamples.last).id)
        #expect(try h.labelBytes() == saved)

        // Rollback: the auto-labelled voice is someone else.
        _ = try h.store.nameSpeaker(recordingID: rec, key: "S1", as: .newPerson(name: "Sam"), remember: true)
        #expect(try h.recording(rec).speaker("S1")?.profile?.name == "Sam")
        #expect(try h.labelBytes() == saved)

        // A recording delete.
        try h.store.delete(id: rec)
        #expect(try h.labelBytes() == saved)
    }

    /// Labels are for the user only: saving, editing and removing one never changes what matching sees.
    @Test func labellingNeverChangesMatching() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.library)
        let tom = try h.tom()
        let key = EmbeddingModelID.fake.key
        func matching() throws -> ([ProfileCandidate], [VoiceVector]) {
            (try h.store.matchCandidates(modelKey: key), try h.store.matchCohort(modelKey: key, excludingRecording: UUID()))
        }
        let before = try matching()
        #expect(before.0.contains { $0.id == tom.profile.id })

        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Close")
        #expect(try matching() == before)
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]), text: "Near")
        _ = try h.store.setGroupLabel(try h.groupRef(tom.profile, holding: tom.far[0]), text: "Far")
        #expect(try matching() == before)
        try h.store.removeGroupLabel(try h.groupRef(tom.profile, holding: tom.close[0]))
        #expect(try matching() == before)
        #expect(LibraryStore.candidate(tom.profile) == before.0.first { $0.id == tom.profile.id })
    }

    @Test func notGroupedSamplesSayWhy() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let older = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.close, 36), minute: 10, modelKey: "old-embedder@1#256")
        let syncing = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.close, 37), minute: 11)
        syncing.vectorData = try #require(VoiceVector(raw: [1])).packed   // a synced sample's placeholder
        let ipad = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.close, 38), minute: 12, channel: CaptureChannel.ipad)
        let unstamped = h.groupSample(tom.profile, GroupVoices.voice(GroupVoices.far, 39), minute: 13)
        unstamped.captureChannel = nil
        try h.context.save()

        let split = GroupingInput.split(tom.profile, localChannel: CaptureChannel.iphone)
        #expect(split.ungrouped == [GroupingInput.Ungrouped(id: older.id, channel: CaptureChannel.iphone, reason: .olderModel),
                                    GroupingInput.Ungrouped(id: syncing.id, channel: CaptureChannel.iphone, reason: .stillSyncing)])
        #expect(split.items.map(\.id) == (tom.close + tom.far + [ipad, unstamped]).map(\.id))
        #expect(split.items.first { $0.id == ipad.id }?.channel == CaptureChannel.ipad)
        #expect(split.items.first { $0.id == unstamped.id }?.channel == CaptureChannel.iphone)
        #expect(split.items[0].addedAtMillis == Int64((Seeds.Dates.c.timeIntervalSince1970 * 1000).rounded()))
        #expect(split.items[0].vector.packed == tom.close[0].vector?.packed)

        #expect(GroupingInput.dimension(ofModelKey: EmbeddingModelID.fake.key) == 256)
        #expect(GroupingInput.dimension(ofModelKey: "no-dimension") == nil)
        #expect(GroupingInput.dimension(ofModelKey: "name@rev#0") == nil)
        #expect(GroupingInput.dimension(ofModelKey: "name@rev#abc") == nil)
    }

    @Test func anchorsSkipLabelsThatCannotShow() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let shown = try h.insertLabel(tom.profile, "Close", on: tom.close, edited: Seeds.Dates.d)
        try h.insertLabel(tom.profile, "", on: tom.far)                                          // a placeholder
        try h.insertLabel(tom.profile, "Old", on: tom.far, modelKey: "old-embedder@1#256")      // another model
        let unreadable = try h.insertLabel(tom.profile, "Broken", on: tom.far)
        unreadable.anchorVectorData = Data([1, 2, 3])
        try h.context.save()
        let anchors = GroupingInput.anchors(tom.profile)
        #expect(anchors.map(\.id) == [shown.id])
        #expect(anchors.first?.channel == CaptureChannel.iphone)
        #expect(anchors.first?.editedAtMillis == Int64((Seeds.Dates.d.timeIntervalSince1970 * 1000).rounded()))
        #expect(anchors.first?.vectors.map(\.packed) == tom.close.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap(\.vector?.packed))
    }
}

extension SyncSuites {
    /// Labels stay on each device in this build (R0): sync ignores them.
    @Suite("Sync: group labels stay local")
    @MainActor
    struct GroupLabelLocalSyncTests {
        /// Every state row as it was agreed with the server.
        func rows(_ d: FakeDevice) -> [String: [String: String]] {
            Dictionary(d.stateRows().map { ($0.recordName, $0.baseHashes) }, uniquingKeysWith: { a, _ in a })
        }

        /// Nothing waits to send, and every record still hashes to what the server holds.
        func expectNothingQueued(_ t: TwoDevices, cloud before: [String: [String: SyncValue]], sequence: Int,
                                 rows agreed: [String: [String: String]],
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
            await t.a.sync.flushAndEnqueue()
            #expect(t.a.pending == 0, sourceLocation: sourceLocation)
            #expect(await t.a.transport.pendingCount == 0, sourceLocation: sourceLocation)
            #expect(t.a.stateRows().allSatisfy { $0.pending == .none }, sourceLocation: sourceLocation)
            #expect(rows(t.a) == agreed, sourceLocation: sourceLocation)
            let projector = RecordProjector(context: t.a.context)
            for row in t.a.stateRows() {
                guard let id = row.recordID, let e = projector.entity(id) else { continue }
                #expect(RecordProjector.hashes(e, unresolved: row.unresolvedLinks) == row.baseHashes, "\(row.recordName)",
                        sourceLocation: sourceLocation)
            }
            #expect(await t.cloud.records(account: "account-1") == before, sourceLocation: sourceLocation)
            #expect(await t.cloud.sequence(account: "account-1") == sequence, sourceLocation: sourceLocation)
        }

        @Test func labelChangesQueueNothingToSync() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let h = try WP3Harness(container: t.a.container, paths: t.a.paths, channel: t.a.channel)
            let karan = try #require(t.a.profile(named: "Karan"))
            let sample = try #require(karan.samples.first)
            let cloud = await t.cloud.records(account: "account-1")
            let sequence = await t.cloud.sequence(account: "account-1")
            let agreed = rows(t.a)

            // Save, edit and remove, each through the device's own store.
            let id = try #require(try t.a.store.setGroupLabel(try h.groupRef(karan, holding: sample), text: "Close"))
            await expectNothingQueued(t, cloud: cloud, sequence: sequence, rows: agreed)
            t.a.clock.advance(60)
            #expect(try t.a.store.setGroupLabel(try h.groupRef(karan, holding: sample), text: "Near") == id)
            await expectNothingQueued(t, cloud: cloud, sequence: sequence, rows: agreed)
            try t.a.store.removeGroupLabel(try h.groupRef(karan, holding: sample))
            await expectNothingQueued(t, cloud: cloud, sequence: sequence, rows: agreed)
            #expect(t.a.count(VoiceGroupLabel.self) == 0)

            // A full sync sends nothing, and the other device gets no label.
            let label = try #require(try t.a.store.setGroupLabel(try h.groupRef(karan, holding: sample), text: "Close"))
            await t.settleBoth()
            await expectNothingQueued(t, cloud: cloud, sequence: sequence, rows: agreed)
            #expect(t.b.count(VoiceGroupLabel.self) == 0)

            // Turning sync off, a new iCloud environment and "Remove iCloud Copy" leave the label alone: it is local data.
            try await t.a.sync.disable(removeCloudCopy: false)
            #expect(try h.label(label)?.text == "Close")
            t.a.sync.cloudEnvironment = "Production"
            await t.a.sync.enable()
            #expect(t.a.settings.syncCloudEnvironment == "Production")
            #expect(try h.label(label)?.text == "Close")
            try await t.a.sync.disable(removeCloudCopy: true)
            #expect(t.a.stateRows().isEmpty)
            #expect(try h.label(label)?.text == "Close" && t.a.count(VoiceGroupLabel.self) == 1)
            #expect(try h.label(label)?.profile?.id == karan.id)
        }
    }
}
