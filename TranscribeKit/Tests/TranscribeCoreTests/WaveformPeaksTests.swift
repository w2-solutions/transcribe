import Foundation
import Testing
@testable import TranscribeCore

@Suite("WaveformPeaks")
struct WaveformPeaksTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString).wav")
    }

    /// A 440 Hz sine whose amplitude is `amplitude(t)`, written through WAVFileWriter.
    func writeSine(seconds: Double, finish: Bool = true, amplitude: (Double) -> Double) throws -> URL {
        let url = tempURL()
        let writer = try WAVFileWriter(url: url)
        let frames = Int(seconds * 16_000)
        try writer.append((0..<frames).map { i in
            let t = Double(i) / 16_000
            return Float(amplitude(t) * sin(2 * .pi * 440 * t))
        })
        if finish { try writer.finish() }
        return url
    }

    @Test func knownSineGivesItsAmplitude() throws {
        let url = try writeSine(seconds: 2) { _ in 0.5 }
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try WaveformPeaks.peaks(ofWAV: url, bins: 20)
        #expect(peaks.count == 20)
        #expect(peaks.allSatisfy { abs($0 - 0.5) < 0.002 }, "\(peaks)")
    }

    @Test func peaksFollowTheEnvelope() throws {
        // 0.25 for the first second, 0.75 for the second, silence for the third.
        let url = try writeSine(seconds: 3) { t in t < 1 ? 0.25 : (t < 2 ? 0.75 : 0) }
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try WaveformPeaks.peaks(ofWAV: url, bins: 6)
        let expected: [Float] = [0.25, 0.25, 0.75, 0.75, 0, 0]
        #expect(zip(peaks, expected).allSatisfy { abs($0 - $1) < 0.002 }, "\(peaks)")
    }

    @Test func fullScaleIsOneAndStaleHeaderStillReadsEverySample() throws {
        // Not finished: the header's data size is still 0, so the file length is used.
        let url = try writeSine(seconds: 1, finish: false) { t in t > 0.9 ? 1.0 : 0.1 }
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try WaveformPeaks.peaks(ofWAV: url, bins: 10)
        #expect(abs(peaks[9] - 1) < 1e-4)
        #expect(peaks[0..<9].allSatisfy { abs($0 - 0.1) < 0.002 })
    }

    @Test func fewerFramesThanBinsLeavesEmptyBinsAtZero() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append([0.5, -0.5, 0.25])
        try writer.finish()
        let peaks = try WaveformPeaks.peaks(ofWAV: url, bins: 6)
        #expect(peaks.count == 6)
        #expect(peaks.filter { $0 > 0 }.count == 3)
        #expect(abs((peaks.max() ?? 0) - 0.5) < 1e-3)
    }

    @Test func emptyFileAndZeroBins() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVFileWriter(url: url).finish()
        #expect(try WaveformPeaks.peaks(ofWAV: url, bins: 4) == [0, 0, 0, 0])
        #expect(try WaveformPeaks.peaks(ofWAV: url, bins: 0) == [])
    }

    @Test func rejectsNonWAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(String(repeating: "x", count: 100).utf8).write(to: url)
        #expect(throws: WAVFormatError.notWAV) { try WaveformPeaks.peaks(ofWAV: url, bins: 4) }
    }

    // MARK: resample

    @Test func resampleDownMaxPools() {
        #expect(WaveformPeaks.resample([0.1, 0.9, 0.2, 0.3], to: 2) == [0.9, 0.3])
        #expect(WaveformPeaks.resample([0.1, 0.9, 0.2, 0.3, 0.5], to: 2) == [0.9, 0.5])
        #expect(WaveformPeaks.resample([0.1, 0.9, 0.2], to: 1) == [0.9])
    }

    @Test func resampleUpStretchesLinearly() {
        #expect(WaveformPeaks.resample([0, 1], to: 3) == [0, 0.5, 1])
        let five = WaveformPeaks.resample([0, 1, 0], to: 5)
        #expect(zip(five, [0, 0.5, 1, 0.5, 0] as [Float]).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(WaveformPeaks.resample([0.4], to: 3) == [0.4, 0.4, 0.4])
    }

    @Test func resampleEdgeCases() {
        let peaks: [Float] = [0.1, 0.2, 0.3]
        #expect(WaveformPeaks.resample(peaks, to: 3) == peaks)
        #expect(WaveformPeaks.resample(peaks, to: 0) == [])
        #expect(WaveformPeaks.resample([], to: 2) == [0, 0])
        let many = (0..<200).map { Float($0) / 199 }
        let down = WaveformPeaks.resample(many, to: 56)
        #expect(down.count == 56 && down.last == 1)
    }
}
