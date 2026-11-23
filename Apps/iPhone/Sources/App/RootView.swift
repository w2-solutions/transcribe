import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var router = Router()
    var body: some View {
        NavigationStack(path: $router.path) {
            LibraryView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .transcript(let id): TranscriptView(recordingID: id)
                    case .voices: VoicesView()
                    case .voice(let id): VoiceDetailView(profileID: id)
                    case .settings: SettingsView()
                    case .modelSettings: ModelSettingsView()
                    case .language: LanguagePickerView()
                    case .attributions: AttributionsView()
                    }
                }
        }
        .fullScreenCover(isPresented: $router.isRecordingPresented) { RecordingView() }
        .sheet(item: $router.sheet) { sheet in
            switch sheet { case .nameSpeaker(let ctx): NameSpeakerSheet(context: ctx) }
        }
        .modifier(AutoCopyObserver())
        // A system end while the recording screen is minimised: the recorder has already stopped and saved.
        // With the screen showing, RecordingView presents this alert instead.
        .alert(env.recorder.systemStop.map { RecordingStatus.systemStopTitle($0.reason) } ?? "Recording stopped",
               isPresented: Binding(get: { env.recorder.systemStop != nil && !router.isRecordingPresented },
                                    set: { if !$0 { env.recorder.acknowledgeSystemStop() } }),
               presenting: env.recorder.systemStop) { stop in
            Button("Show") {
                env.recorder.acknowledgeSystemStop()
                if let id = stop.recordingID { router.showTranscript(id, replacingPath: true) }
            }
            Button("OK", role: .cancel) { env.recorder.acknowledgeSystemStop() }
        } message: { stop in
            Text(RecordingStatus.systemStopMessage(stop.reason))
        }
        .preferredColorScheme(env.settings.appearance == .light ? .light : env.settings.appearance == .dark ? .dark : nil)
        .tint(DS.Colour.accent)
        .environment(router)
        .task { await env.onLaunch(); LaunchRouting.apply(env.config.route, router: router, env: env) }
    }
}
