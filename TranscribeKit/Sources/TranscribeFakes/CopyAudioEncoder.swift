import Foundation
import TranscribeKit

/// An encoder for tests and the fake engine: copies the WAV as it is (format `pcm16kMono`, the real SHA-256), so a
/// receiver stores `Audio/<id>.wav`. Fast, no AVFoundation, and works on the 4-byte "RIFF" stubs sync tests write.
public struct CopyAudioEncoder: AudioEncoding {
    public init() {}

    public func encode(wav: URL, to destination: URL, recordingID: UUID) async throws -> AudioDescriptor {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: wav, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw AudioEncodingError.unreadable
        }
        return try await describe(destination, recordingID: recordingID, format: .pcm16kMono)
    }

    /// The format is `pcm16kMono` for WAV bytes ("RIFF"), whatever the file is called (`encode` writes them to the
    /// `.m4a` name `AudioSync` gives); otherwise it follows the extension.
    public func describe(_ file: URL, recordingID: UUID) async throws -> AudioDescriptor {
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4)
        }
        let format: AudioFormat
        if head == Data("RIFF".utf8) {
            format = .pcm16kMono
        } else if let byName = AudioFormat(fileExtension: file.pathExtension) {
            format = byName
        } else {
            throw AudioEncodingError.unsupportedFormat
        }
        return try await describe(file, recordingID: recordingID, format: format)
    }

    /// Duration from the size: 16 kHz, 16-bit mono after a 44-byte header (0 for a stub).
    private func describe(_ file: URL, recordingID: UUID, format: AudioFormat) async throws -> AudioDescriptor {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber else {
            throw AudioEncodingError.unreadable
        }
        let bytes = size.int64Value
        let sha = try await FileDigest.sha256(of: file)
        return AudioDescriptor(recordingID: recordingID, format: format, bytes: bytes, sha256: sha,
                               duration: max(0, Double(bytes - 44)) / 32_000)
    }
}
