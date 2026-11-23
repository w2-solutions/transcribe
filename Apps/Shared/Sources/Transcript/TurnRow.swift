import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Highlights inside one turn's text (Character offsets into the displayed text).
struct TurnHighlights: Equatable {
    var nowPlaying: Range<Int>?
    var searchHits: [Range<Int>] = []
    var currentHit: Range<Int>?
    static let none = TurnHighlights()
}

/// One speaker turn of the ready transcript (§6.4): chip row, text with now-playing/search marks, and the
/// "Wrong speaker? Change" link. Speaker-less turns (identify off, no speech, failed) show only the timestamp.
///
/// Equatable on its values only: the list applies `.equatable()`, so a playback tick that moves the
/// highlight re-renders just the rows whose highlight changed. Taps go through the shared `actions` box,
/// which always holds the latest callbacks.
struct TurnRow: View, Equatable {
    let index: Int
    let speaker: TranscriptSpeaker?
    let timestamp: String
    let text: String
    let hasMark: Bool
    let highlights: TurnHighlights
    let showsChangeLink: Bool
    let actions: TurnActionsBox

    static func == (a: TurnRow, b: TurnRow) -> Bool {
        a.index == b.index && a.speaker == b.speaker && a.timestamp == b.timestamp && a.text == b.text
            && a.hasMark == b.hasMark && a.highlights == b.highlights && a.showsChangeLink == b.showsChangeLink
            && a.actions === b.actions
    }

    private func onChip() { actions.current?.chip(index) }
    private func onTimestamp() { actions.current?.timestamp(index) }
    private func onChangeSpeaker() { actions.current?.changeSpeaker(index) }
    private func onCopy() { actions.current?.copy(index) }
    private func onTap() { actions.current?.tap(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow
            HighlightedText(text: text, highlights: highlights)
                .font(DS.Typo.transcript)
                .lineSpacing(DS.Typo.transcriptLineSpacing)   // iPhone 17 pt on a 26 pt line; Mac 15 on 24
                .foregroundStyle(DS.Colour.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityValue(highlights.nowPlaying == nil ? "" : "Now playing")
                .accessibilityIdentifier(AX.Transcript.turnText(index))
            if showsChangeLink, speaker?.isLabelled == true {
                LinkButton("Wrong speaker? Change", systemImage: "arrow.left.arrow.right", font: DS.Typo.chip,
                           action: { onChangeSpeaker() })
                    .padding(.top, -4)
                    .padding(.bottom, -12)
                    .accessibilityLabel("Wrong speaker? Change the speaker for this turn")
                    .accessibilityIdentifier(AX.Transcript.changeSpeaker(index))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            if speaker != nil {
                Button("Change speaker…", systemImage: "arrow.left.arrow.right") { onChangeSpeaker() }
            }
            Button("Copy turn", systemImage: "doc.on.doc") { onCopy() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Transcript.turn(index))
    }

    private var chipRow: some View {
        HStack(spacing: 10) {
            if let speaker {
                Button { onChip() } label: {
                    SpeakerChip(name: speaker.chipName, slot: speaker.slot, style: chipStyle(speaker),
                                recognisedBadge: speaker.chipStyle == .filled(recognised: true),
                                showsPencil: speaker.chipStyle == .unnamed)
                        .frame(minHeight: DS.Space.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -8)
                .accessibilityLabel(chipLabel(speaker))
                .accessibilityHint(chipHint(speaker))
                .accessibilityIdentifier(AX.Transcript.turnChip(index))
            }
            Button { onTimestamp() } label: {
                Text(timestamp)
                    .font(DS.Typo.mono)
                    .foregroundStyle(DS.Colour.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 32, minHeight: DS.Space.hit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)   // a long name truncates in the chip before the time wraps
            .padding(.vertical, -8)
            .accessibilityLabel(timestamp)
            .accessibilityHint("Plays from here")
            .accessibilityIdentifier(AX.Transcript.turnTimestamp(index))
            if hasMark {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colour.accent)
                    .accessibilityLabel("Marked moment")
                    .accessibilityIdentifier(AX.Transcript.turnMark(index))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: DS.Size.chipRegular)   // grows with Dynamic Type
    }

    private func chipStyle(_ s: TranscriptSpeaker) -> SpeakerChip.Style {
        switch s.chipStyle {
        case .unnamed: .unnamed
        case .suggested: .suggested
        case .filled: .filled
        }
    }

    /// The display name (UI tests read it); suggested chips read as shown ("Karan?").
    private func chipLabel(_ s: TranscriptSpeaker) -> String {
        s.chipStyle == .suggested ? "\(s.chipName)?" : s.name
    }

    private func chipHint(_ s: TranscriptSpeaker) -> String {
        switch s.chipStyle {
        case .unnamed: "Name this speaker"
        case .suggested: "Confirm or change who this is"
        case .filled(let recognised):
            s.profileID == nil ? "Change who this is"
                : (recognised ? "Recognised from saved voice. Opens voice profile" : "Opens voice profile")
        }
    }
}

/// A speaker-less paragraph while speakers are pending (§6.3): timestamp, then secondary text.
struct PendingParagraph: View {
    let timestamp: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timestamp)
                .font(DS.Typo.monoSmall)
                .foregroundStyle(DS.Colour.secondary)
            Text(text)
                .font(DS.Typo.cardBody)
                .lineSpacing(3.3)   // 16 pt text on a 23 pt line
                .foregroundStyle(DS.Colour.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Highlighted text

/// Draws a rounded accent fill behind marked runs (the `mark` style: accent 10%, radius 6).
private struct MarkAttribute: TextAttribute {
    var opacity: Double
}

private struct MarkRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let mark = run[MarkAttribute.self] else { continue }
                let bounds = run.typographicBounds.rect.insetBy(dx: -3, dy: -1)
                ctx.fill(Path(roundedRect: bounds, cornerRadius: 6), with: .color(DS.Colour.accent.opacity(mark.opacity)))
            }
        }
        for line in layout { ctx.draw(line) }
    }
}

/// Turn text with the now-playing phrase and search matches marked.
struct HighlightedText: View {
    let text: String
    let highlights: TurnHighlights

    var body: some View {
        if highlights == .none {
            Text(text)
        } else {
            segmented.textRenderer(MarkRenderer())
        }
    }

    private struct Segment { var range: Range<Int>; var marked: Bool; var current: Bool }

    private var segmented: Text {
        let chars = Array(text)
        let n = chars.count
        var bounds: Set<Int> = [0, n]
        let marked = ([highlights.nowPlaying].compactMap { $0 } + highlights.searchHits).map { clamp($0, n) }
        let current = highlights.currentHit.map { clamp($0, n) }
        for r in marked + [current].compactMap({ $0 }) { bounds.insert(r.lowerBound); bounds.insert(r.upperBound) }
        let points = bounds.sorted()
        var result = Text("")
        for (a, b) in zip(points, points.dropFirst()) where a < b {
            let piece = String(chars[a..<b])
            let isCurrent = current.map { $0.lowerBound <= a && b <= $0.upperBound } ?? false
            let isMarked = isCurrent || marked.contains { $0.lowerBound <= a && b <= $0.upperBound }
            if isMarked {
                let segment = Text(piece)
                    .foregroundStyle(DS.Colour.accentText)
                    .customAttribute(MarkAttribute(opacity: isCurrent ? 0.24 : 0.10))
                result = Text("\(result)\(segment)")
            } else {
                result = Text("\(result)\(Text(piece))")
            }
        }
        return result
    }

    private func clamp(_ r: Range<Int>, _ n: Int) -> Range<Int> {
        Swift.max(0, Swift.min(n, r.lowerBound))..<Swift.max(0, Swift.min(n, r.upperBound))
    }
}
