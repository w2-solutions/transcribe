import Foundation
public struct AppClock: Sendable {
    private let provider: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date) { provider = now }
    public var now: Date { provider() }
    public static let system = AppClock { Date() }
    public static func frozen(_ date: Date) -> AppClock { AppClock { date } }
}
