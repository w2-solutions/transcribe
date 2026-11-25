import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// One Library row (§6.1, `AX.Library.card(i)`): date or title with a status, speaker chips with a "Name" link,
/// a two-line preview and, for a fresh result, the speaker-coloured waveform.
struct RecordingCard: View {
    let recording: Recording
    let index: Int
    /// Name of the profile a "suggested" speaker points at ("Karan" → chip "Karan?").
    let suggestedName: (UUID) -> String?
    let onOpen: () -> Void
    let onName: (_ first: SpeakerKey, _ followUps: [SpeakerKey]) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var documents = DocumentCache()

    static let maxChips = 3
    static let waveformBars = 21

    var body: some View {
        let status = LibraryCardStatus.make(stage: recording.stage, queueReason: recording.queueReason,
                                            hasUnseenResult: recording.hasUnseenResult, duration: recording.duration,
                                            snapshot: env.monitor.snapshot(for: recording.id),
                                            setupFailed: env.models.hasFailed)
        VStack(alignment: .leading, spacing: 10) {
            topRow(status)
            chipRow
            preview
            if showsWaveform { waveformRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recording.displayTitle)
        .accessibilityAction(named: "Open transcript", onOpen)
        .accessibilityIdentifier(AX.Library.card(index))
    }

    // MARK: Row 1

    /// Date (or title) and status on one line; when they don't fit (a long title, a long status, large text)
    /// the status drops below the date instead of squeezing it.
    private func topRow(_ status: LibraryCardStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                titleText.lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                statusView(status)
            }
            VStack(alignment: .leading, spacing: 8) {
                titleText.lineLimit(3)
                statusView(status)
            }
        }
    }

    private var titleText: some View {
        Text(recording.displayTitle)
            .font(DS.Typo.meta)
            .foregroundStyle(DS.Colour.secondary)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the transcript")
            .accessibilityAction { onOpen() }
    }

    @ViewBuilder private func statusView(_ status: LibraryCardStatus) -> some View {
        switch status {
        case .recognised:
            StatusPill(status.text, systemImage: "checkmark", style: .accent)
                .accessibilityIdentifier(AX.Library.cardStatus(index))
        case .recording:
            HStack(spacing: 6) {
                PulsingRecordDot(isPulsing: true).frame(width: 8, height: 8)
                Text(status.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colour.ink)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule(style: .continuous).fill(DS.Colour.record.opacity(0.10)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.text)
            .accessibilityIdentifier(AX.Library.cardStatus(index))
        case .processing(let text, let fraction):
            StatusPill(text, style: .progress(fraction))
                .accessibilityIdentifier(AX.Library.cardStatus(index))
        case .failed:
            StatusPill(status.text, systemImage: "exclamationmark", style: .failed)
                .accessibilityIdentifier(AX.Library.cardStatus(index))
        case .duration(let text):
            Text(text)
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityLabel(DisplayFormat.spokenDuration(recording.duration))
                .accessibilityIdentifier(AX.Library.cardStatus(index))
        }
    }

    // MARK: Row 2

    @ViewBuilder private var chipRow: some View {
        let speakers = recording.sortedSpeakers
        if recording.stage.isProcessing {
            StatusPill("Speakers pending")
        } else if !speakers.isEmpty {
            let needing = recording.speakersNeedingName
            ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(speakers.prefix(Self.maxChips)) { speaker in
                    chip(for: speaker)
                        .accessibilityIdentifier(AX.Library.cardChip(index, speaker.ordinal))
                }
                if speakers.count > Self.maxChips {
                    Text("+\(speakers.count - Self.maxChips)")
                        .font(DS.Typo.chip)
                        .foregroundStyle(DS.Colour.secondary)
                        .frame(height: DS.Size.chipCompact)
                        .accessibilityLabel("and \(speakers.count - Self.maxChips) more")
                }
                if let first = needing.first {
                    LinkButton("Name", font: DS.Typo.chip) { onName(first.key, needing.dropFirst().map(\.key)) }
                        .padding(.leading, 2)
                        .frame(height: DS.Size.chipCompact)
                        .accessibilityLabel(needing.count == 1 ? "Name \(first.displayName)" : "Name speakers")
                        .accessibilityIdentifier(AX.Library.cardNameLink(index))
                }
            }
        }
    }

    private func chip(for speaker: RecordingSpeaker) -> some View {
        switch speaker.label {
        case .named, .autoLabelled:
            SpeakerChip(name: speaker.displayName, slot: speaker.colourSlot, style: .filled, size: .compact)
        case .suggested:
            SpeakerChip(name: speaker.suggestedProfileID.flatMap(suggestedName) ?? speaker.displayName,
                        slot: speaker.colourSlot, style: .suggested, size: .compact)
        case .unnamed:
            SpeakerChip(name: speaker.displayName, slot: speaker.colourSlot,
                        style: speaker.hasName ? .filled : .unnamed, size: .compact)
        }
    }

    // MARK: Row 3

    private var preview: some View {
        let preview = LibraryCardPreview.make(previewText: recording.previewText, stage: recording.stage,
                                              noSpeech: recording.noSpeech,
                                              queueReason: ProcessingViewState.queueReason(
                                                  snapshot: env.monitor.snapshot(for: recording.id),
                                                  stored: recording.queueReason))
        return Text(preview.text)
            .font(DS.Typo.cardBody)
            .lineSpacing(3.3)   // 16 pt text on a 23 pt line
            .foregroundStyle(preview.isPlaceholder ? DS.Colour.secondary : DS.Colour.ink)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Row 4

    private var showsWaveform: Bool { recording.hasUnseenResult && recording.stage == .ready }

    private var waveformRow: some View {
        // Decoded once per transcript change, not on every body pass (monitor ticks re-render the card).
        let turns = documents.document(recording.transcriptData)?.turns ?? []
        let slots = Dictionary(recording.speakers.map { ($0.key, $0.colourSlot) }, uniquingKeysWith: { a, _ in a })
        let bars = WaveformBars.bars(peaks: recording.peaks, count: Self.waveformBars, duration: recording.duration,
                                     turns: turns, slotForKey: { slots[$0] }, fallback: DS.Colour.tertiary)
        return HStack(spacing: 10) {
            WaveformBars(bars: bars, barWidth: 3, spacing: 3, maxHeight: 18, minHeight: 4)
                .frame(width: CGFloat(Self.waveformBars) * 6 - 3)
            Spacer(minLength: 8)
            Text(DisplayFormat.duration(recording.duration))
                .font(DS.Typo.mono)
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityLabel(DisplayFormat.spokenDuration(recording.duration))
        }
    }
}
