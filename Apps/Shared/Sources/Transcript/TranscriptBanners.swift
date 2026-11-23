import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// "2 new voices" (§6.4): plain card, radius 24, padding 16.
struct NewVoicesBanner: View {
    let count: Int
    let onNameSpeakers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One row when it fits; at large text sizes the pill moves under the title, so the title never
            // breaks mid-word or disappears.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    icon
                    title.fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    pill
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        icon
                        title.fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    pill
                }
            }
            Text("Name them once and Transcribe will recognise them in every recording.")
                .scaledFont(size: 14, relativeTo: .subheadline)
                .lineSpacing(3)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscriptViewState.newVoicesTitle(count))
        .accessibilityIdentifier(AX.Transcript.newVoicesBanner)
    }

    private var icon: some View {
        BannerIcon(systemImage: "person.2", tint: DS.Colour.accentText, fill: DS.Colour.accentFill)
    }

    private var title: some View {
        Text(TranscriptViewState.newVoicesTitle(count))
            .font(.headline)
            .tracking(-0.2)
            .foregroundStyle(DS.Colour.ink)
    }

    private var pill: some View {
        InkPillButton("Name speakers", action: onNameSpeakers)
            .fixedSize()
            .accessibilityIdentifier(AX.Transcript.nameSpeakersButton)
    }
}

/// "Recognised Liam and Karan" (§6.6): 48 tall plain capsule.
struct RecognisedBanner: View {
    let names: [String]
    let onVoices: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var linkSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DS.Colour.accentFill)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Colour.accent)
                }
                .accessibilityHidden(true)
            message
                .scaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
                .foregroundStyle(DS.Colour.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            LinkButton("Voices", font: .system(size: linkSize, weight: .semibold), action: onVoices)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
                .accessibilityIdentifier(AX.Transcript.recognisedVoicesLink)
        }
        .frame(minHeight: 48)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .cardSurface(padding: EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 4), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recognised " + ProcessingCopy.joinNames(names))
        .accessibilityIdentifier(AX.Transcript.recognisedBanner)
    }

    /// "Recognised **Liam** and **Karan**"
    private var message: Text {
        var result = Text("Recognised ")
        for (i, name) in names.enumerated() {
            if i > 0 { result = Text("\(result)\(Text(i == names.count - 1 ? " and " : ", "))") }
            result = Text("\(result)\(Text(name).fontWeight(.semibold))")
        }
        return result
    }
}

/// "Is this Karan?" (§6.6): plain card with play, Yes and No.
struct AskBanner: View {
    let speaker: TranscriptSpeaker
    let isPlaying: Bool
    let onPlay: () -> Void
    let onYes: () -> Void
    let onNo: () -> Void

    private var name: String { speaker.suggestedName ?? speaker.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Is this \(name)?")
                    .font(.headline)
                    .tracking(-0.2)
                    .foregroundStyle(DS.Colour.ink)
                Text("\(speaker.name) sounds like \(name).")
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundStyle(DS.Colour.secondary)
            }
            HStack(spacing: 10) {
                let palette = SpeakerPalette.colour(slot: speaker.slot)
                Button(action: onPlay) {
                    Circle()
                        .fill(palette.fill)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.text)
                        }
                        .frame(width: DS.Space.hit, height: DS.Space.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause clip" : "Play a clip of \(speaker.name)")
                .accessibilityIdentifier(AX.Transcript.askPlay)
                InkPillButton("Yes", action: onYes)
                    .fixedSize()
                    .accessibilityLabel("Yes, this is \(name)")
                    .accessibilityIdentifier(AX.Transcript.askYes)
                GlassCapsuleButton("No", height: 44, action: onNo)
                    .accessibilityLabel("No, this isn't \(name)")
                    .accessibilityIdentifier(AX.Transcript.askNo)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Is this \(name)?")
        .accessibilityIdentifier(AX.Transcript.askBanner)
    }
}

/// "No speech found in this recording." The audio can still be played.
struct NoSpeechCard: View {
    var body: some View {
        HStack(spacing: 12) {
            BannerIcon(systemImage: "waveform.slash", tint: DS.Colour.secondary, fill: DS.Colour.neutralFill)
            VStack(alignment: .leading, spacing: 2) {
                Text("No speech found in this recording.")
                    .font(.headline)
                    .foregroundStyle(DS.Colour.ink)
                Text("You can still play the audio.")
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundStyle(DS.Colour.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Transcript.noSpeechCard)
    }
}

/// "Couldn't finish processing" with Try again (§6.4).
struct FailedCard: View {
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BannerIcon(systemImage: "exclamationmark.triangle", tint: DS.Colour.destructive,
                           fill: DS.Colour.destructive.opacity(0.10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TranscriptViewState.failedTitle)
                        .font(.headline)
                        .foregroundStyle(DS.Colour.ink)
                    Text(message ?? "Something went wrong while working out who said what.")
                        .scaledFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(DS.Colour.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GlassCapsuleButton("Try again", systemImage: "arrow.clockwise", height: 44, action: onRetry)
                .accessibilityIdentifier(AX.Transcript.retryButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16), radius: DS.Radius.banner)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscriptViewState.failedTitle)
        .accessibilityIdentifier(AX.Transcript.failedCard)
    }
}

/// "Wed 18 Nov · 2:29 pm · 0:20" (§6.6).
struct TranscriptMetaLine: View {
    let date: Date
    let duration: TimeInterval

    var body: some View {
        Text("\(Text(DisplayFormat.cardDate(date) + " · "))\(Text(DisplayFormat.duration(duration)).font(DS.Typo.mono))")
            .font(DS.Typo.meta)
            .foregroundStyle(DS.Colour.secondary)
            .padding(.horizontal, 4)
            .accessibilityLabel("\(DisplayFormat.cardDate(date)), \(DisplayFormat.spokenDuration(duration))")
            .accessibilityIdentifier(AX.Transcript.metaLine)
    }
}

/// 40 pt tinted circle with a symbol.
struct BannerIcon: View {
    let systemImage: String
    let tint: Color
    let fill: Color

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 40, height: 40)
            .overlay { Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint) }
            .accessibilityHidden(true)
    }
}
