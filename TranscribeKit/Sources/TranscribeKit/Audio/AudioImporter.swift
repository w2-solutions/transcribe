@preconcurrency import AVFoundation
import Foundation
import TranscribeCore

public enum AudioImportError: Error, Sendable, Equatable { case unreadable, tooLong(TimeInterval), failed(String) }

public enum AudioImporter {
    public static let maxDuration: TimeInterval = 3 * 3600
    /// Converts any AVFoundation-readable file to 16 kHz mono Int16 WAV at `destination`
    /// (streaming AVAudioConverter), returning duration + 200 peaks. Security-scoped access handled by caller.
    ///
    /// Runs off the caller's actor. Channels are averaged to mono before resampling. Throws
    /// `.unreadable` for a file AVFoundation cannot open (or one with no audio), `.tooLong` above
    /// `maxDuration` (checked before converting), `CancellationError` if the task is cancelled, and
    /// `.failed` for conversion or write errors. On any error the partial destination file is removed.
    @concurrent
    public static func importAudio(from source: URL, to destination: URL) async throws -> CapturedAudio {
        try convert(from: source, to: destination, maxDuration: maxDuration)
    }

    static let targetSampleRate = 16_000
    static let peakBins = 200
    static let chunkFrames: AVAudioFrameCount = 32_768

    /// Synchronous conversion; `maxDuration` is a parameter so tests can exercise the limit cheaply.
    static func convert(from source: URL, to destination: URL, maxDuration: TimeInterval) throws -> CapturedAudio {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch { throw AudioImportError.unreadable }
        let inFormat = file.processingFormat
        let sourceRate = inFormat.sampleRate
        let channels = Int(inFormat.channelCount)
        guard sourceRate > 0, channels > 0, file.length > 0 else { throw AudioImportError.unreadable }
        let sourceDuration = Double(file.length) / sourceRate
        guard sourceDuration <= maxDuration else { throw AudioImportError.tooLong(sourceDuration) }

        do {
            let writer = try WAVFileWriter(url: destination, sampleRate: targetSampleRate)
            do {
                try stream(file, into: writer)
                let duration = try writer.finish()
                guard duration > 0 else { throw AudioImportError.unreadable }
                let peaks = try WaveformPeaks.peaks(ofWAV: destination, bins: peakBins)
                // Imported audio counts as heard on the importing device (D9); its route is "imported".
                return CapturedAudio(url: destination, duration: duration, marks: [], peaks: peaks,
                                     detail: CaptureDetail(hardwareModel: CaptureChannel.hardwareModel,
                                                           input: CaptureDetail.Input.imported, routeChanged: false))
            } catch {
                _ = try? writer.finish()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            switch error {
            case is CancellationError, is AudioImportError: throw error
            default: throw AudioImportError.failed(error.localizedDescription)
            }
        }
    }

    /// Reads `file` in chunks, averages channels to mono and resamples to 16 kHz into `writer`.
    private static func stream(_ file: AVAudioFile, into writer: WAVFileWriter) throws {
        let inFormat = file.processingFormat
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                             channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSampleRate),
                                            channels: 1, interleaved: false)
        else { throw AudioImportError.failed("Couldn't create audio buffers") }

        let reader = MonoReader(file: file, readBuffer: readBuffer, monoBuffer: monoBuffer)

        // Same rate: no converter needed.
        if inFormat.sampleRate == Double(targetSampleRate) {
            while let mono = try reader.next() {
                try Task.checkCancellation()
                try writer.append(samples(of: mono))
            }
            return
        }

        guard let converter = AVAudioConverter(from: monoFormat, to: outFormat) else {
            throw AudioImportError.failed("Couldn't create the audio converter")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let outCapacity = AVAudioFrameCount((Double(chunkFrames) * Double(targetSampleRate) / inFormat.sampleRate).rounded(.up)) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioImportError.failed("Couldn't create audio buffers")
        }

        var readError: Error?
        var finished = false
        while !finished {
            try Task.checkCancellation()
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                do {
                    if let mono = try reader.next() {
                        inputStatus.pointee = .haveData
                        return mono
                    }
                } catch {
                    readError = error
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let readError { throw readError }
            switch status {
            case .error:
                throw AudioImportError.failed(conversionError?.localizedDescription ?? "Conversion failed")
            case .endOfStream:
                finished = true
            case .haveData, .inputRanDry:
                break
            @unknown default:
                break
            }
            if outBuffer.frameLength > 0 { try writer.append(samples(of: outBuffer)) }
            if status == .inputRanDry && outBuffer.frameLength == 0 { finished = true }
        }
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

/// Pulls chunks from an `AVAudioFile` and averages their channels into one reused mono buffer.
private final class MonoReader {
    let file: AVAudioFile
    let readBuffer: AVAudioPCMBuffer
    let monoBuffer: AVAudioPCMBuffer

    init(file: AVAudioFile, readBuffer: AVAudioPCMBuffer, monoBuffer: AVAudioPCMBuffer) {
        self.file = file; self.readBuffer = readBuffer; self.monoBuffer = monoBuffer
    }

    /// The next mono chunk, or nil at the end of the file. The returned buffer is reused on the next call.
    func next() throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        readBuffer.frameLength = 0
        try file.read(into: readBuffer, frameCount: readBuffer.frameCapacity)
        let frames = Int(readBuffer.frameLength)
        guard frames > 0, let mono = monoBuffer.floatChannelData?[0] else { return nil }
        let channels = Int(readBuffer.format.channelCount)
        if let float = readBuffer.floatChannelData {
            if channels == 1 {
                mono.update(from: float[0], count: frames)
            } else {
                let scale = 1 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += float[c][i] }
                    mono[i] = sum * scale
                }
            }
        } else {
            throw AudioImportError.failed("Unexpected audio format")
        }
        monoBuffer.frameLength = AVAudioFrameCount(frames)
        return monoBuffer
    }
}
