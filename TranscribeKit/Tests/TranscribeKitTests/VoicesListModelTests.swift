import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("VoicesListModel")
@MainActor
struct VoicesListModelTests {
    let locale = Locale(identifier: "en_AU")
    let tz = TimeZone.current   // seeds build their dates with Calendar.current

    @MainActor struct Fixture {
        let container: ModelContainer
        let paths: AppPaths
        var context: ModelContext { container.mainContext }
        func profiles() throws -> [VoiceProfile] { try context.fetch(FetchDescriptor<VoiceProfile>()) }
        func recordings() throws -> [Recording] { try context.fetch(FetchDescriptor<Recording>()) }
    }

    func seeded(_ seed: SeedName) throws -> Fixture {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)", isDirectory: true))
        try Seeds.apply(seed, context: container.mainContext, paths: paths, clock: .frozen(Seeds.Dates.a))
        return Fixture(container: container, paths: paths)
    }

    func model(_ f: Fixture) throws -> VoicesListModel {
        VoicesListModel(profiles: try f.profiles(), recordings: try f.recordings(), locale: locale, timeZone: tz)
    }

    @Test func librarySavedRowsPutMeFirstWithMockupSubtitles() throws {
        let f = try seeded(.library)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let m = try model(f)
        #expect(m.saved.map(\.name) == ["Liam", "Karan"])
        #expect(m.saved[0].isMe)
        #expect(m.saved[0].subtitle == "In 3 recordings")
        #expect(m.saved[1].subtitle == "In 2 recordings · named 18 Nov")
        #expect(m.saved.map(\.slot) == [0, 1])
        #expect(m.saved.allSatisfy { $0.bars.count == VoicesListModel.barCount })
        #expect(m.saved.allSatisfy { $0.bars.allSatisfy { $0 > 0 && $0 <= 1 } })
    }

    @Test func libraryWaitingRowIsRecordingCSpeaker2() throws {
        let f = try seeded(.library)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let m = try model(f)
        #expect(m.waiting.count == 1)
        let row = try #require(m.waiting.first)
        #expect(row.recordingID == Seeds.ID.recordingC)
        #expect(row.key == "S2")
        #expect(row.name == "Speaker 2")
        #expect(row.dateText == "Tue 17 Nov")
        #expect(row.durationText == "12:48")
        #expect(!row.isSuggested)
    }

    @Test func waitingRowsAreNewestFirstAndIncludeSuggestions() throws {
        let f = try seeded(.askKaran)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let m = try model(f)
        // D (19 Nov, suggested Karan) is newer than C (17 Nov, unnamed).
        #expect(m.waiting.map(\.recordingID) == [Seeds.ID.recordingD, Seeds.ID.recordingC])
        #expect(m.waiting[0].isSuggested)
        #expect(m.waiting[0].key == "S2")
    }

    @Test func twoUnnamedSpeakersAreListedInOrdinalOrder() throws {
        let f = try seeded(.twoSpeakersUnnamed)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let m = try model(f)
        #expect(m.saved.map(\.name) == ["Liam"])
        #expect(m.waiting.map(\.name) == ["Speaker 1", "Speaker 2"])
    }

    @Test func speakersUnderThreeSecondsAndUnfinishedRecordingsAreLeftOut() throws {
        let f = try seeded(.twoSpeakersUnnamed)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let rec = try #require(try f.recordings().first)
        rec.sortedSpeakers[0].cleanSeconds = 2.99
        #expect(try model(f).waiting.map(\.name) == ["Speaker 2"])
        rec.stage = .separated
        #expect(try model(f).waiting.isEmpty)
    }

    @Test func waitingIsCappedAtTwenty() throws {
        let f = try seeded(.empty)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        let base = Seeds.Dates.a
        for i in 0..<12 {
            let r = Recording(id: UUID(), createdAt: base.addingTimeInterval(Double(i) * 60), audioFileName: "x\(i).wav", source: .microphone)
            r.stage = .ready
            r.duration = 30
            f.context.insert(r)
            for o in 1...2 {
                let s = RecordingSpeaker(key: "S\(o)", ordinal: o, colourSlot: o - 1)
                s.cleanSeconds = 5
                s.recording = r
                f.context.insert(s)
            }
        }
        try f.context.save()
        let m = try model(f)
        #expect(m.waiting.count == VoicesListModel.maxWaiting)
        #expect(m.waiting.first?.recordingDate == base.addingTimeInterval(11 * 60))
    }

    @Test func meAndSortingByName() throws {
        let f = try seeded(.empty)
        defer { try? FileManager.default.removeItem(at: f.paths.root) }
        for (name, me) in [("zoe", false), ("Ann", false), ("Mei", true), ("bob", false)] {
            let p = VoiceProfile(name: name, colourSlot: 2, embeddingModelKey: "k", now: Seeds.Dates.a)
            p.isMe = me
            f.context.insert(p)
        }
        try f.context.save()
        let m = try model(f)
        #expect(m.saved.map(\.name) == ["Mei", "Ann", "bob", "zoe"])
        #expect(m.saved[0].subtitle == "In 0 recordings")
        // A profile without samples gets the fallback bar pattern.
        #expect(m.saved[1].bars == VoicesListModel.fallbackBars)
    }

    @Test func subtitleVariants() {
        let d = Seeds.Dates.karanNamed
        #expect(VoicesListModel.subtitle(recordingCount: 1, isMe: false, namedAt: d, needsResample: false, locale: locale, timeZone: tz)
                == "In 1 recording · named 18 Nov")
        #expect(VoicesListModel.subtitle(recordingCount: 4, isMe: true, namedAt: d, needsResample: false, locale: locale, timeZone: tz)
                == "In 4 recordings")
        #expect(VoicesListModel.subtitle(recordingCount: 4, isMe: false, namedAt: d, needsResample: true, locale: locale, timeZone: tz,
                                         platform: .iPhone)
                == "Needs a new sample on this iPhone")
        #expect(VoicesListModel.subtitle(recordingCount: 4, isMe: false, namedAt: d, needsResample: true, locale: locale, timeZone: tz,
                                         platform: .mac)
                == "Needs a new sample on this Mac")
    }

    @Test func sampleCaptions() {
        let rows: [(SampleOrigin, Double, String)] = [
            (.named, 12, "Named by you"),
            (.named, 4.6, "Named by you · short sample"),
            (.confirmed, 10, "Confirmed by you"),
            (.confirmed, 9.99, "Confirmed by you · short sample"),
            (.corrected, 12, "Added when not recognised"),
            (.corrected, 6, "Added when not recognised · short sample"),
            (.addedFromRecording, 10, "Added by you"),
            (.addedFromRecording, 7, "Added by you · short sample"),
            (.strongMatch, 12, "Added automatically"),
            (.strongMatch, 6, "Added automatically"),
            (.merged, 30, "Merged from another voice"),
            (.merged, 6, "Merged from another voice"),
        ]
        for (origin, seconds, caption) in rows {
            #expect(VoicesListModel.sampleCaption(origin: origin, speechSeconds: seconds) == caption, "\(origin) @ \(seconds) s")
        }
        #expect(Set(rows.map(\.0)) == Set(SampleOrigin.allCases))
    }

    @Test func clipPeaksSamplesTheRangeAndNormalises() {
        // 10 s, 10 bins of 1 s: bin value = its index / 10.
        let peaks: [Float] = (0..<10).map { Float($0) / 10 }
        let bars = VoicesListModel.clipPeaks(peaks, duration: 10, range: TimeRange(start: 2, end: 6), count: 4)
        // Bar centres at 2.5, 3.5, 4.5, 5.5 s → bins 2…5 → 0.2…0.5, stretched to 0.25…1.
        #expect(bars.count == 4)
        #expect(abs(bars[0] - 0.25) < 1e-5)
        #expect(abs(bars[1] - 0.5) < 1e-5)
        #expect(abs(bars[3] - 1.0) < 1e-5)
        // An evenly loud clip gives even mid-height bars.
        #expect(VoicesListModel.clipPeaks([0.5, 0.5, 0.5], duration: 3, range: TimeRange(start: 0, end: 3), count: 3) == [0.6, 0.6, 0.6])
        #expect(VoicesListModel.clipPeaks([], duration: 10, range: TimeRange(start: 0, end: 1), count: 9).isEmpty)
        #expect(VoicesListModel.clipPeaks(peaks, duration: 10, range: TimeRange(start: 20, end: 30), count: 9).isEmpty)
        #expect(VoicesListModel.clipPeaks([0, 0, 0], duration: 3, range: TimeRange(start: 0, end: 3), count: 9).isEmpty)
    }
}
