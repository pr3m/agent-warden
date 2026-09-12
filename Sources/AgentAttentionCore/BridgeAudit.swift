import Foundation

/// One change a caller asked the bridge for, and what became of it.
///
/// Holds who vouched for it and what happened — never what was said. A prompt is recorded as its
/// digest, which is enough to tell two sends apart and to match a retry, and is not the prompt.
public struct BridgeAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// `start`, `send`, `stop`, `focus`, `adopt.prepare`, `adopt.complete`, `adopt.cancel`.
    public var operation: String
    public var sessionID: String?
    /// The caller's idempotency key: request id or message id.
    public var key: String?
    public var promptFingerprint: String?
    public var authorized: Bool
    public var statement: String?
    public var via: String?
    public var ok: Bool
    public var error: String?
    /// The phase the session or adoption was left in.
    public var outcome: String?
}

public protocol BridgeAuditRecording: Sendable {
    func append(_ entry: BridgeAuditEntry)
}

public extension BridgeAuditRecording {
    /// Reads are not changes and are not recorded.
    func record(request: BridgeRequest, response: BridgeResponse, at: Date) {
        var entry = BridgeAuditEntry(at: at, operation: "", sessionID: response.session?.sessionID,
                                     key: nil, promptFingerprint: nil, authorized: false,
                                     statement: nil, via: nil, ok: response.ok,
                                     error: response.error?.code.rawValue,
                                     outcome: response.session?.phase.rawValue)
        func vouch(_ authorization: BridgeAuthorization?) {
            entry.authorized = authorization?.isUsable == true
            entry.statement = authorization.map {
                String($0.statement.prefix(BridgeProtocol.maximumAuthorizationLength))
            }
            entry.via = authorization?.via.map { String($0.prefix(BridgeProtocol.maximumIdentifierLength)) }
        }
        switch request {
        case .start(let start):
            entry.operation = "start"
            entry.key = start.requestID
        case .send(let send):
            entry.operation = "send"
            entry.sessionID = send.sessionID
            entry.key = send.messageID
            entry.promptFingerprint = BridgeHost.fingerprint(send.prompt)
            vouch(send.authorization)
        case .stop(let sessionID, let authorization):
            entry.operation = "stop"
            entry.sessionID = sessionID
            vouch(authorization)
        case .focus(let sessionID):
            entry.operation = "focus"
            entry.sessionID = sessionID
        case .adopt(let adopt):
            entry.operation = "adopt." + adopt.action.rawValue
            entry.sessionID = adopt.sessionID
            entry.key = adopt.requestID
            entry.outcome = response.adoption?.phase.rawValue ?? entry.outcome
            vouch(adopt.authorization)
        case .context(let sessionID, _):
            // Reads are not changes, and most of them are noise. These two are the exception: they
            // are the calls that return the user's own typed prose off disk, and they are the only
            // capability here with no approval and no directory confinement. Recording that they
            // happened — never what came back — is what keeps "a client read everything" from
            // looking identical to a client that did nothing.
            entry.operation = "context"
            entry.sessionID = sessionID
        case .summary(let sessionID):
            entry.operation = "summary"
            entry.sessionID = sessionID
        case .status, .events, .sessions:
            return
        }
        append(entry)
    }
}

/// The audit log on disk: `<home>/bridge-audit.jsonl`, one entry per line, private to this user.
///
/// Append-only while it is small, and rotated once to `.1` when it passes the bound — a log that
/// grows for ever is a disk-full waiting for a busy week. A write that fails is not allowed to fail
/// the request it describes; it is the record of the request, not a gate on it.
public final class BridgeAuditLog: BridgeAuditRecording, @unchecked Sendable {
    public let url: URL
    private let maximumBytes: Int
    private let lock = NSLock()

    /// How many rotated generations to keep behind the live file.
    ///
    /// One was not enough. Because `authorization` is the caller's word, this log is the control
    /// that catches a misuse afterwards — and with a single 512 KiB rotation, a caller could push a
    /// real entry out of both files in seconds by sending refused requests, which are recorded too.
    /// Five generations is 2.5 MiB on a machine with terabytes, and turns "roll the log" from
    /// seconds of noise into something that has to be worked at.
    private let generations: Int

    public init(url: URL, maximumBytes: Int = 512 * 1024, generations: Int = 5) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.generations = max(1, generations)
    }

    public func append(_ entry: BridgeAuditEntry) {
        guard var line = try? JSONCoding.encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue + line.count > maximumBytes {
            // Oldest first, so nothing is overwritten while it is still the newest copy of itself.
            try? manager.removeItem(at: url.appendingPathExtension("\(generations)"))
            for generation in stride(from: generations - 1, through: 1, by: -1) {
                try? manager.moveItem(at: url.appendingPathExtension("\(generation)"),
                                      to: url.appendingPathExtension("\(generation + 1)"))
            }
            try? manager.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, line.count) }
    }

    /// Every entry still on disk, oldest first. For tests and for a person reading it back.
    public func entries() -> [BridgeAuditEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONCoding.decoder.decode(BridgeAuditEntry.self, from: Data($0.utf8))
        }
    }
}
