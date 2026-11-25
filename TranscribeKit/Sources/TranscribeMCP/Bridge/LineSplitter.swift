import Foundation

/// Frames stdio as newline-delimited JSON (§6). It splits on 0x0A only, so U+2028, U+2029, U+0085 and a lone CR stay
/// inside a message (`FileHandle.bytes.lines` would split on all of them). One trailing CR is stripped. Bytes past
/// `maxLine` are dropped and the line reads as `.tooLong` at its LF.
public struct LineSplitter {
    public enum Line: Equatable, Sendable { case line(Data), tooLong }

    private let maxLine: Int
    private var buffer = Data()
    private var overflowed = false

    public init(maxLine: Int = 4_194_304) { self.maxLine = maxLine }

    public mutating func feed(_ byte: UInt8) -> Line? {
        guard byte == 0x0A else {
            if buffer.count < maxLine { buffer.append(byte) } else { overflowed = true }
            return nil
        }
        return take()
    }

    /// At end of input: the last line if it had no LF.
    public mutating func finish() -> Line? {
        buffer.isEmpty && !overflowed ? nil : take()
    }

    private mutating func take() -> Line {
        defer { buffer = Data(); overflowed = false }
        if overflowed { return .tooLong }
        if buffer.last == 0x0D { buffer.removeLast() }
        return .line(buffer)
    }
}
