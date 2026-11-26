#if os(macOS)
import CoreAudio
#endif
import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// The Both source over two scripted streams: alignment, the clamped mix, stem bytes, the microphone carrying on after
/// Mac audio is lost, pauses, levels, the detail and which events go through.
@Suite("MixedCaptureSource (scripted streams)")
struct MixedCaptureSourceTests {
    struct Rig {
        let mic: StampedScriptedSource
        let system: StampedScriptedSource
        let mixed: MixedCaptureSource
        let stems: CaptureStems
        let log = DeliveryLog()
    }

    func makeRig(mic: StampedScriptedSource = StampedScriptedSource(),
                 system: StampedScriptedSource = StampedScriptedSource()) throws -> Rig {
        let dir = try TestAudio.temporaryDirectory()
        let stems = CaptureStems.beside(audioURL: dir.appendingPathComponent("rec.wav"))
        return Rig(mic: mic, system: system, mixed: MixedCaptureSource(mic: mic, system: system, stems: stems), stems: stems)
    }

    /// Sends both streams' 100 ms chunks alternately, as their callbacks would come: `mic` from `micFrom`, `system`
    /// from `systemFrom`, each `seconds` long.
    func interleave(_ rig: Rig, mic: Float, micFrom: Double, system: Float, systemFrom: Double, seconds: Double) async {
        let n = Int((seconds * 10).rounded())
        let chunk = 1_600
        for k in 0..<n {
            await rig.mic.send([Float](repeating: mic, count: chunk), host: micFrom + 0.1 * Double(k))
            await rig.system.send([Float](repeating: system, count: chunk), host: systemFrom + 0.1 * Double(k))
        }
    }

    func near(_ a: [Float], _ v: Float, _ tolerance: Float = 0.001) -> Bool { a.allSatisfy { abs($0 - v) < tolerance } }

    @Test func alignsMixesAndWritesStemsOfTheSameLength() async throws {
        let rig = try makeRig()
        try await rig.mixed.start(rig.log.sink())
        // Mac audio starts 100 ms after the microphone.
        await interleave(rig, mic: 0.25, micFrom: 100.0, system: 0.5, systemFrom: 100.1, seconds: 1.0)
        await rig.mixed.stop()

        let audio = rig.log.audio
        #expect(audio.count == 17_600)   // 1.1 s: the microphone's second, then Mac audio's last 100 ms
        #expect(near(Array(audio[0..<1_600]), 0.25))
        #expect(near(Array(audio[1_600..<16_000]), 0.75))
        #expect(near(Array(audio[16_000...]), 0.5))

        let micStem = try TestAudio.readSamples(rig.stems.mic)
        let systemStem = try TestAudio.readSamples(rig.stems.system)
        #expect(micStem.count == 17_600 && systemStem.count == 17_600)
        #expect(near(Array(micStem[0..<16_000]), 0.25) && near(Array(micStem[16_000...]), 0))
        #expect(near(Array(systemStem[0..<1_600]), 0) && near(Array(systemStem[1_600...]), 0.5))
        #expect(try TestAudio.headerDataBytes(rig.stems.mic) == 2 * 17_600)
        #expect(await rig.mic.calls == ["start", "stop"])
        #expect(await rig.system.calls == ["start", "stop"])
    }

    @Test func theMixIsClamped() async throws {
        let rig = try makeRig()
        try await rig.mixed.start(rig.log.sink())
        await interleave(rig, mic: 0.8, micFrom: 5.0, system: 0.7, systemFrom: 5.0, seconds: 0.5)
        await interleave(rig, mic: -0.8, micFrom: 5.5, system: -0.7, systemFrom: 5.5, seconds: 0.5)
        await rig.mixed.stop()
        let audio = rig.log.audio
        #expect(audio.count == 16_000)
        #expect(audio[0..<8_000].allSatisfy { $0 == 1 } && audio[8_000...].allSatisfy { $0 == -1 })
    }

    @Test func theMicrophoneCarriesOnAfterMacAudioIsLost() async throws {
        let rig = try makeRig()
        try await rig.mixed.start(rig.log.sink())
        await interleave(rig, mic: 0.25, micFrom: 10.0, system: 0.5, systemFrom: 10.0, seconds: 0.5)
        await rig.system.send(event: .systemAudioLost)
        await rig.system.send(event: .routeLost)              // a second loss is not reported again
        await rig.system.send([Float](repeating: 0.9, count: 1_600), host: 10.5)   // ignored once lost
        for k in 0..<5 { await rig.mic.send([Float](repeating: 0.25, count: 1_600), host: 10.5 + 0.1 * Double(k)) }
        await rig.mixed.stop()

        #expect(rig.log.events == [.systemAudioLost])
        #expect(await rig.mixed.isSystemLost)
        let audio = rig.log.audio
        #expect(audio.count == 16_000)
        #expect(near(Array(audio[0..<8_000]), 0.75) && near(Array(audio[8_000...]), 0.25))
        let systemStem = try TestAudio.readSamples(rig.stems.system)
        #expect(systemStem.count == 16_000 && near(Array(systemStem[8_000...]), 0))
    }

    @Test func macAudioThatCannotStartLeavesAMicrophoneRecording() async throws {
        let rig = try makeRig(system: StampedScriptedSource(failStart: true))
        try await rig.mixed.start(rig.log.sink())
        for k in 0..<5 { await rig.mic.send([Float](repeating: 0.25, count: 1_600), host: 1.0 + 0.1 * Double(k)) }
        await rig.mixed.stop()
        #expect(rig.log.events == [.systemAudioLost])
        #expect(rig.log.audio.count == 8_000 && near(rig.log.audio, 0.25))
        #expect(near(try TestAudio.readSamples(rig.stems.system), 0))
    }

    @Test func aMicrophoneThatCannotStartFailsAndLeavesNoStems() async throws {
        let rig = try makeRig(mic: StampedScriptedSource(failStart: true))
        await #expect(throws: EngineError.failed("Could not start")) { try await rig.mixed.start(rig.log.sink()) }
        #expect(await rig.system.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.stems.mic.path))
        #expect(!FileManager.default.fileExists(atPath: rig.stems.system.path))
    }

    @Test func aPauseLeavesNoZerosAndAMacAudioThatCannotResumeIsLost() async throws {
        let rig = try makeRig(system: StampedScriptedSource(failResume: true))
        try await rig.mixed.start(rig.log.sink())
        await interleave(rig, mic: 0.25, micFrom: 50.0, system: 0.5, systemFrom: 50.0, seconds: 0.5)
        await rig.mixed.pause()
        #expect(await rig.mic.send([Float](repeating: 0.9, count: 1_600), host: 50.5) == false)
        try await rig.mixed.resume()
        // A minute later on the host clock: the timeline goes on where it stopped.
        for k in 0..<5 { await rig.mic.send([Float](repeating: 0.25, count: 1_600), host: 110.0 + 0.1 * Double(k)) }
        await rig.mixed.stop()
        #expect(rig.log.events == [.systemAudioLost])
        let audio = rig.log.audio
        #expect(audio.count == 16_000)
        #expect(near(Array(audio[0..<8_000]), 0.75) && near(Array(audio[8_000...]), 0.25))
        #expect(await rig.mic.calls == ["start", "pause", "resume", "stop"])
        #expect(await rig.system.calls == ["start", "pause", "resume", "stop"])
    }

    @Test func eachStreamHasItsOwnLevel() async throws {
        let rig = try makeRig()
        try await rig.mixed.start(rig.log.sink())
        await interleave(rig, mic: 0.5, micFrom: 1.0, system: 0, systemFrom: 1.0, seconds: 0.5)
        // The consumer runs on its own: wait until it has metered what was sent.
        #expect(await eventually { (await rig.mixed.streamLevels())?.mic ?? 0 > 0.8 })
        #expect(await rig.mixed.streamLevels()?.system == 0)
        await rig.mixed.stop()
    }

    @Test func theDetailNamesBothAndMacAudiosRoute() async throws {
        let micDetail = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.builtInMic, inputName: "MacBook Pro Microphone")
        var systemDetail = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.systemAudio,
                                         sources: CaptureDetail.Sources.system, outputRoute: CaptureDetail.OutputRoute.headphones)
        systemDetail.routeChanged = true
        let rig = try makeRig(mic: StampedScriptedSource(detail: micDetail), system: StampedScriptedSource(detail: systemDetail))
        let detail = try #require(await rig.mixed.captureDetail())
        #expect(detail.input == CaptureDetail.Input.micAndSystem)
        #expect(detail.sources == CaptureDetail.Sources.both)
        #expect(detail.outputRoute == CaptureDetail.OutputRoute.headphones)
        #expect(detail.inputName == "MacBook Pro Microphone" && detail.routeChanged)
    }

    @Test func eventsThatGoThrough() async throws {
        let rig = try makeRig()
        try await rig.mixed.start(rig.log.sink())
        await rig.mic.send(event: .routeLost)
        await rig.system.send(event: .interrupted)              // only the microphone's session is interrupted
        await rig.system.send(event: .systemAudioSilent)
        await rig.mic.send(event: .interrupted)
        await rig.mixed.stop()
        #expect(rig.log.events == [.routeLost, .systemAudioSilent, .interrupted])
    }
}

@Suite("FluidLiveRecording with Mac audio")
struct FluidLiveRecordingMacAudioTests {
    @Test func aBothRecordingTicksWithBothLevelsAndReturnsItsStems() async throws {
        let dir = try TestAudio.temporaryDirectory()
        let url = dir.appendingPathComponent("rec.wav")
        let stems = CaptureStems(mic: dir.appendingPathComponent("s/rec.mic.wav"), system: dir.appendingPathComponent("s/rec.system.wav"))
        let mic = StampedScriptedSource(detail: CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.builtInMic))
        let system = StampedScriptedSource()
        let source = MixedCaptureSource(mic: mic, system: system, stems: stems)
        let request = RecordingRequest(audioURL: url, liveText: false, language: .automatic, sources: .both, stems: stems)
        let recording = FluidLiveRecording(request: request, source: source, liveModels: { nil }, freeBytes: { _ in 10_000_000_000 })
        let events = collectEvents(recording.events)
        try await recording.start()
        for k in 0..<10 {
            await mic.send([Float](repeating: 0.5, count: 1_600), host: 1.0 + 0.1 * Double(k))
            await system.send([Float](repeating: 0.01, count: 1_600), host: 1.0 + 0.1 * Double(k))
        }
        let audio = try await recording.stop()

        #expect(audio.stems == stems)
        #expect(audio.detail?.sources == CaptureDetail.Sources.both && audio.detail?.input == CaptureDetail.Input.micAndSystem)
        #expect(abs(audio.duration - 1.0) < 1e-9)
        #expect(try TestAudio.readSamples(stems.mic).count == 16_000)
        #expect(try TestAudio.readSamples(stems.system).count == 16_000)
        let ticks = await events.value.compactMap { e -> (Float, Float?)? in
            if case .tick(_, let level, let systemLevel) = e { return (level, systemLevel) } else { return nil }
        }
        #expect(ticks.count == 20)
        #expect(ticks.allSatisfy { $0.1 != nil })
        #expect(ticks.last.map { $0.0 > 0.8 && ($0.1 ?? 1) < 0.5 } == true)   // the microphone is louder than Mac audio
    }

    @Test func macAudioLostPausesAMacAudioOnlyRecordingAndIsANoticeInBoth() async throws {
        for (sources, expected) in [(CaptureSources.macAudio, RecordingEvent.paused(.routeLost)),
                                    (.both, .notice(.systemAudioLost))] {
            let url = try TestAudio.temporaryDirectory().appendingPathComponent("rec.wav")
            let source = ScriptedCaptureSource()
            let request = RecordingRequest(audioURL: url, liveText: false, language: .automatic, sources: sources)
            let recording = FluidLiveRecording(request: request, source: source, liveModels: { nil })
            let events = collectEvents(recording.events)
            try await recording.start()
            await source.send(event: .systemAudioSilent)
            await source.send(event: .systemAudioLost)
            // Audio sent after the events: once it is written, the consumer has handled them (in order).
            await source.send([Float](repeating: 0.1, count: 1_600))
            if sources == .macAudio {
                #expect(await eventually { await source.calls.contains("pause") })
            } else {
                #expect(await eventually { await recording.capturedDuration >= 0.1 })
            }
            let audio = try await recording.stop()
            let states = await events.value.filter { if case .tick = $0 { false } else { true } }
            #expect(states == [.liveTextUnavailable(.modelsNotReady), .notice(.systemAudioSilent), expected], "\(sources)")
            #expect(await source.calls.contains("pause") == (sources == .macAudio))
            // The scripted source reports no detail: the recording still names what it captured.
            #expect(audio.detail?.sources == sources.detailValue && audio.detail?.input == sources.detailInput)
        }
    }

    @Test func aMicrophoneRecordingsDetailIsLeftAsTheMicrophoneReportsIt() {
        let mic = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.builtInMic)
        #expect(FluidLiveRecording.detail(mic, sources: .microphone) == mic)
        #expect(FluidLiveRecording.detail(nil, sources: .microphone) == nil)
        #expect(FluidLiveRecording.detail(mic, sources: .both)?.input == CaptureDetail.Input.builtInMic)
        #expect(FluidLiveRecording.detail(nil, sources: .macAudio)?.input == CaptureDetail.Input.systemAudio)
    }

    @Test func discardingABothRecordingDeletesItsStems() async throws {
        let dir = try TestAudio.temporaryDirectory()
        let url = dir.appendingPathComponent("rec.wav")
        let stems = CaptureStems.beside(audioURL: url)
        let mic = StampedScriptedSource(), system = StampedScriptedSource()
        let request = RecordingRequest(audioURL: url, liveText: false, language: .automatic, sources: .both)
        let recording = FluidLiveRecording(request: request, source: MixedCaptureSource(mic: mic, system: system, stems: stems),
                                           liveModels: { nil }, freeBytes: { _ in 10_000_000_000 })
        try await recording.start()
        await mic.send([Float](repeating: 0.2, count: 1_600), host: 1)
        await system.send([Float](repeating: 0.2, count: 1_600), host: 1)
        #expect(FileManager.default.fileExists(atPath: stems.mic.path))
        await recording.discard()
        for url in [url, stems.mic, stems.system] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }

    #if os(macOS)
    @Test func outputRoutes() {
        let fourCC = SystemOutputRoute.fourCC
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: fourCC("ispk")) == "builtInSpeaker")
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: fourCC("hdpn")) == "headphones")
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == "builtInSpeaker")
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == "bluetooth")
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil) == "bluetooth")
        #expect(SystemOutputRoute.route(transportType: kAudioDeviceTransportTypeHDMI, dataSource: nil) == "other")
        #expect(SystemOutputRoute.route(transportType: nil, dataSource: nil) == "other")
        #expect(fourCC("hdpn") == 0x6864_706E)
    }
    #endif

    @Test func theEngineRecordsMacAudioWithoutTheMicrophoneAndPassesTheStems() async throws {
        let made = Mutex<[(CaptureSources, CaptureStems)]>([])
        let engine = FluidSpeechEngine(modelsRoot: try TestAudio.temporaryDirectory(), captureFactory: { ScriptedCaptureSource() },
                                       sourceFactory: { sources, stems in
                                           made.withLock { $0.append((sources, stems)) }
                                           return ScriptedCaptureSource()
                                       })
        #expect(engine.systemAudioAvailable)
        let url = try TestAudio.temporaryDirectory().appendingPathComponent("r.wav")
        // Mac audio alone never asks for the microphone, whatever this test process's permission is.
        let recording = try await engine.startRecording(RecordingRequest(audioURL: url, liveText: false, language: .automatic,
                                                                         sources: .macAudio))
        _ = try await recording.stop()
        let calls = made.withLock { $0 }
        #expect(calls.count == 1 && calls.first?.0 == .macAudio && calls.first?.1 == CaptureStems.beside(audioURL: url))
    }
}

#if os(macOS)
/// The real Core Audio process tap, for a person at the Mac: `TRANSCRIBE_MAC_AUDIO_LIVE=1 swift test --filter
/// RealMacAudioTests`. It records 2 s of whatever the Mac plays. The first run makes macOS ask the terminal for "System
/// Audio Recording"; if access is refused the tap delivers only silence, which this test reports but does not fail on.
/// Never run by agents or CI.
@Suite("Real Mac audio (gated)", .enabled(if: ProcessInfo.processInfo.environment["TRANSCRIBE_MAC_AUDIO_LIVE"] == "1"))
struct RealMacAudioTests {
    @Test func theTapDeliversAboutTwoSecondsOfAudio() async throws {
        let capture = SystemAudioCapture()
        let log = DeliveryLog()
        try await capture.start(log.sink())
        try await Task.sleep(for: .seconds(2))
        await capture.stop()
        let audio = log.audio
        let detail = await capture.captureDetail()
        print("Mac audio: \(audio.count) samples, peak \(audio.map(abs).max() ?? 0), events \(log.events), " +
              "route \(detail?.outputRoute ?? "?")")
        #expect(audio.count > 24_000 && audio.count < 40_000)
        #expect(detail?.input == CaptureDetail.Input.systemAudio && detail?.sources == CaptureDetail.Sources.system)
    }
}
#endif
