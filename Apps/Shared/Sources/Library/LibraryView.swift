import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit
import UniformTypeIdentifiers

/// Screen 1 (§6.1): the recordings list with filter chips and search, the models card, and the floating dock
/// (import, record, voices) with the minimised-recording pill above it.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @Query private var profiles: [VoiceProfile]

    @State private var query = LibraryQuery()
    @State private var isSearchPresented = false
    @State private var isShowingFolders = false
    @State private var isShowingMicDenied = false
    @State private var importAfterMicSheet = false
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var isStarting = false
    @State private var pendingDelete: PendingDelete?
    @State private var renaming: Renaming?
    @State private var folderEditor: FolderEditor?
    @State private var alert: LibraryAlert?

    private struct PendingDelete: Identifiable { let id: UUID }
    private struct Renaming: Identifiable { let id: UUID; var title: String }
    private struct LibraryAlert: Identifiable { let id = UUID(); let title: String; let message: String }

    private var visible: [Recording] { query.apply(to: recordings) }

    var body: some View {
        let visible = self.visible
        List {
            if env.isLaunched, showsModelsCard {
                ModelsCard().libraryRow()
            }
            if !recordings.isEmpty {
                filterRow.libraryRow(top: 0, bottom: 7, horizontal: 0)
            }
            if recordings.isEmpty {
                emptyState.libraryRow()
            } else if visible.isEmpty {
                noResults.libraryRow()
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, recording in
                card(recording, index: i)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .animation(.snappy, value: visible.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.screen)
        .navigationTitle("Recordings")
        .largeNavigationTitle()
        .toolbar { toolbar }
        .modifier(LibrarySearch(isActive: isSearchPresented, text: $query.searchText, isPresented: $isSearchPresented))
        .safeAreaBar(edge: .bottom) { bottomBar }
        .screenBackground()
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await runImport(from: url) } }
            case .failure(let error): alert = LibraryAlert(title: "Couldn't import", message: LibraryErrors.message(for: error))
            }
        }
        .sheet(isPresented: $isShowingMicDenied, onDismiss: {
            if importAfterMicSheet { importAfterMicSheet = false; isImporterPresented = true }
        }) {
            MicDeniedSheet { importAfterMicSheet = true }
        }
        .sheet(isPresented: $isShowingFolders) { FoldersSheet() }
        .alert("Rename recording",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: Binding(get: { renaming?.title ?? "" }, set: { renaming?.title = $0 }))
                .inputCapitalization(.sentences)
                .accessibilityIdentifier(AX.Transcript.Menu.renameField)
            Button("Save") { saveRename() }
                .accessibilityIdentifier(AX.Transcript.Menu.renameSave)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to show the date.")
        }
        .folderNameAlert(editor: $folderEditor) { editor in createFolder(editor) }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: folders.map(\.id)) { _, ids in
            if case .folder(let id) = query.filter, !ids.contains(id) { query.filter = .all }
        }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented { query.searchText = "" }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .trailingBar) {
            Button("Search recordings", systemImage: "magnifyingglass") { isSearchPresented.toggle() }
                .tint(DS.Colour.ink)
                .accessibilityIdentifier(AX.Library.searchButton)
        }
        ToolbarItem(placement: .trailingBar) {
            Button("Settings", systemImage: "slider.horizontal.3") { router.path.append(.settings) }
                .tint(DS.Colour.ink)
                .accessibilityIdentifier(AX.Library.settingsButton)
        }
    }

    // MARK: Filter chips

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: query.filter == .all) { query.filter = .all }
                    .accessibilityIdentifier(AX.Library.filter("all"))
                FilterChip(title: "Favourites", isSelected: query.filter == .favourites) { toggle(.favourites) }
                    .accessibilityIdentifier(AX.Library.filter("favourites"))
                foldersChip
                FilterChip(title: "Unnamed", isSelected: query.filter == .unnamed, dotColor: DS.Colour.unnamed) {
                    toggle(.unnamed)
                }
                .accessibilityIdentifier(AX.Library.filter("unnamed"))
            }
            .padding(.horizontal, DS.Space.screenInset + 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var foldersChip: some View {
        let isSelected: Bool = { if case .folder = query.filter { true } else { false } }()
        let title = LibraryQuery.folderChipTitle(filter: query.filter, folders: folders.map { ($0.id, $0.name) })
        return Menu {
            if !folders.isEmpty {
                Section {
                    ForEach(folders) { folder in
                        Button {
                            query.filter = query.filter == .folder(folder.id) ? .all : .folder(folder.id)
                        } label: {
                            if query.filter == .folder(folder.id) {
                                Label(folder.name, systemImage: "checkmark")
                            } else {
                                Text(folder.name)
                            }
                        }
                    }
                }
            }
            Section {
                Button("New folder…", systemImage: "folder.badge.plus") { folderEditor = FolderEditor(folderID: nil, name: "") }
                Button("Manage folders…", systemImage: "folder") { isShowingFolders = true }
            }
        } label: {
            FolderChipLabel(title: title, isSelected: isSelected)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Folder, \(title)" : "Folders")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AX.Library.filter("folders"))
    }

    private func toggle(_ filter: LibraryFilter) {
        query.filter = query.filter == filter ? .all : filter
    }

    // MARK: Rows

    private func card(_ recording: Recording, index i: Int) -> some View {
        RecordingCard(recording: recording, index: i,
                      suggestedName: { id in profiles.first { $0.id == id }?.name },
                      onOpen: { open(recording) },
                      onName: { first, rest in
                          router.nameSpeaker(NameSpeakerContext(recordingID: recording.id, key: first, mode: .name,
                                                                followUps: rest))
                      })
            .libraryRow()
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    setFavourite(recording, !recording.isFavourite)
                } label: {
                    Label(recording.isFavourite ? "Unfavourite" : "Favourite",
                          systemImage: recording.isFavourite ? "star.slash" : "star")
                }
                .tint(Color(hex: 0xE8A317))
                .accessibilityIdentifier(AX.Library.cardFavourite(i))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if recording.stage != .capturing {
                    Button(role: .destructive) {
                        pendingDelete = PendingDelete(id: recording.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier(AX.Library.cardDelete(i))
                }
            }
            .modifier(RecordingRowActions(
                recording: recording, folders: folders,
                onRename: { renaming = Renaming(id: recording.id, title: recording.title ?? "") },
                onNewFolder: { folderEditor = FolderEditor(folderID: nil, name: "") },
                onDelete: { pendingDelete = PendingDelete(id: recording.id) },
                onError: show))
            // On the row, so the iOS 27 popover points at the card being deleted (not the top of the list).
            .confirmationDialog("Delete recording?",
                                isPresented: Binding(get: { pendingDelete?.id == recording.id },
                                                     set: { if !$0, pendingDelete?.id == recording.id { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete(recording.id) }
                    .accessibilityIdentifier(AX.Library.deleteConfirm)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(DeviceCopy().deleteRecordingMessage)
            }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No recordings yet")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Colour.ink)
            Text(DeviceCopy().libraryEmptyHint)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Library.emptyState)
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No recordings match")
                .font(DS.Typo.headline)
                .foregroundStyle(DS.Colour.ink)
            Text(noResultsMessage)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AX.Library.noResults)
    }

    private var noResultsMessage: String {
        if !query.normalisedSearch.isEmpty {
            return "Nothing found for “\(query.searchText.trimmingCharacters(in: .whitespaces))”."
        }
        if case .folder = query.filter {
            let name = LibraryQuery.folderChipTitle(filter: query.filter, folders: folders.map { ($0.id, $0.name) })
            return DeviceCopy().emptyFolder(name)
        }
        return "Try another filter."
    }

    // MARK: Bottom bar

    private var showsPill: Bool { env.recorder.isActive && !router.isRecordingPresented }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if showsPill {
                RecordingPill()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Importing audio…").font(.subheadline.weight(.semibold)).foregroundStyle(DS.Colour.ink)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .floatingGlass(Capsule())
                .accessibilityElement(children: .combine)
            }
            if !isSearchPresented {
            ControlDock {
                GlassCircleButton(systemImage: "square.and.arrow.down", size: .large, accessibilityLabel: "Import audio file") {
                    isImporterPresented = true
                }
                .disabled(isImporting)
                .accessibilityIdentifier(AX.Library.importButton)
                RecordButton(mode: .record, accessibilityLabel: "Start recording") { record() }
                    .accessibilityIdentifier(AX.Library.recordButton)
                GlassCircleButton(systemImage: "person.2", size: .large, accessibilityLabel: "Voices") {
                    router.path.append(.voices)
                }
                .accessibilityIdentifier(AX.Library.voicesButton)
            }
            }
        }
        .animation(.snappy, value: showsPill)
        .padding(.bottom, -6)
    }

    // MARK: State

    private var showsModelsCard: Bool {
        if case .failed = env.models.status { true } else { false }
    }

    // MARK: Actions

    private func open(_ recording: Recording) {
        if recording.stage == .capturing {
            if env.recorder.recordingID == recording.id { router.isRecordingPresented = true }
            return
        }
        router.showTranscript(recording.id)
    }

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
                alert = LibraryAlert(title: "Can't record", message: LibraryErrors.message(for: error))
            }
        }
    }

    private func runImport(from source: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let id = try await importAudio(from: source, env: env)
            router.showTranscript(id)
        } catch {
            alert = LibraryAlert(title: "Couldn't import", message: LibraryErrors.message(for: error))
        }
    }

    private func setFavourite(_ recording: Recording, _ on: Bool) {
        do { try env.store.setFavourite(id: recording.id, on) } catch { show(error) }
    }

    private func saveRename() {
        guard let renaming else { return }
        let title = renaming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.renaming = nil
        do { try env.store.rename(id: renaming.id, title: title.isEmpty ? nil : title) } catch { show(error) }
    }

    private func createFolder(_ editor: FolderEditor) {
        let name = editor.trimmedName
        guard !name.isEmpty else { return }
        do {
            let id = try env.store.createFolder(name: name)
            query.filter = .folder(id)
        } catch {
            show(error)
        }
    }

    private func delete(_ id: UUID) {
        pendingDelete = nil
        let fileName = recordings.first { $0.id == id }?.audioFileName
        if let fileName, env.player.loadedURL == env.paths.audioURL(fileName: fileName) { env.player.stop() }
        Task {
            await env.coordinator.cancel(id)
            do { try env.store.delete(id: id) } catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        alert = LibraryAlert(title: "Something went wrong", message: LibraryErrors.message(for: error))
    }
}

// MARK: - Helpers

/// The Folders chip: looks like `FilterChip` but is a `Menu` label (folders, "New folder…", "Manage folders…").
private struct FolderChipLabel: View {
    let title: String
    let isSelected: Bool

    private static let onInk = Color.adaptive(light: .white, dark: Color(hex: 0x0E1116))

    var body: some View {
        Text(title)
            .scaledFont(size: 14, weight: isSelected ? .semibold : .medium, relativeTo: .subheadline)
            .foregroundStyle(isSelected ? Self.onInk : DS.Colour.ink)
            .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .background {
            if isSelected {
                Capsule(style: .continuous).fill(DS.Colour.ink)
            } else {
                Capsule(style: .continuous).fill(DS.Colour.chipFill)
                    .overlay { Capsule(style: .continuous).strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
            }
        }
        .contentShape(Capsule())
    }
}

/// `.searchable` only while the toolbar's search button has it open, so the bar stays hidden like the mockup.
private struct LibrarySearch: ViewModifier {
    let isActive: Bool
    @Binding var text: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, isPresented: $isPresented,
                               placement: .librarySearch, prompt: "Search recordings")
        } else {
            content
        }
    }
}

private extension View {
    /// A clear, separator-less List row with the Library's insets (7 pt top/bottom → 14 pt between cards).
    func libraryRow(top: CGFloat = 7, bottom: CGFloat = 7, horizontal: CGFloat = DS.Space.screenInset) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
