import SwiftUI
import TranscribeCore

public struct PlayerBar: View {
    /// 64 pt glass capsule: 44 pt ink play/pause circle (white icon), scrubber (WaveformBars with playhead: 2 pt ink line
    /// + 8 pt knob at the top; drag/tap to seek; accessibilityAdjustableAction ±5 s), time "0:12 / 0:20" mono 12–13
    /// (current ink, total secondary), speed button 44 "1×" 14 semibold. Marker ticks (accent, 2×6 pt) under the bars.
    /// Hard-coded ids: player.bar, player.playButton, player.scrubber, player.time, player.speedButton.
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let rate: Float
    /// Bars for a given count; the count follows the scrubber's real width (one bar per 6 pt).
    let barSource: (Int) -> [WaveformBars.Bar]
    let markers: [TimeInterval]
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onCycleRate: () -> Void

    public init(isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval, rate: Float,
                bars: [WaveformBars.Bar], markers: [TimeInterval] = [],
                onTogglePlay: @escaping () -> Void, onSeek: @escaping (TimeInterval) -> Void, onCycleRate: @escaping () -> Void) {
        self.isPlaying = isPlaying; self.currentTime = currentTime; self.duration = duration; self.rate = rate
        self.barSource = { _ in bars }; self.markers = markers
        self.onTogglePlay = onTogglePlay; self.onSeek = onSeek; self.onCycleRate = onCycleRate
    }

    /// Additive: bars built for the scrubber's measured width, so they never overflow it at large text sizes.
    public init(isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval, rate: Float,
                barsForCount: @escaping (Int) -> [WaveformBars.Bar], markers: [TimeInterval] = [],
                onTogglePlay: @escaping () -> Void, onSeek: @escaping (TimeInterval) -> Void, onCycleRate: @escaping () -> Void) {
        self.isPlaying = isPlaying; self.currentTime = currentTime; self.duration = duration; self.rate = rate
        self.barSource = barsForCount; self.markers = markers
        self.onTogglePlay = onTogglePlay; self.onSeek = onSeek; self.onCycleRate = onCycleRate
    }

    /// One bar per 6 pt of scrubber (3 pt bar + 3 pt gap), at least 8.
    public static func barCount(forWidth width: CGFloat) -> Int { Swift.max(8, Int(width / 6)) }

    private var fraction: Double { duration > 0 ? Swift.min(1, Swift.max(0, currentTime / duration)) : 0 }

    public var body: some View {
        HStack(spacing: 10) {
            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colour.onInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(DS.Colour.ink))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playButton")

            scrubber
                .frame(minWidth: 80)
                .layoutPriority(1)

            // The capsule has a fixed height, so its labels stop growing at xxLarge; at accessibility sizes the
            // time shows the current position only.
            ViewThatFits(in: .horizontal) {
                timeLabel(showsTotal: true)
                timeLabel(showsTotal: false)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityIdentifier("player.time")

            Button(action: onCycleRate) {
                Text(DisplayFormat.rate(rate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colour.ink)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityLabel(DisplayFormat.rate(rate))
            .accessibilityHint("Playback speed")
            .accessibilityIdentifier("player.speedButton")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: DS.Size.playerHeight)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.bar")
    }

    private func timeLabel(showsTotal: Bool) -> some View {
        Text("\(Text(DisplayFormat.duration(currentTime)).foregroundStyle(DS.Colour.ink))\(Text(showsTotal ? " / " + DisplayFormat.duration(duration) : "").foregroundStyle(DS.Colour.secondary))")
            .font(DS.Typo.monoSmall)
            .lineLimit(1)
            .fixedSize()
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                WaveformBars(bars: barSource(Self.barCount(forWidth: w)), maxHeight: 28, playedFraction: fraction)
                    .frame(width: w, height: 28)
                    .clipped()
                    .position(x: w / 2, y: geo.size.height / 2)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, t in
                    if duration > 0 {
                        RoundedRectangle(cornerRadius: 1).fill(DS.Colour.accent)
                            .frame(width: 2, height: 6)
                            .position(x: w * CGFloat(t / duration), y: geo.size.height - 3)
                    }
                }
                Rectangle().fill(DS.Colour.ink).frame(width: 2, height: 32)
                    .overlay(alignment: .top) { Circle().fill(DS.Colour.ink).frame(width: 8, height: 8).offset(y: -3) }
                    .position(x: w * fraction, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard w > 0, duration > 0 else { return }
                onSeek(Swift.max(0, Swift.min(1, value.location.x / w)) * duration)
            })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(DisplayFormat.duration(currentTime)) of \(DisplayFormat.duration(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(Swift.min(duration, currentTime + 5))
            case .decrement: onSeek(Swift.max(0, currentTime - 5))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player.scrubber")
    }
}

#Preview("Player bar") {
    let bars = previewPeaks.enumerated().map { i, p in
        WaveformBars.Bar(height: p, color: SpeakerPalette.colour(slot: i < 11 ? 0 : 1).dot)
    }
    VStack { Spacer() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            PlayerBar(isPlaying: false, currentTime: 12, duration: 20, rate: 1, bars: bars, markers: [14],
                      onTogglePlay: {}, onSeek: { _ in }, onCycleRate: {})
                .padding(.horizontal, 12)
        }
        .screenBackground()
}
