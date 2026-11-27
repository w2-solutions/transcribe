@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Makes and describes the compressed copy of a recording's audio that audio sync moves (decision 2).
public protocol AudioEncoding: Sendable {
    /// Streams a 16 kHz mono WAV into `destination` (never the whole file in memory); describes the result.
    /// Runs off the main actor (implementations are `@concurrent`).
    func encode(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor
    /// Describes a file already in a transfer format (a downloaded copy): format from its extension, size, hash, duration.
    func describe(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor
}

public enum AudioEncodingError: Error, Equatable, Sendable {
    /// The source cannot be opened as audio, or is not 16 kHz mono.
    case unreadable
    /// The file's extension names no transfer format (`AudioFormat(fileExtension:)` is nil).
    case unsupportedFormat
    /// The encoder refused every bit rate, or writing failed.
    case failed(String)
}

/// AAC-LC, 16 kHz, mono, in `.m4a`, through `AVAudioFile(forWriting:)`: 32 kbit/s, falling back to 24 and then
/// 48 kbit/s if the encoder refuses a rate. Reads and writes 32,768 frames at a time. The file is written beside
/// `destination` as `<name>.tmp.<ext>` and renamed when complete, so a failed or cancelled encode leaves nothing at
/// `destination` (and no temporary file).
public struct AACAudioEncoder: AudioEncoding {
    public static let bitRates = [32_000, 24_000, 48_000]
    static let chunkFrames: AVAudioFrameCount = 32_768
    static let sampleRate: Double = 16_000

    public init() {}

    @concurrent
    public func encode(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor {
        try await Self.encodeFile(wav: wav, to: destination, recordingID: recordingID)
    }

    @concurrent
    public func describe(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor {
        try await Self.describeFile(file, recordingID: recordingID)
    }

    @concurrent
    static func encodeFile(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor {
        let fm = FileManager.default
        let ext = destination.pathExtension.isEmpty ? "m4a" : destination.pathExtension
        let temp = destination.deletingPathExtension().appendingPathExtension("tmp").appendingPathExtension(ext)
        try? fm.removeItem(at: temp)
        do {
            let reader: AVAudioFile
            do { reader = try AVAudioFile(forReading: wav) } catch { throw AudioEncodingError.unreadable }
            let format = reader.processingFormat
            guard format.sampleRate == sampleRate, format.channelCount == 1, reader.length > 0 else {
                throw AudioEncodingError.unreadable
            }
            try write(reader, to: temp)
            try Task.checkCancellation()
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
            let (bytes, sha) = try await digest(destination)
            return AudioDescriptor(recordingID: recordingID, format: .aac16kMono, bytes: bytes, sha256: sha,
                                   duration: Double(reader.length) / sampleRate)
        } catch {
            try? fm.removeItem(at: temp)
            try? fm.removeItem(at: destination)
            switch error {
            case is CancellationError, is AudioEncodingError: throw error
            default: throw AudioEncodingError.failed(String(describing: type(of: error)))
            }
        }
    }

    /// Streams `reader` into an AAC file at `url`. The bit-rate fallback applies only while nothing has been
    /// written (the encoder refuses a rate when the file is made or on its first buffer).
    private static func write(_ reader: AVAudioFile, to url: URL) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: chunkFrames) else {
            throw AudioEncodingError.failed("buffer")
        }
        var lastError: (any Error)?
        for rate in bitRates {
            try? FileManager.default.removeItem(at: url)
            reader.framePosition = 0
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: rate]
            let writer: AVAudioFile
            do {
                writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            } catch {
                lastError = error
                continue
            }
            var wroteAny = false
            do {
                while reader.framePosition < reader.length {
                    try Task.checkCancellation()
                    try reader.read(into: buffer, frameCount: chunkFrames)
                    guard buffer.frameLength > 0 else { break }
                    try writer.write(from: buffer)
                    wroteAny = true
                }
                writer.close()
                return
            } catch {
                writer.close()
                if error is CancellationError || wroteAny { throw error }
                lastError = error
            }
        }
        throw AudioEncodingError.failed(lastError.map { String(describing: type(of: $0)) } ?? "no bit rate")
    }

    @concurrent
    static func describeFile(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor {
        guard let format = AudioFormat(fileExtension: file.pathExtension) else { throw AudioEncodingError.unsupportedFormat }
        let duration: Double
        do {
            let audio = try AVAudioFile(forReading: file)
            let rate = audio.processingFormat.sampleRate
            guard rate > 0 else { throw AudioEncodingError.unreadable }
            duration = Double(audio.length) / rate
        } catch let error as AudioEncodingError {
            throw error
        } catch {
            throw AudioEncodingError.unreadable
        }
        let (bytes, sha) = try await digest(file)
        return AudioDescriptor(recordingID: recordingID, format: format, bytes: bytes, sha256: sha, duration: duration)
    }

    private static func digest(_ url: URL) async throws -> (Int64, String) {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return (size?.int64Value ?? 0, try await FileDigest.sha256(of: url))
    }
}

/// SHA-256 of a file, read 1 MB at a time, off the main actor.
public enum FileDigest {
    static let chunkBytes = 1 << 20

    /// Lowercase hex. Throws the read error, or `CancellationError` when the task is cancelled.
    @concurrent public static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return SyncSchema.hex(hasher.finalize())
    }
}
