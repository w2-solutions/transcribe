import Foundation
import Observation
import TranscribeCore
import TranscribeKit

/// What the Mac sidebar has selected.
enum SidebarItem: Hashable {
    case all, favourites, unnamed
    case folder(UUID)
    case voices

    /// The Library filter for a library item; nil for Voices.
    var libraryFilter: LibraryFilter? {
        switch self {
        case .all: .all
        case .favourites: .favourites
        case .unnamed: .unnamed
        case .folder(let id): .folder(id)
        case .voices: nil
        }
    }
}

/// The Mac main window's selection: sidebar item, then the recording or voice in the middle column.
/// The shared `Router` still drives the detail column's stack, sheets and the recording window.
@MainActor @Observable
final class MacSelection {
    var sidebar: SidebarItem = .all
    var recording: UUID?
    var voice: UUID?
    /// Bumped by Find (⌘F); the recording list then focuses its search field.
    var searchFocusRequest = 0
    /// Set by Import Audio… (⌘O); the main window shows the file importer and clears it. A flag, not a counter, so a
    /// main window that the command itself reopens still sees it when it appears.
    var importRequested = false
    /// Set by New Recording (⌘N); the main window starts recording as its toolbar button does (so a denied microphone
    /// shows its sheet) and clears it.
    var recordRequested = false
    /// Set by File → Record From (a source chosen there); the main window records with it, as `recordRequested` does,
    /// and clears it.
    var recordSourceRequest: CaptureSources?
}
