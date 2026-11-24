import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("LibraryQuery: filters, search and card text")
@MainActor
struct LibraryQueryTests {
    /// The `library` seed: A (auto-labelled, unseen), B (favourite), C (Speaker 2 unnamed), newest first.
    func librarySeed() throws -> (ModelContainer, [Recording], AppPaths) {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("libquery-\(UUID().uuidString)", isDirectory: true))
        try Seeds.apply(.library, context: container.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        let all = try container.mainContext.fetch(FetchDescriptor<Recording>())
        return (container, all, paths)
    }

    @Test func allIsNewestFirst() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        let result = LibraryQuery().apply(to: all.shuffled())
        #expect(result.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC])
    }

    @Test func favouritesKeepsOnlyFavourites() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        #expect(LibraryQuery(filter: .favourites).apply(to: all).map(\.id) == [Seeds.ID.recordingB])
    }

    @Test func unnamedKeepsRecordingsWithSpeakersNeedingAName() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        #expect(LibraryQuery(filter: .unnamed).apply(to: all).map(\.id) == [Seeds.ID.recordingC])
    }

    @Test func folderFilterMatchesTheFolderID() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let folder = Folder(name: "Project", createdAt: Seeds.Dates.a)
        container.mainContext.insert(folder)
        let b = try #require(all.first { $0.id == Seeds.ID.recordingB })
        b.folder = folder
        try container.mainContext.save()
        #expect(LibraryQuery(filter: .folder(folder.id)).apply(to: all).map(\.id) == [Seeds.ID.recordingB])
        #expect(LibraryQuery(filter: .folder(UUID())).apply(to: all).isEmpty)
        #expect(LibraryQuery.folderChipTitle(filter: .folder(folder.id), folders: [(folder.id, "Project")]) == "Project")
        #expect(LibraryQuery.folderChipTitle(filter: .all, folders: [(folder.id, "Project")]) == "Folders")
    }

    @Test(arguments: [
        ("Morning", [Seeds.ID.recordingC]),
        ("morning", [Seeds.ID.recordingC]),
        ("  MORNING  ", [Seeds.ID.recordingC]),
        ("karan", [Seeds.ID.recordingA, Seeds.ID.recordingB]),
        ("zebra", []),
        ("", [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC]),
    ])
    func searchIsCaseInsensitiveContains(_ term: String, _ expected: [UUID]) throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        #expect(LibraryQuery(searchText: term).apply(to: all).map(\.id) == expected)
    }

    @Test func searchAndFilterCombine() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        #expect(LibraryQuery(filter: .favourites, searchText: "karan").apply(to: all).map(\.id) == [Seeds.ID.recordingB])
        #expect(LibraryQuery(filter: .favourites, searchText: "morning").apply(to: all).isEmpty)
        #expect(LibraryQuery(filter: .favourites).isNarrowing)
        #expect(LibraryQuery(searchText: " x ").isNarrowing)
        #expect(!LibraryQuery(searchText: "   ").isNarrowing)
    }

    @Test func searchFindsANewTitleBeforeSearchTextIsRebuilt() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        let c = try #require(all.first { $0.id == Seeds.ID.recordingC })
        c.title = "Weekly sync"
        #expect(LibraryQuery(searchText: "weekly").apply(to: all).map(\.id) == [Seeds.ID.recordingC])
    }

    @Test func filterSlugsMatchTheAccessibilityCatalogue() {
        #expect([LibraryFilter.all, .favourites, .folder(UUID()), .unnamed].map(\.slug)
                == ["all", "favourites", "folders", "unnamed"])
    }

    // MARK: Card status and preview

    @Test func cardStatusForTheLibrarySeed() throws {
        let (container, all, paths) = try librarySeed()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        _ = container
        let statuses = LibraryQuery().apply(to: all).map {
            LibraryCardStatus.make(stage: $0.stage, queueReason: $0.queueReason, hasUnseenResult: $0.hasUnseenResult,
                                   duration: $0.duration, snapshot: nil)
        }
        #expect(statuses == [.recognised, .duration("0:24"), .duration("12:48")])
        #expect(statuses[0].text == "Voices recognised")
    }

    @Test func cardStatusWhileProcessing() {
        let separating = LibraryCardStatus.make(stage: .separating, queueReason: nil, hasUnseenResult: false,
                                                duration: 24, snapshot: nil)
        #expect(separating.text == "Separating speakers… 2/3")
        if case .processing(_, let fraction) = separating { #expect(abs(fraction - 0.45) < 1e-9) } else { Issue.record("not processing") }

        let waiting = LibraryCardStatus.make(stage: .queued, queueReason: .modelsNotReady, hasUnseenResult: false,
                                             duration: 24, snapshot: nil)
        #expect(waiting.text == "Waiting for speech models")

        let queued = LibraryCardStatus.make(stage: .queued, queueReason: nil, hasUnseenResult: false, duration: 24, snapshot: nil)
        #expect(queued.text == "Transcribing… 1/3")

        let matching = LibraryCardStatus.make(stage: .matching, queueReason: nil, hasUnseenResult: true, duration: 24, snapshot: nil)
        #expect(matching.text == "Matching saved voices… 3/3")
    }

    @Test func cardStatusEdgeStages() {
        #expect(LibraryCardStatus.make(stage: .capturing, queueReason: nil, hasUnseenResult: false, duration: 0, snapshot: nil) == .recording)
        #expect(LibraryCardStatus.make(stage: .failed, queueReason: nil, hasUnseenResult: true, duration: 24, snapshot: nil) == .failed)
        #expect(LibraryCardStatus.make(stage: .ready, queueReason: nil, hasUnseenResult: false, duration: 3725, snapshot: nil)
                == .duration("1:02:05"))
    }

    @Test func cardStatusUsesTheLiveSnapshot() {
        let id = UUID()
        let snapshot = ProcessingSnapshot(
            recordingID: id,
            steps: [StepStatus(step: .transcribing, state: .done, subtitle: "Parakeet, on device"),
                    StepStatus(step: .separating, state: .active(fraction: 0.5), subtitle: "Listening for different voices · 50%"),
                    StepStatus(step: .matching, state: .waiting, subtitle: "No saved voices yet")],
            overall: 0.675, voicesFound: nil, comparedWith: [], phase: .running)
        let status = LibraryCardStatus.make(stage: .transcribed, queueReason: nil, hasUnseenResult: false, duration: 24, snapshot: snapshot)
        #expect(status == .processing(text: "Separating speakers… 2/3", fraction: 0.675))
    }

    @Test func previewPlaceholders() {
        #expect(LibraryCardPreview.make(previewText: "Hey, Karan.", stage: .queued, noSpeech: false)
                == LibraryCardPreview(text: "Hey, Karan.", isPlaceholder: false))
        #expect(LibraryCardPreview.make(previewText: "", stage: .transcribing, noSpeech: false)
                == LibraryCardPreview(text: "Transcribing…", isPlaceholder: true))
        #expect(LibraryCardPreview.make(previewText: " ", stage: .ready, noSpeech: true).text == "No speech found")
        #expect(LibraryCardPreview.make(previewText: "", stage: .capturing, noSpeech: false, platform: .iPhone).text
                == "Tap to go back to the recording.")
        #expect(LibraryCardPreview.make(previewText: "", stage: .capturing, noSpeech: false, platform: .mac).text
                == "Click to go back to the recording.")
        #expect(LibraryCardPreview.make(previewText: "", stage: .failed, noSpeech: false).isPlaceholder)
    }
}
