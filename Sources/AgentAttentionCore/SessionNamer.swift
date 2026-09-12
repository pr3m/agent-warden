import Foundation

/// Naming the tabs that never got a name, on request.
///
/// The rule is in `SessionNaming`; this is the part that decides which sessions to ask about, in
/// what order, and what to do with each answer. It is deliberately a plain type with injected
/// dependencies — the command scan, the model call, and the write — because the interesting
/// behaviour is the policy, and a policy that can only be tested by spawning `claude` is a policy
/// nobody tests.
public struct SessionNamer {
    /// One session, reduced to what naming it needs.
    public struct Candidate: Sendable, Equatable {
        public var sessionID: String
        /// What the tab is called now, if anything.
        public var currentName: String?
        /// The folder the session was launched in, which is what an unnamed tab is showing.
        public var folder: String
        public var transcript: URL?

        public init(sessionID: String, currentName: String?, folder: String, transcript: URL?) {
            self.sessionID = sessionID
            self.currentName = currentName
            self.folder = folder
            self.transcript = transcript
        }
    }

    /// Where a name came from. Kept because "the command said so" and "a model read the session and
    /// guessed" are not the same claim, and a log that blurs them cannot be audited later.
    public enum Source: String, Sendable {
        case command
        case model
    }

    public struct Named: Sendable, Equatable {
        public var sessionID: String
        public var name: String
        public var source: String
    }

    public struct Outcome: Sendable, Equatable {
        public var named: [Named] = []
        /// Sessions that were eligible but produced no name — no slug, no usable model answer, or
        /// no model available. Counted rather than listed: the tab is unchanged either way.
        public var unnamed: Int = 0
        /// Sessions not touched at all, because somebody had already named them.
        public var skipped: Int = 0
    }

    /// Reads a transcript for the newest slash-command argument. Injected so a test need not write
    /// a 6 MB file to disk.
    public var commandScan: @Sendable (URL) -> String?
    /// Asks a model to name a session from an excerpt. Returns nil when no model is available —
    /// which is a normal state, not an error: `claude` may simply not be installed.
    public var askModel: @Sendable (String) -> String?
    /// Reads the excerpt a model would be shown. Separate from `commandScan` because the command
    /// rule wants the whole file and the model wants a small, recent slice of it.
    public var excerpt: @Sendable (URL) -> String?
    /// Writes the name. Returns whether it stuck; a tab that has gone away is not a failure worth
    /// reporting, just one that produced no name.
    public var write: @Sendable (String, String) -> Bool

    public init(commandScan: @escaping @Sendable (URL) -> String?,
                askModel: @escaping @Sendable (String) -> String?,
                excerpt: @escaping @Sendable (URL) -> String?,
                write: @escaping @Sendable (String, String) -> Bool) {
        self.commandScan = commandScan
        self.askModel = askModel
        self.excerpt = excerpt
        self.write = write
    }

    /// Name every candidate that is still showing its folder name.
    ///
    /// The command rule runs first for every session, and the model is asked only where it found
    /// nothing. On a real fleet that was two of four sessions answered for free — the other two
    /// had opened with prose (`time to prep next release`) and only reading them could say what
    /// they had become.
    public func run(_ candidates: [Candidate]) -> Outcome {
        var outcome = Outcome()
        for candidate in candidates {
            guard SessionNaming.needsName(current: candidate.currentName, folder: candidate.folder) else {
                outcome.skipped += 1
                continue
            }
            guard let transcript = candidate.transcript else { outcome.unnamed += 1; continue }

            if let fromCommand = commandScan(transcript),
               let name = SessionNaming.sanitize(fromCommand),
               write(candidate.sessionID, name) {
                outcome.named.append(Named(sessionID: candidate.sessionID, name: name,
                                           source: Source.command.rawValue))
                continue
            }
            guard let text = excerpt(transcript), !text.isEmpty,
                  let answer = askModel(SessionNaming.prompt(excerpt: text)),
                  let name = SessionNaming.sanitize(answer),
                  // A model that answers with the folder name has told us nothing, and writing it
                  // would turn an unnamed tab into a tab that only looks named.
                  !SessionNaming.needsName(current: name, folder: candidate.folder),
                  write(candidate.sessionID, name)
            else { outcome.unnamed += 1; continue }
            outcome.named.append(Named(sessionID: candidate.sessionID, name: name,
                                       source: Source.model.rawValue))
        }
        return outcome
    }
}
