import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit
import UniformTypeIdentifiers

/// The middle column for a library item (§5): the shared `RecordingCard` rows filtered by the sidebar item and the
/// search field, with the shared context menu, ⌫ to delete and audio files dropped in to import.
///
/// A focusable scroll view rather than `List(selection:)`: the cards carry their own selected outline (as in the
/// mockup), and AppKit's grey row highlight would sit behind them. The arrow keys move the selection.
struct MacRecordingList: View {
    let onRecord: () -> Void
    let onImport: ([URL]) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(MacSelection.self) private var selection
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @Query private var profiles: [VoiceProfile]

    @State private var searchText = ""
    @State private var pendingDelete: UUID?
    @State private var renaming: Renaming?
    @State private var folderEditor: FolderEditor?
    @State private var errorText: String?
    @State private var isDropTargeted = false
    @FocusState private var searchFocused: Bool

    /// Mac wording, sync-aware ("Delete from all your devices?" while sync is on).
    private var macCopy: DeviceCopy { DeviceCopy(platform: .mac, syncOn: env.copy.syncOn, cloudCopyKept: env.copy.cloudCopyKept) }
    /// The list holds keyboard focus after a click on a card, so ⌫ and the arrow keys act on the selection.
    @FocusState private var listFocused: Bool

    private struct Renaming: Identifiable { let id: UUID; var title: String }

    private var query: LibraryQuery {
        LibraryQuery(filter: selection.sidebar.libraryFilter ?? .all, searchText: searchText)
    }

    var body: some View {
        let visible = query.apply(to: recordings)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(count: visible.count)
                    searchField
                    if env.isLaunched, case .failed = env.models.status { ModelsCard() }
                    if recordings.isEmpty {
                        message("No recordings yet", DeviceCopy(platform: .mac).libraryEmptyHint, id: AX.Library.emptyState)
                    } else if visible.isEmpty {
                        message("No recordings match", noResultsText, id: AX.Library.noResults)
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { i, recording in
                            row(recording, index: i).id(recording.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in move(direction, in: visible, proxy: proxy) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Mac.recordingList)
        .screenBackground()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(DS.Colour.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter(Self.isAudio)
            guard !audio.isEmpty else { return false }
            onImport(audio)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onDeleteCommand {
            if let id = selection.recording, recordings.first(where: { $0.id == id })?.stage != .capturing {
                pendingDelete = id
            }
        }
        .confirmationDialog(macCopy.deleteRecordingTitle,
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let id = pendingDelete { delete(id) } }
                .accessibilityIdentifier(AX.Library.deleteConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(macCopy.deleteRecordingMessage)
        }
        .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: Binding(get: { renaming?.title ?? "" }, set: { renaming?.title = $0 }))
                .accessibilityIdentifier(AX.Transcript.Menu.renameField)
            Button("Save") { saveRename() }
                .accessibilityIdentifier(AX.Transcript.Menu.renameSave)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to show the date.")
        }
        .folderNameAlert(editor: $folderEditor) { editor in createFolder(editor) }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: recordings.map(\.id)) { _, ids in
            if let id = selection.recording, !ids.contains(id) { selection.recording = nil }
        }
        .onChange(of: selection.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: selection.sidebar) { _, _ in searchText = "" }
    }

    // MARK: Header

    private var title: String {
        switch selection.sidebar {
        case .all, .voices: "All Recordings"
        case .favourites: "Favourites"
        case .unnamed: "Unnamed"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(DS.Colour.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(count == 1 ? "1 recording" : "\(count) recordings")
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityHidden(true)
            TextField("Search transcripts and speakers", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel("Search recordings")
                .accessibilityIdentifier(AX.Mac.recordingSearch)
            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { searchText = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Colour.secondary)
                    .accessibilityIdentifier(AX.Mac.recordingSearchClear)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
    }

    private func message(_ title: String, _ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.Typo.headline).foregroundStyle(DS.Colour.ink)
            Text(text)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var noResultsText: String {
        if !query.normalisedSearch.isEmpty {
            return "Nothing found for “\(searchText.trimmingCharacters(in: .whitespaces))”."
        }
        if case .folder = selection.sidebar { return DeviceCopy(platform: .mac).emptyFolder(title) }
        return "Nothing here yet."
    }

    // MARK: Rows

    private func row(_ recording: Recording, index i: Int) -> some View {
        let isSelected = selection.recording == recording.id
        return RecordingCard(recording: recording, index: i,
                             suggestedName: { id in profiles.first { $0.id == id }?.name },
                             onOpen: { open(recording) },
                             onName: { first, rest in
                                 selection.recording = recording.id
                                 router.nameSpeaker(NameSpeakerContext(recordingID: recording.id, key: first, mode: .name,
                                                                       followUps: rest))
                             })
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Colour.accent, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .modifier(RecordingRowActions(
                recording: recording, folders: folders,
                onRename: { renaming = Renaming(id: recording.id, title: recording.title ?? "") },
                onNewFolder: { folderEditor = FolderEditor(folderID: nil, name: "") },
                onDelete: { pendingDelete = recording.id },
                onError: { errorText = LibraryErrors.message(for: $0) }))
    }

    // MARK: Actions

    /// Up and down arrows move the selection through the visible cards.
    private func move(_ direction: MoveCommandDirection, in visible: [Recording], proxy: ScrollViewProxy) {
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selection.recording }
        let next = current.map { Swift.min(Swift.max($0 + step, 0), visible.count - 1) } ?? 0
        selection.recording = visible[next].id
        proxy.scrollTo(visible[next].id)
    }

    private func open(_ recording: Recording) {
        if recording.stage == .capturing, env.recorder.recordingID == recording.id {
            router.presentRecording()
            return
        }
        selection.recording = recording.id
        listFocused = true
    }

    private func saveRename() {
        guard let renaming else { return }
        let title = renaming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.renaming = nil
        do { try env.store.rename(id: renaming.id, title: title.isEmpty ? nil : title) } catch {
            errorText = LibraryErrors.message(for: error)
        }
    }

    private func createFolder(_ editor: FolderEditor) {
        let name = editor.trimmedName
        guard !name.isEmpty else { return }
        do {
            let id = try env.store.createFolder(name: name)
            selection.sidebar = .folder(id)
        } catch {
            errorText = LibraryErrors.message(for: error)
        }
    }

    private func delete(_ id: UUID) {
        pendingDelete = nil
        let fileName = recordings.first { $0.id == id }?.audioFileName
        if let fileName, env.player.loadedURL == env.paths.audioURL(fileName: fileName) { env.player.stop() }
        if selection.recording == id { selection.recording = nil }
        Task {
            await env.coordinator.cancel(id)
            do { try env.store.delete(id: id) } catch { errorText = LibraryErrors.message(for: error) }
        }
    }

    private static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }
}
