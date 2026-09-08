import Foundation
@testable import AgentAttentionCore

/// A fake process table. Test-only, so it does not ship inside the app.
final class StubProcessIdentity: ProcessIdentifying, @unchecked Sendable {
    private struct Entry { var startedAt: Double; var command: String; var path: String?; var tty: String? }
    private var table: [Int32: Entry] = [:]
    private var denied: Set<Int32> = []
    private let available: Bool
    private let lock = NSLock()

    init(available: Bool = true) { self.available = available }

    func add(pid: Int32, startedAt: Double, command: String = "claude",
             executablePath: String? = nil, tty: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        table[pid] = Entry(startedAt: startedAt, command: command, path: executablePath, tty: tty)
    }

    /// Models a refusal for one pid — different from "there is no such process".
    func deny(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        denied.insert(pid)
    }

    var inspectionIsAvailable: Bool { available }

    func inspect(pid: Int32) -> ProcInspection {
        guard available else { return .denied }
        lock.lock(); defer { lock.unlock() }
        if denied.contains(pid) { return .denied }
        guard let entry = table[pid] else { return .notFound }
        return .found(ProcSnapshot(pid: pid, ppid: 1, startedAt: entry.startedAt,
                                   command: entry.command, tty: entry.tty))
    }

    func executablePath(pid: Int32) -> String? {
        lock.lock(); defer { lock.unlock() }
        return table[pid]?.path
    }
}
