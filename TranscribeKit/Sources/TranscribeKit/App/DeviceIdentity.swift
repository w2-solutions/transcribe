import Foundation

public protocol DeviceIdentity: Sendable { func installID() -> String }

public struct FixedDeviceIdentity: DeviceIdentity {
    public let id: String
    public init(_ id: String) { self.id = id }
    public func installID() -> String { id }
}
