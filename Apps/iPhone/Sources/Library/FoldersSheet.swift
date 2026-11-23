import SwiftData
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// "Manage folders…" (§6.1): flat folders with swipe to rename or delete, a "New folder" alert and Done.
struct FoldersSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt) private var folders: [Folder]

    @State private var editor: FolderEditor?
    @State private var pendingDelete: Folder?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if folders.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No folders yet").font(DS.Typo.headline).foregroundStyle(DS.Colour.ink)
                        Text("Folders keep related recordings together. Move a recording into one from its menu.")
                            .font(DS.Typo.subheadline).foregroundStyle(DS.Colour.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                } else {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { i, folder in
                        FolderRow(name: folder.name, count: folder.recordings.count)
                            .accessibilityIdentifier(AX.Library.Folders.folder(i))
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
                                Button("Rename", systemImage: "pencil") {
                                    editor = FolderEditor(folderID: folder.id, name: folder.name)
                                }
                                .tint(DS.Colour.accent)
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    editor = FolderEditor(folderID: folder.id, name: folder.name)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New folder", systemImage: "folder.badge.plus") { editor = FolderEditor(folderID: nil, name: "") }
                        .tint(DS.Colour.ink)
                        .accessibilityIdentifier(AX.Library.Folders.newFolderButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AX.Library.Folders.doneButton)
                }
            }
            .folderNameAlert(editor: $editor) { editor in save(editor) }
            .confirmationDialog("Delete folder?", isPresented: Binding(get: { pendingDelete != nil },
                                                                       set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { folder in
                Button("Delete \(folder.name)", role: .destructive) { delete(folder) }
            } message: { _ in
                Text("Its recordings stay in your library.")
            }
            .alert("Couldn't update folders", isPresented: Binding(get: { errorMessage != nil },
                                                                   set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Library.Folders.sheet)
    }

    private func save(_ editor: FolderEditor) {
        let name = editor.trimmedName
        guard !name.isEmpty else { return }
        do {
            if let id = editor.folderID {
                try env.store.renameFolder(id: id, name: name)
            } else {
                _ = try env.store.createFolder(name: name)
            }
        } catch {
            errorMessage = LibraryErrors.message(for: error)
        }
    }

    private func delete(_ folder: Folder) {
        do { try env.store.deleteFolder(id: folder.id) } catch { errorMessage = LibraryErrors.message(for: error) }
    }
}

private struct FolderRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "folder", tint: .neutral)
            Text(name).font(DS.Typo.rowTitle).foregroundStyle(DS.Colour.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text(count == 1 ? "1 recording" : "\(count) recordings")
                .font(DS.Typo.meta)
                .foregroundStyle(DS.Colour.secondary)
        }
        .frame(minHeight: DS.Size.settingsRow)
        .accessibilityElement(children: .combine)
    }
}

/// A new folder (`folderID == nil`) or a rename in progress.
struct FolderEditor: Identifiable, Equatable {
    let id = UUID()
    var folderID: UUID?
    var name: String
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var title: String { folderID == nil ? "New folder" : "Rename folder" }
}

extension View {
    /// The "New folder" / "Rename folder" alert with its name field (`folders.nameField`).
    func folderNameAlert(editor: Binding<FolderEditor?>, onSave: @escaping (FolderEditor) -> Void) -> some View {
        modifier(FolderNameAlert(editor: editor, onSave: onSave))
    }
}

private struct FolderNameAlert: ViewModifier {
    @Binding var editor: FolderEditor?
    let onSave: (FolderEditor) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(editor?.title ?? "New folder",
                   isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier(AX.Library.Folders.nameField)
                Button("Save") {
                    if var current = editor {
                        current.name = name
                        onSave(current)
                    }
                    editor = nil
                }
                Button("Cancel", role: .cancel) { editor = nil }
            }
            .onChange(of: editor?.id) { _, _ in name = editor?.name ?? "" }
    }
}

/// User-facing wording for store and import errors shown in Library alerts.
enum LibraryErrors {
    static func message(for error: Error) -> String {
        switch error {
        case StoreError.notFound: return "That item no longer exists."
        case StoreError.invalidName: return "Enter a name."
        case StoreError.invariant(let text): return text
        case StoreError.notImplemented: return "This isn't available yet."
        case AudioImportError.unreadable: return "This file can't be read as audio."
        case AudioImportError.tooLong(let duration):
            return "Files up to 3 hours can be imported. This one is \(DisplayFormat.duration(duration))."
        case AudioImportError.failed(let text): return text
        case EngineError.microphoneDenied: return "Microphone access is off."
        case EngineError.failed(let text): return text
        default: return error.localizedDescription
        }
    }
}
