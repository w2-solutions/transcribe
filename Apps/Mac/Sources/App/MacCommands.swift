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
                selection.importRequested = true
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
        CommandGroup(after: .toolbar) {
            Button("Sync Now") { Task { await env.sync?.refreshNow() } }
                .keyboardShortcut("r")
                .disabled(env.sync == nil || !env.settings.syncEnabled)
        }
        CommandMenu("Playback") {
            Button(env.player.isPlaying ? "Pause" : "Play") {
                if let id = focusedTranscript { env.togglePlayback(of: id) }
            }
            .disabled(!env.hasLocalAudio(focusedTranscript))
        }
    }

    /// Brings the Recording window to the front while recording; otherwise the main window starts one through
    /// `MacRootView.record()`, which explains a denied microphone or a failure.
    private func newRecording() {
        openWindow(id: "main")
        if env.recorder.isActive {
            router.isRecordingPresented = true
            openWindow(id: "recording")
            return
        }
        selection.recordRequested = true
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

extension AppEnvironment {
    /// The recording with this id, when it is in the library.
    func libraryRecording(_ id: UUID) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }

    /// The transcript on screen has its audio on this Mac (a synced recording keeps it on the device that recorded it).
    func hasLocalAudio(_ id: UUID?) -> Bool {
        guard let id, let recording = libraryRecording(id) else { return false }
        return store.hasLocalAudio(recording)
    }

    /// Space and Playback → Play/Pause: plays or pauses this recording's own audio, never a file another transcript
    /// left loaded. False (nothing happens) when the recording has no audio on this Mac.
    @discardableResult
    func togglePlayback(of id: UUID) -> Bool {
        guard let recording = libraryRecording(id), store.hasLocalAudio(recording) else { return false }
        let url = paths.audioURL(fileName: recording.audioFileName)
        if player.loadedURL != url {
            guard (try? player.load(url: url)) != nil else { return false }
        }
        player.toggle()
        return true
    }
}
