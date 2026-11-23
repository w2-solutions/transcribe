import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Screen 2 (§6.2), presented as a `fullScreenCover` over the Library. Minimise dismisses the cover while the
/// recording carries on; Stop finalises it and replaces the stack with its transcript.
struct RecordingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var isStopping = false
    @State private var stopError: String?
    @State private var screenHeight: CGFloat = 852
    @State private var dockHeight: CGFloat = 160

    private var recorder: RecorderController { env.recorder }
    private var isPaused: Bool { if case .paused = recorder.state { true } else { false } }
    /// The recorder stops and saves on its own after a system end; this screen only shows the alert.
    private var systemStop: RecorderController.SystemStop? { recorder.systemStop }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            topRow
            header
            // The level meter shows when it fits above the dock; at large text sizes it gives way so it never
            // runs under the pause, stop and mark buttons.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    liveCard
                    LiveLevelMeter(levels: recorder.levels)
                        .padding(.top, 10)
                        .accessibilityIdentifier(AX.Recording.levelMeter)
                }
                liveCard
            }
            .layoutPriority(1)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Recording.screen)
        .onAppear { env.player.stop() }
        .onChange(of: recorder.isActive) { _, active in
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
        LiveTranscriptCard(text: recorder.liveText, note: recorder.liveTextNote, maxHeight: screenHeight * 0.4)
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
            Label {
                Text("Speakers are separated when you stop.")
            } icon: {
                Image(systemName: "person.2").font(.system(size: 14, weight: .medium))
            }
            .labelStyle(HintLabelStyle())
            .scaledFont(size: 14, relativeTo: .subheadline)
            .foregroundStyle(DS.Colour.secondary)
            .padding(.top, 6)
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

/// The live transcript card (§6.2): confirmed text in ink, volatile text in secondary, then a blinking accent
/// caret. Auto-scrolls to keep the newest lines visible, up to `maxHeight`.
private struct LiveTranscriptCard: View {
    let text: TranscribeCore.LiveText
    let note: String?
    let maxHeight: CGFloat
    @State private var textHeight: CGFloat = 26

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
                    LiveTextBody(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                }
                .frame(height: Swift.min(Swift.max(textHeight, 26), Swift.max(120, maxHeight)))
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: EdgeInsets(top: 20, leading: 20, bottom: 22, trailing: 20))
        .modifier(LiveCardAccessibility(hasNote: note != nil, spoken: spokenText))
    }

    private var spokenText: String {
        let all = [text.confirmed, text.volatile].filter { !$0.isEmpty }.joined(separator: " ")
        return all.isEmpty ? "Live transcript. Listening" : "Live transcript. \(all)"
    }

    /// The text is laid out only when it changes. The caret blinks through an animated `TextRenderer`, which
    /// redraws without re-laying out the (growing) text; only the tail of a long session is shown, since the
    /// card scrolls to its last lines anyway.
    private struct LiveTextBody: View {
        let text: TranscribeCore.LiveText
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(AppEnvironment.self) private var env
        @State private var blink = 1.0

        /// Characters of confirmed text kept on screen (cut at a word boundary).
        static let visibleCharacters = 1_500

        var body: some View {
            let steady = reduceMotion || env.config.uiTesting
            content
                .font(DS.Typo.transcript)
                .lineSpacing(5.7)   // 17 pt text on a 26 pt line
                .fixedSize(horizontal: false, vertical: true)
                .textRenderer(CaretBlinkRenderer(opacity: steady ? 1 : blink))
                .onAppear {
                    guard !steady else { return }
                    withAnimation(.linear(duration: 0.53).repeatForever(autoreverses: true)) { blink = 0 }
                }
        }

        private var content: Text {
            let caret = Text(Self.caret)
                .foregroundStyle(DS.Colour.accent)
                .customAttribute(CaretAttribute())
            if text.isEmpty {
                return Text("\(Text("Listening…").foregroundStyle(DS.Colour.secondary))\(caret)")
            }
            let confirmed = Self.tail(text.confirmed, limit: Self.visibleCharacters)
            let gap = !confirmed.isEmpty && !text.volatile.isEmpty ? " " : ""
            return Text("\(Text(confirmed).foregroundStyle(DS.Colour.ink))\(Text(gap + text.volatile).foregroundStyle(DS.Colour.secondary))\(caret)")
        }

        /// The last `limit` characters, starting after a space, with a leading ellipsis when cut.
        static func tail(_ s: String, limit: Int) -> String {
            guard s.count > limit else { return s }
            let start = s.index(s.endIndex, offsetBy: -limit)
            let cut = s[start...].firstIndex(of: " ").map { s.index(after: $0) } ?? start
            return "…" + s[cut...]
        }

        /// 2 × 16 pt rounded caret with a 3 pt lead, standing on the baseline (so it never grows the line), drawn once
        /// as a template image so it can sit inside `Text`.
        static let caret: Image = {
            let size = CGSize(width: 5, height: 16)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.black.setFill()
                UIBezierPath(roundedRect: CGRect(x: 3, y: 0, width: 2, height: 16), cornerRadius: 1).fill()
            }
            return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
        }()
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
