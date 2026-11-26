@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The AAC copy audio sync uploads, with real AVFoundation on the Mac (decision 2): 16 kHz mono AAC-LC in `.m4a`, about
/// 4 kB a second, the same duration and the same timing as the WAV, described by size, SHA-256 and duration.
@Suite("Audio encoder")
struct AudioEncoderTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-encoder-\(UUID().uuidString)",
                                                                               isDirectory: true)
    let id = UUID()

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// Speech-like synthetic audio, all `duration` long (two people taking turns).
    func speechWAV(_ duration: TimeInterval, name: String = "source.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let half = duration / 2
        _ = try SyntheticAudio.write(to: url, duration: duration,
                                     segments: [(TimeRange(start: 0, end: half), .liam), (TimeRange(start: half, end: duration), .karan)])
        return url
    }

    /// Silence with a 20 ms, 1 kHz burst starting at each of `onsets`.
    func burstWAV(_ duration: TimeInterval, onsets: [TimeInterval]) throws -> URL {
        let url = dir.appendingPathComponent("bursts.wav")
        let rate = 16_000
        var samples = [Float](repeating: 0, count: Int(duration * Double(rate)))
        for onset in onsets {
            let start = Int((onset * Double(rate)).rounded())
            for i in 0..<(rate / 50) where start + i < samples.count {
                samples[start + i] = Float(0.8 * sin(2 * .pi * 1_000 * Double(i) / Double(rate)))
            }
        }
        let writer = try WAVFileWriter(url: url, sampleRate: rate)
        try writer.append(samples)
        try writer.finish()
        return url
    }

    /// Every sample of a file, decoded to Float.
    func decode(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return (Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    var destination: URL { dir.appendingPathComponent("\(id.uuidString).m4a") }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp") }
    }

    @Test func encodesSixteenKilohertzMonoAAC() async throws {
        defer { cleanup() }
        let d = try await AACAudioEncoder().encode(wav: try speechWAV(10), to: destination, recordingID: id)
        #expect(d.format == .aac16kMono)
        #expect(d.recordingID == id)
        let file = try AVAudioFile(forReading: destination)
        #expect(file.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(try leftovers().isEmpty)
    }

    @Test func sizeIsAboutFourKilobytesPerSecond() async throws {
        defer { cleanup() }
        let d = try await AACAudioEncoder().encode(wav: try speechWAV(60), to: destination, recordingID: id)
        let expected = 60 * AudioPolicy.bytesPerSecondEstimate
        #expect(abs(Double(d.bytes) - expected) <= 0.15 * expected, "\(d.bytes) bytes for 60 s")
        // A quarter of the WAV's size or less, by far (the WAV is 32,000 bytes a second).
        #expect(d.bytes < 60 * 32_000 / 4)
    }

    @Test func durationMatches() async throws {
        defer { cleanup() }
        let d = try await AACAudioEncoder().encode(wav: try speechWAV(37.3), to: destination, recordingID: id)
        #expect(abs(d.duration - 37.3) <= 0.001)
        let decoded = try decode(destination)
        #expect(decoded.rate == 16_000)
        #expect(abs(Double(decoded.samples.count) / decoded.rate - 37.3) <= 0.05)
    }

    @Test func onsetsLineUp() async throws {
        defer { cleanup() }
        let onsets: [TimeInterval] = [1.000, 7.250, 31.500]
        _ = try await AACAudioEncoder().encode(wav: try burstWAV(34, onsets: onsets), to: destination, recordingID: id)
        let (samples, rate) = try decode(destination)
        for onset in onsets {
            // The first loud sample within 100 ms either side of where the burst starts.
            let from = Int((onset - 0.1) * rate), to = Int((onset + 0.1) * rate)
            let first = try #require((from..<to).first { abs(samples[$0]) > 0.2 }, "no burst near \(onset) s")
            #expect(abs(Double(first) / rate - onset) <= 0.015, "burst at \(onset) s found at \(Double(first) / rate) s")
        }
    }

    @Test func digestAndBytesDescribeTheFile() async throws {
        defer { cleanup() }
        let d = try await AACAudioEncoder().encode(wav: try speechWAV(5), to: destination, recordingID: id)
        let data = try Data(contentsOf: destination)
        #expect(d.bytes == Int64(data.count))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(d.sha256 == sha)
        #expect(d.sha256.count == 64 && d.sha256 == d.sha256.lowercased())
    }

    @Test func aFailedEncodeLeavesNoFile() async throws {
        defer { cleanup() }
        let encoder = AACAudioEncoder()
        // Not audio.
        let junk = dir.appendingPathComponent("junk.wav")
        try Data("this is not a wav file".utf8).write(to: junk)
        await #expect(throws: AudioEncodingError.unreadable) {
            try await encoder.encode(wav: junk, to: destination, recordingID: id)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // Missing.
        await #expect(throws: AudioEncodingError.unreadable) {
            try await encoder.encode(wav: dir.appendingPathComponent("missing.wav"), to: destination, recordingID: id)
        }
        // Not 16 kHz.
        let other = dir.appendingPathComponent("44k.wav")
        let writer = try WAVFileWriter(url: other, sampleRate: 44_100)
        try writer.append([Float](repeating: 0.1, count: 44_100))
        try writer.finish()
        await #expect(throws: AudioEncodingError.unreadable) {
            try await encoder.encode(wav: other, to: destination, recordingID: id)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // Cancelled: nothing at the destination and no temporary file.
        let source = try speechWAV(30)
        let destination = self.destination, id = self.id
        let task = Task { () async throws -> AudioDescriptor in
            while !Task.isCancelled { await Task.yield() }
            return try await encoder.encode(wav: source, to: destination, recordingID: id)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try leftovers().isEmpty)
    }

    @Test func describeReadsADownloadedCopy() async throws {
        defer { cleanup() }
        let encoder = AACAudioEncoder()
        let source = try speechWAV(12)
        let encoded = try await encoder.encode(wav: source, to: destination, recordingID: id)
        // The copy another device downloaded: the same bytes under Audio/<id>.m4a.
        let copy = dir.appendingPathComponent("copy").appendingPathComponent("\(id.uuidString).m4a")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: destination, to: copy)
        let described = try await encoder.describe(copy, recordingID: id)
        #expect(described.format == .aac16kMono)
        #expect(described.bytes == encoded.bytes)
        #expect(described.sha256 == encoded.sha256)
        #expect(abs(described.duration - encoded.duration) <= 0.05)
        // A WAV copy describes as PCM with its exact duration.
        let wav = try await encoder.describe(source, recordingID: id)
        #expect(wav.format == .pcm16kMono)
        #expect(abs(wav.duration - 12) <= 0.001)
        #expect(wav.bytes == Int64(try Data(contentsOf: source).count))
        // No transfer format.
        let text = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        await #expect(throws: AudioEncodingError.unsupportedFormat) { try await encoder.describe(text, recordingID: id) }
    }

    @Test func fileDigestIsTheSHA256() async throws {
        defer { cleanup() }
        let abc = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        #expect(try await FileDigest.sha256(of: abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try await FileDigest.sha256(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Several 1 MB chunks give the one-shot hash.
        let big = dir.appendingPathComponent("big")
        let data = Data((0..<(3 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: big)
        #expect(try await FileDigest.sha256(of: big) == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        await #expect(throws: (any Error).self) { try await FileDigest.sha256(of: dir.appendingPathComponent("missing")) }
    }

    @Test func theCopyEncoderKeepsTheWAV() async throws {
        defer { cleanup() }
        let source = try speechWAV(3)
        let d = try await CopyAudioEncoder().encode(wav: source, to: destination, recordingID: id)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(d.format == .pcm16kMono)
        #expect(d.bytes == Int64(try Data(contentsOf: source).count))
        #expect(d.sha256 == SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined())
        #expect(abs(d.duration - 3) <= 0.001)
        // Its .m4a-named output still describes as WAV bytes; a 4-byte stub describes too.
        #expect(try await CopyAudioEncoder().describe(destination, recordingID: id) == d)
        let stub = dir.appendingPathComponent("stub.wav")
        try Data("RIFF".utf8).write(to: stub)
        let s = try await CopyAudioEncoder().encode(wav: stub, to: dir.appendingPathComponent("stub-out.m4a"), recordingID: id)
        #expect(s.bytes == 4 && s.duration == 0 && s.format == .pcm16kMono)
    }
}
