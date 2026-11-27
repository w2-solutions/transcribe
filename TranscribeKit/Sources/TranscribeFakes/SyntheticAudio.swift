import Foundation
import TranscribeCore

public enum SyntheticAudio {
    public static let sampleRate = 16_000
    public static let peakBins = 200

    /// 16 kHz mono Int16 WAV via WAVFileWriter. Inside each segment: sine at the person's pitch (liam 180 Hz,
    /// karan 240 Hz, stranger 300 Hz) amplitude 0.25 with a 4 Hz syllable envelope; silence elsewhere.
    /// Returns 200 peak bins. Writes in 1 s chunks (a 12:48 file is ~24 MB and takes < 0.3 s).
    public static func write(to url: URL, duration: TimeInterval, segments: [(TimeRange, SyntheticPerson)]) throws -> [Float] {
        let total = Swift.max(0, Int((duration * Double(sampleRate)).rounded()))
        let writer = try WAVFileWriter(url: url, sampleRate: sampleRate)
        // Every pitch and the 4 Hz envelope divide 1 s exactly, so one 1 s table per person is periodic.
        let tables = SyntheticPerson.allCases.map { table(for: $0) }
        let tableMaxes = tables.map { $0.max() ?? 0 }
        let sampleRanges: [(Int, Int, [Float], Float)] = segments.map { range, person in
            (Int(range.start * Double(sampleRate)), Int(range.end * Double(sampleRate)), tables[person.rawValue], tableMaxes[person.rawValue])
        }.sorted { $0.0 < $1.0 }

        var peaks = [Float](repeating: 0, count: peakBins)
        var chunk = [Float](repeating: 0, count: sampleRate)
        var start = 0
        while start < total {
            let n = Swift.min(sampleRate, total - start)
            let end = start + n
            chunk.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                base.update(repeating: 0, count: buf.count)
                for (a, b, t, tMax) in sampleRanges where b > start && a < end {
                    let lo = Swift.max(a, start), hi = Swift.min(b, end)
                    // The table is periodic over 1 s, so copy contiguous runs instead of single samples.
                    t.withUnsafeBufferPointer { tb in
                        var s = lo
                        while s < hi {
                            let offset = s % sampleRate
                            let run = Swift.min(hi - s, sampleRate - offset)
                            (base + (s - start)).update(from: tb.baseAddress! + offset, count: run)
                            s += run
                        }
                    }
                    // Peaks: the loudest sample of this person's table over the covered span, per bin.
                    var s = lo
                    while s < hi {
                        let bin = Swift.min(peakBins - 1, s * peakBins / Swift.max(1, total))
                        let binEnd = Swift.min(hi, (bin + 1) * total / peakBins + 1)
                        let v = Self.maxAbs(t, tableMax: tMax, from: s, to: Swift.max(s + 1, binEnd))
                        if v > peaks[bin] { peaks[bin] = v }
                        s = Swift.max(s + 1, binEnd)
                    }
                }
            }
            try writer.append(n == chunk.count ? chunk : Array(chunk[0..<n]))
            start = end
        }
        try writer.finish()
        // Normalise so the loudest bin is 1 (peaks are 0...1 display values).
        let maxPeak = peaks.max() ?? 0
        return maxPeak > 0 ? peaks.map { $0 / maxPeak } : peaks
    }

    /// The stems of a recording of `script` made with the microphone and Mac audio (`FakeScript.stemSegments`),
    /// written to `stems` (folders are created). Returns the duration written.
    @discardableResult
    public static func writeStems(for script: FakeScript, to stems: CaptureStems) throws -> TimeInterval {
        for stream in CaptureStream.allCases {
            _ = try write(to: stems.url(stream), duration: script.duration, segments: script.stemSegments(stream))
        }
        return script.duration
    }

    /// Max |table| over absolute sample range [from, to) (the table repeats every second).
    static func maxAbs(_ table: [Float], tableMax: Float, from: Int, to: Int) -> Float {
        if to - from >= sampleRate / 4 { return tableMax }   // a whole 4 Hz syllable is covered
        var m: Float = 0
        table.withUnsafeBufferPointer { tb in
            for s in from..<to { let v = abs(tb[s % sampleRate]); if v > m { m = v } }
        }
        return m
    }

    static func pitch(_ p: SyntheticPerson) -> Double {
        switch p { case .liam: 180; case .karan: 240; case .stranger: 300 }
    }

    static func table(for p: SyntheticPerson) -> [Float] {
        let f = pitch(p)
        return (0..<sampleRate).map { i in
            let t = Double(i) / Double(sampleRate)
            let envelope = 0.55 + 0.45 * sin(2 * .pi * 4 * t)          // 4 Hz syllables, 0.1...1
            return Float(0.25 * envelope * sin(2 * .pi * f * t))
        }
    }
}
