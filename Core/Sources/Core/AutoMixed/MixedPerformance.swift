import Foundation

/// Numeric, request-local instrumentation. No input, context, or candidates are retained.
/// The task-local scope also keeps concurrent test/server requests independent.
public enum MixedPerformance {
    public enum Phase: String, Sendable, Codable { case judgment, classification, roman, conversion, render }
    public enum Counter: String, Sendable, Codable { case sessionCreated, sessionReleased, candidates, scorePass }
    public struct Snapshot: Sendable, Codable {
        public let microseconds: [String: UInt64]
        public let counts: [String: Int]
    }
    public final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [String: UInt64] = [:]
        private var counts: [String: Int] = [:]
        public init() {}
        fileprivate func add(_ phase: Phase, nanoseconds: UInt64) {
            lock.lock(); defer { lock.unlock() }
            times[phase.rawValue, default: 0] += nanoseconds
        }
        fileprivate func add(_ counter: Counter) {
            lock.lock(); defer { lock.unlock() }
            counts[counter.rawValue, default: 0] += 1
        }
        public func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(microseconds: times.mapValues { $0 / 1000 }, counts: counts)
        }
    }
    @TaskLocal public static var trace: Trace?
    public static func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        guard let trace else { return try operation() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { trace.add(phase, nanoseconds: DispatchTime.now().uptimeNanoseconds - start) }
        return try operation()
    }
    public static func count(_ counter: Counter) { trace?.add(counter) }
}
