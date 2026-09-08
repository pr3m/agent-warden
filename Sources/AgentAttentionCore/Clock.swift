import Foundation

/// Time source. Injected so engine behaviour (snooze, stall, staleness) is testable
/// without sleeping and without depending on the machine clock.
public protocol ClockProviding: AnyObject {
    var now: Date { get }
}

public final class SystemClock: ClockProviding {
    public init() {}
    public var now: Date { Date() }
}

/// Manually advanced clock for tests.
public final class TestClock: ClockProviding {
    private var current: Date
    public init(_ start: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        self.current = start
    }
    public var now: Date { current }

    @discardableResult
    public func advance(_ seconds: TimeInterval) -> Date {
        current = current.addingTimeInterval(seconds)
        return current
    }

    public func set(_ date: Date) { current = date }
}
