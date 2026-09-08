import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What we were able to learn about a process.
///
/// The third case is the point. "We looked and it is gone" and "we were not allowed to look" lead
/// to opposite actions: the first should clear an alert, the second must not. Collapsing them into
/// a boolean is how a sandboxed query ends up reporting a running app as dead and a waiting session
/// as finished.
public enum LivenessVerdict: String, Codable, Sendable {
    case alive
    case dead
    /// Process inspection was refused or unavailable. Nothing is claimed.
    case unknown
}

public protocol LivenessProbing: Sendable {
    /// `startedAt` guards against PID reuse: a recycled pid has a different start time.
    func probe(pid: Int32, startedAt: Double?) -> LivenessVerdict
}

extension LivenessProbing {
    /// For the places that must make a binary decision.
    ///
    /// `unknown` counts as alive: throwing away a real alert because a sandbox refused a `sysctl`
    /// is a far worse failure than keeping a stale session around until it goes stale on time.
    public func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        probe(pid: pid, startedAt: startedAt) != .dead
    }
}

public struct SystemLiveness: LivenessProbing {
    /// Process start times are seconds-with-microseconds; allow a little slack for rounding
    /// through JSON.
    private let tolerance: Double = 2.0

    public init() {}

    public func probe(pid: Int32, startedAt: Double?) -> LivenessVerdict {
        // If we cannot even inspect ourselves, process inspection is unavailable in this context
        // (a sandbox, a restricted profile). Every answer is then "unknown", not "dead".
        guard ProcessProbe.inspectionIsAvailable else { return .unknown }

        switch ProcessProbe.inspect(pid: pid) {
        case .denied:
            return .unknown
        case .notFound:
            return .dead
        case .found(let snapshot):
            guard let expected = startedAt else { return .alive }
            return abs(snapshot.startedAt - expected) <= tolerance ? .alive : .dead
        }
    }
}

/// Test double. Everything is alive unless explicitly killed; `deny` models a refused inspection.
public final class StubLiveness: LivenessProbing, @unchecked Sendable {
    private var dead: Set<Int32> = []
    private var denied: Set<Int32> = []
    private var denyEverything = false
    private let lock = NSLock()

    public init() {}

    public func kill(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        dead.insert(pid)
        denied.remove(pid)
    }

    public func deny(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        denied.insert(pid)
    }

    /// Models a sandbox where no process may be inspected at all.
    public func denyAll() {
        lock.lock(); defer { lock.unlock() }
        denyEverything = true
    }

    public func revive(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        dead.remove(pid)
        denied.remove(pid)
    }

    public func probe(pid: Int32, startedAt: Double?) -> LivenessVerdict {
        lock.lock(); defer { lock.unlock() }
        if denyEverything || denied.contains(pid) { return .unknown }
        return dead.contains(pid) ? .dead : .alive
    }
}
