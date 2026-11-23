import AVFoundation
import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

@Suite("AudioImporter")
final class AudioImporterTests {
    let dir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Writes a 440 Hz sine of `amplitude` to every channel with AVAudioFile.
    func makeSource(_ name: String, settings: [String: Any], sampleRate: Double, channels: AVAudioChannelCount,
                    seconds: Double, amplitude: Float = 0.5, channelAmplitudes: [Float]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            let a = channelAmplitudes?[c] ?? amplitude
            for i in 0..<Int(frames) { data[i] = a * Float(sin(2 * .pi * 440 * Double(i) / sampleRate)) }
        }
        try file.write(from: buffer)
        return url
    }

    func header(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url).prefix(44)) }
    func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }

    /// The output is a canonical 16 kHz mono Int16 WAV whose header matches its length.
    func expectCanonical(_ url: URL, duration: TimeInterval) throws {
        let h = try header(url)
        #expect(String(decoding: h[0..<4], as: UTF8.self) == "RIFF")
        #expect(le16(h, 20) == 1 && le16(h, 22) == 1 && le32(h, 24) == 16_000 && le16(h, 34) == 16)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(Int(le32(h, 40)) == size - 44)
        #expect(abs(Double(size - 44) / 2 / 16_000 - duration) < 1e-9)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition((size - 44) / 2))
    }

    @Test func converts44kStereoWAV() async throws {
        let source = try makeSource("stereo.wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], sampleRate: 44_100, channels: 2, seconds: 2)
        let destination = dir.appendingPathComponent("out/stereo-16k.wav")

        let captured = try await AudioImporter.importAudio(from: source, to: destination)

        #expect(captured.url == destination)
        #expect(abs(captured.duration - 2.0) < 0.01, "duration \(captured.duration)")
        #expect(captured.marks.isEmpty)
        #expect(captured.peaks.count == 200)
        // Identical channels average to the same 0.5 sine; the resampler may ring slightly.
        #expect(captured.peaks.allSatisfy { abs($0 - 0.5) < 0.03 }, "\(captured.peaks.min() ?? 0)...\(captured.peaks.max() ?? 0)")
        try expectCanonical(destination, duration: captured.duration)
    }

    @Test func downmixesChannelsByAveraging() async throws {
        // Left 0.6 sine, right silent → mono 0.3.
        let url = try makeSource("left-only.wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ], sampleRate: 16_000, channels: 2, seconds: 1, channelAmplitudes: [0.6, 0])
        let destination = dir.appendingPathComponent("left-only-16k.wav")

        let captured = try await AudioImporter.importAudio(from: url, to: destination)

        #expect(abs(captured.duration - 1.0) < 1e-9, "same rate: no resampling, exact length")
        #expect(captured.peaks.allSatisfy { abs($0 - 0.3) < 0.002 })
        try expectCanonical(destination, duration: captured.duration)
    }

    @Test func convertsM4A() async throws {
        let source = try makeSource("speech.m4a", settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ], sampleRate: 44_100, channels: 2, seconds: 1.5)
        let destination = dir.appendingPathComponent("speech-16k.wav")

        let captured = try await AudioImporter.importAudio(from: source, to: destination)

        #expect(abs(captured.duration - 1.5) < 0.1, "duration \(captured.duration)")
        #expect(captured.peaks.count == 200)
        #expect((captured.peaks.max() ?? 0) > 0.3)
        try expectCanonical(destination, duration: captured.duration)
    }

    @Test func rejectsFilesOverThreeHours() async throws {
        // A 100 Hz mono WAV of 3 h 0 min 10 s is only ~2 MB but is over the limit.
        let source = dir.appendingPathComponent("long.wav")
        let frames = 10_810 * 100
        try (WAVFileWriter.header(dataBytes: frames * 2, sampleRate: 100) + Data(count: frames * 2)).write(to: source)
        let destination = dir.appendingPathComponent("long-16k.wav")

        await #expect(throws: AudioImportError.tooLong(10_810)) {
            try await AudioImporter.importAudio(from: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(AudioImporter.maxDuration == 3 * 3600)
    }

    @Test func limitIsInclusiveAndChecked() throws {
        let source = try makeSource("two.wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], sampleRate: 22_050, channels: 1, seconds: 2)
        let destination = dir.appendingPathComponent("two-16k.wav")
        #expect(throws: AudioImportError.tooLong(2)) {
            try AudioImporter.convert(from: source, to: destination, maxDuration: 1.99)
        }
        let captured = try AudioImporter.convert(from: source, to: destination, maxDuration: 2)
        #expect(abs(captured.duration - 2) < 0.01)
    }

    @Test func unreadableFileThrows() async throws {
        let source = dir.appendingPathComponent("notes.m4a")
        try Data("definitely not audio".utf8).write(to: source)
        let destination = dir.appendingPathComponent("notes-16k.wav")
        await #expect(throws: AudioImportError.unreadable) {
            try await AudioImporter.importAudio(from: source, to: destination)
        }
        await #expect(throws: AudioImportError.unreadable) {
            try await AudioImporter.importAudio(from: dir.appendingPathComponent("missing.wav"), to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellationRemovesThePartialFile() async throws {
        let source = try makeSource("cancel.wav", settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], sampleRate: 48_000, channels: 1, seconds: 1)
        let destination = dir.appendingPathComponent("cancel-16k.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioImporter.importAudio(from: source, to: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
