import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 8 (§6.8): one saved voice — samples, where it appears, merge, auto-label and forget.
struct VoiceDetailView: View {
    let profileID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Query private var matches: [VoiceProfile]
    @Query private var allProfiles: [VoiceProfile]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var sheet: VoiceDetailSheet?
    @State private var confirmForget = false
    @State private var pendingRemoval: UUID?
    @State private var labelEditor: GroupLabelEditor?
    @State private var showAllAppearances = false
    @State private var toastText: String?
    @State private var errorText: String?
    @ScaledMetric(relativeTo: .subheadline) private var statusSize: CGFloat = 14

    static let appearanceLimit = 10

    init(profileID: UUID) {
        self.profileID = profileID
        _matches = Query(filter: #Predicate<VoiceProfile> { $0.id == profileID })
    }

    var body: some View {
        Group {
            if let profile = matches.first, !GoneModels.isGone(profile) {
                content(profile)
            } else {
                // Forgotten or merged away while on screen (here or by sync); the router pops us (`GoneModelObserver`).
                Color.clear
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.screen)
        .inlineNavigationTitle()
        .toolbar {
            if let profile = matches.first {
                ToolbarItem(placement: .trailingBar) {
                    Button("Edit") { sheet = .edit(name: profile.name, isMe: profile.isMe) }
                        .font(.callout.weight(.semibold))
                        .tint(DS.Colour.ink)
                        .accessibilityLabel("Edit \(profile.name)")
                        .accessibilityIdentifier(AX.VoiceDetail.editButton)
                }
            }
        }
        .screenBackground()
        .toast(toastText, id: AX.VoiceDetail.toast)
        .sheet(item: $sheet) { sheet in sheetView(sheet) }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onDisappear { if env.player.playingClipID.map(isSampleClip) == true { env.player.stop() } }
    }

    // MARK: Content

    private func content(_ profile: VoiceProfile) -> some View {
        let samples = profile.sortedSamples
        let byID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(profile)
                samplesCard(profile, samples: samples, recordingsByID: byID)
                appearsInCard(profile)
                actionsCard(profile)
                Text("Past transcripts keep the name. \(profile.name) won't be recognised in new recordings.")
                    .font(DS.Typo.meta)
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, -4)
                    .accessibilityIdentifier(AX.VoiceDetail.footnote)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
    }

    private func header(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 22) {
            // 8 tick groups: 12 (the sample cap) at 3° spacing does not read.
            VoiceRingAvatar(initial: profile.initial, slot: profile.colourSlot, sampleCount: profile.samples.count,
                            maxSamples: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(DS.Typo.screenTitle)
                    .tracking(-0.5)
                    .foregroundStyle(DS.Colour.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AX.VoiceDetail.name)
                statusLine(profile)
                    .accessibilityIdentifier(AX.VoiceDetail.status)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 100)
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    private func statusLine(_ profile: VoiceProfile) -> some View {
        let named = "named " + DisplayFormat.dayMonth(profile.namedAt)
        let lead: Text
        let spoken: String
        if profile.needsResample {
            lead = Text(env.copy.needsSample).foregroundStyle(DS.Colour.unnamedText)
            spoken = env.copy.needsSample
        } else if profile.autoLabel {
            lead = Text("\(Image(systemName: "checkmark.circle")) Recognised automatically")
                .foregroundStyle(DS.Colour.accentText)
                .fontWeight(.semibold)
            spoken = "Recognised automatically · \(named)"
        } else {
            lead = Text("Auto-label off")
            spoken = "Auto-label off · \(named)"
        }
        let showsNamed = !profile.needsResample
        // One line when it fits ("✓ Recognised automatically · named 18 Nov"); otherwise the date drops to a second line.
        return ViewThatFits(in: .horizontal) {
            (showsNamed ? Text("\(lead) · \(named)") : lead).lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                lead.fixedSize(horizontal: false, vertical: true)
                if showsNamed { Text("· " + named) }
            }
        }
        .font(.system(size: statusSize))
        .foregroundStyle(DS.Colour.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: Samples

    private func samplesCard(_ profile: VoiceProfile, samples: [VoiceSample], recordingsByID: [UUID: Recording]) -> some View {
        // Grouped by the device that heard each sample once more than one device has (each microphone hears a voice a
        // little differently), and within a device by sound (voice sample groups §7). Row indexes stay global, in
        // `sortedSamples` order.
        // Audio sync's state per source recording ("Downloading audio…", "Audio is in iCloud"); reading it observes
        // audio sync's `revision`, so a sample turns playable when its recording's audio lands.
        let audio = env.sync?.audio
        let model = VoiceSampleGroups.build(profile: profile, recordingsByID: recordingsByID, localChannel: localChannel,
                                            paths: env.paths,
                                            audioState: audio.map { audio in
                                                { id in recordingsByID[id].map(audio.state(of:)) }
                                            })
        let items = Self.cardItems(model, sampleIDs: samples.map(\.id))
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice samples").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(model.showsNote ? VoiceSampleGroups.groupedNote : VoiceSampleGroups.defaultNote)
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.VoiceDetail.samplesNote)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))

            ForEach(items) { item in
                switch item.kind {
                case .channel(let section):
                    channelHeader(section)
                case .group(let group, let channel):
                    if item.dividerAbove { divider(inset: 16) }
                    groupHeader(group, channel: channel, clipStates: model.clipStates)
                case .ungrouped(let section):
                    if item.dividerAbove { divider(inset: 16) }
                    ungroupedHeader(section)
                case .sample(let i):
                    if item.dividerAbove { divider(inset: 72) }
                    let sample = samples[i]
                    sampleRow(sample, index: i, slot: profile.colourSlot,
                              recording: sample.sourceRecordingID.flatMap { recordingsByID[$0] },
                              state: model.clipStates[sample.id] ?? .noClip)
                }
            }

            divider(inset: 16)
            Button { sheet = .addSample } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle").font(.system(size: 18, weight: .medium))
                    Text("Add a sample from a recording").font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Colour.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AX.VoiceDetail.addSample)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets())
        // Anchored to the card so the iOS 27 popover points at the samples.
        .confirmationDialog("Remove this sample?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove sample", role: .destructive) {
                if let id = pendingRemoval { removeSample(id) }
            }
            .accessibilityIdentifier(AX.VoiceDetail.removeSampleConfirm)
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("\(profile.name) may be recognised less reliably.")
        }
        .groupLabelAlert(editor: $labelEditor, voiceName: profile.name,
                         onSave: { editor, text in saveGroupLabel(editor, text: text) },
                         onRemove: { editor in removeGroupLabel(editor) })
    }

    /// This device's capture channel (the fake engine and UI tests may set it).
    private var localChannel: String { env.config.channel ?? CaptureChannel.current }

    /// One line of the samples card. The card is flattened so each line knows whether a sample row sits right above it:
    /// rows are divided from each other (inset 72) and a group or "Not grouped" header from the rows before it (inset 16);
    /// nothing is drawn between a header and its first row, as under today's channel headers.
    struct SampleCardItem: Identifiable {
        enum Kind {
            case channel(ChannelSection)
            case group(GroupSection, channel: String)
            case ungrouped(ChannelSection)
            case sample(Int)
        }
        let id: String
        let kind: Kind
        let dividerAbove: Bool
    }

    /// The card's lines in order: per channel its header (when `showsChannelHeaders`), each group's header (when
    /// `showsHeader`) and rows, then "Not grouped" and its rows. `sampleIDs` are the `sortedSamples` ids.
    static func cardItems(_ model: VoiceSampleGroupsView, sampleIDs: [UUID]) -> [SampleCardItem] {
        var items: [SampleCardItem] = []
        var afterRow = false
        func add(_ id: String, _ kind: SampleCardItem.Kind, isRow: Bool) {
            items.append(SampleCardItem(id: id, kind: kind, dividerAbove: afterRow))
            afterRow = isRow
        }
        func addRows(_ indexes: [Int]) {
            for i in indexes where sampleIDs.indices.contains(i) { add("sample.\(sampleIDs[i])", .sample(i), isRow: true) }
        }
        for section in model.channels {
            if model.showsChannelHeaders {
                add("channel.\(section.channel)", .channel(section), isRow: false)
            }
            for group in section.groups {
                if group.showsHeader { add("group.\(group.id)", .group(group, channel: section.channel), isRow: false) }
                addRows(group.sampleIndexes)
            }
            if !section.ungroupedIndexes.isEmpty {
                add("ungrouped.\(section.channel)", .ungrouped(section), isRow: false)
                addRows(section.ungroupedIndexes)
            }
        }
        return items
    }

    /// "On this Mac · 2" / "On your iPhone · 3"
    private func channelHeader(_ section: ChannelSection) -> some View {
        let platform = DevicePlatform(channel: section.channel)
        let place: String = {
            guard let platform else { return "On another device" }
            return section.channel == localChannel ? "On this \(platform.noun)" : "On your \(platform.noun)"
        }()
        let text = "\(place) · \(section.sampleCount)"
        return HStack(spacing: 6) {
            Image(systemName: AudioBanner.symbol(section.channel))
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
        }
        .font(DS.Typo.chip)
        .foregroundStyle(DS.Colour.secondary)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(text)
        .accessibilityValue(text)
        .accessibilityIdentifier(AX.Voices.sampleGroup(section.channel))
    }

    /// "Close · 3" with its play button and Label/Edit link.
    private func groupHeader(_ group: GroupSection, channel: String, clipStates: [UUID: SampleClipState]) -> some View {
        let isPlaying = env.player.playingClipID.map { id in group.ref.memberIDs.contains { $0.uuidString == id } } == true
        return SampleGroupHeader(
            title: group.title, count: group.sampleIndexes.count, subtitle: group.subtitle,
            note: group.heardThroughMacAudio ? VoiceSampleGroups.macAudioNote : nil, isLabelled: group.isLabelled,
            isPlaying: isPlaying, canPlay: group.playSampleID != nil, id: AX.VoiceDetail.group(channel, group.position),
            onPlay: { playGroup(group, isPlaying: isPlaying, clipStates: clipStates) },
            onLabel: {
                labelEditor = GroupLabelEditor(ref: group.ref, text: group.isLabelled ? group.title : "",
                                               isLabelled: group.isLabelled)
            })
    }

    /// Plays a clip of the group (its first representative that can play here), or stops one of its clips.
    private func playGroup(_ group: GroupSection, isPlaying: Bool, clipStates: [UUID: SampleClipState]) {
        if isPlaying { env.player.stop(); return }
        guard let id = group.playSampleID, case .playable(let fileName, let range)? = clipStates[id] else { return }
        env.player.playClip(url: env.paths.audioURL(fileName: fileName), range: range, id: id.uuidString)
    }

    /// "Not grouped · 2" over a channel's samples that cannot be grouped, with why.
    private func ungroupedHeader(_ section: ChannelSection) -> some View {
        let text = "Not grouped · \(section.ungroupedIndexes.count)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(DS.Typo.chip)
                .fontWeight(.medium)
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(text)
                .accessibilityValue(text)
                .accessibilityIdentifier(AX.VoiceDetail.ungrouped(section.channel))
            if let subtitle = section.ungroupedSubtitle {
                Text(subtitle)
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Lines up with the group titles (past the group header's 32 pt play button).
        .padding(EdgeInsets(top: 4, leading: 60, bottom: 4, trailing: 16))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func sampleRow(_ sample: VoiceSample, index i: Int, slot: Int, recording: Recording?,
                           state: SampleClipState) -> some View {
        let clipID = sample.id.uuidString
        let range = sample.clipRange
        let caption = state.caption(env.copy)
        let isPlaying = env.player.playingClipID == clipID
        let quote = sample.quote ?? "Voice sample \(i + 1)"
        // Whole seconds, rounded to nearest: a 2.95 s clip reads "0:03" (DisplayFormat rounds down).
        let duration = (range?.duration ?? sample.speechSeconds).rounded()
        let peaks: [Float] = {
            guard let recording, let range else { return [] }
            return VoicesListModel.clipPeaks(recording.peaks, duration: recording.duration, range: range, count: 27)
        }()
        let play = {
            guard case .playable(let fileName, let range) = state else { return }
            if isPlaying {
                env.player.stop()
            } else {
                env.player.playClip(url: env.paths.audioURL(fileName: fileName), range: range, id: clipID)
            }
        }
        return VStack(spacing: 0) {
            SampleRow(quote: quote, duration: duration, slot: slot, peaks: peaks, isPlaying: isPlaying,
                      unavailableCaption: caption, action: play)
                .contentShape(Rectangle())
                .onTapGesture(perform: play)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(caption.map { "Sample: \(quote). \($0)." }
                    ?? "\(isPlaying ? "Pause" : "Play") sample: \(quote), \(DisplayFormat.spokenDuration(duration))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { play() }
                .accessibilityAction(named: "Remove sample") { pendingRemoval = sample.id }
                .accessibilityIdentifier(AX.VoiceDetail.samplePlay(i))
                .contextMenu {
                    Button(role: .destructive) { pendingRemoval = sample.id } label: {
                        Label("Remove sample", systemImage: "trash")
                    }
                    .accessibilityIdentifier(AX.VoiceDetail.sampleRemove(i))
                }
            Text(VoicesListModel.sampleCaption(origin: sample.origin, speechSeconds: sample.speechSeconds))
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 72)
                .padding(.bottom, 8)
                .accessibilityIdentifier(AX.VoiceDetail.sampleOrigin(i))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.sample(i))
    }

    private func isSampleClip(_ id: String) -> Bool {
        matches.first?.samples.contains { $0.id.uuidString == id } ?? false
    }

    // MARK: Appears in

    private func appearsInCard(_ profile: VoiceProfile) -> some View {
        let appearances = Self.appearances(of: profile)
        let shown = showAllAppearances ? appearances : Array(appearances.prefix(Self.appearanceLimit))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Appears in").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(appearances.count == 1 ? "1 recording" : "\(appearances.count) recordings")
                    .font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))

            if appearances.isEmpty {
                Text(env.copy.notInAnyRecording)
                    .font(.subheadline).foregroundStyle(DS.Colour.secondary)
                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, rec in
                if i > 0 { divider(inset: 16) }
                Button { router.showTranscript(rec.id) } label: {
                    HStack(spacing: 10) {
                        Text(rec.displayTitle).font(.subheadline).foregroundStyle(DS.Colour.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(DisplayFormat.duration(rec.duration)).font(DS.Typo.mono).foregroundStyle(DS.Colour.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Colour.chevron)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rec.displayTitle), \(DisplayFormat.spokenDuration(rec.duration))")
                .accessibilityIdentifier(AX.VoiceDetail.appearance(i))
            }
            if appearances.count > Self.appearanceLimit && !showAllAppearances {
                divider(inset: 16)
                LinkButton("Show all \(appearances.count)") { showAllAppearances = true }
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier(AX.VoiceDetail.showAllAppearances)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets())
    }

    /// Recordings this voice is linked to, newest first, each once.
    static func appearances(of profile: VoiceProfile) -> [Recording] {
        var seen = Set<UUID>()
        return profile.speakers.compactMap(\.recording)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Actions

    private func actionsCard(_ profile: VoiceProfile) -> some View {
        let others = allProfiles.filter { $0.id != profile.id }
        return VStack(spacing: 0) {
            Button { sheet = .merge } label: {
                HStack(spacing: 12) {
                    actionIcon("arrow.triangle.merge").foregroundStyle(DS.Colour.secondary)
                    Text("Merge with another voice").font(.callout).foregroundStyle(DS.Colour.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colour.chevron)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(others.isEmpty)
            .opacity(others.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier(AX.VoiceDetail.mergeButton)

            divider(inset: 50)

            Toggle(isOn: Binding(get: { profile.autoLabel }, set: { setAutoLabel(profile, $0) })) {
                HStack(spacing: 12) {
                    actionIcon("wand.and.stars").foregroundStyle(DS.Colour.secondary)
                    Text("Auto-label in new recordings").font(.callout).foregroundStyle(DS.Colour.ink)
                }
            }
            .toggleStyle(.switch)
            .tint(DS.Colour.accent)
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(minHeight: 52)
            .accessibilityIdentifier(AX.VoiceDetail.autoLabelToggle)

            divider(inset: 50)

            Button(role: .destructive) { confirmForget = true } label: {
                HStack(spacing: 12) {
                    actionIcon("trash")
                    Text("Forget this voice").font(.callout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Colour.destructive)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AX.VoiceDetail.forgetButton)
            // Anchored to the row so the iOS 27 popover points at it.
            .confirmationDialog("Forget \(profile.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { forget(profile) }
                    .accessibilityIdentifier(AX.VoiceDetail.forgetConfirm)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(env.copy.forgetVoiceMessage(profile.name))
            }
        }
        .frame(maxWidth: .infinity)
        .cardSurface(padding: EdgeInsets())
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private func divider(inset: CGFloat) -> some View {
        Rectangle().fill(DS.Colour.divider).frame(height: 1).padding(.leading, inset).accessibilityHidden(true)
    }

    // MARK: Store calls

    private func setAutoLabel(_ profile: VoiceProfile, _ on: Bool) {
        do { try env.store.setAutoLabel(profileID: profile.id, on) } catch { errorText = Self.describe(error) }
    }

    private func removeSample(_ id: UUID) {
        pendingRemoval = nil
        if env.player.playingClipID == id.uuidString { env.player.stop() }
        do {
            try env.store.removeSample(id: id)
            showToast("Sample removed")
        } catch {
            errorText = Self.describe(error)
        }
    }

    private func saveGroupLabel(_ editor: GroupLabelEditor, text: String) {
        do { try env.store.setGroupLabel(editor.ref, text: text) } catch { groupLabelFailed(error) }
    }

    private func removeGroupLabel(_ editor: GroupLabelEditor) {
        do { try env.store.removeGroupLabel(editor.ref) } catch { groupLabelFailed(error) }
    }

    /// A group that changed under the alert (a sample added, removed or synced) is not an error: say so and let the
    /// user try again on the group as it is now.
    private func groupLabelFailed(_ error: any Error) {
        if case StoreError.groupChanged = error {
            showToast(Self.groupChangedText)
        } else {
            errorText = Self.describe(error)
        }
    }

    static let groupChangedText = "These samples just changed. Try again."

    private func showToast(_ text: String) {
        toastText = nil
        Task {
            await Task.yield()
            toastText = text
        }
    }

    private func forget(_ profile: VoiceProfile) {
        env.player.stop()
        do {
            try env.store.forgetProfile(profile.id)
            popSelf(showVoices: false)
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// Removes this screen from the path. After a merge the user lands on Voices even when they came from a transcript.
    private func popSelf(showVoices: Bool) {
        if let i = router.path.lastIndex(of: .voice(profileID)) {
            router.path.removeSubrange(i...)
        }
        if showVoices, router.path.last != .voices {
            router.path.append(.voices)
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: VoiceDetailSheet) -> some View {
        switch sheet {
        case .edit(let name, let isMe):
            VoiceEditSheet(profileID: profileID, initialName: name, initialIsMe: isMe,
                           otherNames: allProfiles.filter { $0.id != profileID }.map(\.name))
        case .merge:
            VoiceMergeSheet(profileID: profileID) {
                self.sheet = nil
                popSelf(showVoices: true)
            }
        case .addSample:
            VoiceAddSampleSheet(profileID: profileID) { message in
                self.sheet = nil
                toastText = nil
                Task { @MainActor in
                    // Let the sheet go before the toast appears, so it shows on this screen.
                    try? await Task.sleep(for: .milliseconds(350))
                    toastText = message
                }
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case StoreError.invalidName: "Enter a name."
        case StoreError.notFound: "That voice no longer exists."
        case StoreError.notImplemented: "This isn't available yet."
        case StoreError.invariant(let text): text
        case StoreError.groupChanged: groupChangedText
        default: error.localizedDescription
        }
    }
}

/// The sound group being labelled: the ref captured when Label or Edit was pressed (the store checks it is still the
/// group drawn), and the label it showed then.
struct GroupLabelEditor: Identifiable, Equatable {
    let id = UUID()
    let ref: SampleGroupRef
    /// The shown label's text, "" for an unlabelled group.
    let text: String
    let isLabelled: Bool
}

extension View {
    /// "Label this group" (voice sample groups §7), in the pattern of `folderNameAlert`: the label field (cut to
    /// `GroupLabelText.maxLength` while typing), Save, Remove Label (only when the group is labelled) and Cancel.
    func groupLabelAlert(editor: Binding<GroupLabelEditor?>, voiceName: String,
                         onSave: @escaping (GroupLabelEditor, String) -> Void,
                         onRemove: @escaping (GroupLabelEditor) -> Void) -> some View {
        modifier(GroupLabelAlert(editor: editor, voiceName: voiceName, onSave: onSave, onRemove: onRemove))
    }
}

private struct GroupLabelAlert: ViewModifier {
    @Binding var editor: GroupLabelEditor?
    let voiceName: String
    let onSave: (GroupLabelEditor, String) -> Void
    let onRemove: (GroupLabelEditor) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Label this group", isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
                TextField("Label", text: $text)
                    .inputCapitalization(.sentences)
                    .accessibilityIdentifier(AX.VoiceDetail.GroupLabel.field)
                Button("Save") {
                    if let current = editor { onSave(current, text) }
                    editor = nil
                }
                .accessibilityIdentifier(AX.VoiceDetail.GroupLabel.save)
                if editor?.isLabelled == true {
                    Button("Remove Label", role: .destructive) {
                        if let current = editor { onRemove(current) }
                        editor = nil
                    }
                    .accessibilityIdentifier(AX.VoiceDetail.GroupLabel.remove)
                }
                Button("Cancel", role: .cancel) { editor = nil }
                    .accessibilityIdentifier(AX.VoiceDetail.GroupLabel.cancel)
            } message: {
                Text("A name just for you, like Close, Far or On speaker. It doesn't change how \(voiceName) is recognised.")
            }
            .onChange(of: editor?.id) { _, _ in text = editor?.text ?? "" }
            .onChange(of: text) { _, new in
                if new.count > GroupLabelText.maxLength { text = String(new.prefix(GroupLabelText.maxLength)) }
            }
    }
}

enum VoiceDetailSheet: Identifiable, Hashable {
    case edit(name: String, isMe: Bool)
    case merge
    case addSample

    var id: String {
        switch self {
        case .edit: "edit"
        case .merge: "merge"
        case .addSample: "addSample"
        }
    }
}
