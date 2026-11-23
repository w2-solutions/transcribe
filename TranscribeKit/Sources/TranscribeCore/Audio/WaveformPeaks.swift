import Foundation

public enum WaveformPeaks {
    /// Peak absolute amplitude per bin (0...1) of a 16 kHz mono Int16 WAV, streamed in chunks.
    ///
    /// Bins split the frames evenly; bins with no frames (a file shorter than `bins` frames, or an empty
    /// file) are 0. Any 16-bit PCM WAV is accepted; with several channels the loudest channel counts.
    public static func peaks(ofWAV url: URL, bins: Int) throws -> [Float] {
        guard bins > 0 else { return [] }
        let info = try WAVHeaderInfo.read(url)
        var peaks = [Int32](repeating: 0, count: bins)
        let total = info.frameCount
        guard total > 0 else { return [Float](repeating: 0, count: bins) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(info.dataOffset))

        let channels = info.channels
        let chunkFrames = 1 << 16
        var frame = 0
        var bin = 0
        var binEnd = boundary(1, total: total, bins: bins)
        while frame < total {
            let frames = Swift.min(chunkFrames, total - frame)
            guard let data = try handle.read(upToCount: frames * info.blockAlign), !data.isEmpty else { break }
            let readFrames = data.count / info.blockAlign
            data.withUnsafeBytes { raw in
                for f in 0..<readFrames {
                    let absolute = frame + f
                    while absolute >= binEnd && bin < bins - 1 {
                        bin += 1
                        binEnd = boundary(bin + 1, total: total, bins: bins)
                    }
                    var peak = peaks[bin]
                    for c in 0..<channels {
                        let o = (f * channels + c) * 2
                        let sample = Int16(bitPattern: UInt16(raw[o]) | UInt16(raw[o + 1]) << 8)
                        let magnitude = abs(Int32(sample))
                        if magnitude > peak { peak = magnitude }
                    }
                    peaks[bin] = peak
                }
            }
            frame += readFrames
            if readFrames < frames { break }
        }
        return peaks.map { Swift.min(1, Float($0) / 32767) }
    }

    /// Max-pool (or linear-stretch if fewer) to `count` bins.
    public static func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let n = peaks.count
        guard n > 0 else { return [Float](repeating: 0, count: count) }
        if n == count { return peaks }
        if n > count {
            return (0..<count).map { j in
                let lo = j * n / count, hi = Swift.max(lo + 1, (j + 1) * n / count)
                return peaks[lo..<hi].max() ?? 0
            }
        }
        if n == 1 { return [Float](repeating: peaks[0], count: count) }
        let scale = Double(n - 1) / Double(count - 1)
        return (0..<count).map { j in
            let x = Double(j) * scale
            let i = Swift.min(n - 2, Int(x))
            let t = Float(x - Double(i))
            return peaks[i] + (peaks[i + 1] - peaks[i]) * t
        }
    }

    /// First frame of bin `b` (b in 0...bins): ceil(b · total / bins).
    private static func boundary(_ b: Int, total: Int, bins: Int) -> Int {
        (b * total + bins - 1) / bins
    }
}
