import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Shared wording for the recording status capsule (screen 2) and the minimised pill (screen 1).
enum RecordingStatus {
    /// "Recording", "Paused", "Paused · call in progress", …
    static func title(_ state: RecorderController.State) -> String {
        switch state {
        case .idle, .stopping: "Saving"
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused(.user): "Paused"
        case .paused(.interruption): "Paused · call in progress"
        case .paused(.routeLost): "Paused · microphone disconnected"
        }
    }

    /// Short form for the Library pill, which has less room.
    static func shortTitle(_ state: RecorderController.State) -> String {
        if case .paused = state { return "Paused" }
        return state == .recording || state == .starting ? "Recording" : "Saving"
    }

    static func isLive(_ state: RecorderController.State) -> Bool { state == .recording }

    /// Alert after the system ended a recording (shown on the recording screen, or over the app if minimised).
    static func systemStopTitle(_ reason: RecordingEndReason) -> String {
        switch reason {
        case .lowStorage: "Recording stopped — iPhone storage is almost full"
        case .mediaServicesReset, .failed: "Recording stopped"
        }
    }

    static func systemStopMessage(_ reason: RecordingEndReason) -> String {
        switch reason {
        case .lowStorage: "What was recorded so far has been saved."
        case .mediaServicesReset: "The audio system restarted. What was recorded so far has been saved."
        case .failed(let text): text
        }
    }

    /// VoiceOver: "Recording, 0 minutes 14 seconds".
    static func accessibilityLabel(_ state: RecorderController.State, elapsed: TimeInterval) -> String {
        "\(title(state)), \(DisplayFormat.spokenDuration(elapsed))"
    }
}

/// 8 pt record-red dot with a 4 pt ring at 18% that pulses while recording (static under Reduce Motion or when paused).
struct PulsingRecordDot: View {
    let isPulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animate = isPulsing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            let phase = animate ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 0.8) + 1) / 2 : 1
            ZStack {
                Circle()
                    .fill(DS.Colour.record.opacity(isPulsing ? 0.18 : 0.10))
                    .frame(width: 8 + 8 * phase, height: 8 + 8 * phase)
                Circle()
                    .fill(isPulsing ? DS.Colour.record : DS.Colour.secondary)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 16, height: 16)
        }
        .accessibilityHidden(true)
    }
}

/// A glass capsule toast that re-shows every time `trigger` changes (unlike `.toast`, which needs new text).
struct RepeatingToast: ViewModifier {
    let text: String?
    let systemImage: String?
    let trigger: Int
    let id: String
    var topPadding: CGFloat = 8
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    Toast(shown, systemImage: systemImage)
                        .accessibilityIdentifier(id)
                        .padding(.top, topPadding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task(id: trigger) {
                guard trigger > 0, let text else { return }
                withAnimation(.snappy) { shown = text }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { shown = nil }
            }
    }
}

extension View {
    /// Shows `Toast(text)` for 2 s each time `trigger` changes to a positive value.
    func repeatingToast(_ text: String?, systemImage: String? = nil, trigger: Int, id: String,
                        topPadding: CGFloat = 8) -> some View {
        modifier(RepeatingToast(text: text, systemImage: systemImage, trigger: trigger, id: id, topPadding: topPadding))
    }
}
