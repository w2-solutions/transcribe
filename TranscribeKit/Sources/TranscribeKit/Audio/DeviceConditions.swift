import Foundation
import Network
import Synchronization

/// The network audio sync is on, as its rules see it.
public enum NetworkKind: String, Sendable, Equatable {
    /// Wi-Fi or Ethernet, not in Low Data Mode: automatic transfers may run.
    case unmetered
    /// Mobile data or a personal hotspot (`isExpensive`).
    case metered
    /// Low Data Mode (`isConstrained`).
    case constrained
    case offline
}

/// The device state audio sync decides on: network, Low Power Mode and free space.
public protocol DeviceConditions: AnyObject, Sendable {
    var network: NetworkKind { get }
    var lowPowerMode: Bool { get }
    /// Volume capacity at `url` (opportunistic or important usage); nil when unknown.
    func freeBytes(at url: URL, opportunistic: Bool) -> Int64?
    /// `handler` runs (any thread) when the network or power state changes.
    func setOnChange(_ handler: @escaping @Sendable () -> Void)
}

/// NWPathMonitor (status → offline, isConstrained → constrained, isExpensive → metered), ProcessInfo low power and its
/// notification, URLResourceValues volumeAvailableCapacityFor{Opportunistic,Important}Usage.
public final class LiveDeviceConditions: DeviceConditions, @unchecked Sendable {
    private struct State {
        var network: NetworkKind
        var lowPower: Bool
        var onChange: (@Sendable () -> Void)?
    }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "ai.w2solutions.transcribe.device-conditions", qos: .utility)
    private let state: Mutex<State>
    private var powerObserver: (any NSObjectProtocol)?

    /// Until the monitor's first update (moments after start) the network may read `.offline`; that update then
    /// calls the change handler.
    public init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        state = Mutex(State(network: Self.kind(of: monitor.currentPath),
                            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, onChange: nil))
        monitor.pathUpdateHandler = { [weak self] path in self?.update(network: Self.kind(of: path)) }
        monitor.start(queue: queue)
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.update(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    deinit {
        monitor.cancel()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }

    public var network: NetworkKind { state.withLock { $0.network } }
    public var lowPowerMode: Bool { state.withLock { $0.lowPower } }

    public func freeBytes(at url: URL, opportunistic: Bool) -> Int64? {
        let key: URLResourceKey = opportunistic ? .volumeAvailableCapacityForOpportunisticUsageKey
                                                : .volumeAvailableCapacityForImportantUsageKey
        guard let values = try? url.resourceValues(forKeys: [key]) else { return nil }
        return opportunistic ? values.volumeAvailableCapacityForOpportunisticUsage
                             : values.volumeAvailableCapacityForImportantUsage
    }

    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onChange = handler }
    }

    /// The kind of a path: unsatisfied → offline, then constrained, then expensive, else unmetered.
    static func kind(of path: NWPath) -> NetworkKind {
        guard path.status == .satisfied else { return .offline }
        if path.isConstrained { return .constrained }
        if path.isExpensive { return .metered }
        return .unmetered
    }

    private func update(network: NetworkKind? = nil, lowPower: Bool? = nil) {
        let handler: (@Sendable () -> Void)? = state.withLock { s in
            var changed = false
            if let network, network != s.network { s.network = network; changed = true }
            if let lowPower, lowPower != s.lowPower { s.lowPower = lowPower; changed = true }
            return changed ? s.onChange : nil
        }
        handler?()
    }
}
