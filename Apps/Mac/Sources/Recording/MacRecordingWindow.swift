import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The Recording window (§5): the shared `RecordingView` in its own single window, so the library stays usable while
/// recording. Closing the window (or the view's Minimise button) only hides it; the recording keeps running and the
/// main window's toolbar shows the recording pill to bring it back.
struct MacRecordingWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(MacSelection.self) private var selection
    @Environment(MacWindowOpener.self) private var opener
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        RecordingView()
            .frame(minWidth: 480, minHeight: 620)
            .accessibilityIdentifier(AX.Mac.recordingWindow)
            // The shared view finishes with `showTranscript`; on the Mac that selects the recording in the list.
            .onChange(of: router.path) { _, path in
                if case .transcript(let id)? = path.first, path.count == 1 {
                    if selection.sidebar == .voices { selection.sidebar = .all }
                    selection.recording = id
                    router.path = []
                }
            }
            .onAppear {
                router.isRecordingPresented = true
                opener.fill(open: openWindow, dismiss: dismissWindow)
            }
            .onDisappear { router.isRecordingPresented = false }
    }
}
