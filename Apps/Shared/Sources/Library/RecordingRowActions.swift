import SwiftUI
import TranscribeCore
import TranscribeKit

/// A recording row's context menu (Rename, Favourite, Move to folder, Delete), shared by the iPhone Library and
/// the Mac recording list. Favourite and Move are applied here; Rename, New folder and Delete hand back to the
/// screen, which owns those alerts and confirmations.
struct RecordingRowActions: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let recording: Recording
    let folders: [Folder]
    let onRename: () -> Void
    let onNewFolder: () -> Void
    let onDelete: () -> Void
    let onError: (Error) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            // A recording deleted (by sync) while its menu is open offers nothing: every action would fail.
            if !GoneModels.isGone(recording), recording.stage != .capturing {
                Button("Rename", systemImage: "pencil") { onRename() }
                Button(recording.isFavourite ? "Unfavourite" : "Favourite",
                       systemImage: recording.isFavourite ? "star.slash" : "star") {
                    setFavourite(!recording.isFavourite)
                }
                Menu("Move to folder", systemImage: "folder") {
                    Button {
                        move(to: nil)
                    } label: {
                        if recording.folder == nil { Label("No folder", systemImage: "checkmark") } else { Text("No folder") }
                    }
                    ForEach(folders) { folder in
                        Button {
                            move(to: folder.id)
                        } label: {
                            if recording.folder?.id == folder.id {
                                Label(folder.name, systemImage: "checkmark")
                            } else {
                                Text(folder.name)
                            }
                        }
                    }
                    Divider()
                    Button("New folder…", systemImage: "folder.badge.plus") { onNewFolder() }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
            }
        }
    }

    private func setFavourite(_ on: Bool) {
        do { try env.store.setFavourite(id: recording.id, on) } catch { onError(error) }
    }

    private func move(to folderID: UUID?) {
        do { try env.store.move(recordingID: recording.id, toFolder: folderID) } catch { onError(error) }
    }
}
