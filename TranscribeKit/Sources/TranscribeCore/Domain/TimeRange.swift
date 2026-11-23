import Foundation

public struct TimeRange: Sendable, Hashable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = Swift.min(start, end)
        self.end = Swift.max(start, end)
    }
    public var duration: TimeInterval { end - start }
    public var mid: TimeInterval { (start + end) / 2 }
    public func overlap(with other: TimeRange) -> TimeInterval {
        Swift.max(0, Swift.min(end, other.end) - Swift.max(start, other.start))
    }
    public func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
}
