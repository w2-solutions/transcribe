import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The middle column for People → Voices (§5): saved voices and the speakers waiting for a name, from the shared
/// `VoicesListModel`. Selecting a saved voice shows its profile in the detail column; "Name…" opens the name sheet.
struct MacVoiceList: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(MacSelection.self) private var selection
    @Query private var profiles: [VoiceProfile]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var searchText = ""
    @State private var mergeRequest: MergeRequest?

    /// Mac wording, sync-aware.
    private var macCopy: DeviceCopy { DeviceCopy(platform: .mac, syncOn: env.copy.syncOn) }

    var body: some View {
        let model = VoicesListModel(profiles: profiles, recordings: recordings, platform: .mac)
        let term = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let saved = term.isEmpty ? model.saved : model.saved.filter { $0.name.lowercased().contains(term) }
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                header(count: model.saved.count)
                searchField.padding(.bottom, 6)

                // After sync (§8.6): two voices with one name, and another device on a different build.
                ForEach(DuplicateVoiceBanner.duplicates(profiles), id: \.newer) { d in
                    DuplicateVoiceBanner(name: d.name) { mergeRequest = MergeRequest(id: d.newer) }
                        .padding(.bottom, 6)
                }
                if env.sync?.otherDeviceNeedsUpdate == true {
                    UpdateOtherDevicesBanner().padding(.bottom, 6)
                }

                if model.saved.isEmpty {
                    Text("No saved voices yet. Name a speaker in any transcript and Transcribe will recognise them next time.")
                        .font(DS.Typo.subheadline)
                        .foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface(radius: 20)
                        .accessibilityIdentifier(AX.Voices.emptyState)
                } else {
                    sectionTitle("Saved voices")
                    ForEach(saved) { row in
                        savedRow(row, isSelected: selection.voice == row.id)
                    }
                }

                if !model.waiting.isEmpty {
                    sectionTitle("Waiting for a name")
                    ForEach(Array(model.waiting.enumerated()), id: \.element.id) { i, row in
                        waitingRow(row, index: i)
                    }
                }

                Label(macCopy.voicesFooter, systemImage: macCopy.syncOn ? "icloud" : "lock")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Colour.secondary)
                    .padding(.top, 14)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier(AX.Voices.privacyCard)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Mac.voiceList)
        .screenBackground()
        .sheet(item: $mergeRequest) { request in
            VoiceMergeSheet(profileID: request.id) { mergeRequest = nil }
                .sheetSizing(minWidth: 480, minHeight: 560)
        }
        .onChange(of: profiles.map(\.id)) { _, ids in
            if let id = selection.voice, !ids.contains(id) { selection.voice = nil }
        }
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Voices")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(DS.Colour.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(count == 1 ? "1 saved" : "\(count) saved")
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityHidden(true)
            TextField("Search voices", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .accessibilityIdentifier(AX.Mac.voiceSearch)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Colour.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Rows

    private func savedRow(_ row: SavedVoiceRow, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            VoiceAvatar(initial: row.initial, slot: row.slot, diameter: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Colour.ink)
                        .lineLimit(1)
                    if row.isMe { StatusPill("You", compact: true) }
                }
                Text(row.subtitle)
                    .font(DS.Typo.meta)
                    .foregroundStyle(row.needsResample ? DS.Colour.unnamedText : DS.Colour.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            MiniBars(peaks: row.bars, color: SpeakerPalette.colour(slot: row.slot).dot, barWidth: 3, spacing: 2, maxHeight: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? DS.Colour.cardFill : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(DS.Colour.accent, lineWidth: 2)
                        .opacity(isSelected ? 1 : 0)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.voice = row.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)\(row.isMe ? ", you" : ""). \(row.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AX.Voices.profile(AX.slug(row.name)))
    }

    /// The other-device question for a suggested voice ("Karan was named on your iPhone. … Is this Karan?").
    private func askPrompt(_ row: WaitingVoiceRow) -> String? {
        guard row.isSuggested, let r = recordings.first(where: { $0.id == row.recordingID }),
              let id = r.speaker(row.key)?.suggestedProfileID else { return nil }
        return NameSpeakerModel.askPrompt(suggested: profiles.first { $0.id == id }, recordingChannel: r.captureChannel,
                                          copy: macCopy)
    }

    private func waitingRow(_ row: WaitingVoiceRow, index i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            waitingRowMain(row, index: i)
            if let ask = askPrompt(row) {
                Text(ask)
                    .font(DS.Typo.meta)
                    .lineSpacing(2)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 48)
                    .accessibilityIdentifier(AX.Voices.waitingAsk(i))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func waitingRowMain(_ row: WaitingVoiceRow, index i: Int) -> some View {
        HStack(spacing: 12) {
            VoiceAvatar(initial: "", slot: nil, style: .unnamed, diameter: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colour.unnamedText)
                Text("\(row.dateText) · \(Text(row.durationText).font(DS.Typo.mono)) recording")
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            LinkButton("Name…", font: .system(size: 13, weight: .semibold)) {
                router.nameSpeaker(NameSpeakerContext(recordingID: row.recordingID, key: row.key))
            }
            .accessibilityLabel("Name \(row.name)")
            .accessibilityIdentifier(AX.Voices.waitingName(i))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Voices.waiting(i))
    }
}
