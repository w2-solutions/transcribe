@preconcurrency import AVFoundation
import Darwin
import Foundation
import TranscribeCore
@testable import TranscribeFluid

/// A capture source driven by the test: it records the calls it receives and delivers what the test sends.
/// Like the microphone, it delivers nothing while paused or after `stop()`.
actor ScriptedCaptureSource: CaptureSource {
    private(set) var calls: [String] = []
    private var deliver: (@Sendable (CaptureInput) -> Void)?
    private var paused = false
    private let failStart: Bool

    init(failStart: Bool = false) { self.failStart = failStart }

    func start(_ deliver: @escaping @Sendable (CaptureInput) -> Void) async throws {
        calls.append("start")
        if failStart { throw EngineError.failed("No microphone input is available") }
        self.deliver = deliver
    }

    func pause() async { calls.append("pause"); paused = true }
    func resume() async throws { calls.append("resume"); paused = false }
    func stop() async { calls.append("stop"); deliver = nil }

    /// Delivers samples unless paused or stopped. Returns whether they were delivered.
    @discardableResult
    func send(_ samples: [Float]) -> Bool {
        guard !paused, let deliver else { return false }
        deliver(.audio(samples))
        return true
    }

    func send(event: CaptureSourceEvent) { deliver?(.event(event)) }

    /// Sends `seconds` of a sine wave in 100 ms chunks.
    func sendSine(seconds: Double, amplitude: Float = 0.5, frequency: Double = 440) {
        let total = Int(seconds * 16_000)
        var i = 0
        while i < total {
            let n = Swift.min(1_600, total - i)
            send((0..<n).map { k in amplitude * Float(sin(2 * .pi * frequency * Double(i + k) / 16_000)) })
            i += n
        }
    }
}

/// Streams a 16 kHz mono WAV file through the capture path in 100 ms chunks (for the gated live-text test).
actor FileCaptureSource: CaptureSource {
    private let samples: [Float]
    private var deliver: (@Sendable (CaptureInput) -> Void)?

    init(url: URL) throws { samples = try TestAudio.readSamples(url) }

    func start(_ deliver: @escaping @Sendable (CaptureInput) -> Void) async throws { self.deliver = deliver }
    func pause() async {}
    func resume() async throws {}
    func stop() async { deliver = nil }

    /// Delivers the whole file, pausing briefly between chunks so the live recognizer keeps up.
    func play(chunkPause: Duration = .milliseconds(5)) async {
        var i = 0
        while i < samples.count, let deliver {
            let n = Swift.min(1_600, samples.count - i)
            deliver(.audio(Array(samples[i..<(i + n)])))
            i += n
            try? await Task.sleep(for: chunkPause)
        }
    }

    var duration: TimeInterval { Double(samples.count) / 16_000 }
}

enum TestAudio {
    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-fluid-tests", isDirectory: true)
            .appendingPathComponent("\(safe)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bytes 40..<44 of a canonical WAV header: the data chunk size.
    static func headerDataBytes(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 44) ?? Data()
        guard header.count == 44 else { return -1 }
        return header[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }
}

/// Collects a recording's events until its stream finishes.
func collectEvents(_ stream: AsyncStream<RecordingEvent>) -> Task<[RecordingEvent], Never> {
    Task {
        var events: [RecordingEvent] = []
        for await e in stream { events.append(e) }
        return events
    }
}

/// Waits (up to `timeout`) until `condition` holds; the live-recording consumer runs asynchronously.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

enum Memory {
    /// Current physical footprint of this process in MB (what jetsam counts on iOS).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Resident memory in MB, including file-backed pages such as memory-mapped Core ML weights.
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1_048_576
    }

    /// Lifetime peak physical footprint in MB (`ledger_phys_footprint_peak`).
    static func peakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.ledger_phys_footprint_peak) / 1_048_576
    }
}

/// Samples this process's physical footprint and resident size every 5 ms on its own thread until `stop()`.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double
    private var residentPeak: Double
    private var running = true
    private let done = DispatchSemaphore(value: 0)
    let residentBefore: Double

    init() {
        peak = Memory.footprintMB()
        residentBefore = Memory.residentMB()
        residentPeak = residentBefore
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Memory.footprintMB(), resident = Memory.residentMB()
                lock.withLock { peak = Swift.max(peak, now); residentPeak = Swift.max(residentPeak, resident) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            done.signal()
        }
    }

    /// Peak footprint MB (what jetsam counts on iOS).
    func stop() -> Double {
        lock.withLock { running = false }
        done.wait()
        return lock.withLock { Swift.max(peak, Memory.footprintMB()) }
    }

    /// Peak resident MB minus resident before (counts mapped weights); valid after `stop()`.
    var residentGrowthMB: Double { lock.withLock { residentPeak - residentBefore } }
}

/// The true turns `make-fixtures.sh` writes next to a multi-voice fixture.
struct TrueTurns: Sendable {
    struct Turn: Codable, Sendable { var voice: String; var start: Double; var end: Double }
    var turns: [Turn]
    var voices: Set<String> { Set(turns.map(\.voice)) }
    static func load(_ url: URL) throws -> TrueTurns {
        TrueTurns(turns: try JSONDecoder().decode([Turn].self, from: Data(contentsOf: url)))
    }
}

/// One separator on one fixture: speakers, how much true speech it covers, how much it gives the right voice.
struct SeparatorReport: Sendable {
    let fixture: String
    let separator: SpeakerSeparator
    let speakers: Int
    let speechSeconds: Double
    /// True speech covered by any segment.
    let coveredShare: Double
    /// True speech covered by the speaker its voice maps to (one-to-one mapping, greedy by overlap).
    let attributedShare: Double
    /// Stretches of true speech ≥ 0.2 s that no segment covers.
    let gaps: [TimeRange]
    let mapping: [String: SpeakerKey]
    let elapsed: Duration
    let duration: Double
    let footprintBeforeMB: Double
    let peakMB: Double
    let residentGrowthMB: Double
    let label: String
    let segments: [SpeakerSegment]

    init(fixture: String, separator: SpeakerSeparator, label: String? = nil, separation: SpeakerSeparation, truth: TrueTurns,
         duration: Double, elapsed: Duration, footprintBeforeMB: Double, peakMB: Double, residentGrowthMB: Double = 0) {
        self.fixture = fixture; self.separator = separator; self.duration = duration; self.elapsed = elapsed
        self.footprintBeforeMB = footprintBeforeMB; self.peakMB = peakMB; self.residentGrowthMB = residentGrowthMB
        self.label = label ?? separator.rawValue
        self.segments = separation.segments
        let segments = separation.segments
        speakers = Set(segments.map(\.speakerKey)).count
        func overlap(_ a: TimeRange, _ b: TimeRange) -> Double { Swift.max(0, Swift.min(a.end, b.end) - Swift.max(a.start, b.start)) }
        let all = Self.union(segments.map(\.range))
        // One-to-one voice → key mapping, greedily by overlap (as diarization error rate scoring does): a key
        // can stand for one voice only, so two voices merged into one speaker count against the result.
        let keys = Set(segments.map(\.speakerKey))
        var pairs: [(voice: String, key: SpeakerKey, seconds: Double)] = []
        for voice in truth.voices {
            let turns = truth.turns.filter { $0.voice == voice }.map { TimeRange(start: $0.start, end: $0.end) }
            for key in keys {
                let own = Self.union(segments.filter { $0.speakerKey == key }.map(\.range))
                let seconds = turns.reduce(0) { sum, t in sum + own.reduce(0) { $0 + overlap(t, $1) } }
                if seconds > 0 { pairs.append((voice, key, seconds)) }
            }
        }
        var mapping: [String: SpeakerKey] = [:]
        for pair in pairs.sorted(by: { ($0.seconds, $1.voice, $1.key) > ($1.seconds, $0.voice, $0.key) })
        where mapping[pair.voice] == nil && !mapping.values.contains(pair.key) {
            mapping[pair.voice] = pair.key
        }
        self.mapping = mapping
        var speech = 0.0, covered = 0.0, attributed = 0.0
        var gaps: [TimeRange] = []
        for turn in truth.turns {
            let t = TimeRange(start: turn.start, end: turn.end)
            speech += t.duration
            covered += all.reduce(0) { $0 + overlap(t, $1) }
            if let key = mapping[turn.voice] {
                let own = Self.union(segments.filter { $0.speakerKey == key }.map(\.range))
                attributed += own.reduce(0) { $0 + overlap(t, $1) }
            }
            var cursor = t.start
            for r in all where r.end > t.start && r.start < t.end {
                if r.start - cursor >= 0.2 { gaps.append(TimeRange(start: cursor, end: r.start)) }
                cursor = Swift.max(cursor, r.end)
            }
            if t.end - cursor >= 0.2 { gaps.append(TimeRange(start: cursor, end: t.end)) }
        }
        speechSeconds = speech
        coveredShare = speech > 0 ? covered / speech : 0
        attributedShare = speech > 0 ? attributed / speech : 0
        self.gaps = gaps
    }

    static func union(_ ranges: [TimeRange]) -> [TimeRange] {
        var merged: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.end > r.start {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start, end: Swift.max(last.end, r.end))
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    var summary: String {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let gapText = gaps.map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", ")
        return String(format: "COMPARE %@ %@: speakers %d; covered %.1f%% of %.1f s speech; right voice %.1f%%; uncovered [%@]; "
                      + "%.3f s (RTF %.4f); footprint before %.0f MB, peak during %.0f MB (+%.0f); resident +%.0f MB; mapping %@",
                      fixture, label, speakers, coveredShare * 100, speechSeconds, attributedShare * 100,
                      gapText, seconds, seconds / Swift.max(duration, 0.001), footprintBeforeMB, peakMB,
                      peakMB - footprintBeforeMB, residentGrowthMB, mapping.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: " "))
    }
}

/// How two separations of one file differ: the share of 10 ms frames whose set of active speakers differs, and,
/// when both have the same segments in the same order, the largest start / end shift.
struct SegmentDiff: Sendable {
    let disagreeShare: Double
    let maxBoundaryShift: Double?
    let sameSegmentCount: Bool

    init(_ a: [SpeakerSegment], _ b: [SpeakerSegment], duration: Double) {
        let frames = Swift.max(1, Int((duration * 100).rounded(.up)))
        func labels(_ segments: [SpeakerSegment]) -> [Set<SpeakerKey>] {
            var out = [Set<SpeakerKey>](repeating: [], count: frames)
            for s in segments {
                let lo = Swift.max(0, Int((s.range.start * 100).rounded())), hi = Swift.min(frames, Int((s.range.end * 100).rounded()))
                if lo < hi { for f in lo..<hi { out[f].insert(s.speakerKey) } }
            }
            return out
        }
        let la = labels(a), lb = labels(b)
        disagreeShare = Double(zip(la, lb).filter { $0 != $1 }.count) / Double(frames)
        sameSegmentCount = a.count == b.count && zip(a, b).allSatisfy { $0.speakerKey == $1.speakerKey }
        maxBoundaryShift = sameSegmentCount
            ? zip(a, b).map { Swift.max(abs($0.range.start - $1.range.start), abs($0.range.end - $1.range.end)) }.max() ?? 0
            : nil
    }

    var summary: String {
        let shift = maxBoundaryShift.map { String(format: "same segments, max boundary shift %.2f s", $0) } ?? "different segmentation"
        return String(format: "frames that differ %.2f%%; %@", disagreeShare * 100, shift)
    }
}
