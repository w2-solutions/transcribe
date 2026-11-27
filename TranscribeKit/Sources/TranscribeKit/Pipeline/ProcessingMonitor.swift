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
    /// A job is queued or running. A finished or failed job's snapshot stays for the views, so `snapshots` is not
    /// empty again after the first job of a launch; this is what "processing runs" means.
    public var isProcessing: Bool {
        snapshots.values.contains { snapshot in
            switch snapshot.phase {
            case .queued, .running: true
            case .finished, .failed: false
            }
        }
    }
    public func update(_ snapshot: ProcessingSnapshot) {
        snapshots[snapshot.recordingID] = snapshot
        if case .finished = snapshot.phase { lastFinished = snapshot }
    }
    public func clear(_ id: UUID) { snapshots[id] = nil }
}
