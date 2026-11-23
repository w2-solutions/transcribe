import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("TranscriptViewState")
@MainActor
struct TranscriptViewStateTests {
    // MARK: Fixtures

    static let docA = TranscriptDocument(words: SeedContent.allWords(SeedContent.conversationA),
                                         turns: SeedContent.speakerTurns(SeedContent.conversationA), asrModelID: "fake")
    static let docB = TranscriptDocument(words: SeedContent.allWords(SeedContent.conversationB),
                                         turns: SeedContent.speakerTurns(SeedContent.conversationB), asrModelID: "fake")
    static let liamID = UUID(), karanID = UUID()

    static func speaker(_ key: SpeakerKey, _ ordinal: Int, _ label: SpeakerLabelState, name: String? = nil,
                        clean: Double = 11, suggested: String? = nil) -> TranscriptSpeaker {
        TranscriptSpeaker(key: key, ordinal: ordinal, slot: ordinal - 1, label: label, name: name ?? "Speaker \(ordinal)",
                          profileID: (label == .named || label == .autoLabelled) ? UUID() : nil,
                          suggestedProfileID: suggested == nil ? nil : karanID, suggestedName: suggested,
                          cleanSeconds: clean, totalSeconds: clean + 1)
    }

    static func state(stage: RecordingStage = .ready, doc: TranscriptDocument? = docB, _ speakers: [TranscriptSpeaker],
                      noSpeech: Bool = false, failure: String? = nil, marks: [TimeInterval] = []) -> TranscriptViewState {
        TranscriptViewState(stage: stage, document: doc, speakers: speakers, marks: marks, duration: 24,
                            noSpeech: noSpeech, failureMessage: failure)
    }

    /// The container must outlive every model read from its context.
    func seeded(_ seed: SeedName) throws -> (ModelContext, AppPaths, ModelContainer) {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("tvs-\(UUID().uuidString)"))
        try Seeds.apply(seed, context: container.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        return (container.mainContext, paths, container)
    }

    func viewState(_ id: UUID, in context: ModelContext) throws -> TranscriptViewState {
        let recording = try #require(try context.fetch(FetchDescriptor<Recording>()).first { $0.id == id })
        let names = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<VoiceProfile>()).map { ($0.id, $0.name) })
        return TranscriptViewState(recording: recording, document: recording.transcript, profileNames: names)
    }

    // MARK: Phase and banner priority

    @Test(arguments: [
        (RecordingStage.capturing, TranscriptViewState.Phase.capturing),
        (.queued, .processing), (.transcribing, .processing), (.transcribed, .processing),
        (.separating, .processing), (.separated, .processing), (.matching, .processing),
        (.ready, .ready), (.failed, .failed),
    ])
    func phaseFollowsStage(_ stage: RecordingStage, _ phase: TranscriptViewState.Phase) {
        #expect(Self.state(stage: stage, []).phase == phase)
    }

    @Test func failedBeatsEverything() {
        let s = Self.state(stage: .failed, [Self.speaker("S1", 1, .unnamed)], noSpeech: true, failure: "Audio file is missing")
        #expect(s.banner == .failed(message: "Audio file is missing"))
    }

    @Test func failedHidesAMessageThatRepeatsTheTitle() {
        #expect(Self.state(stage: .failed, [], failure: "Couldn't finish processing").banner == .failed(message: nil))
        #expect(Self.state(stage: .failed, [], failure: nil).banner == .failed(message: nil))
    }

    @Test func noSpeechBeatsAskAndNewVoices() {
        let s = Self.state([Self.speaker("S1", 1, .suggested, suggested: "Karan"), Self.speaker("S2", 2, .unnamed)], noSpeech: true)
        #expect(s.banner == .noSpeech)
    }

    @Test func askBeatsNewVoices() {
        let ask = Self.speaker("S2", 2, .suggested, suggested: "Karan")
        let s = Self.state([Self.speaker("S1", 1, .unnamed), ask])
        #expect(s.banner == .ask(ask))
    }

    @Test func suggestionWithoutAKnownProfileCountsAsANewVoice() {
        let orphan = TranscriptSpeaker(key: "S2", ordinal: 2, slot: 1, label: .suggested, name: "Speaker 2",
                                       suggestedProfileID: UUID(), suggestedName: nil, cleanSeconds: 8, totalSeconds: 9)
        let s = Self.state([orphan])
        #expect(s.banner == .newVoices([orphan]))
        #expect(orphan.chipStyle == .unnamed)
    }

    @Test func newVoicesListsSpeakersNeedingANameInOrdinalOrder() {
        let s1 = Self.speaker("S1", 1, .unnamed), s2 = Self.speaker("S2", 2, .unnamed)
        let s = Self.state([s2, Self.speaker("S3", 3, .unnamed, clean: 2.9), s1, Self.speaker("S4", 4, .autoLabelled, name: "Liam")])
        #expect(s.banner == .newVoices([s1, s2]))
        #expect(TranscriptViewState.newVoicesTitle(2) == "2 new voices")
        #expect(TranscriptViewState.newVoicesTitle(1) == "1 new voice")
    }

    @Test func speakerUnderThreeSecondsDoesNotNeedAName() {
        #expect(!Self.speaker("S1", 1, .unnamed, clean: 2.99).needsName)
        #expect(Self.speaker("S1", 1, .unnamed, clean: 3.0).needsName)
    }

    @Test func recognisedWhenAutoLabelledAndNobodyNeedsAName() {
        let s = Self.state(doc: Self.docA, [Self.speaker("S2", 2, .autoLabelled, name: "Karan"), Self.speaker("S1", 1, .autoLabelled, name: "Liam")])
        #expect(s.banner == .recognised(names: ["Liam", "Karan"]))
        #expect(ProcessingCopy.joinNames(s.recognisedNames) == "Liam and Karan")
    }

    @Test func recognisedLeavesOutASpeakerWhoseTurnsWereAllMovedAway() {
        var doc = Self.docA
        for i in doc.turns.indices where doc.turns[i].speakerKey == "S2" { doc.turns[i].speakerKeyOverride = "S1" }
        let s = Self.state(doc: doc, [Self.speaker("S1", 1, .autoLabelled, name: "Liam"), Self.speaker("S2", 2, .autoLabelled, name: "Karan")])
        #expect(s.banner == .recognised(names: ["Liam"]))
    }

    @Test func allNamedByHandShowsNoBanner() {
        let s = Self.state([Self.speaker("S1", 1, .named, name: "Liam"), Self.speaker("S2", 2, .named, name: "Karan")])
        #expect(s.banner == .none)
    }

    @Test func processingShowsNoBanner() {
        #expect(Self.state(stage: .separating, [Self.speaker("S1", 1, .unnamed)]).banner == .none)
    }

    // MARK: Seeds

    @Test func seedTwoSpeakersUnnamedAsksForTwoNames() throws {
        let (context, paths, container) = try seeded(.twoSpeakersUnnamed)
        defer { try? FileManager.default.removeItem(at: paths.root); withExtendedLifetime(container) {} }
        let s = try viewState(Seeds.ID.recordingB, in: context)
        guard case .newVoices(let speakers) = s.banner else { Issue.record("expected newVoices, got \(s.banner)"); return }
        #expect(speakers.map(\.key) == ["S1", "S2"])
        #expect(s.speaker(forTurn: 1)?.chipStyle == .unnamed)
        #expect(s.speaker(forTurn: 1)?.chipName == "Speaker 2")
        #expect(s.turnCount(for: "S2") == 2)
    }

    @Test func seedLibraryARecognisesLiamAndKaran() throws {
        let (context, paths, container) = try seeded(.library)
        defer { try? FileManager.default.removeItem(at: paths.root); withExtendedLifetime(container) {} }
        let s = try viewState(Seeds.ID.recordingA, in: context)
        #expect(s.banner == .recognised(names: ["Liam", "Karan"]))
        #expect(s.speaker(forTurn: 0)?.chipStyle == .filled(recognised: true))
        #expect(s.speaker(forTurn: 1)?.isLabelled == true)
    }

    @Test func seedAskKaranAsksAboutSpeakerTwo() throws {
        let (context, paths, container) = try seeded(.askKaran)
        defer { try? FileManager.default.removeItem(at: paths.root); withExtendedLifetime(container) {} }
        let s = try viewState(Seeds.ID.recordingD, in: context)
        guard case .ask(let speaker) = s.banner else { Issue.record("expected ask, got \(s.banner)"); return }
        #expect(speaker.key == "S2")
        #expect(speaker.suggestedName == "Karan")
        #expect(speaker.chipStyle == .suggested)
        #expect(speaker.chipName == "Karan")
    }

    @Test func seedFailedProcessingShowsTheFailedCardWithParagraphs() throws {
        let (context, paths, container) = try seeded(.failedProcessing)
        defer { try? FileManager.default.removeItem(at: paths.root); withExtendedLifetime(container) {} }
        let s = try viewState(Seeds.ID.recordingF, in: context)
        #expect(s.banner == .failed(message: nil))
        #expect(s.turns.count == 4)
        #expect(!s.hasSpeakers)
    }

    // MARK: Turns

    @Test func timestampsRoundToTheNearestSecond() {
        let s = Self.state([])
        #expect(s.turns.indices.map(s.timestamp) == ["0:01", "0:07", "0:15", "0:20"])
        let a = Self.state(doc: Self.docA, [])
        #expect(a.turns.indices.map(a.timestamp) == ["0:01", "0:11", "0:16"])
    }

    @Test func overridesDecideTheTurnSpeaker() {
        var doc = Self.docA
        doc.turns[1].speakerKeyOverride = "S1"
        let s = Self.state(doc: doc, [Self.speaker("S1", 1, .named, name: "Liam"), Self.speaker("S2", 2, .named, name: "Karan")])
        #expect(s.speaker(forTurn: 1)?.name == "Liam")
        #expect(s.turnCount(for: "S1") == 3)
        #expect(s.turnCount(for: "S2") == 0)
    }

    @Test func marksFindTheirTurns() {
        let s = Self.state([], marks: [14.0, 21.0, 100])
        #expect(s.markedTurnIndices == [1, 3])
    }

    // MARK: Now playing

    @Test func nowPlayingIsThePhraseAroundTheCurrentWord() throws {
        let s = Self.state(doc: Self.docA, [])
        let span = try #require(s.nowPlaying(at: 14.0, removeFillers: false))
        let text = s.displayText(1, removeFillers: false)
        #expect(span.turnIndex == 1)
        let r = try #require(text.range(of: "which is a second attempt at testing the app."))
        #expect(span.range == TranscriptViewState.offsets(r, in: text))
    }

    @Test func nowPlayingAtTheStartOfATurnIsItsFirstPhrase() throws {
        let s = Self.state([])
        let span = try #require(s.nowPlaying(at: 0.65, removeFillers: false))
        #expect(span == .init(turnIndex: 0, range: 0..<"Hey,".count))
    }

    @Test func nowPlayingInAGapStaysOnThePreviousTurn() throws {
        let s = Self.state([])
        let span = try #require(s.nowPlaying(at: 14.65, removeFillers: false))
        #expect(span.turnIndex == 1)
        let text = s.displayText(1, removeFillers: false)
        #expect(span.range.upperBound == text.count)
    }

    @Test func nothingPlaysBeforeTheFirstWord() {
        #expect(Self.state([]).nowPlaying(at: 0.1, removeFillers: false) == nil)
    }

    @Test func nowPlayingFindsThePhraseInFilteredText() throws {
        let s = Self.state([])
        // "just" in "Um, I just want to test out if this transcription app works."
        let justStart = try #require(s.turns[0].words.first { $0.text == "just" }).range.start
        let span = try #require(s.nowPlaying(at: justStart + 0.01, removeFillers: true))
        let text = s.displayText(0, removeFillers: true)
        let r = try #require(text.range(of: "I just want to test out if this transcription app works."))
        #expect(span.range == TranscriptViewState.offsets(r, in: text))
    }

    @Test func nowPlayingFollowsTimeAcrossTheWholeRecording() {
        let s = Self.state([])
        var t = 0.6
        var lastTurn = 0
        while t < 24 {
            if let span = s.nowPlaying(at: t, removeFillers: false) {
                #expect(span.turnIndex >= lastTurn)
                lastTurn = span.turnIndex
                #expect(span.range.upperBound <= s.displayText(span.turnIndex, removeFillers: false).count)
            }
            t += 0.05
        }
        #expect(lastTurn == 3)
    }

    // MARK: Search

    @Test func searchFindsEveryMatchInReadingOrder() {
        let s = Self.state(doc: Self.docA, [])
        let hits = s.searchHits("karan", removeFillers: false)
        #expect(hits.map(\.turnIndex) == [0, 2])
        let t2 = s.displayText(2, removeFillers: false)
        let r = t2.range(of: "Karan")!
        #expect(hits[1].range == TranscriptViewState.offsets(r, in: t2))
        #expect(TranscriptViewState.searchCountText(current: 1, total: hits.count) == "2 of 2")
    }

    @Test func searchFindsRepeatsWithinATurn() {
        let s = Self.state(doc: Self.docA, [])
        #expect(s.searchHits("auto-detect", removeFillers: false).count == 2)
        #expect(s.searchHits("AUTO", removeFillers: false).map(\.turnIndex) == [0, 0])
    }

    @Test func emptyOrMissingSearch() {
        let s = Self.state([])
        #expect(s.searchHits("   ", removeFillers: false).isEmpty)
        #expect(s.searchHits("zebra", removeFillers: false).isEmpty)
        #expect(TranscriptViewState.searchCountText(current: nil, total: 0) == "No matches")
    }
}
