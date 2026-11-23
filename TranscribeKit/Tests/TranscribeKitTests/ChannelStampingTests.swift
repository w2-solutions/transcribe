import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// `stampCaptureChannels()` (§6.4), the capture channel and detail types (§6.1), and where new rows get their
/// channel from.
@Suite("Capture channels")
@MainActor
struct ChannelStampingTests {
    func channels<T: PersistentModel>(_ h: WP3Harness, _ type: T.Type, _ channel: (T) -> String?) throws -> [String?] {
        try h.context.fetch(FetchDescriptor<T>()).map(channel)
    }

    // MARK: Stamping

    @Test func stampsNilRowsOnce() throws {
        let h = try WP3Harness(channel: CaptureChannel.iphone)
        defer { h.cleanup() }
        try h.seed(.askKaran, stamp: false)
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")   // one negative
        let recordings = try h.count(Recording.self), samples = try h.count(VoiceSample.self)
        let negatives = try h.count(VoiceNegative.self)
        #expect(recordings > 0 && samples > 0 && negatives == 1)
        #expect(try channels(h, Recording.self, \.captureChannel).allSatisfy { $0 == nil })

        #expect(try h.store.stampCaptureChannels() == recordings + samples + negatives)
        #expect(try channels(h, Recording.self, \.captureChannel).allSatisfy { $0 == CaptureChannel.iphone })
        #expect(try channels(h, VoiceSample.self, \.captureChannel).allSatisfy { $0 == CaptureChannel.iphone })
        #expect(try channels(h, VoiceNegative.self, \.captureChannel).allSatisfy { $0 == CaptureChannel.iphone })
        // captureInput stays nil: a backfilled row's route is unknown.
        #expect(try channels(h, VoiceSample.self, \.captureInput).allSatisfy { $0 == nil })
        #expect(try channels(h, VoiceNegative.self, \.captureInput).allSatisfy { $0 == nil })
        #expect(!h.context.hasChanges)

        // Idempotent: nothing left to stamp, and a later launch on another channel relabels nothing.
        #expect(try h.store.stampCaptureChannels() == 0)
        let mac = try WP3Harness(container: h.container, paths: h.paths, channel: CaptureChannel.mac)
        #expect(try mac.store.stampCaptureChannels() == 0)
        #expect(try channels(h, Recording.self, \.captureChannel).allSatisfy { $0 == CaptureChannel.iphone })
    }

    @Test func copiesASampleChannelFromItsSourceRecording() throws {
        let h = try WP3Harness(channel: CaptureChannel.mac)
        defer { h.cleanup() }
        try h.seed(.askKaran, stamp: false)
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        // Recording B was captured on an iPhone; A and the rest have no channel yet.
        try h.recording(Seeds.ID.recordingB).captureChannel = CaptureChannel.iphone
        try h.recording(Seeds.ID.recordingD).captureChannel = CaptureChannel.ipad
        try h.context.save()

        _ = try h.store.stampCaptureChannels()
        let samples = try h.context.fetch(FetchDescriptor<VoiceSample>())
        let fromB = samples.filter { $0.sourceRecordingID == Seeds.ID.recordingB }
        let others = samples.filter { $0.sourceRecordingID != Seeds.ID.recordingB }
        #expect(!fromB.isEmpty && !others.isEmpty)
        #expect(fromB.allSatisfy { $0.captureChannel == CaptureChannel.iphone })
        // Other sources were stamped in the same pass with the local channel, and the samples follow them.
        #expect(others.allSatisfy { $0.captureChannel == CaptureChannel.mac })
        let negative = try #require(try h.context.fetch(FetchDescriptor<VoiceNegative>()).first)
        #expect(negative.sourceRecordingID == Seeds.ID.recordingD && negative.captureChannel == CaptureChannel.ipad)
        #expect(try h.recording(Seeds.ID.recordingB).captureChannel == CaptureChannel.iphone)
        #expect(try h.recording(Seeds.ID.recordingA).captureChannel == CaptureChannel.mac)
    }

    @Test func usesTheLocalChannelWhenTheRecordingIsGone() throws {
        let h = try WP3Harness(channel: CaptureChannel.iphone)
        defer { h.cleanup() }
        try h.seed(.askKaran, stamp: false)
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        for r in try h.context.fetch(FetchDescriptor<Recording>()) { r.captureChannel = CaptureChannel.mac }
        try h.context.save()
        // Deleting recordings keeps the samples and negatives taken from them (plain ids, §5.5).
        try h.store.delete(id: Seeds.ID.recordingB)
        try h.store.delete(id: Seeds.ID.recordingD)
        let orphanSamples = try h.context.fetch(FetchDescriptor<VoiceSample>()).filter { $0.sourceRecordingID == Seeds.ID.recordingB }
        #expect(!orphanSamples.isEmpty)

        _ = try h.store.stampCaptureChannels()
        for s in try h.context.fetch(FetchDescriptor<VoiceSample>()) {
            #expect(s.captureChannel == (s.sourceRecordingID == Seeds.ID.recordingB ? CaptureChannel.iphone : CaptureChannel.mac))
        }
        let negative = try #require(try h.context.fetch(FetchDescriptor<VoiceNegative>()).first)
        #expect(negative.captureChannel == CaptureChannel.iphone)
    }

    @Test func neverDeletesEvenWithAMismatchedStoreDevicePlist() throws {
        let h = try WP3Harness(device: "this-phone")
        defer { h.cleanup() }
        try h.seed(.askKaran, stamp: false)
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        try h.store.writeDeviceID("some-other-device")
        let counts = [try h.count(Recording.self), try h.count(RecordingSpeaker.self), try h.count(VoiceProfile.self),
                      try h.count(VoiceSample.self), try h.count(VoiceNegative.self), try h.count(Folder.self)]
        let vectors = try h.context.fetch(FetchDescriptor<RecordingSpeaker>()).compactMap(\.vectorData)

        #expect(try h.store.stampCaptureChannels() > 0)
        #expect([try h.count(Recording.self), try h.count(RecordingSpeaker.self), try h.count(VoiceProfile.self),
                 try h.count(VoiceSample.self), try h.count(VoiceNegative.self), try h.count(Folder.self)] == counts)
        #expect(try h.context.fetch(FetchDescriptor<RecordingSpeaker>()).compactMap(\.vectorData) == vectors)
        #expect(try h.context.fetch(FetchDescriptor<VoiceProfile>()).allSatisfy { !$0.needsResample })
        #expect(h.store.storedDeviceID() == "some-other-device")   // the plist is never rewritten once present
    }

    // MARK: New rows

    @Test func newRecordingsTakeTheLocalChannelAndKeepTheirDetail() throws {
        let h = try WP3Harness(channel: CaptureChannel.mac)
        defer { h.cleanup() }
        let id = UUID()
        try h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: "x.wav", source: .imported)
        #expect(try h.recording(id).captureChannel == CaptureChannel.mac)
        let detail = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.imported)
        try h.store.finishCapture(id: id, audio: CapturedAudio(url: h.paths.audioURL(fileName: "x.wav"), duration: 3,
                                                               marks: [], peaks: [], detail: detail), language: .automatic)
        let r = try h.recording(id)
        #expect(r.captureChannel == CaptureChannel.mac && CaptureDetail.decode(r.captureDetailJSON) == detail)
        #expect(try h.store.stampCaptureChannels() == 0)

        // No detail (an older capture path) leaves the JSON empty.
        let bare = try h.queuedRecording()
        #expect(try h.recording(bare).captureDetailJSON == nil && h.recording(bare).captureChannel == CaptureChannel.mac)
    }

    @Test func theLaunchConfigChannelStampsTheWholeStore() async throws {
        let env = [LaunchConfig.envChannel: "mac", LaunchConfig.envSeed: SeedName.library.rawValue, "TRANSCRIBE_SPEED": "instant"]
        let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting], environment: env)
        #expect(config.channel == CaptureChannel.mac)
        let engine = FakeSpeechEngine(config: config, script: FakeScript.named(config.script))
        let app = try AppEnvironment(config: config, engine: engine, background: NoopBackgroundTaskBridge(),
                                     deviceIdentity: FixedDeviceIdentity("ui-test"), seeder: Seeds.apply)
        defer { try? FileManager.default.removeItem(at: app.paths.root) }
        await app.onLaunch()
        #expect(app.launchError == nil)
        let context = app.container.mainContext
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(!recordings.isEmpty && recordings.allSatisfy { $0.captureChannel == CaptureChannel.mac })
        #expect(try context.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == CaptureChannel.mac })
    }

    // MARK: Types

    @Test func launchConfigReadsTheChannelOnlyForFakesAndUITests() {
        let env = [LaunchConfig.envChannel: " Mac "]
        #expect(LaunchConfig(arguments: ["-useFakeEngine"], environment: env).channel == "mac")
        #expect(LaunchConfig(arguments: ["-uiTesting"], environment: env).channel == "mac")
        #expect(LaunchConfig(arguments: [], environment: env).channel == nil)
        #expect(LaunchConfig(arguments: ["-useFakeEngine"], environment: [:]).channel == nil)
        #expect(LaunchConfig(arguments: ["-useFakeEngine"], environment: [LaunchConfig.envChannel: ""]).channel == nil)
    }

    @Test func captureChannelIsTheDeviceClass() {
        // `swift test` runs on a Mac host.
        #expect(CaptureChannel.current == CaptureChannel.mac)
        #expect(CaptureChannel.channel(forHardwareModel: "iPad14,1") == CaptureChannel.mac)
        #expect(!CaptureChannel.hardwareModel.isEmpty && CaptureChannel.hardwareModel != "unknown")
        #expect([CaptureChannel.iphone, CaptureChannel.ipad, CaptureChannel.mac] == ["iphone", "ipad", "mac"])
    }

    @Test func captureDetailRoundTripsAsJSON() {
        let full = CaptureDetail(hardwareModel: "iPhone15,4", input: CaptureDetail.Input.bluetoothHFP, inputName: "AirPods",
                                 inputModelUID: "00:11:22", routeChanged: true)
        #expect(CaptureDetail.decode(full.json()) == full)
        let sparse = CaptureDetail(hardwareModel: "Mac15,3", input: nil)
        #expect(CaptureDetail.decode(sparse.json()) == sparse && sparse.routeChanged == false)
        #expect(full.json() == full.json())   // deterministic (sorted keys)
        #expect(CaptureDetail.decode(nil) == nil && CaptureDetail.decode("") == nil && CaptureDetail.decode("not json") == nil)
    }

    @Test func importedAudioIsMarkedImported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("in.wav"), destination = root.appendingPathComponent("out.wav")
        _ = try SyntheticAudio.write(to: source, duration: 2, segments: [(TimeRange(start: 0, end: 2), .liam)])
        let audio = try await AudioImporter.importAudio(from: source, to: destination)
        #expect(audio.detail?.input == CaptureDetail.Input.imported)
        #expect(audio.detail?.hardwareModel == CaptureChannel.hardwareModel && audio.detail?.routeChanged == false)
    }

    @Test func fakeCapturesAreMarkedFake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = RecordingRequest(audioURL: root.appendingPathComponent("f.wav"), liveText: false, language: .automatic)
        let session = FakeLiveRecording(script: FakeScript.named(.newVoices), speed: .instant, request: request)
        let audio = try await session.stop()
        #expect(audio.detail?.input == CaptureDetail.Input.fake)
    }
}
