import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// Auto copy (§6.1, §9): when a job finishes while the app is active and Settings → Auto copy is not Off, copies
/// the transcript (text only, or with speakers) and shows "Transcript copied".
struct AutoCopyObserver: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var toastCount = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: env.monitor.lastFinished) { _, finished in
                guard let finished else { return }
                copy(finished)
            }
            .repeatingToast("Transcript copied", systemImage: "doc.on.doc", trigger: toastCount,
                            id: AX.Transcript.copiedToast)
    }

    private func copy(_ snapshot: ProcessingSnapshot) {
        guard scenePhase == .active, env.settings.autoCopy != .off else { return }
        guard case .finished(let outcome) = snapshot.phase, !outcome.noSpeech else { return }
        let id = snapshot.recordingID
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let recording = try? env.container.mainContext.fetch(descriptor).first,
              let document = recording.transcript else { return }
        let text = TranscriptFormatter.plainText(document, format: env.settings.autoCopy,
                                                 removeFillers: env.settings.removeFillers) { key in
            recording.speaker(key)?.displayName ?? "Speaker"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Pasteboard.copy(text)
        toastCount += 1
    }
}
