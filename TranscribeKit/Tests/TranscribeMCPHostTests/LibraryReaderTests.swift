import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit
import TranscribeMCP
@testable import TranscribeMCPHost

@Suite("MCP: library reader")
@MainActor
struct LibraryReaderTests {
    let container: ModelContainer
    let paths: AppPaths
    let reader: LibraryReader

    init() throws {
        container = try ModelContainerFactory.make(inMemory: true, url: nil)
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-reader-\(UUID().uuidString)", isDirectory: true))
        reader = LibraryReader(container: container)
    }

    func seed(_ name: SeedName) throws {
        try Seeds.apply(name, context: container.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
    }

    func all(_ q: MCPRecordingQuery = MCPRecordingQuery()) async throws -> MCPRecordingPage {
        try await reader.recordings(q)
    }

    // MARK: D12: run these first

    /// The reader's own context sees what the main context saved, including saves made after the reader's first
    /// fetch (changed values and deletes, not only new rows).
    @Test func readerSeesMainContextSaves() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        #expect(try await all().total == 0)
        try seed(.library)
        #expect(try await all().items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC])
        #expect(try await reader.transcript(id: Seeds.ID.recordingB)?.summary.title != "Renamed")

        let context = container.mainContext
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let b = try #require(recordings.first { $0.id == Seeds.ID.recordingB })
        b.title = "Renamed"
        let karan = try #require(try context.fetch(FetchDescriptor<VoiceProfile>()).first { $0.name == "Karan" })
        karan.name = "Karan S"
        context.delete(try #require(recordings.first { $0.id == Seeds.ID.recordingC }))
        try context.save()

        let page = try await all()
        #expect(page.items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB])
        #expect(page.items[1].title == "Renamed")
        #expect(page.items[1].speakers.map(\.name) == ["Liam", "Karan S"])
        #expect(try await reader.transcript(id: Seeds.ID.recordingB)?.summary.title == "Renamed")
        #expect(try await reader.transcript(id: Seeds.ID.recordingC) == nil)
    }

    /// The same on an on-disk store, as the app opens it: a reader that fetched an empty library before the seed (the
    /// server starts in `App.init`, before `onLaunch` seeds) sees the seeded and saved recordings afterwards.
    @Test func readerSeesMainContextSavesOnDisk() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let disk = try ModelContainerFactory.make(inMemory: false, url: paths.storeURL)
        let reader = LibraryReader(container: disk)
        #expect(try await reader.recordings(MCPRecordingQuery()).total == 0)
        try Seeds.apply(.library, context: disk.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        #expect(try await reader.recordings(MCPRecordingQuery()).items.map(\.id)
                == [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC])
        // A reader made after the save sees them too.
        #expect(try await LibraryReader(container: disk).recordings(MCPRecordingQuery()).total == 3)
    }

    /// The reader's kept context follows rows that are deleted and then created again with the same ids (a re-seed,
    /// or a recording deleted and synced back), in memory and on disk.
    @Test(arguments: [false, true])
    func readerSeesRowsRecreatedWithTheSameIDs(onDisk: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let store = onDisk ? try ModelContainerFactory.make(inMemory: false, url: paths.storeURL) : container
        let reader = LibraryReader(container: store)
        try Seeds.apply(.library, context: store.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        #expect(try await reader.recordings(MCPRecordingQuery()).total == 3)
        try Seeds.wipe(store.mainContext)
        #expect(try await reader.recordings(MCPRecordingQuery()).total == 0)
        try Seeds.apply(.library, context: store.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        #expect(try await reader.recordings(MCPRecordingQuery()).total == 3)
        #expect(try await reader.transcript(id: Seeds.ID.recordingA)?.summary.id == Seeds.ID.recordingA)
    }

    @Test func fetchRunsOffMainThread() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        #expect(pthread_main_np() != 0)   // the caller is on the main thread
        _ = try await all()
        #expect(await reader._isOnMainThread() == false)
        #expect(await reader.contextMadeOnMainThread == false)
    }

    // MARK: Listing

    @Test func libraryListsThreeReadyNewestFirst() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        let page = try await all()
        #expect(page.total == 3)
        #expect(page.items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB, Seeds.ID.recordingC])
        #expect(page.items.map(\.duration) == [20, 24, 768])
        #expect(page.items[0].createdAt == Seeds.Dates.a)
        let second = try await all(MCPRecordingQuery(offset: 1, limit: 1))
        #expect(second.total == 3 && second.items.map(\.id) == [Seeds.ID.recordingB])
        #expect(try await all(MCPRecordingQuery(offset: 5)).items.isEmpty)
    }

    @Test(arguments: [SeedName.processingHeld, .failedProcessing])
    func processingAndFailedExcluded(_ name: SeedName) async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(name)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 1)
        let page = try await all()
        #expect(page.total == 0 && page.items.isEmpty)
    }

    @Test func askKaranSpeakerIsSuggestedWithGuess() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.askKaran)
        let d = try #require(try await all().items.first { $0.id == Seeds.ID.recordingD })
        #expect(d.speakers.map(\.key) == ["S1", "S2"])
        let s2 = d.speakers[1]
        #expect(s2.status == .suggested && s2.suggestedName == "Karan" && s2.name == "Speaker 2" && !s2.isUser)
        #expect(d.speakers[0].status == .autoLabelled && d.speakers[0].suggestedName == nil)
    }

    @Test func namedAndAutoLabelledStatuses() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        let items = try await all().items
        #expect(items[0].speakers.map(\.status) == [.autoLabelled, .autoLabelled])   // A
        #expect(items[0].speakers.map(\.name) == ["Liam", "Karan"])
        #expect(items[1].speakers.map(\.status) == [.named, .named])                 // B
        #expect(items[2].speakers.map(\.status) == [.named, .unnamed])               // C
        #expect(items[2].speakers.map(\.name) == ["Liam", "Speaker 2"])
    }

    @Test func isUserFromIsMe() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        let b = try await all().items[1]
        #expect(b.speakers.map(\.isUser) == [true, false])
    }

    @Test func queryNeedsEveryTerm() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        #expect(try await all(MCPRecordingQuery(terms: ["budget", "finance"])).items.map(\.id) == [Seeds.ID.recordingC])
        #expect(try await all(MCPRecordingQuery(terms: ["budget", "karan"])).total == 0)
        #expect(try await all(MCPRecordingQuery(terms: ["transcription"])).items.map(\.id) == [Seeds.ID.recordingB])
        #expect(try await all(MCPRecordingQuery(terms: ["karan"])).items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB])
        // A title the user set counts even before searchText is rebuilt.
        let c = try #require(try container.mainContext.fetch(FetchDescriptor<Recording>()).first { $0.id == Seeds.ID.recordingC })
        c.title = "Quarterly Planning"
        try container.mainContext.save()
        #expect(try await all(MCPRecordingQuery(terms: ["quarterly", "finance"])).items.map(\.id) == [Seeds.ID.recordingC])
    }

    @Test func speakerFilterIgnoresGuesses() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.askKaran)
        // D has Karan only as a suggestion ("Is this Karan?"), so it is not listed.
        #expect(try await all(MCPRecordingQuery(speaker: "KAR")).items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB])
        #expect(try await all(MCPRecordingQuery(speaker: "liam")).total == 4)
        #expect(try await all(MCPRecordingQuery(speaker: "Speaker 2")).total == 0)
        #expect(try await all(MCPRecordingQuery(speaker: "   ")).total == 4)
    }

    @Test func dateFilter() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        let day = Calendar.current.startOfDay(for: Seeds.Dates.a)            // Wed 18 Nov
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        #expect(try await all(MCPRecordingQuery(from: day, to: next)).items.map(\.id) == [Seeds.ID.recordingA, Seeds.ID.recordingB])
        #expect(try await all(MCPRecordingQuery(to: day)).items.map(\.id) == [Seeds.ID.recordingC])
        #expect(try await all(MCPRecordingQuery(from: Seeds.Dates.a)).items.map(\.id) == [Seeds.ID.recordingA])   // inclusive
        #expect(try await all(MCPRecordingQuery(to: Seeds.Dates.a)).items.map(\.id) == [Seeds.ID.recordingB, Seeds.ID.recordingC])
    }

    @Test func folderDeviceLanguageFilled() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        let context = container.mainContext
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let folder = Folder(name: "Work", createdAt: Seeds.Dates.c)
        context.insert(folder)
        let a = try #require(recordings.first { $0.id == Seeds.ID.recordingA })
        a.folder = folder
        a.languageRaw = "en"
        a.captureChannel = CaptureChannel.mac
        try #require(recordings.first { $0.id == Seeds.ID.recordingB }).captureChannel = CaptureChannel.iphone
        try context.save()
        let items = try await all().items
        #expect(items[0].folder == "Work" && items[0].language == "en" && items[0].device == "Mac")
        #expect(items[1].folder == nil && items[1].language == nil && items[1].device == "iPhone")
        #expect(items[2].device == nil)
    }

    @Test func transcriptForNotReadyIsNil() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.processingHeld)
        #expect(try await reader.transcript(id: Seeds.ID.recordingE) == nil)
        #expect(try await reader.transcript(id: UUID()) == nil)
        try seed(.library)
        let b = try #require(try await reader.transcript(id: Seeds.ID.recordingB))
        #expect(b.document.turns.count == 4 && b.summary.speakers.map(\.name) == ["Liam", "Karan"])
        #expect(b.document.turns.first?.text.hasPrefix("Hey, Karan.") == true)
    }

    @Test func snippetOnlyWithTerms() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try seed(.library)
        #expect(try await all().items.allSatisfy { $0.snippet == nil })
        let c = try #require(try await all(MCPRecordingQuery(terms: ["finance", "budget"])).items.first)
        let snippet = try #require(c.snippet)
        #expect(snippet.text == "The budget sheet still needs the new rates from the finance team.")
        #expect(snippet.speaker == "Speaker 2" && snippet.start > 60)
        // A match only in a speaker name has no line to show.
        let named = try await all(MCPRecordingQuery(terms: ["liam"]))
        #expect(named.total == 3)
        #expect(named.items.first { $0.id == Seeds.ID.recordingB }?.snippet == nil)
    }
}
