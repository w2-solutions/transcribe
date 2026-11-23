import Foundation

public struct AlignmentConfig: Sendable, Equatable {
    public var nearestSegmentTolerance: TimeInterval = 0.5
    public var overlapFlagFraction: Double = 0.3
    public var islandMaxWords = 1
    public var islandMaxDuration: TimeInterval = 0.4
    public var sameSpeakerGapSplit: TimeInterval = 3.0
    public var minCleanSpan: TimeInterval = 1.0
    public var spanEdgeTrim: TimeInterval = 0.1
    public var maxEmbedSeconds: TimeInterval = 60
    public var paragraphGap: TimeInterval = 1.5
    public var paragraphMaxSeconds: TimeInterval = 30
    public var listenClipMin: TimeInterval = 1.5
    public var listenClipMax: TimeInterval = 8
    public init() {}
    public static let `default` = AlignmentConfig()
}
