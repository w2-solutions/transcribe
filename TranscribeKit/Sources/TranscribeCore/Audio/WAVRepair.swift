import Foundation

public enum WAVRepair {
    /// Patches RIFF/data sizes of a 44-byte-header 16 kHz mono Int16 WAV from the file length
    /// (truncating a partial frame). Returns the resulting duration in seconds.
    ///
    /// A header that is entirely zero (never synced before a crash) is rewritten as the canonical
    /// 16 kHz header. Any other header must already be 16-bit mono PCM with `data` at byte 36, otherwise
    /// `WAVFormatError` is thrown and the file is left untouched.
    public static func repairHeader(at url: URL) throws -> TimeInterval {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        guard fileSize >= WAVHeaderInfo.canonicalSize else { throw WAVFormatError.tooShort }
        try handle.seek(toOffset: 0)
        let header = [UInt8](try handle.read(upToCount: WAVHeaderInfo.canonicalSize) ?? Data())
        guard header.count == WAVHeaderInfo.canonicalSize else { throw WAVFormatError.tooShort }

        let dataBytes = (fileSize - WAVHeaderInfo.canonicalSize) & ~1
        let sampleRate: Int
        if header.allSatisfy({ $0 == 0 }) {
            sampleRate = 16_000
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAVFileWriter.header(dataBytes: dataBytes, sampleRate: sampleRate))
        } else {
            sampleRate = try validatedSampleRate(header)
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: le32(UInt32(truncatingIfNeeded: dataBytes)))
        }
        if WAVHeaderInfo.canonicalSize + dataBytes != fileSize {
            try handle.truncate(atOffset: UInt64(WAVHeaderInfo.canonicalSize + dataBytes))
        }
        try handle.synchronize()
        return Double(dataBytes / 2) / Double(sampleRate)
    }

    /// Checks the 44-byte canonical layout written by `WAVFileWriter` and returns its sample rate.
    static func validatedSampleRate(_ h: [UInt8]) throws -> Int {
        guard WAVHeaderInfo.tag(h, 0) == "RIFF", WAVHeaderInfo.tag(h, 8) == "WAVE" else { throw WAVFormatError.notWAV }
        guard WAVHeaderInfo.tag(h, 12) == "fmt ", WAVHeaderInfo.le32(h, 16) == 16, WAVHeaderInfo.tag(h, 36) == "data" else {
            throw WAVFormatError.unsupported("Not a 44-byte PCM header")
        }
        let code = WAVHeaderInfo.le16(h, 20), channels = WAVHeaderInfo.le16(h, 22)
        let rate = Int(WAVHeaderInfo.le32(h, 24)), bits = WAVHeaderInfo.le16(h, 34)
        guard code == 1, channels == 1, bits == 16, rate > 0 else {
            throw WAVFormatError.unsupported("format \(code), \(bits)-bit, \(channels) ch")
        }
        return rate
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
