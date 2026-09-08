import Foundation

/// One record from Claude Code's local session registry (`~/.claude/sessions/*.json`).
///
/// This is Claude Code's own bookkeeping, not a published interface. Every field is optional except
/// the two that identify the thing, unknown keys are ignored, and nothing here is treated as a
/// promise about future versions.
public struct RegistryRecord: Sendable, Equatable {
    public var sessionID: String
    public var pid: Int32
    /// Parsed from `procStart`, e.g. "Sun Sep  6 08:24:43 2026" — local time, one-second resolution.
    public var procStart: Date?
    /// The directory the session was *launched* in. Often not where it is working now.
    public var cwd: String?
    /// The session's display name (`name`), and where it came from (`nameSource`).
    public var title: String?
    public var titleSource: String?
    public var version: String?
    /// Kept verbatim and never interpreted. `busy` here can be a quarter of an hour old.
    public var status: String?
    public var startedAt: Date?
    public var updatedAt: Date?

    public init(
        sessionID: String,
        pid: Int32,
        procStart: Date? = nil,
        cwd: String? = nil,
        title: String? = nil,
        titleSource: String? = nil,
        version: String? = nil,
        status: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.pid = pid
        self.procStart = procStart
        self.cwd = cwd
        self.title = title
        self.titleSource = titleSource
        self.version = version
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// The identity we are willing to carry forward.
    ///
    /// `birth` is the kernel's own start time for the pid, taken from the snapshot that *passed*
    /// verification — never the registry's `procStart`. That string has no timezone in it, is
    /// rendered in UTC on this machine, and storing it would leave `claudePIDStartedAt` three hours
    /// wrong; `SystemLiveness` would then declare every discovered session dead and remove it.
    ///
    /// Deliberately narrow otherwise: the messaging socket path in the record is never copied
    /// anywhere, so nothing downstream can dial it even by accident.
    public func sessionIdentity(birth: Double? = nil, tty: String? = nil) -> SessionIdentity {
        SessionIdentity(
            sessionID: sessionID,
            cwd: cwd ?? "",
            claudePID: pid,
            claudePIDStartedAt: birth,
            tty: tty,
            title: title,
            titleSource: titleSource
        )
    }
}

/// Why a registry record was or was not accepted.
public enum RegistryVerdict: String, Sendable, Codable {
    case verified
    /// The kernel says there is no such process.
    case processGone
    /// The pid exists but was born at a different time — it has been recycled.
    case startTimeMismatch
    /// The pid exists but is not a Claude Code executable.
    case notClaude
    /// We could not check: inspection refused, or the record carries no birth time to check against.
    case unverifiable
}

public struct DiscoveredSession: Sendable, Equatable {
    public var record: RegistryRecord
    public var identity: SessionIdentity

    public init(record: RegistryRecord, identity: SessionIdentity) {
        self.record = record
        self.identity = identity
    }
}

public struct RejectedRecord: Sendable, Equatable {
    public var sessionID: String
    public var pid: Int32
    public var verdict: RegistryVerdict
}

/// What one scan of the registry found. Reported as-is; the counts are how the UI and `aa-status`
/// describe coverage honestly rather than implying the list is complete.
public struct DiscoveryReport: Sendable, Equatable {
    public var scannedAt: Date
    public var registryPresent: Bool
    public var inspectionAvailable: Bool
    public var filesConsidered: Int
    public var malformed: Int
    public var oversized: Int
    public var verified: [DiscoveredSession]
    public var rejected: [RejectedRecord]

    public init(
        scannedAt: Date,
        registryPresent: Bool,
        inspectionAvailable: Bool,
        filesConsidered: Int,
        malformed: Int,
        oversized: Int,
        verified: [DiscoveredSession],
        rejected: [RejectedRecord]
    ) {
        self.scannedAt = scannedAt
        self.registryPresent = registryPresent
        self.inspectionAvailable = inspectionAvailable
        self.filesConsidered = filesConsidered
        self.malformed = malformed
        self.oversized = oversized
        self.verified = verified
        self.rejected = rejected
    }

    /// Only a scan that actually looked and could verify may be used to remove anything.
    public var isAuthoritative: Bool { registryPresent && inspectionAvailable }

    /// Sessions we looked at but could not decide about.
    ///
    /// A per-pid refusal is not a disappearance. These must survive a scan they are absent from,
    /// or a momentary inspection failure would quietly delete a live session.
    public var unverifiableSessionIDs: Set<String> {
        Set(rejected.filter { $0.verdict == .unverifiable }.map(\.sessionID))
    }
}

// MARK: - Process identity (injected so verification is testable)

public protocol ProcessIdentifying: Sendable {
    var inspectionIsAvailable: Bool { get }
    func inspect(pid: Int32) -> ProcInspection
    func executablePath(pid: Int32) -> String?
}

public struct SystemProcessIdentity: ProcessIdentifying {
    public init() {}
    public var inspectionIsAvailable: Bool { ProcessProbe.inspectionIsAvailable }
    public func inspect(pid: Int32) -> ProcInspection { ProcessProbe.inspect(pid: pid) }
    public func executablePath(pid: Int32) -> String? { ProcessProbe.executablePath(pid: pid) }
}

// MARK: - The scan

/// Read-only discovery of Claude Code sessions that were already running.
///
/// Hooks only tell us about a session once it does something. A session that has been sitting at a
/// prompt since before Agent Warden started is invisible until then — which is exactly when you
/// most want to know it exists. This reads Claude Code's registry to list them.
///
/// Boundaries, all deliberate:
/// - **`*.json` only.** The sibling `*.key` files are peer tokens and are never opened.
/// - **Never connect.** Records carry a `messagingSocketPath`; it is not copied anywhere and no
///   socket is ever opened.
/// - **Read-only.** Nothing in this file writes, renames or touches a registry file.
/// - **Verify, don't assume.** A record is accepted only if its pid is alive, was born when the
///   record says, and is running a Claude executable. Anything else is rejected or left unverified.
/// - **A discovery is not an event.** It says a session exists. It says nothing about attention.
public enum SessionRegistry {
    /// Records are a few hundred bytes. Anything wildly larger is not a record we understand.
    public static let maximumRecordBytes = 64 * 1024

    /// `procStart` has one-second resolution; the kernel's birth time has microseconds. Compare
    /// with a little slack rather than demanding equality.
    public static let startTimeTolerance: TimeInterval = 2.0

    /// `startedAt` is written a moment *after* the process execs, so it may legitimately sit a few
    /// seconds later than the birth time. It may never sit meaningfully earlier.
    public static let startedAtWindow: ClosedRange<TimeInterval> = -2 ... 30

    public static let environmentKey = "AGENT_WARDEN_CLAUDE_HOME"

    /// Where Claude Code keeps its own state. Overridable so tests and the smoke suite can never
    /// discover the real sessions on this machine.
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    public static func scan(
        root: URL,
        identity: ProcessIdentifying = SystemProcessIdentity(),
        now: Date = Date()
    ) -> DiscoveryReport {
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else {
            return DiscoveryReport(scannedAt: now, registryPresent: false,
                                   inspectionAvailable: identity.inspectionIsAvailable,
                                   filesConsidered: 0, malformed: 0, oversized: 0,
                                   verified: [], rejected: [])
        }

        // `.json` and nothing else. The `.key` files next to them are peer tokens.
        let candidates = names.filter { $0.hasSuffix(".json") }.sorted()
        var malformed = 0
        var oversized = 0
        var newest: [String: RegistryRecord] = [:]

        for name in candidates {
            let url = sessionsDir.appendingPathComponent(name)
            // Regular files only, and never through a symlink: a `.json` pointing at a peer token
            // or at something enormous is not a record, and following it would be exactly the kind
            // of surprise this scan exists to avoid.
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else {
                malformed += 1
                continue
            }
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumRecordBytes {
                oversized += 1
                continue
            }
            guard let data = boundedRead(url, limit: maximumRecordBytes) else {
                oversized += 1
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = parse(object) else {
                malformed += 1
                continue
            }
            // The pid in the filename is not evidence; the record is. Two files for one session
            // collapse to whichever was written last.
            if let existing = newest[record.sessionID] {
                let existingStamp = existing.updatedAt ?? existing.startedAt ?? .distantPast
                let candidateStamp = record.updatedAt ?? record.startedAt ?? .distantPast
                if candidateStamp <= existingStamp { continue }
            }
            newest[record.sessionID] = record
        }

        var verified: [DiscoveredSession] = []
        var rejected: [RejectedRecord] = []

        for record in newest.values.sorted(by: { $0.sessionID < $1.sessionID }) {
            let outcome = verifyDetailed(record, identity: identity)
            if outcome.verdict == .verified, let snapshot = outcome.snapshot {
                verified.append(DiscoveredSession(
                    record: record,
                    identity: record.sessionIdentity(birth: snapshot.startedAt, tty: snapshot.tty)
                ))
            } else {
                rejected.append(RejectedRecord(sessionID: record.sessionID, pid: record.pid,
                                               verdict: outcome.verdict))
            }
        }

        return DiscoveryReport(
            scannedAt: now,
            registryPresent: true,
            inspectionAvailable: identity.inspectionIsAvailable,
            filesConsidered: candidates.count,
            malformed: malformed,
            oversized: oversized,
            verified: verified,
            rejected: rejected
        )
    }

    /// Three things must hold: the process exists, it was born when the record says, and it is
    /// Claude Code. Any doubt is reported as doubt.
    public static func verify(_ record: RegistryRecord, identity: ProcessIdentifying) -> RegistryVerdict {
        verifyDetailed(record, identity: identity).verdict
    }

    /// The verdict plus, when accepted, the kernel snapshot that justified it.
    public static func verifyDetailed(
        _ record: RegistryRecord,
        identity: ProcessIdentifying
    ) -> (verdict: RegistryVerdict, snapshot: ProcSnapshot?) {
        guard identity.inspectionIsAvailable else { return (.unverifiable, nil) }
        // At least one basis for "is this the same process" must exist, or there is nothing to
        // check the pid against and a recycled number would sail through.
        guard record.procStart != nil || record.startedAt != nil else { return (.unverifiable, nil) }

        switch identity.inspect(pid: record.pid) {
        case .denied:
            return (.unverifiable, nil)
        case .notFound:
            return (.processGone, nil)
        case .found(let snapshot):
            let path = identity.executablePath(pid: record.pid)
            guard ProcessProbe.looksLikeClaude(command: snapshot.command, executablePath: path) else {
                return (.notClaude, nil)
            }
            guard birthTimeMatches(record, birth: snapshot.startedAt) else {
                return (.startTimeMismatch, nil)
            }
            return (.verified, snapshot)
        }
    }

    /// Does this record describe the process that is actually running under that pid?
    ///
    /// Two independent bases, because neither is quite enough on its own:
    ///
    /// - **`procStart`** is a `ctime` string with no zone in it. Observed output renders it in UTC
    ///   while `ps` renders local, so on a machine at UTC+3 a naive local parse is wrong by exactly
    ///   three hours and rejects every live session. Both readings are tried; a recycled pid would
    ///   have to have been born exactly one zone offset away, to the second, to slip through.
    /// - **`startedAt`** is epoch milliseconds and has no zone at all, so it is unambiguous — but it
    ///   is stamped just after the exec, hence the asymmetric window.
    ///
    /// A record carrying neither cannot be verified, and is not accepted.
    static func birthTimeMatches(_ record: RegistryRecord, birth: Double) -> Bool {
        if let procStart = record.procStart {
            if abs(birth - procStart.timeIntervalSince1970) <= startTimeTolerance { return true }
            let localOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: procStart))
            if abs(birth - (procStart.timeIntervalSince1970 - localOffset)) <= startTimeTolerance { return true }
        }
        if let startedAt = record.startedAt {
            return startedAtWindow.contains(startedAt.timeIntervalSince1970 - birth)
        }
        return false
    }

    /// Read at most `limit` bytes. Returns nil if the file turned out to be larger than that
    /// between the stat and the read — a record that grew is not a record we understand.
    static func boundedRead(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        return data.count > limit ? nil : data
    }

    // MARK: - Parsing

    static func parse(_ object: [String: Any]) -> RegistryRecord? {
        guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        guard let rawPid = object["pid"] as? Int, rawPid > 0, rawPid <= Int(Int32.max) else { return nil }

        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func millis(_ key: String) -> Date? {
            guard let value = object[key] as? Int, value > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }

        return RegistryRecord(
            sessionID: sessionID,
            pid: Int32(rawPid),
            procStart: string("procStart").flatMap(parseProcStart),
            cwd: string("cwd"),
            // 240, not 80. The session name is what the panel wraps and what Details shows in full,
            // so clipping it here would make the real name unrecoverable everywhere above. A real
            // worktree-plus-task name goes well past 80 characters. The cap is still a bound on a
            // field from a file we do not control; the record itself is read under a size limit.
            title: string("name").map { HookTranslator.truncate($0, limit: 240) },
            titleSource: string("nameSource"),
            version: string("version"),
            status: string("status"),
            startedAt: millis("startedAt"),
            updatedAt: millis("updatedAt")
        )
    }

    /// "Sun Sep  6 08:24:43 2026" — `ctime`-style, and note the double space that pads a
    /// single-digit day. The string carries no zone; it is parsed as UTC here and the local reading
    /// is derived where it is compared.
    public static func parseProcStart(_ raw: String) -> Date? {
        let collapsed = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return procStartFormatter.date(from: collapsed)
    }

    private static let procStartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)   // no zone in the string; see birthTimeMatches
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}

extension DiscoveredSession {
    /// Fold in what the transcript tail knows.
    ///
    /// The registry records where a session was *launched*; the transcript's last line records
    /// where it is working now. For a session we have only discovered, the transcript is the newer
    /// and better label, so it wins here. It never gets the chance to argue with a hook — the
    /// engine only ever lets a discovery fill gaps.
    public func enriched(withTranscript summary: TranscriptMetadata.Summary) -> DiscoveredSession {
        var copy = self
        if let cwd = summary.cwd, !cwd.isEmpty { copy.identity.cwd = cwd }
        if copy.identity.gitBranch == nil, let branch = summary.gitBranch, !branch.isEmpty {
            copy.identity.gitBranch = branch
        }
        return copy
    }
}
