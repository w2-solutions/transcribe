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
            if let profile = matches.first {
                content(profile)
            } else {
                // Forgotten or merged away while on screen; the router pops us.
                Color.clear
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.VoiceDetail.screen)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let profile = matches.first {
                ToolbarItem(placement: .topBarTrailing) {
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
            VoiceRingAvatar(initial: profile.initial, slot: profile.colourSlot, sampleCount: profile.samples.count,
                            maxSamples: MatchPolicy.default.maxSamplesPerProfile)
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
            lead = Text("Needs a new sample on this iPhone").foregroundStyle(DS.Colour.unnamedText)
            spoken = "Needs a new sample on this iPhone"
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Voice samples").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("More samples make recognition more reliable.").font(DS.Typo.meta).foregroundStyle(DS.Colour.secondary)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))

            ForEach(Array(samples.enumerated()), id: \.element.id) { i, sample in
                if i > 0 { divider(inset: 72) }
                sampleRow(sample, index: i, slot: profile.colourSlot, recording: sample.sourceRecordingID.flatMap { recordingsByID[$0] })
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
    }

    private func sampleRow(_ sample: VoiceSample, index i: Int, slot: Int, recording: Recording?) -> some View {
        let clipID = sample.id.uuidString
        let range = sample.clipRange
        let url = recording.map { env.paths.audioURL(fileName: $0.audioFileName) }
        let isAvailable = range != nil && url.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let isPlaying = env.player.playingClipID == clipID
        let quote = sample.quote ?? "Voice sample \(i + 1)"
        // Whole seconds, rounded to nearest: a 2.95 s clip reads "0:03" (DisplayFormat rounds down).
        let duration = (range?.duration ?? sample.speechSeconds).rounded()
        let peaks: [Float] = {
            guard let recording, let range else { return [] }
            return VoicesListModel.clipPeaks(recording.peaks, duration: recording.duration, range: range, count: 27)
        }()
        let play = {
            guard isAvailable, let url, let range else { return }
            if isPlaying { env.player.stop() } else { env.player.playClip(url: url, range: range, id: clipID) }
        }
        return VStack(spacing: 0) {
            SampleRow(quote: quote, duration: duration, slot: slot, peaks: peaks, isPlaying: isPlaying,
                      isAvailable: isAvailable, action: play)
                .contentShape(Rectangle())
                .onTapGesture(perform: play)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isAvailable
                    ? "\(isPlaying ? "Pause" : "Play") sample: \(quote), \(DisplayFormat.spokenDuration(duration))"
                    : "Sample: \(quote). Recording deleted")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { play() }
                .accessibilityIdentifier(AX.VoiceDetail.samplePlay(i))
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
                Text("Not in any recording on this iPhone yet.")
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
                Text("Past transcripts keep the name.")
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
        default: error.localizedDescription
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
