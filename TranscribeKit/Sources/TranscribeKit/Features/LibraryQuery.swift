import Foundation
import TranscribeCore

/// The Library filter chips (§6.1).
public enum LibraryFilter: Hashable, Sendable {
    case all
    case favourites
    case folder(UUID)
    case unnamed

    /// The accessibility slug used by `AX.Library.filter(_:)`: all | favourites | folders | unnamed.
    public var slug: String {
        switch self {
        case .all: "all"
        case .favourites: "favourites"
        case .folder: "folders"
        case .unnamed: "unnamed"
        }
    }
}

/// Filter and search over the Library's recordings (§6.1). Pure: it only reads the models it is given.
public struct LibraryQuery: Equatable, Sendable {
    public var filter: LibraryFilter
    public var searchText: String

    public init(filter: LibraryFilter = .all, searchText: String = "") {
        self.filter = filter
        self.searchText = searchText
    }

    /// The trimmed, lower-cased search term; empty means "no search".
    public var normalisedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when a filter or a search term narrows the list (used to choose "No recordings match").
    public var isNarrowing: Bool { filter != .all || !normalisedSearch.isEmpty }

    /// Newest first; filtered by the chip, then by a case-insensitive `contains` on `searchText`.
    @MainActor
    public func apply(to recordings: [Recording]) -> [Recording] {
        recordings
            .filter(matches)
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    @MainActor
    public func matches(_ recording: Recording) -> Bool {
        switch filter {
        case .all: break
        case .favourites: guard recording.isFavourite else { return false }
        case .folder(let id): guard recording.folder?.id == id else { return false }
        case .unnamed: guard !recording.speakersNeedingName.isEmpty else { return false }
        }
        let term = normalisedSearch
        guard !term.isEmpty else { return true }
        // searchText is stored lower-cased; the title is checked too so a fresh rename is always found.
        if recording.searchText.contains(term) { return true }
        return recording.displayTitle.lowercased().contains(term)
    }

    /// The Folders chip title: the selected folder's name, else "Folders".
    public static func folderChipTitle(filter: LibraryFilter, folders: [(id: UUID, name: String)]) -> String {
        if case .folder(let id) = filter, let folder = folders.first(where: { $0.id == id }) { return folder.name }
        return "Folders"
    }
}

/// What the right-hand side of a Library card's first row shows (§6.1, `RecordingCard` row 1).
public enum LibraryCardStatus: Equatable, Sendable {
    /// "✓ Voices recognised" (accent pill).
    case recognised
    /// The recording is still being captured.
    case recording
    /// "<activeTitle>… <n>/<total>" or "Waiting for speech models" (progress pill).
    case processing(text: String, fraction: Double)
    /// "Couldn't process" (failed pill).
    case failed
    /// The duration in mono ("0:20").
    case duration(String)

    public static let recognisedText = "Voices recognised"
    public static let recordingText = "Recording"
    public static let failedText = "Couldn't process"

    public static func make(stage: RecordingStage, queueReason: QueueReason?, hasUnseenResult: Bool,
                            duration: TimeInterval, snapshot: ProcessingSnapshot?) -> LibraryCardStatus {
        if stage == .capturing { return .recording }
        if stage == .failed { return .failed }
        if stage.isProcessing {
            let state = ProcessingViewState(stage: stage, queueReason: queueReason, snapshot: snapshot)
            return .processing(text: state.cardText, fraction: state.overall)
        }
        if hasUnseenResult { return .recognised }
        return .duration(DisplayFormat.duration(duration))
    }

    /// The text a test or VoiceOver reads.
    public var text: String {
        switch self {
        case .recognised: Self.recognisedText
        case .recording: Self.recordingText
        case .processing(let text, _): text
        case .failed: Self.failedText
        case .duration(let d): d
        }
    }
}

/// Row 3 of a Library card: the preview line and whether it is a secondary-coloured placeholder.
public struct LibraryCardPreview: Equatable, Sendable {
    public var text: String
    public var isPlaceholder: Bool

    public init(text: String, isPlaceholder: Bool) {
        self.text = text
        self.isPlaceholder = isPlaceholder
    }

    public static func make(previewText: String, stage: RecordingStage, noSpeech: Bool) -> LibraryCardPreview {
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return LibraryCardPreview(text: trimmed, isPlaceholder: false) }
        switch stage {
        case .capturing: return LibraryCardPreview(text: "Tap to go back to the recording.", isPlaceholder: true)
        case .failed: return LibraryCardPreview(text: "Couldn't finish processing this recording.", isPlaceholder: true)
        case .ready: return LibraryCardPreview(text: noSpeech ? "No speech found" : "No transcript", isPlaceholder: true)
        default: return LibraryCardPreview(text: "Transcribing…", isPlaceholder: true)
        }
    }
}
