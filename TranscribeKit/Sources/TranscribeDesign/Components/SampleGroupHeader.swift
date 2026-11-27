import SwiftUI

/// Voice detail: the header of one sound group of a voice's samples ("Close · 3"), above its sample rows. A plain row
/// on the card (no glass), inset 16, at least 44 tall: a 32 pt circle play button (chip fill and stroke) that plays a
/// clip of the group, the title "‹title› · ‹count›" in chip type (ink when labelled, secondary for "Group N"), an
/// optional subtitle in meta type ("From “Standup” and “Dinner”"), and a trailing "Label" or "Edit" link.
///
/// Accessibility ids derive from `id`: the title is `id`, then `id.play`, `id.subtitle` and `id.label`.
public struct SampleGroupHeader: View {
    let title: String
    let count: Int
    let subtitle: String?
    /// A second line with a speaker glyph ("Heard through Mac audio"); nil for none. Its identifier is `id` + ".macAudio".
    let note: String?
    let isLabelled: Bool
    let isPlaying: Bool
    /// False when no sample of the group can play here: the play button is hidden (its space is kept, so titles line up).
    let canPlay: Bool
    let id: String
    let onPlay: () -> Void
    let onLabel: () -> Void

    public init(title: String, count: Int, subtitle: String?, note: String? = nil, isLabelled: Bool, isPlaying: Bool,
                canPlay: Bool, id: String, onPlay: @escaping () -> Void, onLabel: @escaping () -> Void) {
        self.title = title; self.count = count; self.subtitle = subtitle; self.note = note; self.isLabelled = isLabelled
        self.isPlaying = isPlaying; self.canPlay = canPlay; self.id = id; self.onPlay = onPlay; self.onLabel = onLabel
    }

    private var heading: String { "\(title) · \(count)" }

    public var body: some View {
        HStack(spacing: 12) {
            playButton
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(DS.Typo.chip)
                    .fontWeight(isLabelled ? .semibold : .medium)
                    .foregroundStyle(isLabelled ? DS.Colour.ink : DS.Colour.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(heading)
                    .accessibilityValue(heading)
                    .accessibilityIdentifier(id)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Typo.meta)
                        .foregroundStyle(DS.Colour.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(id + ".subtitle")
                }
                if let note {
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 10, weight: .semibold))
                    }
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note)
                    .accessibilityValue(note)
                    .accessibilityIdentifier(id + ".macAudio")
                }
            }
            Spacer(minLength: 8)
            LinkButton(isLabelled ? "Edit" : "Label", font: DS.Typo.chip, action: onLabel)
                .accessibilityLabel(isLabelled ? "Edit label \(title)" : "Label \(title)")
                .accessibilityIdentifier(id + ".label")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var playButton: some View {
        if canPlay {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colour.ink)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle().fill(DS.Colour.chipFill)
                            .overlay { Circle().strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause clip from \(title)" : "Play a clip from \(title)")
            .accessibilityIdentifier(id + ".play")
        } else {
            Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
        }
    }
}

#Preview("Sample group headers") {
    VStack(alignment: .leading, spacing: 0) {
        SampleGroupHeader(title: "Close", count: 3, subtitle: "From \u{201C}Standup\u{201D} and \u{201C}Dinner\u{201D}",
                          isLabelled: true, isPlaying: true, canPlay: true, id: "preview.0", onPlay: {}, onLabel: {})
        SampleRow(quote: "Can you pass me that?", duration: 4, slot: 2,
                  peaks: [0.3, 0.5, 0.8, 0.4, 0.6, 0.9, 0.55, 0.35, 0.7], isPlaying: true, unavailableCaption: nil) {}
        SampleGroupHeader(title: "Group 2", count: 3, subtitle: "From \u{201C}Kitchen chat\u{201D}, \u{201C}Wed 18 Nov · 2:29 pm\u{201D} and 1 more",
                          isLabelled: false, isPlaying: false, canPlay: true, id: "preview.1", onPlay: {}, onLabel: {})
        SampleRow(quote: "I said the blue one!", duration: 3, slot: 2,
                  peaks: [], isPlaying: false, unavailableCaption: "Recording deleted") {}
        SampleGroupHeader(title: "Group 3", count: 2, subtitle: nil,
                          isLabelled: false, isPlaying: false, canPlay: false, id: "preview.2", onPlay: {}, onLabel: {})
        SampleRow(quote: "You're breaking up a bit.", duration: 4, slot: 2,
                  peaks: [], isPlaying: false, unavailableCaption: "No clip saved") {}
    }
    .cardSurface(padding: EdgeInsets())
    .padding(16)
    .screenBackground()
}
