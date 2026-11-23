import Foundation
import SwiftData
import TranscribeCore
import TranscribeKit

/// A `LaunchRoute` with its references looked up in the library: where the app should open.
enum ResolvedRoute: Equatable {
    case library, recording, voices, settings, models, attributions
    case transcript(UUID)
    case name(UUID, SpeakerKey)
    case voice(UUID)
}

/// Applies `TRANSCRIBE_ROUTE` once, after launch (§4.10). `resolve` is shared by both apps; each app then
/// applies the result to its own navigation (`apply` here for the iPhone's stack, `MacLaunchRouting` on the Mac).
@MainActor enum LaunchRouting {
    /// Looks up the route's references. A recording reference that matches nothing resolves to the Library;
    /// a voice name that matches no profile resolves to the Voices list.
    static func resolve(_ route: LaunchRoute, env: AppEnvironment) async -> ResolvedRoute {
        switch route {
        case .library: return .library
        case .recording: return .recording
        case .voices: return .voices
        case .settings: return .settings
        case .modelSettings: return .models
        case .attributions: return .attributions
        case .transcript(let ref):
            guard let id = recordingID(ref, env: env) else { return .library }
            return .transcript(id)
        case .nameSpeaker(let ref, let key):
            guard let id = recordingID(ref, env: env) else { return .library }
            return .name(id, key)
        case .voice(let name):
            let profiles = (try? env.container.mainContext.fetch(FetchDescriptor<VoiceProfile>())) ?? []
            guard let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return .voices
            }
            return .voice(profile.id)
        }
    }

    /// The iPhone's navigation-stack apply, called from `RootView`.
    static func apply(_ route: ResolvedRoute, router: Router, env: AppEnvironment) {
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
        case .models:
            router.path = [.settings, .modelSettings]
        case .attributions:
            router.path = [.settings, .attributions]
        case .transcript(let id):
            router.showTranscript(id, replacingPath: true)
        case .name(let id, let key):
            router.showTranscript(id, replacingPath: true)
            Task {
                // Let the push settle before presenting the sheet.
                try? await Task.sleep(for: .milliseconds(400))
                router.nameSpeaker(NameSpeakerContext(recordingID: id, key: key))
            }
        case .voice(let id):
            router.path = [.voices, .voice(id)]
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
