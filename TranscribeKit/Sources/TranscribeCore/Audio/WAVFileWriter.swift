import Foundation

/// Writes 16 kHz mono 16-bit little-endian PCM WAV with a 44-byte header.
/// Sizes are patched on every flushHeader() and on finish(), so a crash loses at most the unflushed tail.
/// Not Sendable: always own a writer from a single actor.
public final class WAVFileWriter {
    public let url: URL
    public let sampleRate: Int
    public private(set) var framesWritten: Int = 0
    private let handle: FileHandle
    private var isFinished = false

    static let headerSize = 44
    static let bytesPerFrame = 2

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: WAVFileWriter.header(dataBytes: 0, sampleRate: sampleRate)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    /// Clamps to -1...1 and converts to Int16.
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        precondition(!isFinished, "WAVFileWriter: append after finish")
        let bytes = [UInt8](unsafeUninitializedCapacity: samples.count * WAVFileWriter.bytesPerFrame) { dst, initialised in
            samples.withUnsafeBufferPointer { src in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for i in 0..<src.count {
                    let x = s[i]
                    let c = x.isFinite ? Swift.min(1, Swift.max(-1, x)) : 0
                    let v = UInt16(bitPattern: Int16((c * 32767).rounded()))
                    d[2 * i] = UInt8(truncatingIfNeeded: v); d[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            }
            initialised = samples.count * WAVFileWriter.bytesPerFrame
        }
        try handle.write(contentsOf: bytes)
        framesWritten += samples.count
    }

    /// Patches sizes + synchronize(); call ~every 5 s.
    public func flushHeader() throws {
        try patchSizes()
        try handle.synchronize()
    }

    /// Patches, closes; returns duration.
    @discardableResult public func finish() throws -> TimeInterval {
        guard !isFinished else { return duration }
        try patchSizes()
        try handle.synchronize()
        try handle.close()
        isFinished = true
        return duration
    }

    public var duration: TimeInterval { Double(framesWritten) / Double(sampleRate) }

    private func patchSizes() throws {
        let dataBytes = framesWritten * WAVFileWriter.bytesPerFrame
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WAVFileWriter.le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WAVFileWriter.le32(UInt32(truncatingIfNeeded: dataBytes)))
        try handle.seekToEnd()
    }

    /// The canonical 44-byte header for 16-bit mono PCM.
    public static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))                                   // fmt chunk size
        d.append(le16(1))                                    // PCM
        d.append(le16(1))                                    // mono
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(sampleRate * bytesPerFrame)))   // byte rate
        d.append(le16(UInt16(bytesPerFrame)))                // block align
        d.append(le16(16))                                   // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(UInt32(truncatingIfNeeded: dataBytes)))
        return d
    }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
