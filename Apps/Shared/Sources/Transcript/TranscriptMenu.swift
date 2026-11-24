import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

/// The More (•••) menu of a ready transcript (§6.4).
struct TranscriptMoreMenu: View {
    let isFavourite: Bool
    let folderID: UUID?
    let folders: [Folder]
    let shareText: () -> String
    /// Nil when the audio is on another device: no "Share audio".
    let audioURL: URL?
    let shareTitle: String
    let onRename: () -> Void
    let onToggleFavourite: () -> Void
    let onMove: (UUID?) -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button("Rename…", systemImage: "pencil", action: onRename)
                .accessibilityIdentifier(AX.Transcript.Menu.rename)
            Button(isFavourite ? "Remove from favourites" : "Favourite",
                   systemImage: isFavourite ? "star.slash" : "star", action: onToggleFavourite)
                .accessibilityIdentifier(AX.Transcript.Menu.favourite)
            Menu {
                folderButton(nil, title: "None")
                ForEach(folders) { folder in folderButton(folder.id, title: folder.name) }
            } label: {
                Label("Move to folder", systemImage: "folder")
            }
            .accessibilityIdentifier(AX.Transcript.Menu.moveToFolder)
            Divider()
            ShareLink(item: shareText(), subject: Text(shareTitle), preview: SharePreview(shareTitle)) {
                Label("Share transcript", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(AX.Transcript.Menu.shareText)
            if let audioURL {
                ShareLink(item: audioURL, preview: SharePreview(shareTitle)) {
                    Label("Share audio", systemImage: "waveform")
                }
                .accessibilityIdentifier(AX.Transcript.Menu.shareAudio)
            }
            Divider()
            Button("Delete recording", systemImage: "trash", role: .destructive, action: onDelete)
                .accessibilityIdentifier(AX.Transcript.Menu.delete)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier(AX.Transcript.moreButton)
    }

    private func folderButton(_ id: UUID?, title: String) -> some View {
        Button {
            onMove(id)
        } label: {
            if folderID == id { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Search field shown under the navigation bar (§6.4 "Search"): "n of m" with previous / next.
struct TranscriptSearchBar: View {
    @Binding var query: String
    let countText: String
    let canStep: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colour.secondary)
                .accessibilityHidden(true)
            TextField("Search transcript", text: $query)
                .font(DS.Typo.subheadline)
                .foregroundStyle(DS.Colour.ink)
                .autocorrectionDisabled()
                .inputCapitalization(.never)
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { if canStep { onNext() } }
                .accessibilityIdentifier(AX.Transcript.searchField)
            if !query.isEmpty {
                Text(countText)
                    .font(DS.Typo.meta.monospacedDigit())
                    .foregroundStyle(DS.Colour.secondary)
                    .fixedSize()
                    .accessibilityIdentifier(AX.Transcript.searchCount)
            }
            stepButton("chevron.up", label: "Previous match", id: AX.Transcript.searchPrevious, action: onPrevious)
            stepButton("chevron.down", label: "Next match", id: AX.Transcript.searchNext, action: onNext)
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .frame(height: 44)
        .background {
            Capsule(style: .continuous).fill(DS.Colour.fieldFill)
                .overlay { Capsule(style: .continuous).strokeBorder(DS.Colour.chipStroke, lineWidth: 1) }
                .shadow(color: DS.Colour.shadow.opacity(0.07), radius: 12, x: 0, y: 6)
        }
        .padding(.horizontal, DS.Space.screenInset)
        .padding(.bottom, 6)
        .onAppear { focused = true }
    }

    private func stepButton(_ systemImage: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(canStep ? DS.Colour.ink : DS.Colour.tertiary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canStep)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
