import Foundation

/// Written by the running app so a read-only query can tell "nothing is waiting" apart from
/// "nothing is watching".
public struct AppRunStatus: Codable, Sendable, Equatable {
    public var pid: Int32
    public var pidStartedAt: Double?
    public var version: String
    public var startedAt: Date

    public init(pid: Int32, pidStartedAt: Double?, version: String, startedAt: Date) {
        self.pid = pid
        self.pidStartedAt = pidStartedAt
        self.version = version
        self.startedAt = startedAt
    }
}

/// File-backed transport between the hook emitter and the app.
///
/// Deliberately a directory of small files rather than a socket: the emitter must never block,
/// must never depend on the app running, and whatever it wrote must survive a restart of either
/// side. The app watches the directories, so delivery is still prompt.
public struct EventStore: Sendable {
    public let paths: AppPaths
    /// Hard cap so an app that is not running cannot let the spool grow without bound.
    public let spoolCap: Int

    public init(paths: AppPaths, spoolCap: Int = 250) {
        self.paths = paths
        self.spoolCap = spoolCap
    }

    // MARK: - Write side (hook emitter)

    public func write(event: EmittedEvent) throws {
        try FileManager.default.createDirectory(at: paths.spool, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        pruneSpoolIfNeeded()
        let name = String(format: "%013.0f-%@.json", event.occurredAt.timeIntervalSince1970 * 1000, event.id)
        try AtomicFile.write(try JSONCoding.encoder.encode(event), to: paths.spool.appendingPathComponent(name))
    }

    public func write(heartbeat: SessionHeartbeat) throws {
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let safe = Self.safeFileName(heartbeat.identity.sessionID)
        try AtomicFile.write(
            try JSONCoding.encoder.encode(heartbeat),
            to: paths.sessions.appendingPathComponent("\(safe).json")
        )
    }

    /// Session ids are UUIDs in practice; this stops a malformed one becoming a path traversal.
    public static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(80))
    }

    private func pruneSpoolIfNeeded() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.spool.path) else { return }
        let files = names.filter { $0.hasSuffix(".json") }.sorted()
        guard files.count >= spoolCap else { return }
        for name in files.prefix(files.count - spoolCap + 1) {
            try? FileManager.default.removeItem(at: paths.spool.appendingPathComponent(name))
        }
    }

    // MARK: - Read side (app)

    public struct DrainResult: Sendable {
        public var events: [EmittedEvent]
        /// The files those events came from. Delete them with `acknowledge` — but only once the
        /// state that absorbed them has been saved.
        public var receipts: [URL]
        public var quarantined: [String]

        public init(events: [EmittedEvent] = [], receipts: [URL] = [], quarantined: [String] = []) {
            self.events = events
            self.receipts = receipts
            self.quarantined = quarantined
        }
    }

    /// Read every spooled event **without deleting anything**.
    ///
    /// Deleting on read loses alerts: a crash between the read and the next state save would take
    /// the event with it, and the recently-seen-id ring cannot bring back something that was never
    /// written down. The caller consumes the events, saves state, and only then calls
    /// `acknowledge`. Replaying an already-absorbed event is harmless — the ring catches it.
    public func readSpool() -> DrainResult {
        var events: [EmittedEvent] = []
        var receipts: [URL] = []
        var quarantined: [String] = []
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.spool.path) else {
            return DrainResult()
        }

        // An emitter killed mid-write can leave a temp file behind; clear old ones out.
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(".tmp-") {
            let url = paths.spool.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: url)
        }

        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let url = paths.spool.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let event = try? JSONCoding.decoder.decode(EmittedEvent.self, from: data) {
                events.append(event)
                receipts.append(url)
            } else {
                // Unparseable now is unparseable forever: move it aside so it cannot block the
                // queue, but keep it so somebody can look.
                try? fm.createDirectory(at: paths.quarantine, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
                let target = paths.quarantine.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: url, to: target)
                quarantined.append(name)
            }
        }
        return DrainResult(
            events: events.sorted { $0.occurredAt < $1.occurredAt },
            receipts: receipts,
            quarantined: quarantined
        )
    }

    /// Delete the spool files whose events are now safely recorded in saved state.
    public func acknowledge(_ receipts: [URL]) {
        for url in receipts {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func pendingSpoolCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.spool.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }

    public func readHeartbeats() -> [SessionHeartbeat] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.sessions.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .compactMap { name in
                guard let data = try? Data(contentsOf: paths.sessions.appendingPathComponent(name)) else { return nil }
                return try? JSONCoding.decoder.decode(SessionHeartbeat.self, from: data)
            }
    }

    /// Delete heartbeat files whose session is provably gone.
    ///
    /// Without this the directory leaks: a session that ends while the app is not running leaves a
    /// heartbeat too old for the engine to accept, so nothing would ever clean it up. Run this
    /// *before* reading heartbeats in a cycle, or a dead session is resurrected and pruned on
    /// alternate ticks forever. Returns the session ids removed.
    @discardableResult
    public func pruneHeartbeats(now: Date, staleAfter: TimeInterval, liveness: LivenessProbing) -> [String] {
        var removed: [String] = []
        for beat in readHeartbeats() {
            let identity = beat.identity
            let processGone = identity.claudePID.map { !liveness.isAlive(pid: $0, startedAt: identity.claudePIDStartedAt) } ?? false
            let tooOld = now.timeIntervalSince(beat.lastEventAt) > staleAfter
            guard processGone || tooOld else { continue }
            removeHeartbeat(sessionID: identity.sessionID)
            removed.append(identity.sessionID)
        }
        return removed
    }

    public func removeHeartbeat(sessionID: String) {
        let url = paths.sessions.appendingPathComponent("\(Self.safeFileName(sessionID)).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Engine state

    public func loadSnapshot() -> EngineSnapshot? {
        guard let data = try? Data(contentsOf: paths.stateFile) else { return nil }
        return try? JSONCoding.decoder.decode(EngineSnapshot.self, from: data)
    }

    public func save(snapshot: EngineSnapshot) throws {
        try AtomicFile.write(try JSONCoding.encoder.encode(snapshot), to: paths.stateFile)
    }

    public func stateModifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.stateFile.path))?[.modificationDate] as? Date
    }

    // MARK: - App presence

    public func write(appStatus: AppRunStatus) throws {
        try AtomicFile.write(try JSONCoding.encoder.encode(appStatus), to: paths.appStatusFile)
    }

    public func readAppStatus() -> AppRunStatus? {
        guard let data = try? Data(contentsOf: paths.appStatusFile) else { return nil }
        return try? JSONCoding.decoder.decode(AppRunStatus.self, from: data)
    }

    public func clearAppStatus() {
        try? FileManager.default.removeItem(at: paths.appStatusFile)
    }
}
