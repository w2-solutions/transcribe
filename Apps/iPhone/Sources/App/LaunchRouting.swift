import Foundation
import SwiftData
import TranscribeCore
import TranscribeKit

/// Applies `TRANSCRIBE_ROUTE` once, after launch (§4.10).
@MainActor enum LaunchRouting {
    static func apply(_ route: LaunchRoute?, router: Router, env: AppEnvironment) {
        guard let route else { return }
        switch route {
        case .library:
            break
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
            router.path = [.voices]
        case .settings:
            router.path = [.settings]
        case .modelSettings:
            router.path = [.settings, .modelSettings]
        case .attributions:
            router.path = [.settings, .attributions]
        case .transcript(let ref):
            if let id = recordingID(ref, env: env) { router.showTranscript(id, replacingPath: true) }
        case .nameSpeaker(let ref, let key):
            guard let id = recordingID(ref, env: env) else { return }
            router.showTranscript(id, replacingPath: true)
            Task {
                // Let the push settle before presenting the sheet.
                try? await Task.sleep(for: .milliseconds(400))
                router.nameSpeaker(NameSpeakerContext(recordingID: id, key: key))
            }
        case .voice(let name):
            let profiles = (try? env.container.mainContext.fetch(FetchDescriptor<VoiceProfile>())) ?? []
            if let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                router.path = [.voices, .voice(profile.id)]
            } else {
                router.path = [.voices]
            }
        }
    }

    /// "latest" = newest recording; "n" = n-th in library order (newest first).
    static func recordingID(_ ref: String, env: AppEnvironment) -> UUID? {
        let descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let all = (try? env.container.mainContext.fetch(descriptor)) ?? []
        if ref == "latest" { return all.first?.id }
        if let i = Int(ref), all.indices.contains(i) { return all[i].id }
        return nil
    }
}
