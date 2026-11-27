import Foundation
import Synchronization
import TranscribeKit

/// Device conditions a test sets by hand. Changing a value does not notify; `change()` does, as a network or power
/// change would.
public final class FakeDeviceConditions: DeviceConditions, @unchecked Sendable {
    private struct State {
        var network: NetworkKind
        var lowPowerMode: Bool
        var free: Int64?
        var onChange: (@Sendable () -> Void)?
    }

    private let state: Mutex<State>

    public init(network: NetworkKind = .unmetered, lowPowerMode: Bool = false, free: Int64? = nil) {
        state = Mutex(State(network: network, lowPowerMode: lowPowerMode, free: free, onChange: nil))
    }

    public var network: NetworkKind {
        get { state.withLock { $0.network } }
        set { state.withLock { $0.network = newValue } }
    }

    public var lowPowerMode: Bool {
        get { state.withLock { $0.lowPowerMode } }
        set { state.withLock { $0.lowPowerMode = newValue } }
    }

    /// The free space every volume reports (opportunistic and important alike); nil = unknown.
    public var free: Int64? {
        get { state.withLock { $0.free } }
        set { state.withLock { $0.free = newValue } }
    }

    public func freeBytes(at url: URL, opportunistic: Bool) -> Int64? { free }

    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.onChange = handler }
    }

    /// Fires the change handler.
    public func change() {
        let handler = state.withLock { $0.onChange }
        handler?()
    }
}
