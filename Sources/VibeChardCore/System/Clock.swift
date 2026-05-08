import Foundation

/// Source of "now". Abstracted so `createdAt` timestamps in tests are
/// deterministic.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
