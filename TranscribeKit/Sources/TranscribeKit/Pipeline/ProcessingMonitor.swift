import Foundation
import Observation
import TranscribeCore

@MainActor @Observable
public final class ProcessingMonitor {
    public private(set) var snapshots: [UUID: ProcessingSnapshot] = [:]
    /// Last job that reached .finished; AutoCopyObserver watches it.
    public private(set) var lastFinished: ProcessingSnapshot?
    public init() {}
    public func snapshot(for id: UUID) -> ProcessingSnapshot? { snapshots[id] }
    public func update(_ snapshot: ProcessingSnapshot) {
        snapshots[snapshot.recordingID] = snapshot
        if case .finished = snapshot.phase { lastFinished = snapshot }
    }
    public func clear(_ id: UUID) { snapshots[id] = nil }
}
