import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit
import UniformTypeIdentifiers

/// The Mac main window (§5): sidebar, a recordings or voices list, and the transcript or voice in the detail column.
struct MacRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(MacSelection.self) private var selection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    @State private var columns = NavigationSplitViewVisibility.all
    @State private var isImporterPresented = false
    @State private var isShowingMicDenied = false
    @State private var importAfterMicSheet = false
    @State private var isStarting = false
    @State private var alert: MacAlert?
    @State private var captureActivity = CaptureActivity()

    private struct MacAlert: Identifiable { let id = UUID(); let title: String; let message: String }

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebar(onRecord: record)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                // The sidebar carries the app name and the column its own heading, as in the mockup.
                .navigationTitle("")
        } detail: {
            NavigationStack(path: $router.path) {
                detailRoot
                    .navigationDestination(for: Route.self) { route in destination(route) }
            }
        }
        // `.contain` gives the split view its own element, so the identifier reaches the accessibility tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Mac.main)
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .nameSpeaker(let ctx):
                NameSpeakerSheet(context: ctx).sheetSizing(minWidth: 480, minHeight: 560)
            }
        }
        .sheet(isPresented: $isShowingMicDenied, onDismiss: {
            if importAfterMicSheet { importAfterMicSheet = false; isImporterPresented = true }
        }) {
            MicDeniedSheet { importAfterMicSheet = true }.sheetSizing(minWidth: 480, minHeight: 360)
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio, .movie],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await runImport(urls) }
            case .failure(let error): alert = MacAlert(title: "Couldn't import", message: LibraryErrors.message(for: error))
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(env.recorder.systemStop.map { RecordingStatus.systemStopTitle($0.reason) } ?? "Recording stopped",
               isPresented: Binding(get: { env.recorder.systemStop != nil && !router.isRecordingPresented },
                                    set: { if !$0 { env.recorder.acknowledgeSystemStop() } }),
               presenting: env.recorder.systemStop) { stop in
            Button("Show") {
                env.recorder.acknowledgeSystemStop()
                if let id = stop.recordingID { show(recording: id) }
            }
            Button("OK", role: .cancel) { env.recorder.acknowledgeSystemStop() }
        } message: { stop in
            Text(RecordingStatus.systemStopMessage(stop.reason))
        }
        .modifier(AutoCopyObserver())
        .syncPrompts()
        .onChange(of: router.isRecordingPresented) { _, presented in
            if presented { openWindow(id: "recording") } else { dismissWindow(id: "recording") }
        }
        .onChange(of: router.path) { _, path in absorb(path) }
        .onChange(of: selection.sidebar) { _, _ in router.path = [] }
        .onChange(of: selection.recording) { _, _ in router.path = [] }
        .onChange(of: selection.voice) { _, _ in router.path = [] }
        .onChange(of: selection.importRequest) { _, _ in isImporterPresented = true }
        .onChange(of: env.recorder.isActive, initial: true) { _, active in captureActivity.set(active: active) }
        .task {
            await env.onLaunch()
            if let route = env.config.route {
                MacLaunchRouting.apply(await LaunchRouting.resolve(route, env: env), selection: selection,
                                       router: router, env: env, openSettings: { openSettings() })
            }
        }
    }

    // MARK: Columns

    @ViewBuilder private var contentColumn: some View {
        if selection.sidebar == .voices {
            MacVoiceList()
        } else {
            MacRecordingList(onRecord: record, onImport: { urls in Task { await runImport(urls) } })
        }
    }

    @ViewBuilder private var detailRoot: some View {
        if selection.sidebar == .voices, let id = selection.voice {
            VoiceDetailView(profileID: id).id(id)
        } else if selection.sidebar != .voices, let id = selection.recording {
            TranscriptView(recordingID: id).id(id)
                .focusedSceneValue(\.macTranscriptID, id)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard env.player.loadedURL != nil else { return .ignored }
                    env.player.toggle()
                    return .handled
                }
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: selection.sidebar == .voices ? "person.2" : "waveform")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(DS.Colour.tertiary)
                .accessibilityHidden(true)
            Text(selection.sidebar == .voices ? "Select a voice" : "Select a recording")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Colour.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Mac.detailEmpty)
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .transcript(let id): TranscriptView(recordingID: id)
        case .voices: MacVoiceList()
        case .voice(let id): VoiceDetailView(profileID: id)
        case .settings: SettingsView()
        case .modelSettings: ModelSettingsView()
        case .language: LanguagePickerView()
        case .attributions: AttributionsView()
        }
    }

    /// The shared views navigate as on the iPhone (`showTranscript`, `path.append(.voices)` …). On the Mac a
    /// transcript, a voice or the voices list is a selection, and Settings is its own window, so those pushes
    /// become selections here instead of stacking up in the detail column.
    private func absorb(_ path: [Route]) {
        guard let first = path.first else { return }
        switch first {
        case .transcript(let id) where path.count == 1:
            show(recording: id)
        case .voices:
            selection.sidebar = .voices
            if case .voice(let id)? = path.dropFirst().first { selection.voice = id }
            router.path = []
        case .voice(let id) where path.count == 1:
            selection.sidebar = .voices
            selection.voice = id
            router.path = []
        case .settings, .modelSettings, .language, .attributions:
            router.path = []
            openSettings()
        default:
            break
        }
    }

    private func show(recording id: UUID) {
        if selection.sidebar == .voices { selection.sidebar = .all }
        selection.recording = id
        router.path = []
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if env.recorder.isActive && !router.isRecordingPresented {
                RecordingPill()
                    .accessibilityIdentifier(AX.Mac.toolbarRecordingPill)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Import Audio…", systemImage: "square.and.arrow.down") { isImporterPresented = true }
                .help("Import an audio file")
                .accessibilityIdentifier(AX.Mac.toolbarImport)
            Button("New Recording", systemImage: "record.circle") { record() }
                .help("Start a new recording")
                .accessibilityIdentifier(AX.Mac.toolbarRecord)
        }
    }

    // MARK: Actions

    private func record() {
        if env.recorder.isActive { router.isRecordingPresented = true; return }
        guard !isStarting else { return }
        isStarting = true
        env.player.stop()
        Task {
            defer { isStarting = false }
            do {
                try await env.recorder.start()
                router.isRecordingPresented = true
            } catch EngineError.microphoneDenied {
                isShowingMicDenied = true
            } catch {
                alert = MacAlert(title: "Can't record", message: LibraryErrors.message(for: error))
            }
        }
    }

    private func runImport(_ urls: [URL]) async {
        var lastID: UUID?
        for url in urls {
            do {
                lastID = try await importAudio(from: url, env: env)
            } catch {
                alert = MacAlert(title: "Couldn't import", message: LibraryErrors.message(for: error))
            }
        }
        if let lastID { show(recording: lastID) }
    }
}
