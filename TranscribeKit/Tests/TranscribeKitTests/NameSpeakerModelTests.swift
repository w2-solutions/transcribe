import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Records the naming calls `NameSpeakerModel.save` makes; every other method is unused here.
@MainActor
final class NamingSpyStore: LibraryStoring {
    enum Call: Equatable {
        case name(UUID, SpeakerKey, NameTarget, Bool)
        case confirm(UUID, SpeakerKey)
        case reassign(UUID, UUID, TurnTarget)
        case moveAll(UUID, SpeakerKey, SpeakerKey)
    }
    let context: ModelContext
    var calls: [Call] = []
    var nameResult = NameResult(profileID: UUID(), sampleStored: true, skipReason: nil)
    var error: (any Error)?
    init(context: ModelContext) { self.context = context }

    func nameSpeaker(recordingID: UUID, key: SpeakerKey, as target: NameTarget, remember: Bool) throws -> NameResult {
        if let error { throw error }
        calls.append(.name(recordingID, key, target, remember)); return nameResult
    }
    func confirmSuggestion(recordingID: UUID, key: SpeakerKey) throws -> NameResult {
        calls.append(.confirm(recordingID, key)); return nameResult
    }
    func reassignTurn(recordingID: UUID, turnID: UUID, to target: TurnTarget) throws {
        calls.append(.reassign(recordingID, turnID, target))
    }

    func moveAllTurns(recordingID: UUID, from source: SpeakerKey, to target: SpeakerKey) throws {
        calls.append(.moveAll(recordingID, source, target))
    }

    func stampCaptureChannels() throws -> Int { 0 }
    func createRecording(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) throws {}
    func finishCapture(id: UUID, audio: CapturedAudio, language: LanguageHint) throws {}
    func discardRecording(id: UUID) throws {}
    func snapshot(of id: UUID) throws -> RecordingSnapshot { throw StoreError.notFound("unused") }
    func setStage(_ stage: RecordingStage, queueReason: QueueReason?, for id: UUID) throws {}
    func checkpointTranscript(id: UUID, document: TranscriptDocument) throws {}
    func checkpointSeparation(id: UUID, document: TranscriptDocument, speakers: [SpeakerDraft]) throws {}
    func probes(for id: UUID) throws -> [SpeakerProbe] { [] }
    func matchCandidates(modelKey: String) throws -> [ProfileCandidate] { [] }
    func matchCohort(modelKey: String, excludingRecording: UUID) throws -> [VoiceVector] { [] }
    func applyMatches(id: UUID, decisions: [SpeakerKey: MatchDecision], traces: [SpeakerKey: MatchTrace],
                      policy: MatchPolicy) throws -> ProcessingOutcome { .init() }
    func finishWithoutMatching(id: UUID, document: TranscriptDocument?, noSpeech: Bool) throws -> ProcessingOutcome { .init() }
    func markFailed(id: UUID, message: String) throws {}
    func incrementAttempt(id: UUID) throws -> Int { 0 }
    func releaseAttempt(id: UUID) throws {}
    func resetForRetry(id: UUID) throws {}
    func recoveryCandidates() throws -> [RecoverySnapshot] { [] }
    func repairCaptured(id: UUID, duration: TimeInterval, peaks: [Float]) throws {}
    func rename(id: UUID, title: String?) throws {}
    func setFavourite(id: UUID, _ isFavourite: Bool) throws {}
    func markSeen(id: UUID) throws {}
    func delete(id: UUID) throws {}
    func createFolder(name: String) throws -> UUID { UUID() }
    func renameFolder(id: UUID, name: String) throws {}
    func deleteFolder(id: UUID) throws {}
    func move(recordingID: UUID, toFolder folderID: UUID?) throws {}
    func rejectSuggestion(recordingID: UUID, key: SpeakerKey) throws {}
    func setAutoLabel(profileID: UUID, _ on: Bool) throws {}
    func setIsMe(profileID: UUID?) throws {}
    func renameProfile(profileID: UUID, name: String) throws {}
    func mergeProfiles(source: UUID, into target: UUID) throws {}
    func forgetProfile(_ profileID: UUID) throws {}
    func addSample(profileID: UUID, fromSpeaker recordingSpeakerID: UUID) throws -> NameResult { nameResult }
    func sampleCandidates(for profileID: UUID) throws -> [SampleCandidate] { [] }
    func removeSample(id: UUID) throws {}
    func matchingLog() throws -> String { "{}" }
}

@Suite("NameSpeakerModel")
@MainActor
struct NameSpeakerModelTests {
    @MainActor final class Fixture {
        let context: ModelContext
        let paths: AppPaths
        let container: ModelContainer
        init(_ seed: SeedName) throws {
            container = try ModelContainerFactory.make(inMemory: true, url: nil)
            context = container.mainContext
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("nsm-\(UUID().uuidString)"))
            try Seeds.apply(seed, context: context, paths: paths, clock: .frozen(Seeds.Dates.a))
        }
        deinit { try? FileManager.default.removeItem(at: paths.root) }
        func recording(_ id: UUID) throws -> Recording {
            try #require(try context.fetch(FetchDescriptor<Recording>()).first { $0.id == id })
        }
        var profiles: [VoiceProfile] { (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? [] }
        func model(_ id: UUID, _ key: SpeakerKey, mode: NameSpeakerModel.Mode = .name,
                   platform: DevicePlatform = .iPhone, syncOn: Bool = false) throws -> NameSpeakerModel {
            NameSpeakerModel(recording: try recording(id), key: key, mode: mode, profiles: profiles,
                             platform: platform, syncOn: syncOn)
        }
    }

    // MARK: Name mode (mockup 5)

    @Test func headerAndButtonForSpeakerTwo() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        #expect(m.title == "Who is this?")
        #expect(m.subtitle == "Speaker 2 · spoke for 0:13")
        #expect(m.saveTitle == "Save and label 2 turns")
        #expect(m.name.isEmpty)
        #expect(m.selection == .newPerson)
        #expect(!m.canSave)
        #expect(m.action == .none)
        #expect(!m.showsScope)
        #expect(m.fieldSlot == 1)
    }

    @Test func typingANewNameSavesANewPersonAndRemembers() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        m.name = "Karan"
        #expect(m.canSave)
        #expect(m.selection == .newPerson)
        #expect(m.rememberEnabled && m.remember)
        #expect(m.rememberHelp == "Saved on this iPhone only. Used to label Karan automatically next time.")
        #expect(m.action == .name(.newPerson(name: "Karan"), remember: true))
        m.remember = false
        #expect(m.action == .name(.newPerson(name: "Karan"), remember: false))
    }

    @Test func helpSaysThemWithoutAName() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        #expect(m.rememberHelp == "Saved on this iPhone only. Used to label them automatically next time.")
    }

    @Test func helpNamesTheMacAndSync() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let mac = try f.model(Seeds.ID.recordingB, "S2", platform: .mac)
        mac.name = "Karan"
        #expect(mac.rememberHelp == "Saved on this Mac only. Used to label Karan automatically next time.")
        let synced = try f.model(Seeds.ID.recordingB, "S2", platform: .mac, syncOn: true)
        synced.name = "Karan"
        #expect(synced.rememberHelp == "Saved to your voices and synced with iCloud. Used to label Karan automatically next time.")
    }

    @Test func namesAreTrimmedAndValidated() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        m.name = "   "
        #expect(!m.canSave)
        m.name = "  Karan  "
        #expect(m.action == .name(.newPerson(name: "Karan"), remember: true))
        m.name = String(repeating: "x", count: NameSpeakerModel.maxNameLength + 1)
        #expect(!m.canSave)
    }

    @Test func typingASavedNameSelectsThatVoice() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let liam = Seeds.ID.liam
        let m = try f.model(Seeds.ID.recordingB, "S1")
        m.name = "liam"
        #expect(m.selection == .profile(liam))
        #expect(m.rememberHelp == "Adds this recording to Liam's voice.")
        #expect(m.fieldSlot == 0)
        #expect(m.action == .name(.existing(profileID: liam), remember: true))
        m.name = "liam s"
        #expect(m.selection == .newPerson)
    }

    @Test func choosingAChipFillsTheField() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let m = try f.model(Seeds.ID.recordingB, "S1")
        m.select(.profile(Seeds.ID.liam))
        #expect(m.name == "Liam")
        #expect(m.selection == .profile(Seeds.ID.liam))
        m.select(.newPerson)
        #expect(m.name.isEmpty)
        #expect(m.selection == .newPerson)
        m.name = "Mei"
        m.select(.newPerson)
        #expect(m.name == "Mei")
        m.clearName()
        #expect(m.name.isEmpty && m.selection == .newPerson)
    }

    @Test func meComesFirstAmongSavedVoices() throws {
        let f = try Fixture(.library)
        let m = try f.model(Seeds.ID.recordingC, "S2")
        #expect(m.profiles.map(\.name) == ["Liam", "Karan"])
        #expect(m.profiles.first?.isMe == true)
        #expect(m.profiles.map(\.slug) == ["liam", "karan"])
    }

    @Test func rememberIsDisabledUnderTenSeconds() throws {
        let f = try Fixture(.library)
        // Recording A, Karan: 4.6 s of clean speech.
        let m = try f.model(Seeds.ID.recordingA, "S2")
        #expect(!m.rememberEnabled)
        #expect(!m.remember)
        #expect(!m.rememberEffective)
        #expect(m.rememberHelp == "Needs about 10 seconds of clear speech to remember a voice. Karan spoke for 0:04.")
        m.remember = true
        m.name = "Mei"
        #expect(m.action == .name(.newPerson(name: "Mei"), remember: false))
    }

    @Test func sixSecondsCanBeAddedToASavedVoiceButNotANewOne() throws {
        let f = try Fixture(.shortKaran)
        // Recording G, S2: 6.2 s of clean speech, unnamed.
        let m = try f.model(Seeds.ID.recordingG, "S2")
        #expect(m.remember)
        #expect(m.selection == .newPerson)
        #expect(!m.rememberEnabled)
        #expect(m.rememberHelp == "Needs about 10 seconds of clear speech to remember a voice. Speaker 2 spoke for 0:06.")
        m.select(.profile(Seeds.ID.karan))
        #expect(m.rememberEnabled)
        #expect(m.rememberHelp == "Adds this recording to Karan's voice.")
        #expect(m.action == .name(.existing(profileID: Seeds.ID.karan), remember: true))
    }

    @Test func underFiveSecondsSavedVoiceHelp() throws {
        let f = try Fixture(.library)
        // Recording A, Karan: 4.6 s of clean speech.
        let m = try f.model(Seeds.ID.recordingA, "S2")
        m.select(.profile(Seeds.ID.liam))
        #expect(m.rememberHelp == "Needs about 5 seconds of clear speech to add to Liam's voice. Karan spoke for 0:04.")
        #expect(!m.rememberEnabled)
        #expect(!m.rememberEffective)
    }

    @Test func suggestionIsPrefilledAndConfirmed() throws {
        let f = try Fixture(.askKaran)
        let m = try f.model(Seeds.ID.recordingD, "S2")
        #expect(m.name == "Karan")
        #expect(m.selection == .profile(Seeds.ID.karan))
        #expect(m.action == .confirmSuggestion)
        m.select(.profile(Seeds.ID.liam))
        #expect(m.action == .name(.existing(profileID: Seeds.ID.liam), remember: true))
    }

    @Test func rememberOffOnTheSuggestedVoiceDoesNotConfirm() throws {
        let f = try Fixture(.askKaran)
        let spy = NamingSpyStore(context: f.context)
        let m = try f.model(Seeds.ID.recordingD, "S2")
        #expect(m.selection == .profile(Seeds.ID.karan) && m.rememberEnabled)
        m.remember = false
        // Confirming would store a sample; naming with Remember off stores nothing (D14).
        #expect(m.action == .name(.existing(profileID: Seeds.ID.karan), remember: false))
        try m.save(using: spy)
        #expect(spy.calls == [.name(Seeds.ID.recordingD, "S2", .existing(profileID: Seeds.ID.karan), false)])
    }

    @Test func aShortNewPersonStillPassesRememberForTheNegative() throws {
        let f = try Fixture(.shortKaran)
        // Recording G, S2: 6.2 s. Too short for a new voice (the toggle is off and disabled), but long enough
        // for a negative, so Save passes the user's choice and the store creates no profile.
        let m = try f.model(Seeds.ID.recordingG, "S2")
        m.name = "Mei"
        #expect(!m.rememberEffective)
        #expect(m.action == .name(.newPerson(name: "Mei"), remember: true))
        // Switched off on a saved voice, then a new name: the user's "off" is kept.
        m.select(.profile(Seeds.ID.karan))
        m.remember = false
        m.name = "Mei"
        #expect(m.selection == .newPerson)
        #expect(m.action == .name(.newPerson(name: "Mei"), remember: false))
    }

    @Test func clipPeaksComeFromTheClipsSliceOfTheRecording() {
        let peaks = (0..<200).map { Float($0) / 200 }
        let slice = NameSpeakerModel.peaks(peaks, duration: 20, range: TimeRange(start: 10, end: 12))
        #expect(slice.first == 0.5)
        #expect(slice.count == 20)
        #expect(NameSpeakerModel.peaks([], duration: 20, range: TimeRange(start: 1, end: 2)).isEmpty)
        #expect(NameSpeakerModel.peaks(peaks, duration: 20, range: TimeRange(start: 19.99, end: 25)).count == 1)
    }

    @Test func clipsUseTheListenClipRule() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let r = try f.recording(Seeds.ID.recordingB)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        let expected = CleanSpeech.listenClips(for: "S2", turns: r.transcript?.turns ?? [], max: 2)
        #expect(m.clips.map(\.range) == expected.map(\.range))
        #expect(m.clips.map(\.quote) == expected.map(\.quote))
        #expect(Set(m.clips.map(\.id)).count == m.clips.count)
    }

    // MARK: Correct mode

    @Test func justThisTurnReusesTheSpeakerWhoIsAlreadyThatPerson() throws {
        let f = try Fixture(.library)
        let r = try f.recording(Seeds.ID.recordingA)
        let turn1 = try #require(r.transcript?.turns[1])
        let m = try f.model(Seeds.ID.recordingA, "S2", mode: .correct(turnID: turn1.id))
        #expect(m.title == "Who said this?")
        #expect(m.showsScope)
        #expect(m.allTurnsTitle == "All of Karan's turns here")
        #expect(m.scope == .allTurns)
        m.scope = .justThisTurn
        #expect(m.saveTitle == "Save and label 1 turn")
        #expect(!m.showsRemember)
        m.select(.profile(Seeds.ID.liam))
        #expect(m.action == .reassignTurn(turn1.id, .speaker("S1")))
    }

    @Test func justThisTurnWithANewNameOrAnUnlinkedVoice() throws {
        let f = try Fixture(.library)
        let r = try f.recording(Seeds.ID.recordingC)
        let turn = try #require(r.transcript?.turns.first { $0.speakerKey == "S1" })
        let m = try f.model(Seeds.ID.recordingC, "S1", mode: .correct(turnID: turn.id))
        m.scope = .justThisTurn
        m.select(.profile(Seeds.ID.karan))
        #expect(m.action == .reassignTurn(turn.id, .profile(Seeds.ID.karan)))
        m.name = "Mei"
        #expect(m.action == .reassignTurn(turn.id, .newName("Mei")))
        m.select(.profile(Seeds.ID.liam))
        #expect(m.action == .none)   // already Liam's turn
    }

    @Test func correctModeOffersOtherUnlinkedSpeakers() throws {
        let f = try Fixture(.library)
        let m = try f.model(Seeds.ID.recordingC, "S1", mode: .correct(turnID: nil))
        #expect(!m.showsScope)
        #expect(m.otherSpeakers.map(\.key) == ["S2"])
        #expect(m.otherSpeakers.first?.name == "Speaker 2")
        m.select(.speaker("S2"))
        #expect(m.name == "Speaker 2")
        #expect(!m.showsRemember)
        let r = try f.recording(Seeds.ID.recordingC)
        let ids = (r.transcript?.turns ?? []).filter { $0.effectiveSpeakerKey == "S1" }.map(\.id)
        #expect(m.action == .reassignAllTurns(ids, .speaker("S2")))
    }

    @Test func nameModeOffersNoOtherSpeakers() throws {
        let f = try Fixture(.library)
        #expect(try f.model(Seeds.ID.recordingC, "S2").otherSpeakers.isEmpty)
    }

    @Test func allTurnsCorrectionNamesTheWholeSpeaker() throws {
        let f = try Fixture(.library)
        let m = try f.model(Seeds.ID.recordingA, "S2", mode: .correct(turnID: nil))
        m.name = "Mei"
        #expect(m.saveTitle == "Save and label 1 turn")
        #expect(m.action == .name(.newPerson(name: "Mei"), remember: false))   // 4.6 s: cannot be remembered
    }

    // MARK: Save dispatch

    @Test func saveCallsTheStore() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let spy = NamingSpyStore(context: f.context)
        let m = try f.model(Seeds.ID.recordingB, "S2")
        m.name = "Karan"
        let result = try m.save(using: spy)
        #expect(result == spy.nameResult)
        #expect(spy.calls == [.name(Seeds.ID.recordingB, "S2", .newPerson(name: "Karan"), true)])
    }

    @Test func saveConfirmsASuggestion() throws {
        let f = try Fixture(.askKaran)
        let spy = NamingSpyStore(context: f.context)
        try f.model(Seeds.ID.recordingD, "S2").save(using: spy)
        #expect(spy.calls == [.confirm(Seeds.ID.recordingD, "S2")])
    }

    @Test func saveReassignsEveryTurnOfTheSpeaker() throws {
        let f = try Fixture(.library)
        let spy = NamingSpyStore(context: f.context)
        let m = try f.model(Seeds.ID.recordingC, "S1", mode: .correct(turnID: nil))
        m.select(.speaker("S2"))
        try m.save(using: spy)
        // One whole-speaker move (a single transaction that also rolls back a wrong match).
        #expect(spy.calls == [.moveAll(Seeds.ID.recordingC, "S1", "S2")])
    }

    @Test func saveWithNothingToDoWritesNothing() throws {
        let f = try Fixture(.twoSpeakersUnnamed)
        let spy = NamingSpyStore(context: f.context)
        #expect(try f.model(Seeds.ID.recordingB, "S2").save(using: spy) == nil)
        #expect(spy.calls.isEmpty)
    }

    @Test func errorsAndNotesReadWell() {
        #expect(NameSpeakerModel.message(for: StoreError.invalidName) == "Enter a name.")
        #expect(NameSpeakerModel.message(for: StoreError.notFound("x")) == "This recording or voice no longer exists.")
        #expect(NameSpeakerModel.message(for: EngineError.cancelled) == "Couldn't save. Please try again.")
        #expect(NameSpeakerModel.note(for: NameResult(profileID: nil, sampleStored: false, skipReason: .tooLittleSpeech(seconds: 4)))
                == "Name saved. Not enough clear speech to remember the voice yet.")
        #expect(NameSpeakerModel.note(for: nil) == nil)
    }
}
