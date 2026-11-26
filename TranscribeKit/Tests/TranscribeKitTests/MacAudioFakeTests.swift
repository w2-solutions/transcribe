import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The Mac audio test hooks: `TRANSCRIBE_SOURCE` and `TRANSCRIBE_MAC_AUDIO` in `LaunchConfig`, the fake engine's
/// Mac audio (levels, notices, the lost pause) through the recorder, and the fake stems the real source attribution
/// runs on.
@Suite("Mac audio on the fake engine", .serialized)
@MainActor
struct MacAudioFakeTests {
    let rigs = RecorderControllerTests()

    // MARK: LaunchConfig

    @Test func sourceAndMacAudioAreReadOnlyInTestRuns() {
        let env = [LaunchConfig.envSource: " both ", LaunchConfig.envMacAudio: "silent"]
        let fake = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine], environment: env)
        #expect(fake.source == .both && fake.macAudio == .silent)
        let ui = LaunchConfig(arguments: [LaunchConfig.argUITesting], environment: [LaunchConfig.envSource: "macAudio",
                                                                                   LaunchConfig.envMacAudio: "lost"])
        #expect(ui.source == .macAudio && ui.macAudio == .lost)
        // A plain launch never takes them, so a stray variable cannot change what the real app records.
        let real = LaunchConfig(arguments: [], environment: env)
        #expect(real.source == nil && real.macAudio == .granted)
    }

    @Test func sourceAndMacAudioDefaults() {
        let none = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine], environment: [:])
        #expect(none.source == nil && none.macAudio == .granted)
        let unknown = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine],
                                   environment: [LaunchConfig.envSource: "speakers", LaunchConfig.envMacAudio: "denied"])
        #expect(unknown.source == nil && unknown.macAudio == .granted)
        for source in CaptureSources.allCases {
            let c = LaunchConfig(arguments: [LaunchConfig.argUITesting], environment: [LaunchConfig.envSource: source.rawValue])
            #expect(c.source == source)
        }
        for mode in FakeMacAudio.allCases {
            let c = LaunchConfig(arguments: [LaunchConfig.argUITesting], environment: [LaunchConfig.envMacAudio: mode.rawValue])
            #expect(c.macAudio == mode)
        }
    }

    // MARK: The fake engine through the recorder

    @Test func theFakeEngineRecordsMacAudioOnTheMacUnlessToldItCannot() throws {
        let rig = try rigs.makeRig()
        defer { rig.cleanUp() }
        #if os(macOS)
        #expect(rig.engine.systemAudioAvailable)
        #else
        #expect(!rig.engine.systemAudioAvailable)
        #endif
        let without = try rigs.makeRig(macAudio: .unavailable)
        defer { without.cleanUp() }
        #expect(!without.engine.systemAudioAvailable)
    }

    @Test func macAudioOnlyNeedsNoMicrophoneButBothDoes() async throws {
        let rig = try rigs.makeRig(mic: .denied)
        defer { rig.cleanUp() }
        await #expect(throws: EngineError.microphoneDenied) { try await rig.recorder.start(sources: .both) }
        let id = try await rig.recorder.start(sources: .macAudio)
        #expect(rig.recorder.sources == .macAudio)
        #expect(await rigs.wait { !rig.recorder.levels.isEmpty })
        #expect(rig.recorder.systemLevels.isEmpty)   // one meter: Mac audio's level is the level
        #expect(try await rig.recorder.stop() == id)
        let row = try #require(try rig.recording(id))
        let detail = try #require(CaptureDetail.decode(row.captureDetailJSON))
        #expect(detail.sources == CaptureDetail.Sources.system && detail.input == FakeLiveRecording.macAudioInput)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.stems(recordingID: id).mic.path))
    }

    @Test func aBothRecordingFillsTwoMeters() async throws {
        let rig = try rigs.makeRig(speed: .frozen)
        defer { rig.cleanUp() }
        _ = try await rig.recorder.start(sources: .both)
        #expect(await rigs.wait { rig.recorder.systemLevels.count == RecorderController.levelHistory })
        #expect(rig.recorder.levels.count == RecorderController.levelHistory)
        #expect(rig.recorder.levels != rig.recorder.systemLevels)
        #expect(rig.recorder.systemLevels.contains { $0 > 0 })
        #expect(rig.recorder.notice == nil)
        await rig.recorder.discard()
    }

    @Test func silentMacAudioGivesItsNoticeAndNoLevel() async throws {
        let rig = try rigs.makeRig(speed: .frozen, macAudio: .silent)
        defer { rig.cleanUp() }
        _ = try await rig.recorder.start(sources: .both)
        #expect(await rigs.wait(timeout: 10) { rig.recorder.notice == .systemAudioSilent })
        #expect(rig.recorder.systemLevels.count == RecorderController.levelHistory)
        #expect(rig.recorder.systemLevels.allSatisfy { $0 == 0 })
        #expect(rig.recorder.state == .recording)
        await rig.recorder.discard()
    }

    /// Frozen speed sends the notice on the first tick; the waits allow 10 s because a full parallel `swift test`
    /// can hold the main actor for seconds (a 3 s wait failed there once).
    @Test func lostMacAudioIsANoticeInBothAndAPauseAlone() async throws {
        let both = try rigs.makeRig(speed: .frozen, macAudio: .lost)
        defer { both.cleanUp() }
        _ = try await both.recorder.start(sources: .both)
        #expect(await rigs.wait(timeout: 10) { both.recorder.notice == .systemAudioLost })
        #expect(both.recorder.state == .recording)
        await both.recorder.discard()

        let alone = try rigs.makeRig(speed: .frozen, macAudio: .lost)
        defer { alone.cleanUp() }
        _ = try await alone.recorder.start(sources: .macAudio)
        #expect(await rigs.wait(timeout: 10) { alone.recorder.state == .paused(.routeLost) })
        #expect(alone.recorder.notice == nil)
        await alone.recorder.resume()
        #expect(await rigs.wait { alone.recorder.state == .recording })
        await alone.recorder.discard()
    }

    @Test func lostMacAudioArrivesAfterThreeSecondsOfRecording() async throws {
        let rig = try rigs.makeRig(macAudio: .lost)
        defer { rig.cleanUp() }
        _ = try await rig.recorder.start(sources: .both)
        #expect(await rigs.wait { rig.recorder.elapsed >= 1 })
        #expect(rig.recorder.notice == nil)
        #expect(await rigs.wait(timeout: 6) { rig.recorder.notice == .systemAudioLost })
        #expect(rig.recorder.elapsed >= FakeLiveRecording.lostAfter)
        #expect(rig.recorder.systemLevels.last == 0)
        await rig.recorder.discard()
    }

    // MARK: Fake stems

    /// 16-bit samples of a canonical WAV written by `WAVFileWriter`, as Floats.
    func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return stride(from: 44, to: data.count - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)) / 32767
        }
    }

    /// Whether `samples` has sound in [start, end) seconds, ignoring 10 ms at each edge.
    func hasSound(_ samples: [Float], _ range: TimeRange) -> Bool {
        let lo = Int((range.start + 0.01) * 16_000), hi = Swift.min(samples.count, Int((range.end - 0.01) * 16_000))
        guard lo < hi else { return false }
        return samples[lo..<hi].contains { $0 != 0 }
    }

    func request(sources: CaptureSources) throws -> (RecordingRequest, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-stems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rec.wav")
        return (RecordingRequest(audioURL: url, liveText: false, language: .automatic, sources: sources), dir)
    }

    @Test func theSystemStemHoldsExactlyTheRemoteSpeakers() async throws {
        var script = FakeScript.named(.newVoices)
        script.speakerSources = ["S2": .system]
        let (request, dir) = try request(sources: .both)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = FakeLiveRecording(script: script, speed: .instant, request: request)
        let audio = try await session.stop()

        let stems = CaptureStems.beside(audioURL: request.audioURL)
        #expect(audio.stems == stems)
        #expect(audio.detail == CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: FakeLiveRecording.macAudioInput,
                                              sources: CaptureDetail.Sources.both,
                                              outputRoute: CaptureDetail.OutputRoute.headphones))
        let mic = try readWAV(stems.mic), system = try readWAV(stems.system), main = try readWAV(request.audioURL)
        #expect(mic.count == main.count && system.count == main.count)
        #expect(!script.segments.isEmpty)
        for segment in script.segments {
            let remote = segment.speakerKey == "S2"
            #expect(hasSound(system, segment.range) == remote, "\(segment.speakerKey) \(segment.range)")
            #expect(hasSound(mic, segment.range) == !remote, "\(segment.speakerKey) \(segment.range)")
            #expect(hasSound(main, segment.range))
        }
        // Silence between segments stays silent on both stems.
        var heard = [Bool](repeating: false, count: system.count)
        for segment in script.segments {
            let lo = Int(segment.range.start * 16_000), hi = Swift.min(system.count, Int(segment.range.end * 16_000))
            if lo < hi { for i in lo..<hi { heard[i] = true } }
        }
        #expect(zip(heard, zip(mic, system)).allSatisfy { $0.0 || ($0.1.0 == 0 && $0.1.1 == 0) })
    }

    /// The fake Both recording writes the same stems as `SyntheticAudio.writeStems` (both use
    /// `FakeScript.stemSegments`), so the real attribution finds `callVoices`' three sources in them.
    @Test func callVoicesStemsAttributeEachSpeaker() async throws {
        let script = FakeScript.named(.callVoices)
        let (request, dir) = try request(sources: .both)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try await FakeLiveRecording(script: script, speed: .instant, request: request).stop()
        let stems = try #require(audio.stems)
        let levels = try SourceAttribution.levels(ofWAV: stems.system)
        let spans = Dictionary(grouping: script.segments, by: \.speakerKey).mapValues { $0.map(\.range) }
        let result = SourceAttribution.attribute(speakers: spans, levels: levels)
        #expect(result.mapValues(\.source) == script.speakerSources)
        #expect(script.speakerSources == ["S1": .mic, "S2": .system, "S3": .mixed])
    }

    @Test func silentMacAudioLeavesTheSystemStemEmpty() async throws {
        var script = FakeScript.named(.newVoices)
        script.speakerSources = ["S2": .system]
        let (request, dir) = try request(sources: .both)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try await FakeLiveRecording(script: script, speed: .instant, request: request, macAudio: .silent).stop()
        let stems = try #require(audio.stems)
        #expect(try readWAV(stems.system).allSatisfy { $0 == 0 })
        let mic = try readWAV(stems.mic)
        #expect(script.segments.allSatisfy { hasSound(mic, $0.range) })
    }

    @Test func otherSourcesWriteNoStemsAndAMicrophoneDetailIsUnchanged() async throws {
        for sources in [CaptureSources.microphone, .macAudio] {
            let (request, dir) = try request(sources: sources)
            defer { try? FileManager.default.removeItem(at: dir) }
            let audio = try await FakeLiveRecording(script: .named(.newVoices), speed: .instant, request: request).stop()
            #expect(audio.stems == nil)
            #expect(!FileManager.default.fileExists(atPath: CaptureStems.beside(audioURL: request.audioURL).mic.path))
            if sources == .microphone {
                #expect(audio.detail?.json() == "{\"hardwareModel\":\"\(CaptureChannel.hardwareModel)\",\"input\":\"fake\",\"routeChanged\":false}")
            }
        }
    }

    @Test func discardingABothRecordingDeletesItsStems() async throws {
        let (request, dir) = try request(sources: .both)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stems = CaptureStems.beside(audioURL: request.audioURL)
        let first = FakeLiveRecording(script: .named(.newVoices), speed: .instant, request: request)
        _ = try await first.stop()
        #expect(FileManager.default.fileExists(atPath: stems.system.path))
        let second = FakeLiveRecording(script: .named(.newVoices), speed: .instant, request: request)
        await second.discard()
        for url in [request.audioURL, stems.mic, stems.system] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }
}
