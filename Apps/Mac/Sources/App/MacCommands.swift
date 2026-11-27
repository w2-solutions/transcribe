import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeKit

/// Values the focused main window publishes for the menu commands.
extension FocusedValues {
    /// The transcript showing in the main window's detail column.
    @Entry var macTranscriptID: UUID?
}

/// The Mac menu commands (§5): Check for Updates… or Update Available… (app menu, after About), Shortcuts… (app menu,
/// after Settings), New Recording ⌘N, Stop Recording ⌘.,
/// Import Audio… ⌘O, Copy Transcript ⇧⌘C, Copy Last Dictation, Find ⌘F and Play/Pause. Space plays and pauses from the transcript itself
/// (`onKeyPress` in `MacRootView`), so typing a space in a text field never toggles playback. Delete (⌫) is the
/// recording list's `onDeleteCommand`; Settings (⌘,) is the system's.
struct MacCommands: Commands {
    let env: AppEnvironment
    let router: Router
    let selection: MacSelection
    let updater: AppUpdater
    let shortcuts: MacShortcuts
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.macTranscriptID) private var focusedTranscript

    /// The transcript a command acts on.
    private var transcriptID: UUID? { focusedTranscript }

    var body: some Commands {
        // Always present; disabled while updates are off (Debug, test runs) or a check is already running. "Update
        // Available…" while an update waits (D23): it brings up Sparkle's window for that update.
        CommandGroup(after: .appInfo) {
            Button(UpdateCopy.checkTitle(pendingVersion: updater.pendingVersion)) { updater.checkForUpdates() }
                .disabled(!updater.controlsEnabled)
        }
        // Settings at its Shortcuts section: the global shortcuts are otherwise easy to miss.
        CommandGroup(after: .appSettings) {
            Button(ShortcutCopy.menuItem) {
                shortcuts.revealSettingsSection = true
                openSettings()
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Recording") { newRecording() }
                .keyboardShortcut("n")
            if env.macAudioAvailable {
                // File → Record From: picks this Mac's source (the setting) and records with it. ⌘N uses the current one.
                Menu(RecordingSourceCopy.recordFromTitle) {
                    ForEach(CaptureSources.allCases, id: \.self) { source in
                        Toggle(RecordingSourceCopy.title(source), isOn: Binding(
                            get: { env.settings.recordingSource == source },
                            set: { if $0 { recordFrom(source) } }))
                    }
                }
                .disabled(env.recorder.isActive)
            }
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
            // The last dictation's text, kept in memory for 10 minutes: a paste into an app that ignored ⌘V, or a
            // clipboard replaced since, can be recovered.
            Button(ShortcutCopy.copyLastDictation) { shortcuts.copyLastDictation() }
                .disabled(shortcuts.dictation.lastText == nil)
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

    /// File → Record From: remembers the source as this Mac's setting, then the main window records with it.
    private func recordFrom(_ source: CaptureSources) {
        guard !env.recorder.isActive else { return }
        env.settings.recordingSource = source
        openWindow(id: "main")
        selection.recordSourceRequest = source
    }

    private func stopRecording() {
        Task {
            guard let id = try? await env.recorder.stop() else { return }
            router.isRecordingPresented = false
            // With the main window closed, nothing else closes the Recording window.
            shortcuts.opener.dismiss("recording")
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

    /// The transcript on screen has its audio on this Mac (a synced recording's audio may not be: not in iCloud, not
    /// downloaded yet, or not syncing here). Reads audio sync's `revision`, so Playback → Play turns on when a download
    /// lands.
    func hasLocalAudio(_ id: UUID?) -> Bool {
        _ = sync?.audio?.revision
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
