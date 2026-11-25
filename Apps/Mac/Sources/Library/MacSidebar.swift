import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The Mac sidebar (§5): Library (All Recordings, Favourites, Unnamed, Folders) and People (Voices, with a dashed
/// badge counting voices waiting for a name), then the privacy footer and a glass New Recording pill.
struct MacSidebar: View {
    let onRecord: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(MacSelection.self) private var selection
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Folder.createdAt) private var folders: [Folder]
    @Query private var profiles: [VoiceProfile]
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]

    @State private var foldersExpanded = true
    @State private var folderEditor: FolderEditor?
    @State private var pendingFolderDelete: Folder?
    @State private var errorText: String?

    var body: some View {
        @Bindable var selection = selection
        let waiting = VoicesListModel(profiles: profiles, recordings: recordings, platform: .mac).waiting.count
        List(selection: Binding(get: { Optional(selection.sidebar) }, set: { if let item = $0 { selection.sidebar = item } })) {
            Text("Transcribe")
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(DS.Colour.ink)
                .selectionDisabled()
                .accessibilityAddTraits(.isHeader)
            Section("Library") {
                Label("All Recordings", systemImage: "waveform")
                    .tag(SidebarItem.all)
                    .accessibilityIdentifier(AX.Mac.sidebarAll)
                Label("Favourites", systemImage: "star")
                    .tag(SidebarItem.favourites)
                    .accessibilityIdentifier(AX.Mac.sidebarFavourites)
                Label("Unnamed", systemImage: "person.crop.circle.dashed")
                    .tag(SidebarItem.unnamed)
                    .accessibilityIdentifier(AX.Mac.sidebarUnnamed)
                DisclosureGroup(isExpanded: $foldersExpanded) {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { i, folder in
                        Label(folder.name, systemImage: "folder")
                            .tag(SidebarItem.folder(folder.id))
                            .contextMenu {
                                Button("Rename…") { folderEditor = FolderEditor(folderID: folder.id, name: folder.name) }
                                    .accessibilityIdentifier(AX.Mac.sidebarFolderRename(i))
                                Button("Delete", role: .destructive) { pendingFolderDelete = folder }
                                    .accessibilityIdentifier(AX.Mac.sidebarFolderDelete(i))
                            }
                            .accessibilityIdentifier(AX.Mac.sidebarFolder(i))
                    }
                } label: {
                    Label("Folders", systemImage: "folder")
                        .contextMenu {
                            Button("New Folder…") { folderEditor = FolderEditor(folderID: nil, name: "") }
                                .accessibilityIdentifier(AX.Mac.sidebarNewFolder)
                        }
                        .accessibilityIdentifier(AX.Mac.sidebarFolders)
                }
            }
            Section("People") {
                HStack {
                    Label("Voices", systemImage: "person.2")
                    Spacer(minLength: 4)
                    if waiting > 0 { WaitingBadge(count: waiting) }
                }
                .tag(SidebarItem.voices)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AX.Mac.sidebarVoices)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .folderNameAlert(editor: $folderEditor) { editor in saveFolder(editor) }
        .confirmationDialog("Delete folder?",
                            isPresented: Binding(get: { pendingFolderDelete != nil }, set: { if !$0 { pendingFolderDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingFolderDelete) { folder in
            Button("Delete", role: .destructive) { deleteFolder(folder) }
                .accessibilityIdentifier(AX.Mac.folderDeleteConfirm)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(AX.Mac.folderDeleteCancel)
        } message: { _ in
            Text("Recordings in the folder are kept.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: folders.map(\.id)) { _, ids in
            if case .folder(let id) = selection.sidebar, !ids.contains(id) { selection.sidebar = .all }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            syncFooter
            Button(action: onRecord) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(DS.Colour.record)
                        .frame(width: 14, height: 14)
                        .shadow(color: DS.Colour.record.opacity(0.45), radius: 4, y: 2)
                    Text(env.recorder.isActive ? "Show Recording" : "New Recording")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Colour.ink)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier(AX.Mac.sidebarNewRecording)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 8)
    }

    /// The privacy line, or the iCloud status while sync is on (§8.6). Clicking it opens Settings.
    private var syncFooter: some View {
        let status = env.sync.map { env.settings.syncEnabled ? $0.status : .off } ?? .off
        let copy = env.copy
        let text = SyncCopy.footer(status, copy: DeviceCopy(platform: .mac, syncOn: copy.syncOn, cloudCopyKept: copy.cloudCopyKept,
                                                            claudeOn: copy.claudeOn))
        let symbol = status == .off ? "lock" : SyncSettingsSection.symbol(status)
        return Button { openSettings() } label: {
            Label(text, systemImage: symbol)
                .font(DS.Typo.caption)
                .foregroundStyle(status.isPaused ? DS.Colour.unnamedText : DS.Colour.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .help("iCloud sync settings")
        .accessibilityLabel(text)
        .accessibilityValue(text)
        .accessibilityHint("Opens Settings")
        .accessibilityIdentifier(AX.Mac.sidebarFooter)
    }

    private func saveFolder(_ editor: FolderEditor) {
        let name = editor.trimmedName
        guard !name.isEmpty else { return }
        do {
            if let id = editor.folderID {
                try env.store.renameFolder(id: id, name: name)
            } else {
                let id = try env.store.createFolder(name: name)
                selection.sidebar = .folder(id)
            }
        } catch {
            errorText = LibraryErrors.message(for: error)
        }
    }

    private func deleteFolder(_ folder: Folder) {
        do { try env.store.deleteFolder(id: folder.id) } catch { errorText = LibraryErrors.message(for: error) }
    }
}

/// The dashed amber badge on Voices: how many voices are waiting for a name.
private struct WaitingBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(DS.Colour.unnamedText)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 18)
            .overlay {
                Capsule().strokeBorder(DS.Colour.unnamed, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .accessibilityLabel("\(count) waiting for a name")
            .accessibilityIdentifier(AX.Mac.sidebarVoicesBadge)
    }
}
