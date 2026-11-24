import Foundation
import TranscribeCore
import TranscribeKit

/// Applies a resolved `TRANSCRIBE_ROUTE` to the Mac window: a selection in the sidebar and list, the recording
/// window, or the Settings window. The lookups are shared with the iPhone (`LaunchRouting.resolve`).
@MainActor enum MacLaunchRouting {
    static func apply(_ route: ResolvedRoute, selection: MacSelection, router: Router, env: AppEnvironment,
                      openSettings: @escaping () -> Void) {
        switch route {
        case .library:
            selection.sidebar = .all
        case .recording:
            Task {
                // Live text needs ready models; give the detached prepare a moment (fake engine: well under 1 s).
                for _ in 0..<40 where !env.models.isReady { try? await Task.sleep(for: .milliseconds(50)) }
                do {
                    try await env.recorder.start()
                    router.isRecordingPresented = true
                } catch {
                    // Mic denied or engine failure: stay on the Library.
                }
            }
        case .voices:
            selection.sidebar = .voices
        case .settings, .models, .attributions:
            openSettings()
        case .transcript(let id):
            selection.sidebar = .all
            selection.recording = id
        case .name(let id, let key):
            selection.sidebar = .all
            selection.recording = id
            Task {
                // Let the transcript appear before presenting the sheet.
                try? await Task.sleep(for: .milliseconds(400))
                router.nameSpeaker(NameSpeakerContext(recordingID: id, key: key))
            }
        case .voice(let id):
            selection.sidebar = .voices
            selection.voice = id
        }
    }
}
