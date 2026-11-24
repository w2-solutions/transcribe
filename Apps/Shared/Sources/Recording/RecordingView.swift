import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 2 (§6.2): a `fullScreenCover` over the Library on iPhone, its own Recording window on the Mac.
/// Minimise dismisses it while the recording carries on; Stop finalises it and shows its transcript.
struct RecordingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var isStopping = false
    @State private var stopError: String?
    @State private var dockHeight: CGFloat = 160
    /// Set once the live text has outgrown its card: the header shrinks to one line and the level meter to a
    /// strip, handing the room to the words. It stays set for the rest of the recording so nothing jumps back.
    @State private var isCompact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recorder: RecorderController { env.recorder }
    private var isPaused: Bool { if case .paused = recorder.state { true } else { false } }
    /// The recorder stops and saves on its own after a system end; this screen only shows the alert.
    private var systemStop: RecorderController.SystemStop? { recorder.systemStop }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            topRow
            header
            // The card takes the room that is left above the dock and never more, so the newest words are
            // always on screen. At accessibility text sizes the level meter gives way to the text.
            liveCard
                .layoutPriority(1)
            if !dynamicTypeSize.isAccessibilitySize {
                LiveLevelMeter(levels: recorder.levels, maxHeight: isCompact ? 36 : 64, height: isCompact ? 44 : 96)
                    .padding(.top, isCompact ? 0 : 10)
                    .accessibilityIdentifier(AX.Recording.levelMeter)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.screenInset)
        .padding(.top, 4)
        .padding(.bottom, dockHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            // Pinned to the screen edge like the mockup (dock 30 pt from the bottom, footer 16 pt above it).
            bottomBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { dockHeight = $0 }
                .padding(.bottom, DS.Space.dockBottom - 4)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .repeatingToast(recorder.lastMarkAt.map { "Moment marked \(DisplayFormat.duration($0))" },
                        systemImage: "bookmark.fill", trigger: recorder.marks.count, id: AX.Recording.markToast,
                        topPadding: 60)   // below the status row, so the capsule stays readable
        .sensoryFeedback(.impact(weight: .light), trigger: recorder.marks.count)
        .background { AmbientBackground(drift: true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Recording.screen)
        .onAppear { env.player.stop() }
        .onChange(of: recorder.isActive) { _, active in
            // A new capture: the Mac's single Recording window keeps this view's state between recordings, so the
            // previous recording's finished stop must not leave Stop disabled.
            if active { isStopping = false; stopError = nil }
            // Ended elsewhere (discarded, or a failed start): nothing left to show. A system end shows its alert.
            if !active, !isStopping, recorder.systemEndReason == nil { dismiss() }
        }
        .alert(systemStop.map { RecordingStatus.systemStopTitle($0.reason) } ?? "Recording stopped",
               isPresented: Binding(get: { systemStop != nil }, set: { if !$0 { recorder.acknowledgeSystemStop() } }),
               presenting: systemStop) { stop in
            Button("OK") {
                recorder.acknowledgeSystemStop()
                finish(with: stop.recordingID)
            }
        } message: { stop in
            Text(RecordingStatus.systemStopMessage(stop.reason))
        }
        .alert("Couldn't stop recording", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stopError ?? "")
        }
    }

    private var liveCard: some View {
        LiveTranscriptCard(text: recorder.liveText, note: recorder.liveTextNote,
                           steady: reduceMotion || env.config.uiTesting) {
            guard !isCompact else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { isCompact = true }
        }
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 0) {
            GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: "Minimise recording") { dismiss() }
                .accessibilityIdentifier(AX.Recording.minimiseButton)
            Spacer(minLength: 8)
            statusCapsule
            Spacer(minLength: 8)
            Color.clear.frame(width: DS.Space.hit, height: DS.Space.hit).accessibilityHidden(true)
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 9) {
            PulsingRecordDot(isPulsing: RecordingStatus.isLive(recorder.state))
                .frame(width: 8, height: 8)
            Text(RecordingStatus.title(recorder.state))
                .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(DisplayFormat.duration(recorder.elapsed))
                .font(DS.Typo.monoStatus)
                .accessibilityLabel(DisplayFormat.duration(recorder.elapsed))
                .accessibilityIdentifier(AX.Recording.elapsed)
        }
        .foregroundStyle(DS.Colour.ink)
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(minHeight: 36)
        .floatingGlass(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RecordingStatus.accessibilityLabel(recorder.state, elapsed: recorder.elapsed))
        .accessibilityIdentifier(AX.Recording.statusCapsule)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCompact {
                Text("New recording")
                    .font(DS.Typo.largeTitle)
                    .tracking(-0.6)
                    .foregroundStyle(DS.Colour.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AX.Recording.title)
                Text(DisplayFormat.longDate(recorder.startedAt ?? env.clock.now))
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(DS.Colour.secondary)
                    .accessibilityIdentifier(AX.Recording.date)
            }
            Label {
                Text("Speakers are separated when you stop.")
            } icon: {
                Image(systemName: "person.2").font(.system(size: 14, weight: .medium))
            }
            .labelStyle(HintLabelStyle())
            .scaledFont(size: 14, relativeTo: .subheadline)
            .foregroundStyle(DS.Colour.secondary)
            .padding(.top, isCompact ? 0 : 6)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 16) {
            Label {
                Text("On-device · \(env.engine.info.asrDisplayName)")
            } icon: {
                Image(systemName: "lock").font(.system(size: 12, weight: .semibold))
            }
            .labelStyle(HintLabelStyle(spacing: 6))
            .font(.footnote.weight(.medium))
            .foregroundStyle(DS.Colour.secondary)
            ControlDock {
                GlassCircleButton(systemImage: isPaused ? "play" : "pause", size: .large,
                                  accessibilityLabel: isPaused ? "Resume recording" : "Pause recording") {
                    Task { isPaused ? await recorder.resume() : await recorder.pause() }
                }
                .disabled(recorder.state == .starting || isStopping)
                .accessibilityIdentifier(AX.Recording.pauseButton)
                RecordButton(mode: .stop, accessibilityLabel: "Stop recording") { stop() }
                    .disabled(isStopping || recorder.systemEndReason != nil)
                    .accessibilityIdentifier(AX.Recording.stopButton)
                GlassCircleButton(systemImage: "bookmark", size: .large, accessibilityLabel: "Mark this moment") {
                    Task { await recorder.markMoment() }
                }
                .disabled(recorder.state == .starting || isStopping)
                .accessibilityIdentifier(AX.Recording.markButton)
            }
        }
    }

    // MARK: Actions

    private func stop() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            do {
                let id = try await recorder.stop()
                finish(with: id)
            } catch {
                isStopping = false
                if recorder.isActive {
                    stopError = "The recording is still running. \(error.localizedDescription)"
                } else {
                    dismiss()
                }
            }
        }
    }

    /// Dismisses the cover and shows the transcript (or just the Library if nothing was saved).
    private func finish(with id: UUID?) {
        dismiss()
        if let id { router.showTranscript(id, replacingPath: true) }
    }

}

/// Icon then text with a fixed gap, centred vertically (hint rows and the footer).
private struct HintLabelStyle: LabelStyle {
    var spacing: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// The live transcript card (§6.2). The words are split into short paragraphs and arrive a word at a time at
/// about speaking pace; the paragraph being spoken is in full ink (its newest, still-settling words in
/// secondary, then a blinking accent caret) and earlier paragraphs step back. The card grows with the text up
/// to the room it is given, then keeps the newest lines in view while older ones fade out under its top edge.
private struct LiveTranscriptCard: View {
    let text: TranscribeCore.LiveText
    let note: String?
    /// Show text at once and hold the caret still (Reduce Motion, UI tests).
    let steady: Bool
    /// Called when the text no longer fits the room the card was given.
    let onOverflow: () -> Void

    @State private var contentHeight: CGFloat = Self.lineHeight
    @State private var viewportHeight: CGFloat = 0
    /// Words shown so far; nil until the card first appears (text already spoken is then shown at once).
    @State private var revealed: Int?

    static let lineHeight: CGFloat = 26
    /// Paragraphs kept on screen; older ones have scrolled away.
    static let visibleParagraphs = 12

    private var totalWords: Int { LiveTextLayout.wordCount(text) }
    private var overflows: Bool { viewportHeight > 0 && contentHeight > viewportHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(DS.Colour.accent).frame(width: 6, height: 6)
                Text("Live transcript").font(DS.Typo.chip).foregroundStyle(DS.Colour.secondary)
            }
            .accessibilityHidden(true)
            if let note {
                Text(note)
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AX.Recording.liveTextNote)
            } else {
                ScrollView {
                    LiveTextBody(paragraphs: paragraphs, steady: steady)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(minHeight: Self.lineHeight, maxHeight: Swift.max(Self.lineHeight, contentHeight))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .mask { TopFade(height: overflows ? 30 : 0) }
                .accessibilityHidden(true)
                .task(id: overflows) {
                    // The viewport follows the text height a frame late, so only a lasting overflow counts.
                    guard overflows else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { onOverflow() }
                }
                .task(id: totalWords) { await reveal(upTo: totalWords) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 20, leading: 20, bottom: 22, trailing: 20))
        .modifier(LiveCardAccessibility(hasNote: note != nil, spoken: spokenText))
    }

    private var paragraphs: [LiveParagraph] {
        let shown = steady ? totalWords : Swift.min(revealed ?? totalWords, totalWords)
        return LiveTextLayout.paragraphs(LiveTextLayout.revealing(text, words: shown)).suffix(Self.visibleParagraphs)
    }

    /// Shows the waiting words one at a time, faster when more are waiting.
    private func reveal(upTo total: Int) async {
        guard !steady else { return }
        var shown = Swift.min(revealed ?? total, total)
        revealed = shown
        while shown < total {
            try? await Task.sleep(for: .seconds(LiveTextLayout.revealInterval(backlog: total - shown)))
            guard !Task.isCancelled else { return }
            shown += 1
            revealed = shown
        }
    }

    /// VoiceOver reads everything recognised so far, not just the words shown.
    private var spokenText: String {
        let all = [text.confirmed, text.volatile].filter { !$0.isEmpty }.joined(separator: " ")
        return all.isEmpty ? "Live transcript. Listening" : "Live transcript. \(all)"
    }

    /// Fades the top `height` points to clear (lines scrolling away); fully opaque when `height` is 0.
    private struct TopFade: View {
        let height: CGFloat
        var body: some View {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.black
            }
        }
    }

    /// The text is laid out only when it changes. The caret blinks through an animated `TextRenderer`, which
    /// redraws without re-laying out the text.
    private struct LiveTextBody: View {
        let paragraphs: [LiveParagraph]
        let steady: Bool
        @State private var blink = 1.0

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                if paragraphs.isEmpty {
                    styled(Text("\(Text("Listening…").foregroundStyle(DS.Colour.secondary))\(caret)"))
                }
                ForEach(paragraphs) { paragraph in
                    let isCurrent = paragraph.id == paragraphs.last?.id
                    styled(content(paragraph, isCurrent: isCurrent))
                        .opacity(isCurrent ? 1 : 0.5)
                }
            }
            .animation(steady ? nil : .easeOut(duration: 0.4), value: paragraphs.last?.id)
            .onAppear {
                guard !steady else { return }
                withAnimation(.linear(duration: 0.53).repeatForever(autoreverses: true)) { blink = 0 }
            }
        }

        private func styled(_ text: Text) -> some View {
            text
                .font(DS.Typo.transcript)
                .lineSpacing(5.7)   // 17 pt text on a 26 pt line
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(CaretBlinkRenderer(opacity: steady ? 1 : blink))
        }

        private var caret: Text {
            Text(Self.caret)
                .foregroundStyle(DS.Colour.accent)
                .customAttribute(CaretAttribute())
        }

        private func content(_ paragraph: LiveParagraph, isCurrent: Bool) -> Text {
            let gap = !paragraph.confirmed.isEmpty && !paragraph.volatile.isEmpty ? " " : ""
            let confirmed = Text(paragraph.confirmed).foregroundStyle(DS.Colour.ink)
            let volatile = Text(gap + paragraph.volatile).foregroundStyle(DS.Colour.secondary)
            return isCurrent ? Text("\(confirmed)\(volatile)\(caret)") : Text("\(confirmed)\(volatile)")
        }

        /// 2 × 16 pt rounded caret with a 3 pt lead, standing on the baseline (so it never grows the line), drawn once
        /// as a template image so it can sit inside `Text`.
        static let caret: Image = Image(size: CGSize(width: 5, height: 16)) { ctx in
            ctx.fill(Path(roundedRect: CGRect(x: 3, y: 0, width: 2, height: 16), cornerRadius: 1, style: .circular), with: .color(.black))
        }
        .renderingMode(.template)
    }
}

/// Marks the caret run inside the live text.
private struct CaretAttribute: TextAttribute {}

/// Draws the live text and shows the caret run only in the "on" half of the blink.
private struct CaretBlinkRenderer: TextRenderer, Animatable {
    var opacity: Double
    var animatableData: Double {
        get { opacity }
        set { opacity = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let caretOn = opacity >= 0.5
        for line in layout {
            for run in line where caretOn || run[CaretAttribute.self] == nil {
                ctx.draw(run)
            }
        }
    }
}

/// With live text the card is one element whose label carries the text; with a note, the note is its own element.
private struct LiveCardAccessibility: ViewModifier {
    let hasNote: Bool
    let spoken: String

    func body(content: Content) -> some View {
        if hasNote {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Live transcript")
                .accessibilityIdentifier(AX.Recording.liveTranscript)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier(AX.Recording.liveTranscript)
        }
    }
}
