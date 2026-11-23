import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 7 (§6.7): saved voices, speakers waiting for a name, and the per-device privacy note.
struct VoicesView: View {
    @Environment(Router.self) private var router
    @Query private var profiles: [VoiceProfile]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    /// Row subtitles are 14 pt in the mockup (between footnote and subheadline); scale with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var subtitleSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let model = VoicesListModel(profiles: profiles, recordings: recordings)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("People Transcribe can recognise. Stored only on this device.")
                    .font(DS.Typo.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)

                if model.saved.isEmpty {
                    emptyState.padding(.top, 26)
                } else {
                    SectionHeader("Saved").padding(.top, 26).padding(.bottom, 8)
                    DividedCard(dividerInset: 74) {
                        ForEach(model.saved) { row in
                            savedRow(row)
                        }
                    }
                }

                if !model.waiting.isEmpty {
                    SectionHeader("Waiting for a name").padding(.top, 26).padding(.bottom, 8)
                    DividedCard(dividerInset: 74) {
                        ForEach(Array(model.waiting.enumerated()), id: \.element.id) { i, row in
                            waitingRow(row, index: i)
                        }
                    }
                }

                privacyCard.padding(.top, 26)
            }
            .padding(.horizontal, DS.Space.screenInset)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Voices.screen)
        .navigationTitle("Voices")
        .largeNavigationTitle()
        .screenBackground()
    }

    // MARK: Saved

    private func savedRow(_ row: SavedVoiceRow) -> some View {
        Button { router.path.append(.voice(row.id)) } label: {
            HStack(spacing: 14) {
                VoiceAvatar(initial: row.initial, slot: row.slot)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(DS.Typo.headline)
                            .tracking(-0.2)
                            .foregroundStyle(DS.Colour.ink)
                            .lineLimit(1)
                        if row.isMe { StatusPill("You", compact: true) }
                    }
                    Text(row.subtitle)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(row.needsResample ? DS.Colour.unnamedText : DS.Colour.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MiniBars(peaks: row.bars, color: SpeakerPalette.colour(slot: row.slot).dot, barWidth: 3, spacing: 2, maxHeight: 18)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Colour.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .frame(minHeight: DS.Size.voiceRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)\(row.isMe ? ", you" : ""). \(row.subtitle)")
        .accessibilityHint("Opens the voice profile")
        .accessibilityIdentifier(AX.Voices.profile(AX.slug(row.name)))
    }

    // MARK: Waiting

    private func waitingRow(_ row: WaitingVoiceRow, index i: Int) -> some View {
        // At accessibility text sizes the Name link moves under the row, so the name never breaks mid-word.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button { router.showTranscript(row.recordingID) } label: {
                HStack(spacing: 14) {
                    VoiceAvatar(initial: "", slot: nil, style: .unnamed)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            SpeakerDot(slot: nil, diameter: 8)
                            Text(row.name)
                                .font(DS.Typo.headline)
                                .tracking(-0.2)
                                .foregroundStyle(DS.Colour.ink)
                                .layoutPriority(1)
                            if row.isSuggested { StatusPill("Suggested", compact: true) }
                        }
                        Text("\(row.dateText) · \(Text(row.durationText).font(DS.Typo.mono)) recording")
                            .font(.system(size: subtitleSize))
                            .foregroundStyle(DS.Colour.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: DS.Size.voiceRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(row.name), \(row.dateText), \(DisplayFormat.spokenDuration(row.duration)) recording")
            .accessibilityHint("Opens the transcript")
            .accessibilityIdentifier(AX.Voices.waiting(i))

            LinkButton("Name", font: .callout.weight(.semibold)) {
                router.nameSpeaker(NameSpeakerContext(recordingID: row.recordingID, key: row.key))
            }
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 0 : 12)
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 58 : 0)
            .accessibilityLabel("Name \(row.name)")
            .accessibilityIdentifier(AX.Voices.waitingName(i))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }

    // MARK: Privacy + empty

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(DS.Colour.neutralFill)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DS.Colour.ink)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(DeviceCopy().voicesFooter)
                    .font(DS.Typo.subheadline)
                    .lineSpacing(3)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LinkButton("Speaker settings", systemImage: "chevron.right", font: .subheadline.weight(.semibold)) {
                    openSettings()
                }
                .accessibilityIdentifier(AX.Voices.speakerSettingsLink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardSurface(padding: EdgeInsets(top: 18, leading: 18, bottom: 8, trailing: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Voices.privacyCard)
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(DS.Colour.accentFill)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "person.2").font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.Colour.accentText)
                }
                .accessibilityHidden(true)
            Text("No saved voices yet. Name a speaker in any transcript and Transcribe will recognise them next time.")
                .font(DS.Typo.subheadline)
                .lineSpacing(3)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Voices.emptyState)
    }

    /// Back to Settings when the user came from there; otherwise push it.
    private func openSettings() {
        if let i = router.path.lastIndex(of: .settings) {
            router.path.removeSubrange((i + 1)...)
        } else {
            router.path.append(.settings)
        }
    }
}

/// Plain card whose rows are separated by 1 pt dividers inset from the leading edge.
struct DividedCard<Content: View>: View {
    let dividerInset: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id {
                        Rectangle().fill(DS.Colour.divider).frame(height: 1).padding(.leading, dividerInset)
                            .accessibilityHidden(true)
                    }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity)
        .cardSurface(padding: EdgeInsets())
    }
}
