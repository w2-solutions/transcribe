import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The minimised recording (§6.1): a glass capsule above the Library dock while a recording runs with its cover
/// dismissed. Tapping it brings the Recording screen back.
struct RecordingPill: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        let recorder = env.recorder
        Button {
            router.isRecordingPresented = true
        } label: {
            HStack(spacing: 9) {
                PulsingRecordDot(isPulsing: RecordingStatus.isLive(recorder.state))
                    .frame(width: 8, height: 8)
                Text(RecordingStatus.shortTitle(recorder.state))
                    .font(.system(size: 14, weight: .semibold))
                Text(DisplayFormat.duration(recorder.elapsed))
                    .font(DS.Typo.monoStatus)
            }
            .foregroundStyle(DS.Colour.ink)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(minHeight: DS.Space.hit)
        .accessibilityLabel(RecordingStatus.accessibilityLabel(recorder.state, elapsed: recorder.elapsed))
        .accessibilityHint("Returns to the recording")
        .accessibilityIdentifier(AX.Library.recordingPill)
    }
}
