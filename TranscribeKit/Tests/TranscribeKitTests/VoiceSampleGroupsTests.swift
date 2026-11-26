import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A voice's samples as plain values, oldest first, for the pure `VoiceSampleGroups.build`. Vectors come from
/// `GroupVoices` (0.85 within a setting, 0.36 across), so each setting axis is one sound group.
private struct Card {
    let profileID = UUID()
    var ids: [UUID] = []
    var items: [SampleGrouping.Item] = []
    var ungrouped: [GroupingInput.Ungrouped] = []
    var labels: [GroupLabelAnchor] = []
    var labelTexts: [UUID: String] = [:]
    var clipStates: [UUID: SampleClipState] = [:]
    var titles: [UUID: String] = [:]
    var sources: [UUID: UUID] = [:]

    /// A grouped sample of `axis`, one second after the previous sample.
    @discardableResult
    mutating func add(_ axis: Int, _ variant: Int, channel: String = CaptureChannel.iphone,
                      vector: VoiceVector? = nil) -> UUID {
        let id = UUID()
        items.append(SampleGrouping.Item(id: id, vector: vector ?? GroupVoices.voice(axis, variant), channel: channel,
                                         addedAtMillis: Int64(ids.count) * 1_000))
        ids.append(id)
        return id
    }

    @discardableResult
    mutating func addUngrouped(channel: String, reason: GroupingInput.UngroupedReason) -> UUID {
        let id = UUID()
        ungrouped.append(GroupingInput.Ungrouped(id: id, channel: channel, reason: reason))
        ids.append(id)
        return id
    }

    /// A label anchored on `members`, as `setGroupLabel` saves it (vectors in canonical order).
    mutating func label(_ text: String, on members: [UUID], channel: String = CaptureChannel.iphone) -> UUID {
        let id = UUID()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })
        let vectors = members.sorted { $0.uuidString < $1.uuidString }.compactMap { byID[$0] }
        labels.append(GroupLabelAnchor(id: id, channel: channel, vectors: vectors, editedAtMillis: 0))
        labelTexts[id] = text
        return id
    }

    func build(local: String = CaptureChannel.iphone) -> VoiceSampleGroupsView {
        VoiceSampleGroups.build(profileID: profileID, sortedSampleIDs: ids,
                                split: GroupingInput.Split(items: items, ungrouped: ungrouped),
                                anchors: labels, labelTexts: labelTexts, dimension: SyntheticVoices.dimension,
                                localChannel: local, clipStates: clipStates, recordingTitles: titles, sampleSource: sources)
    }
}

@Suite("Voice sample groups: the samples card")
struct VoiceSampleGroupsTests {
    let close = GroupVoices.close, far = GroupVoices.far, speaker = GroupVoices.speaker

    @Test func defaultTitlesFollowPosition() throws {
        var card = Card()
        // Interleaved in time: row indexes of a group are not contiguous.
        let c0 = card.add(close, 30), f0 = card.add(far, 33), c1 = card.add(close, 31)
        let f1 = card.add(far, 34), s0 = card.add(speaker, 36), c2 = card.add(close, 32), s1 = card.add(speaker, 37)
        let far = card.label("Far", on: [f0, f1])
        let view = card.build()

        let channel = try #require(view.channels.first)
        #expect(view.channels.map(\.channel) == [CaptureChannel.iphone] && !view.showsChannelHeaders)
        #expect(channel.groups.map(\.position) == [0, 1, 2])
        // Labelled groups count too, so "Group 3" stays the third group.
        #expect(channel.groups.map(\.title) == ["Group 1", "Far", "Group 3"])
        #expect(channel.groups.map(\.isLabelled) == [false, true, false])
        #expect(channel.groups.allSatisfy { $0.showsHeader })
        #expect(channel.groups.map(\.sampleIndexes) == [[0, 2, 5], [1, 3], [4, 6]])
        #expect(channel.sampleCount == 7 && channel.ungroupedIndexes.isEmpty && channel.ungroupedSubtitle == nil)

        // The refs are what the store checks: key = oldest member, members oldest first, the shown label.
        let refs = channel.groups.map(\.ref)
        #expect(refs.map(\.key) == [c0, f0, s0])
        #expect(refs.map(\.memberIDs) == [[c0, c1, c2], [f0, f1], [s0, s1]])
        #expect(refs.map(\.shownLabelID) == [nil, far, nil])
        #expect(refs.allSatisfy { $0.profileID == card.profileID && $0.channel == CaptureChannel.iphone })
        #expect(channel.groups.map(\.id) == refs.map(\.key))
    }

    @Test func soleUnlabelledGroupHasNoHeader() throws {
        var card = Card()
        (30..<33).forEach { card.add(close, $0) }
        let view = card.build()
        let group = try #require(view.channels.first?.groups.first)
        #expect(view.channels.count == 1 && view.channels[0].groups.count == 1)
        #expect(!group.showsHeader && group.title == "Group 1" && !group.isLabelled && group.ref.shownLabelID == nil)
        #expect(!view.showsNote && !view.showsChannelHeaders)
    }

    @Test func labelledSoleGroupShowsHeader() throws {
        var card = Card()
        let members = (30..<33).map { card.add(close, $0) }
        let label = card.label("Close", on: [members[0]])
        let group = try #require(card.build().channels.first?.groups.first)
        #expect(group.showsHeader && group.isLabelled && group.title == "Close" && group.ref.shownLabelID == label)

        // A label with no text (never shown by `GroupingInput.anchors`, but if one came through) reads as unlabelled.
        card.labelTexts[label] = ""
        let blank = try #require(card.build().channels.first?.groups.first)
        #expect(!blank.showsHeader && !blank.isLabelled && blank.title == "Group 1")
    }

    @Test func localChannelFirst() {
        var card = Card()
        card.add(close, 30, channel: CaptureChannel.mac)
        (31..<34).forEach { card.add(close, $0, channel: CaptureChannel.iphone) }
        (34..<37).forEach { card.add(close, $0, channel: CaptureChannel.ipad) }
        card.add(far, 37, channel: CaptureChannel.ipad)

        // This device first, then by size, then by name.
        let onMac = card.build(local: CaptureChannel.mac)
        #expect(onMac.channels.map(\.channel) == [CaptureChannel.mac, CaptureChannel.ipad, CaptureChannel.iphone])
        #expect(onMac.channels.map(\.sampleCount) == [1, 4, 3])
        #expect(onMac.showsChannelHeaders)
        let onIPhone = card.build(local: CaptureChannel.iphone)
        #expect(onIPhone.channels.map(\.channel) == [CaptureChannel.iphone, CaptureChannel.ipad, CaptureChannel.mac])
        // Positions and default names count within each channel.
        #expect(onIPhone.channels[1].groups.map(\.title) == ["Group 1", "Group 2"])
        #expect(onIPhone.channels[0].groups.map(\.position) == [0])

        // Only another device's samples: its header still says where they were heard.
        var other = Card()
        other.add(close, 30, channel: CaptureChannel.ipad)
        #expect(other.build(local: CaptureChannel.iphone).showsChannelHeaders)
        #expect(!Card().build().showsChannelHeaders && Card().build().channels.isEmpty)
    }

    @Test func subtitleUsesExistingRecordingTitles() throws {
        let standup = UUID(), gone = UUID(), dinner = UUID(), lunch = UUID(), walk = UUID()
        var card = Card()
        let members = (30..<36).map { card.add(close, $0) }
        // Oldest first: Standup, a deleted recording, Standup again, Dinner, Lunch, Walk.
        for (m, r) in zip(members, [standup, gone, standup, dinner, lunch, walk]) { card.sources[m] = r }
        card.titles = [standup: "Standup", dinner: "Dinner", lunch: "Lunch", walk: "Walk"]
        let group = try #require(card.build().channels.first?.groups.first)
        #expect(group.subtitle == "From \u{201C}Standup\u{201D}, \u{201C}Dinner\u{201D} and 2 more")

        typealias S = VoiceSampleGroups
        #expect(S.subtitle(memberIDs: members, sampleSource: card.sources, recordingTitles: [:]) == nil)
        #expect(S.subtitle(memberIDs: members, sampleSource: card.sources, recordingTitles: [standup: "Standup"])
                == "From \u{201C}Standup\u{201D}")
        #expect(S.subtitle(memberIDs: members, sampleSource: card.sources,
                           recordingTitles: [dinner: "Dinner", standup: "Standup"])
                == "From \u{201C}Standup\u{201D} and \u{201C}Dinner\u{201D}")
        // Two recordings with one title count once.
        #expect(S.subtitle(memberIDs: members, sampleSource: card.sources,
                           recordingTitles: [standup: "Standup", dinner: "Standup", lunch: "Lunch"])
                == "From \u{201C}Standup\u{201D} and \u{201C}Lunch\u{201D}")
        // Samples with no source recording add nothing.
        #expect(S.subtitle(memberIDs: members, sampleSource: [:], recordingTitles: card.titles) == nil)
    }

    @Test func playFallsBackToNextPlayableRepresentative() throws {
        var card = Card()
        (30..<33).forEach { card.add(close, $0) }
        let reps = try #require(SampleGrouping.group(card.items, dimension: SyntheticVoices.dimension).first).representativeIDs
        #expect(reps.count == 3)
        let range = TimeRange(start: 1, end: 4)

        card.clipStates = [reps[0]: .recordingDeleted, reps[1]: .playable(fileName: "b.wav", range: range),
                           reps[2]: .playable(fileName: "c.wav", range: range)]
        #expect(card.build().channels.first?.groups.first?.playSampleID == reps[1])
        card.clipStates[reps[0]] = .playable(fileName: "a.wav", range: range)
        #expect(card.build().channels.first?.groups.first?.playSampleID == reps[0])
        card.clipStates = [reps[0]: .noClip, reps[1]: .audioElsewhere(channel: CaptureChannel.ipad)]   // reps[2]: no state
        #expect(card.build().channels.first?.groups.first?.playSampleID == nil)
        #expect(card.build().clipStates == card.clipStates)
    }

    @Test func otherModelSamplesAreUngrouped() throws {
        var card = Card()
        card.add(close, 30)
        card.addUngrouped(channel: CaptureChannel.iphone, reason: .olderModel)   // 1
        card.add(close, 31)
        card.addUngrouped(channel: CaptureChannel.ipad, reason: .stillSyncing)   // 3
        card.add(far, 33)
        card.addUngrouped(channel: CaptureChannel.iphone, reason: .olderModel)   // 5
        // An item the grouping drops (another dimension) is still listed, never hidden.
        let odd = try #require(VoiceVector(raw: [1, 0, 0]))
        card.add(close, 0, channel: CaptureChannel.mac, vector: odd)             // 6
        card.addUngrouped(channel: CaptureChannel.mac, reason: .olderModel)      // 7

        let view = card.build()
        // Not-grouped samples count towards a channel's size: the Mac's two come before the iPad's one.
        #expect(view.channels.map(\.channel) == [CaptureChannel.iphone, CaptureChannel.mac, CaptureChannel.ipad])
        let iphone = view.channels[0], mac = view.channels[1], ipad = view.channels[2]
        #expect(iphone.groups.map(\.sampleIndexes) == [[0, 2], [4]])
        #expect(iphone.ungroupedIndexes == [1, 5] && iphone.ungroupedSubtitle == "From an older voice model")
        #expect(iphone.sampleCount == 5)
        #expect(ipad.groups.isEmpty && ipad.ungroupedIndexes == [3] && ipad.ungroupedSubtitle == "Still syncing")
        #expect(mac.groups.isEmpty && mac.ungroupedIndexes == [6, 7])
        #expect(mac.ungroupedSubtitle == "From an older voice model, or still syncing")
        // Every row shows exactly once.
        let shown = view.channels.flatMap { $0.groups.flatMap(\.sampleIndexes) + $0.ungroupedIndexes }
        #expect(shown.sorted() == Array(0..<card.ids.count))
    }

    @Test func noteShowsOnlyWithTwoGroups() {
        var card = Card()
        card.add(close, 30, channel: CaptureChannel.iphone)
        card.add(far, 33, channel: CaptureChannel.ipad)
        // Two channels of one group each: no note (groups never span channels).
        #expect(!card.build().showsNote)
        card.add(far, 34, channel: CaptureChannel.iphone)
        #expect(card.build().showsNote)
        #expect(VoiceSampleGroups.groupedNote
                == "Samples that sound alike are grouped. Play one to hear it, and label it if you like.")
        #expect(VoiceSampleGroups.defaultNote == "More samples make recognition more reliable.")
    }
}

@Suite("Voice sample groups: the samples card from a profile")
@MainActor
struct VoiceSampleGroupsProfileTests {
    @Test func refsAreTheOnesTheStoreAccepts() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let view = VoiceSampleGroups.build(profile: tom.profile, recordingsByID: [:], localChannel: h.store.localChannel,
                                           paths: h.paths)
        let groups = try #require(view.channels.first?.groups)
        #expect(view.channels.count == 1 && groups.count == 2 && view.showsNote)
        #expect(groups[0].ref == (try h.groupRef(tom.profile, holding: tom.close[0])))
        #expect(groups[1].ref == (try h.groupRef(tom.profile, holding: tom.far[0])))
        #expect(groups[0].sampleIndexes == [0, 1, 2] && groups[1].sampleIndexes == [3, 4, 5])

        // The ref a Label button hands back is accepted, and the label then shows.
        let id = try h.store.setGroupLabel(groups[1].ref, text: "Far")
        let after = VoiceSampleGroups.build(profile: tom.profile, recordingsByID: [:], localChannel: h.store.localChannel,
                                            paths: h.paths)
        let far = try #require(after.channels.first?.groups.last)
        #expect(far.title == "Far" && far.isLabelled && far.ref.shownLabelID == id)
        try h.store.removeGroupLabel(far.ref)
        #expect(try h.labels().isEmpty)
        // No sample has a source recording: nothing to play.
        #expect(view.clipStates.values.allSatisfy { $0 == .noClip } && view.clipStates.count == 6)
        #expect(groups.allSatisfy { $0.playSampleID == nil && $0.subtitle == nil })
    }

    @Test func clipStateReadsTheRecordingAndItsAudio() throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let tom = try h.tom()
        let id = UUID()
        let recording = Recording(id: id, createdAt: Seeds.Dates.c, audioFileName: h.paths.newAudioFileName(for: id),
                                  source: .microphone)
        recording.title = "Standup"
        recording.captureChannel = CaptureChannel.ipad
        h.context.insert(recording)
        let sample = tom.close[0]
        sample.sourceRecordingID = id
        sample.clipStart = 10.8
        sample.clipEnd = 14.8
        try h.context.save()
        let byID = [id: recording]

        // The WAV stayed on the iPad.
        #expect(VoiceSampleGroups.clipState(sample, recordingsByID: byID, paths: h.paths) == .audioElsewhere(channel: "ipad"))
        try Data([0]).write(to: h.paths.audioURL(fileName: recording.audioFileName))
        let playable = SampleClipState.playable(fileName: recording.audioFileName, range: TimeRange(start: 10.8, end: 14.8))
        #expect(VoiceSampleGroups.clipState(sample, recordingsByID: byID, paths: h.paths) == playable)
        #expect(VoiceSampleGroups.clipState(sample, recordingsByID: [:], paths: h.paths) == .recordingDeleted)
        #expect(VoiceSampleGroups.clipState(tom.close[1], recordingsByID: byID, paths: h.paths) == .noClip)

        // The card plays that clip from the group and names the recording.
        let view = VoiceSampleGroups.build(profile: tom.profile, recordingsByID: byID, localChannel: h.store.localChannel,
                                           paths: h.paths)
        let close = try #require(view.channels.first?.groups.first)
        #expect(close.playSampleID == sample.id && close.subtitle == "From \u{201C}Standup\u{201D}")
        #expect(view.clipStates[sample.id] == playable)
    }
}
