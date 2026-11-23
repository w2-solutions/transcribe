import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeKit

/// Values the focused main window publishes for the menu commands.
extension FocusedValues {
    /// The transcript showing in the main window's detail column.
    @Entry var macTranscriptID: UUID?
}

/// The Mac menu commands (§5): New Recording ⌘N, Stop Recording ⌘., Import Audio… ⌘O, Copy Transcript ⇧⌘C,
/// Find ⌘F and Play/Pause. Space plays and pauses from the transcript itself (`onKeyPress` in `MacRootView`), so
/// typing a space in a text field never toggles playback. Delete (⌫) is the recording list's `onDeleteCommand`;
/// Settings (⌘,) is the system's.
struct MacCommands: Commands {
    let env: AppEnvironment
    let router: Router
    let selection: MacSelection
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.macTranscriptID) private var focusedTranscript

    /// The transcript a command acts on.
    private var transcriptID: UUID? { focusedTranscript }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { newRecording() }
                .keyboardShortcut("n")
            Button("Stop Recording") { stopRecording() }
                .keyboardShortcut(".")
                .disabled(!env.recorder.isActive)
            Divider()
            Button("Import Audio…") {
                openWindow(id: "main")
                selection.importRequest += 1
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Transcript") { copyTranscript() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(transcriptID == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { selection.searchFocusRequest += 1 }
                .keyboardShortcut("f")
        }
        CommandMenu("Playback") {
            Button(env.player.isPlaying ? "Pause" : "Play") { env.player.toggle() }
                .disabled(focusedTranscript == nil || env.player.loadedURL == nil)
        }
    }

    private func newRecording() {
        openWindow(id: "main")
        if env.recorder.isActive { router.isRecordingPresented = true; return }
        env.player.stop()
        Task {
            do {
                try await env.recorder.start()
                router.isRecordingPresented = true
            } catch {
                // Mic denied or engine failure: the toolbar's Record button explains; the command stays quiet.
            }
        }
    }

    private func stopRecording() {
        Task {
            guard let id = try? await env.recorder.stop() else { return }
            router.isRecordingPresented = false
            if selection.sidebar == .voices { selection.sidebar = .all }
            selection.recording = id
        }
    }

    private func copyTranscript() {
        guard let id = transcriptID else { return }
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let recording = try? env.container.mainContext.fetch(descriptor).first,
              let document = recording.transcript else { return }
        let format: CopyFormat = env.settings.autoCopy == .off ? .withSpeakers : env.settings.autoCopy
        let text = TranscriptFormatter.plainText(document, format: format, removeFillers: env.settings.removeFillers) { key in
            recording.speaker(key)?.displayName ?? "Speaker"
        }
        Pasteboard.copy(text)
    }
}
