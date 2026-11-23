import Foundation

/// Errors from reading or repairing the app's PCM WAV files.
public enum WAVFormatError: Error, Sendable, Equatable {
    /// The file is shorter than a WAV header.
    case tooShort
    /// The file has no RIFF/WAVE header.
    case notWAV
    /// The header describes something other than 16-bit integer PCM (or, for repair, the 44-byte mono layout).
    case unsupported(String)
}

/// The parts of a RIFF/WAVE header the app needs: format, where the samples start and how many bytes there are.
struct WAVHeaderInfo: Equatable {
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int
    /// Byte offset of the first sample.
    var dataOffset: Int
    /// Sample bytes available, whole frames only. Uses the file length when the header's size is
    /// stale (0, larger than the file, or the 0xFFFFFFFF streaming marker).
    var dataBytes: Int

    var blockAlign: Int { channels * bitsPerSample / 8 }
    var frameCount: Int { blockAlign > 0 ? dataBytes / blockAlign : 0 }

    static let canonicalSize = 44

    /// Parses the header of 16-bit integer PCM WAV at `url`, walking chunks until `data`.
    static func read(_ url: URL) throws -> WAVHeaderInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = [UInt8](try handle.read(upToCount: Swift.min(fileSize, 64 * 1024)) ?? Data())
        guard head.count >= 12 else { throw WAVFormatError.tooShort }
        guard tag(head, 0) == "RIFF", tag(head, 8) == "WAVE" else { throw WAVFormatError.notWAV }

        var format: (code: Int, channels: Int, rate: Int, bits: Int)?
        var offset = 12
        while offset + 8 <= head.count {
            let id = tag(head, offset)
            let size = Int(le32(head, offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= head.count else { throw WAVFormatError.unsupported("Short fmt chunk") }
                format = (Int(le16(head, body)), Int(le16(head, body + 2)), Int(le32(head, body + 4)), Int(le16(head, body + 14)))
            } else if id == "data" {
                guard let f = format else { throw WAVFormatError.unsupported("data chunk before fmt chunk") }
                // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (assumed integer PCM when 16-bit).
                guard f.code == 1 || f.code == 0xFFFE, f.bits == 16, f.channels >= 1, f.rate > 0 else {
                    throw WAVFormatError.unsupported("format \(f.code), \(f.bits)-bit, \(f.channels) ch")
                }
                let available = Swift.max(0, fileSize - body)
                let declared = size == 0 || size == Int(UInt32.max) || size > available ? available : size
                let align = f.channels * 2
                return WAVHeaderInfo(sampleRate: f.rate, channels: f.channels, bitsPerSample: 16,
                                     dataOffset: body, dataBytes: declared - declared % align)
            }
            offset = body + size + (size & 1)
        }
        throw format == nil ? WAVFormatError.notWAV : WAVFormatError.unsupported("No data chunk")
    }

    static func tag(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
    static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
