import Foundation
import TranscribeCore

/// What a voice's samples card shows (voice sample groups §6, §7): the samples by channel, each channel's sound
/// groups with their labels, and the samples that are not grouped. Derived on every draw; nothing here is stored.
public struct VoiceSampleGroupsView: Equatable, Sendable {
    /// This device's channel first, then by sample count (most first), then by channel name.
    public var channels: [ChannelSection]
    /// Some channel has two or more groups: the card explains grouping instead of today's note.
    public var showsNote: Bool
    /// The channel headers show ("On this iPhone · 8"): more than one channel, or the only one is another device's.
    /// One channel of this device's reads as it did before channels were shown.
    public var showsChannelHeaders: Bool
    /// Every sample's clip state, by sample id, so a row needs no second look at the disk.
    public var clipStates: [UUID: SampleClipState]

    public init(channels: [ChannelSection], showsNote: Bool, showsChannelHeaders: Bool,
                clipStates: [UUID: SampleClipState]) {
        self.channels = channels; self.showsNote = showsNote; self.showsChannelHeaders = showsChannelHeaders
        self.clipStates = clipStates
    }
}

/// One channel of the samples card: its groups, oldest first, then its samples that are not grouped.
public struct ChannelSection: Identifiable, Equatable, Sendable {
    public let channel: String
    public let groups: [GroupSection]
    /// Indexes into `sortedSamples`, ascending, of this channel's samples that are not grouped.
    public let ungroupedIndexes: [Int]
    /// Under "Not grouped · N": "From an older voice model", "Still syncing", or both; nil when nothing is ungrouped.
    public let ungroupedSubtitle: String?
    public var id: String { channel }
    /// Every sample of this channel, grouped or not (the channel header's count).
    public var sampleCount: Int { groups.reduce(0) { $0 + $1.sampleIndexes.count } + ungroupedIndexes.count }

    public init(channel: String, groups: [GroupSection], ungroupedIndexes: [Int], ungroupedSubtitle: String?) {
        self.channel = channel; self.groups = groups; self.ungroupedIndexes = ungroupedIndexes
        self.ungroupedSubtitle = ungroupedSubtitle
    }
}

/// One sound group of a channel.
public struct GroupSection: Identifiable, Equatable, Sendable {
    /// What a Label or Remove action hands the store, which checks it is still the group drawn here.
    public let ref: SampleGroupRef
    /// 0-based within the channel, counting labelled groups too (accessibility ids; "Group N" is `position + 1`).
    public let position: Int
    /// The label's text, or "Group N".
    public let title: String
    public let isLabelled: Bool
    /// "From “Standup” and “Dinner”": the source recordings still here, in member order; nil when none is.
    public let subtitle: String?
    /// Indexes into `sortedSamples`, ascending (oldest first).
    public let sampleIndexes: [Int]
    /// The group's play button plays this sample: the first representative whose clip can play; nil hides the button.
    public let playSampleID: UUID?
    /// False only for a channel's sole unlabelled group not heard through Mac audio, which then looks as the channel
    /// did before grouping.
    public let showsHeader: Bool
    /// Most of the group's samples were heard through Mac audio (`captureInput == systemAudio`): the header says
    /// "Heard through Mac audio" (`VoiceSampleGroups.macAudioNote`). Display only, like the groups themselves.
    public let heardThroughMacAudio: Bool
    public var id: UUID { ref.key }

    public init(ref: SampleGroupRef, position: Int, title: String, isLabelled: Bool, subtitle: String?,
                sampleIndexes: [Int], playSampleID: UUID?, showsHeader: Bool, heardThroughMacAudio: Bool = false) {
        self.ref = ref; self.position = position; self.title = title; self.isLabelled = isLabelled
        self.subtitle = subtitle; self.sampleIndexes = sampleIndexes; self.playSampleID = playSampleID
        self.showsHeader = showsHeader; self.heardThroughMacAudio = heardThroughMacAudio
    }
}

/// Builds `VoiceSampleGroupsView`. The core takes plain values only (no SwiftData), so it is tested without a store;
/// the main-actor conveniences read a `VoiceProfile` through `GroupingInput`, exactly as the store does when it checks
/// a label action, so the screen's refs are the ones the store accepts.
public enum VoiceSampleGroups {
    /// "Samples that sound alike are grouped…", shown instead of today's note when `showsNote` is true. Groups are
    /// scored on their own when matching, and curation keeps a sample of every group (with a confirmed sample).
    public static let groupedNote = "Samples that sound alike are grouped. Each group is recognised on its own, and Transcribe keeps at least one sample from every group."
    /// Under a group's title when most of its samples were heard through Mac audio (a call, or another app's sound).
    public static let macAudioNote = "Heard through Mac audio"
    /// Today's note, kept while no channel has two groups.
    public static let defaultNote = "More samples make recognition more reliable."

    /// The pure core.
    /// - `sortedSampleIDs`: the profile's `sortedSamples` ids; row indexes are positions in it.
    /// - `split`: `GroupingInput.split` of the same samples. `anchors`: `GroupingInput.anchors`. `labelTexts`: label
    ///   text by label id. `dimension`: the profile's model dimension (`GroupingInput.dimension(ofModelKey:)`).
    /// - `clipStates`: by sample id; a sample with none counts as not playable.
    /// - `recordingTitles`: display titles of the recordings that exist here, by id. `sampleSource`: each sample's
    ///   source recording id.
    /// - `captureInputs`: each sample's `captureInput`, by sample id (a group whose samples are mostly `systemAudio` is
    ///   marked as heard through Mac audio).
    /// An item the grouping drops (a vector of another dimension) is listed as not grouped, "still syncing", so no
    /// sample is ever hidden.
    public static func build(profileID: UUID, sortedSampleIDs: [UUID], split: GroupingInput.Split,
                             anchors: [GroupLabelAnchor], labelTexts: [UUID: String], dimension: Int,
                             localChannel: String, clipStates: [UUID: SampleClipState],
                             recordingTitles: [UUID: String], sampleSource: [UUID: UUID],
                             captureInputs: [UUID: String] = [:],
                             policy: SampleGroupPolicy = .default) -> VoiceSampleGroupsView {
        let index = Dictionary(sortedSampleIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = SampleGrouping.group(split.items, dimension: dimension, policy: policy)
        let vectors = Dictionary(split.items.map { ($0.id, $0.vector) }, uniquingKeysWith: { a, _ in a })
        let placement = GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: anchors, policy: policy)

        // Samples that are not grouped, by channel.
        var ungrouped: [String: [(index: Int, reason: GroupingInput.UngroupedReason)]] = [:]
        for u in split.ungrouped {
            guard let i = index[u.id] else { continue }
            ungrouped[u.channel, default: []].append((i, u.reason))
        }
        let grouped = Set(groups.flatMap(\.memberIDs))
        for item in split.items where !grouped.contains(item.id) {
            guard let i = index[item.id] else { continue }
            ungrouped[item.channel, default: []].append((i, .stillSyncing))
        }

        // Groups by channel, in the grouping's order (oldest key first).
        var groupsByChannel: [String: [SampleGrouping.Group]] = [:]
        for g in groups { groupsByChannel[g.channel, default: []].append(g) }

        var sections: [ChannelSection] = []
        for channel in Set(groupsByChannel.keys).union(ungrouped.keys) {
            let channelGroups = groupsByChannel[channel] ?? []
            var built: [GroupSection] = []
            for (position, g) in channelGroups.enumerated() {
                let labelID = placement.placed[g.key]
                let text = labelID.flatMap { labelTexts[$0] }.flatMap { $0.isEmpty ? nil : $0 }
                let ref = SampleGroupRef(profileID: profileID, channel: channel, key: g.key, memberIDs: g.memberIDs,
                                         shownLabelID: labelID)
                let macAudio = heardThroughMacAudio(memberIDs: g.memberIDs, captureInputs: captureInputs)
                built.append(GroupSection(
                    ref: ref, position: position, title: text ?? "Group \(position + 1)", isLabelled: text != nil,
                    subtitle: subtitle(memberIDs: g.memberIDs, sampleSource: sampleSource, recordingTitles: recordingTitles),
                    sampleIndexes: g.memberIDs.compactMap { index[$0] }.sorted(),
                    playSampleID: g.representativeIDs.first { clipStates[$0]?.isPlayable == true },
                    showsHeader: channelGroups.count > 1 || text != nil || macAudio,
                    heardThroughMacAudio: macAudio))
            }
            let rest = (ungrouped[channel] ?? []).sorted { $0.index < $1.index }
            sections.append(ChannelSection(channel: channel, groups: built, ungroupedIndexes: rest.map(\.index),
                                           ungroupedSubtitle: ungroupedSubtitle(Set(rest.map(\.reason)))))
        }
        sections.sort { a, b in
            if (a.channel == localChannel) != (b.channel == localChannel) { return a.channel == localChannel }
            if a.sampleCount != b.sampleCount { return a.sampleCount > b.sampleCount }
            return a.channel < b.channel
        }
        return VoiceSampleGroupsView(
            channels: sections,
            showsNote: sections.contains { $0.groups.count >= 2 },
            showsChannelHeaders: sections.count > 1 || sections.contains { $0.channel != localChannel },
            clipStates: clipStates)
    }

    /// More than half of the members were heard through Mac audio.
    static func heardThroughMacAudio(memberIDs: [UUID], captureInputs: [UUID: String]) -> Bool {
        let heard = memberIDs.filter { captureInputs[$0] == CaptureDetail.Input.systemAudio }.count
        return heard * 2 > memberIDs.count
    }

    /// "From “Standup”", "From “Standup” and “Dinner”", "From “Standup”, “Dinner” and 2 more": the distinct titles
    /// of the members' source recordings that exist here, in member order; nil when none exists.
    static func subtitle(memberIDs: [UUID], sampleSource: [UUID: UUID], recordingTitles: [UUID: String]) -> String? {
        var titles: [String] = []
        for id in memberIDs {
            guard let source = sampleSource[id], let title = recordingTitles[source], !titles.contains(title) else { continue }
            titles.append(title)
        }
        let quoted = titles.map { "\u{201C}\($0)\u{201D}" }
        switch quoted.count {
        case 0: return nil
        case 1: return "From \(quoted[0])"
        case 2: return "From \(quoted[0]) and \(quoted[1])"
        default: return "From \(quoted[0]), \(quoted[1]) and \(quoted.count - 2) more"
        }
    }

    /// Why a channel's samples are not grouped, under "Not grouped · N".
    static func ungroupedSubtitle(_ reasons: Set<GroupingInput.UngroupedReason>) -> String? {
        switch (reasons.contains(.olderModel), reasons.contains(.stillSyncing)) {
        case (true, true): "From an older voice model, or still syncing"
        case (true, false): "From an older voice model"
        case (false, true): "Still syncing"
        case (false, false): nil
        }
    }

    /// The card for `profile` as it is now: its samples split and labelled exactly as the store checks them, with clip
    /// states read from this device's audio folder. `audioState` gives a recording's audio state by id (from
    /// `AudioSync.state(of:)`), so a sample whose audio is in iCloud or downloading says so; nil without audio sync.
    @MainActor
    public static func build(profile: VoiceProfile, recordingsByID: [UUID: Recording], localChannel: String,
                             paths: AppPaths,
                             audioState: ((UUID) -> RecordingAudioState?)? = nil) -> VoiceSampleGroupsView {
        let samples = profile.sortedSamples
        var clipStates: [UUID: SampleClipState] = [:], sampleSource: [UUID: UUID] = [:]
        var recordingTitles: [UUID: String] = [:], captureInputs: [UUID: String] = [:]
        for sample in samples {
            clipStates[sample.id] = clipState(sample, recordingsByID: recordingsByID, paths: paths, audioState: audioState)
            if let input = sample.captureInput { captureInputs[sample.id] = input }
            guard let source = sample.sourceRecordingID else { continue }
            sampleSource[sample.id] = source
            if let recording = recordingsByID[source] { recordingTitles[source] = recording.displayTitle }
        }
        return build(profileID: profile.id, sortedSampleIDs: samples.map(\.id),
                     split: GroupingInput.split(profile, localChannel: localChannel),
                     anchors: GroupingInput.anchors(profile),
                     labelTexts: Dictionary(profile.groupLabels.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a }),
                     dimension: GroupingInput.dimension(ofModelKey: profile.embeddingModelKey) ?? 0,
                     localChannel: localChannel, clipStates: clipStates, recordingTitles: recordingTitles,
                     sampleSource: sampleSource, captureInputs: captureInputs)
    }

    /// Whether `sample`'s clip can play here: its source recording from `recordingsByID`, its audio file under
    /// `paths` (the WAV, or a downloaded copy), and, when the file is missing, the recording's `audioState`.
    @MainActor
    public static func clipState(_ sample: VoiceSample, recordingsByID: [UUID: Recording], paths: AppPaths,
                                 audioState: ((UUID) -> RecordingAudioState?)? = nil) -> SampleClipState {
        let recording = sample.sourceRecordingID.flatMap { recordingsByID[$0] }
        return SampleClipState.resolve(
            sourceRecordingID: sample.sourceRecordingID, clip: sample.clipRange,
            recording: recording.map { (fileName: $0.audioFileName, channel: $0.captureChannel) },
            audioExists: { FileManager.default.fileExists(atPath: paths.audioURL(fileName: $0).path) },
            audioState: { audioState?($0) })
    }
}
