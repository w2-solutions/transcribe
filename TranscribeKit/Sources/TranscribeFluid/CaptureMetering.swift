import Foundation

/// Level meter for the recording screen: RMS per 50 ms block → dBFS → 0...1, smoothed.
/// One block of 800 frames at 16 kHz gives the ~20 Hz tick rate the contract asks for.
struct LevelMeter: Sendable {
    static let sampleRate = 16_000
    static let blockFrames = 800
    /// dBFS mapped to level 0; 0 dBFS maps to level 1.
    static let floorDB: Float = -60
    /// Fast rise, slower fall, so speech onsets show at once and the meter does not flicker.
    static let attack: Float = 0.6
    static let release: Float = 0.2

    private(set) var level: Float = 0
    /// Frames ingested so far (the audio timeline).
    private(set) var totalFrames = 0
    private var blockSumSquares: Float = 0
    private var blockCount = 0

    /// Feeds samples and returns one smoothed level per completed block, with the frame index at the
    /// block's end (so `endFrame / 16000` is the elapsed time the tick reports).
    mutating func ingest(_ samples: [Float]) -> [(endFrame: Int, level: Float)] {
        var out: [(endFrame: Int, level: Float)] = []
        for s in samples {
            let x = s.isFinite ? s : 0
            blockSumSquares += x * x
            blockCount += 1
            totalFrames += 1
            if blockCount == Self.blockFrames {
                let rms = (blockSumSquares / Float(blockCount)).squareRoot()
                let raw = Self.normalisedLevel(rms: rms)
                level += (raw - level) * (raw > level ? Self.attack : Self.release)
                out.append((totalFrames, level))
                blockSumSquares = 0
                blockCount = 0
            }
        }
        return out
    }

    /// dBFS of the RMS, mapped linearly from `floorDB`...0 dB to 0...1.
    static func normalisedLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Swift.min(1, Swift.max(0, (db - floorDB) / -floorDB))
    }
}

/// Waveform peaks for the library card and transcript player: at most 200 bins of peak |amplitude| (0...1).
///
/// The recording length is unknown while capturing, so bins start at 50 ms and double in width whenever
/// 400 are full (pairs merge by max). Memory stays bounded for any length, and `result()` max-pools the
/// final 200...399 bins down to exactly 200 (or returns fewer for recordings under 10 s).
struct PeakBins: Sendable {
    static let targetBins = 200
    static let initialBinFrames = 800

    private(set) var binFrames = PeakBins.initialBinFrames
    private var bins: [Float] = []
    private var current: Float = 0
    private var currentFrames = 0

    init() { bins.reserveCapacity(2 * Self.targetBins) }

    mutating func ingest(_ samples: [Float]) {
        for s in samples {
            let a = s.isFinite ? Swift.min(1, Swift.abs(s)) : 0
            if a > current { current = a }
            currentFrames += 1
            if currentFrames == binFrames {
                bins.append(current)
                current = 0
                currentFrames = 0
                if bins.count == 2 * Self.targetBins { mergePairs() }
            }
        }
    }

    private mutating func mergePairs() {
        var merged: [Float] = []
        merged.reserveCapacity(2 * Self.targetBins)
        var i = 0
        while i + 1 < bins.count {
            merged.append(Swift.max(bins[i], bins[i + 1]))
            i += 2
        }
        if i < bins.count { merged.append(bins[i]) }
        bins = merged
        binFrames *= 2
    }

    /// ≤ 200 bins covering the whole recording (the trailing partial bin included).
    func result() -> [Float] {
        var all = bins
        if currentFrames > 0 { all.append(current) }
        return Self.maxPool(all, to: Self.targetBins)
    }

    /// Max-pools `values` down to `count` bins; returns `values` unchanged when it already fits.
    static func maxPool(_ values: [Float], to count: Int) -> [Float] {
        let n = values.count
        guard count > 0, n > count else { return values }
        return (0..<count).map { i in
            let lo = i * n / count
            let hi = Swift.max(lo + 1, (i + 1) * n / count)
            return values[lo..<hi].max() ?? 0
        }
    }
}
