import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The floating bottom layer of a ready transcript (§6.4 "Player", "Copy"): the Copy glass capsule above the
/// glass `PlayerBar`, 12 pt from the screen edges.
struct TranscriptPlayer: View {
    let audioURL: URL
    let peaks: [Float]
    let duration: TimeInterval
    let turns: [Turn]
    let marks: [TimeInterval]
    let slotForKey: (SpeakerKey) -> Int?
    let showsCopy: Bool
    /// False while a recording runs (§6.4: playback would fight capture for the audio session).
    var showsPlayer: Bool = true
    /// False when the audio is on another device (§8.5): no player at all; the transcript shows `AudioElsewhereBanner`.
    var hasAudio: Bool = true
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if showsCopy {
                GlassCapsuleButton("Copy", systemImage: "doc.on.doc", height: 44, action: onCopy)
                    .glassCapsuleCompact()
                    .accessibilityLabel("Copy transcript")
                    .accessibilityIdentifier(AX.Transcript.copyButton)
                    .padding(.trailing, 4)
            }
            if !hasAudio {
                EmptyView()
            } else if showsPlayer {
                // The bar count follows the scrubber's measured width (PlayerBar), so Dynamic Type never
                // pushes the waveform under the buttons.
                let covering = Self.coveringTurns(turns, duration: duration)
                LivePlayerBar(audioURL: audioURL, fallbackDuration: duration, marks: marks,
                              bars: { [peaks, duration, slotForKey] count in
                                  WaveformBars.bars(peaks: peaks, count: count, duration: duration, turns: covering,
                                                    slotForKey: slotForKey, fallback: DS.Colour.ink)
                              })
                    .frame(height: DS.Size.playerHeight)
            } else {
                // Copy stays available while a recording runs; only playback is off.
                Text("Playback is off while recording")
                    .font(DS.Typo.meta)
                    .foregroundStyle(DS.Colour.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("player.offWhileRecording")
            }
        }
        // Full width, so Copy keeps to the trailing edge even with no player under it (audio on another device).
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    /// Turns stretched to meet each other (first from 0, last to the end), so pauses between turns take the
    /// colour of the speaker before them instead of breaking the waveform.
    static func coveringTurns(_ turns: [Turn], duration: TimeInterval) -> [Turn] {
        let spoken = turns.filter { $0.effectiveSpeakerKey != nil }.sorted { $0.range.start < $1.range.start }
        return spoken.enumerated().map { i, turn in
            var t = turn
            let start = i == 0 ? 0 : turn.range.start
            let end = i + 1 < spoken.count ? spoken[i + 1].range.start : Swift.max(duration, turn.range.end)
            t.range = TimeRange(start: start, end: Swift.max(start, end))
            return t
        }
    }
}

/// The only part that observes the 20 Hz playback position.
private struct LivePlayerBar: View {
    let audioURL: URL
    let fallbackDuration: TimeInterval
    let marks: [TimeInterval]
    let bars: (Int) -> [WaveformBars.Bar]
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let player = env.player
        let isThisFile = player.loadedURL == audioURL
        PlayerBar(isPlaying: isThisFile && player.isPlaying && player.playingClipID == nil,
                  currentTime: isThisFile ? player.currentTime : 0,
                  duration: isThisFile && player.duration > 0 ? player.duration : fallbackDuration,
                  rate: player.rate,
                  barsForCount: bars,
                  markers: marks,
                  onTogglePlay: {
                      ensureLoaded()
                      if player.playingClipID != nil { player.play() } else { player.toggle() }
                  },
                  onSeek: { t in ensureLoaded(); player.seek(to: t) },
                  onCycleRate: { player.cycleRate() })
    }

    private func ensureLoaded() { try? env.player.load(url: audioURL) }
}
