import AVFoundation
import Foundation
import Testing
@testable import TranscribeCore

@Suite("WAVRepair")
struct WAVRepairTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
    }

    /// Simulates a crash: samples written, header sizes never patched (still 0), plus a stray half frame.
    func crashedFile(frames: Int, extraBytes: [UInt8] = [0x7F]) throws -> URL {
        let url = tempURL()
        do {
            let writer = try WAVFileWriter(url: url)
            try writer.append((0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.5 })
            // No flushHeader() / finish(): the writer is dropped as if the process died.
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extraBytes))
        try handle.close()
        return url
    }

    func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
    func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    @Test func repairsZeroSizesAndTruncatesPartialFrame() throws {
        let url = try crashedFile(frames: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try bytes(url)
        #expect(before.count == 44 + 48_000 + 1)
        #expect(le32(before, 4) == 36 && le32(before, 40) == 0)

        let duration = try WAVRepair.repairHeader(at: url)
        #expect(abs(duration - 1.5) < 1e-9)

        let after = try bytes(url)
        #expect(after.count == 44 + 48_000)
        #expect(le32(after, 4) == 36 + 48_000)
        #expect(le32(after, 40) == 48_000)
        #expect(after[44...] == before[44..<(44 + 48_000)], "samples untouched")

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 24_000)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
    }

    @Test func repairIsIdempotent() throws {
        let url = try crashedFile(frames: 1_600, extraBytes: [])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(abs(try WAVRepair.repairHeader(at: url) - 0.1) < 1e-9)
        let once = try bytes(url)
        #expect(abs(try WAVRepair.repairHeader(at: url) - 0.1) < 1e-9)
        #expect(try bytes(url) == once)
    }

    @Test func staleNonZeroSizesArePatched() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try WAVFileWriter(url: url)
            try writer.append([Float](repeating: 0.1, count: 16_000))
            try writer.flushHeader()                       // header says 1 s
            try writer.append([Float](repeating: 0.1, count: 8_000))   // tail after the last flush
        }
        #expect(le32(try bytes(url), 40) == 32_000)
        #expect(abs(try WAVRepair.repairHeader(at: url) - 1.5) < 1e-9)
        #expect(le32(try bytes(url), 40) == 48_000)
    }

    @Test func zeroedHeaderIsRewritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 44 + 3_200 + 1).write(to: url)
        #expect(abs(try WAVRepair.repairHeader(at: url) - 0.1) < 1e-9)
        let after = try bytes(url)
        #expect(Data(after[0..<44]) == WAVFileWriter.header(dataBytes: 3_200, sampleRate: 16_000))
        #expect(after.count == 44 + 3_200)
    }

    @Test func headerOnlyFileHasZeroDuration() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVFileWriter.header(dataBytes: 999, sampleRate: 16_000).write(to: url)
        #expect(try WAVRepair.repairHeader(at: url) == 0)
        #expect(le32(try bytes(url), 40) == 0)
    }

    @Test func rejectsFilesItCannotRepair() throws {
        let short = tempURL(), text = tempURL(), stereo = tempURL()
        defer { for u in [short, text, stereo] { try? FileManager.default.removeItem(at: u) } }
        try Data([1, 2, 3]).write(to: short)
        #expect(throws: WAVFormatError.tooShort) { try WAVRepair.repairHeader(at: short) }

        try Data(String(repeating: "not a wav file ", count: 10).utf8).write(to: text)
        #expect(throws: WAVFormatError.notWAV) { try WAVRepair.repairHeader(at: text) }

        var header = [UInt8](WAVFileWriter.header(dataBytes: 0, sampleRate: 16_000))
        header[22] = 2   // two channels
        try Data(header + [UInt8](repeating: 0, count: 400)).write(to: stereo)
        #expect(throws: WAVFormatError.self) { try WAVRepair.repairHeader(at: stereo) }
        #expect(try bytes(stereo).count == 444, "left untouched")

        #expect(throws: (any Error).self) { try WAVRepair.repairHeader(at: tempURL()) }   // missing file
    }
}
