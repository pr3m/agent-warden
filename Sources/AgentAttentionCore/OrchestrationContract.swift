import Foundation
import CryptoKit

/// The working agreement, read from wherever the user keeps it.
///
/// **What this is.** A pointer to one human-readable document the user has chosen, plus an honest
/// report of what is at that path *right now*. Nothing is cached between requests: every query
/// re-reads the configuration and re-reads the file, because a consumer acting on a stale copy of
/// an agreement is worse than one that knows it cannot read it.
///
/// **What this is not.** Not an engine, not a watcher, not a rule interpreter. Selecting a document
/// grants nothing and enforces nothing — it is user policy expressed inside whatever the system,
/// the tools and the permissions already allow, and every one of those still decides for itself.
/// Nothing here executes the file, opens it, edits it, or writes a byte of it.
public enum ContractAvailability: String, Codable, Sendable, Equatable {
    /// No document has been chosen. Not a fault: the app runs exactly as it did before.
    case noSelection
    /// Read, whole, as UTF-8.
    case available
    /// Chosen, but nothing is at that path now. The selection is **kept** — a document that is
    /// temporarily gone is not a decision to stop having one.
    case missing
    /// There, but not a regular file: a directory, a socket, a device, a named pipe.
    case notRegularFile
    /// There, but this reader will not treat it as a document — a script, an executable, a bundle.
    case unsupportedType
    /// Larger than the bound. Reported with its size, and **no partial body**: half an agreement
    /// read as though it were whole is the failure mode worth designing against.
    case tooLarge
    /// There and readable, but not valid UTF-8 text.
    case notText
    /// The file system refused it — permissions, or an I/O error.
    case unreadable
    /// It changed underneath the read, so the bytes and the revision could not be shown to belong
    /// together. Reported rather than resolved by guessing which half was right.
    case changedWhileReading
    /// The configuration itself could not be read, so what is selected is unknown. Distinct from
    /// "nothing is selected", which is a fact.
    case configUnreadable
}

/// One reading of the contract, at one moment.
public struct ContractReading: Codable, Sendable, Equatable {
    public var availability: ContractAvailability
    /// Exactly what is stored in the configuration, unresolved.
    public var selectedPath: String?
    /// The same path with `~` expanded and symlinks resolved, when it exists.
    public var resolvedPath: String?
    /// When this reading was taken. Every query takes a new one.
    public var readAt: Date
    public var sizeBytes: Int?
    public var modifiedAt: Date?
    /// SHA-256 of the exact bytes, hex. **The** way to tell whether the document changed: a size
    /// and a timestamp both stay the same across an edit that swaps one word for another of equal
    /// length, and one that rewrites a file within the same second.
    public var revision: String?
    /// Present only when the caller asked for it, and only when the whole document was read.
    public var content: String?
    /// One sentence a person can act on.
    public var note: String
    /// The bound this reader applies, so a caller can see what "too large" meant.
    public var maximumBytes: Int

    public init(availability: ContractAvailability, selectedPath: String? = nil,
                resolvedPath: String? = nil, readAt: Date, sizeBytes: Int? = nil,
                modifiedAt: Date? = nil, revision: String? = nil, content: String? = nil,
                note: String, maximumBytes: Int = OrchestrationContract.maximumBytes) {
        self.availability = availability
        self.selectedPath = selectedPath
        self.resolvedPath = resolvedPath
        self.readAt = readAt
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.content = content
        self.note = note
        self.maximumBytes = maximumBytes
    }

    /// Is there a document a consumer may act on?
    public var isUsable: Bool { availability == .available }
}

public enum OrchestrationContract {
    /// 256 KiB. An agreement a person is expected to read is a few pages; this is generous by two
    /// orders of magnitude and still bounded.
    public static let maximumBytes = 256 * 1024
    /// The configuration is small; this is room to spare, and still a bound.
    public static let maximumConfigurationBytes = 1024 * 1024

    /// Document types this reader will open. Deliberately a short list of plain-text kinds.
    ///
    /// An empty extension is allowed — plenty of agreements are just `AGREEMENT` — because the
    /// contents are validated as UTF-8 anyway. Everything else is refused **by name**, so a caller
    /// is told the file was rejected rather than left wondering why it read as empty.
    public static let supportedExtensions: Set<String> = ["md", "markdown", "mdown", "txt", "text", ""]

    /// Extensions that are refused outright, whatever else is true of them. Listed explicitly so
    /// the reasoning is visible: each of these is something a machine may *run*, and an agreement
    /// is a thing to read.
    public static let executableExtensions: Set<String> = [
        "command", "sh", "bash", "zsh", "csh", "fish", "py", "rb", "pl", "js", "mjs", "cjs",
        "swift", "scpt", "applescript", "app", "workflow", "shortcut", "terminal", "html", "htm",
        "xhtml", "svg", "webloc", "url", "pkg", "dmg", "jar", "exe", "bat", "ps1", "action",
    ]

    /// Read whatever the configuration currently points at.
    ///
    /// Both halves are re-read on every call: the configuration, because it may have been changed
    /// in another window or by hand, and the file, because that is the whole point.
    ///
    /// The configuration gets the **same discipline as the document** — a regular file, opened
    /// without blocking, read within a bound. `Data(contentsOf:)` would happily wait for ever on a
    /// named pipe left at that path, and a query that hangs is worse than one that refuses.
    ///
    /// Only a definite `ENOENT` means "nothing is selected". Anything else — unreadable, not a
    /// regular file, not JSON, or a `orchestrationContractPath` that is present but is not a string
    /// — is `configUnreadable`, because "we could not find out" and "there is none" are different
    /// answers and a consumer will act differently on each.
    public static func read(configuration: URL, includeContent: Bool,
                            now: @escaping () -> Date = Date.init) -> ContractReading {
        let moment = now()
        func unreadable(_ why: String) -> ContractReading {
            ContractReading(availability: .configUnreadable, readAt: moment,
                            note: "The configuration at \(configuration.path) \(why), so what is "
                                + "selected is unknown.")
        }

        let bytes: Data
        switch boundedRead(configuration.path, limit: maximumConfigurationBytes) {
        case .read(let data, _):
            bytes = data
        case .absent:
            return ContractReading(availability: .noSelection, readAt: moment,
                                   note: "No orchestration contract is selected.")
        case .notRegular:
            return unreadable("is not a regular file")
        case .tooLarge(let size):
            return unreadable("is \(size) bytes, larger than this will read")
        case .failed(let code):
            return unreadable("could not be read (errno \(code))")
        }

        // Inspected as JSON *before* the tolerant decoder sees it. `AttentionConfig` forgives a
        // wrong type so the monitor still starts on a mangled file — right for the monitor, wrong
        // here, because a number under that key would be silently reported as "nothing selected".
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            return unreadable("could not be parsed")
        }
        let raw = object["orchestrationContractPath"]
        if raw == nil || raw is NSNull {
            return ContractReading(availability: .noSelection, readAt: moment,
                                   note: "No orchestration contract is selected.")
        }
        guard let selection = raw as? String else {
            return unreadable("holds an orchestrationContractPath that is not a path")
        }
        return read(selection: selection, includeContent: includeContent, now: now)
    }

    /// Read one path, with every rule applied. Used directly by the settings window, which already
    /// knows what the user just chose.
    ///
    /// `afterRead` is a seam for one regression and nothing else: it fires between reading the
    /// bytes and re-checking what they came from, so a replacement mid-read can be tested exactly
    /// rather than by racing two threads and hoping.
    public static func read(selection: String?, includeContent: Bool,
                            now: @escaping () -> Date = Date.init,
                            afterRead: (() -> Void)? = nil) -> ContractReading {
        let moment = now()
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ContractReading(availability: .noSelection, readAt: moment,
                                   note: "No orchestration contract is selected.")
        }

        // A selection names a local file, by an absolute path. Not a URL, not a command, and not
        // something relative — see `absolutePath`.
        //
        // **The validated string is the one used.** Checking a tidied-up copy and then opening the
        // original is how a path that passed becomes a different path on the way to the file
        // system: a leading space survives `expandingTildeInPath` untouched, and a tilde naming a
        // user who does not exist is left exactly as written. Either one then resolves against
        // whatever directory happened to ask.
        let expanded: String
        switch absolutePath(selection) {
        case .refused(let refusal):
            return ContractReading(availability: .unsupportedType, selectedPath: selection,
                                   readAt: moment, note: refusal)
        case .path(let path):
            expanded = path
        }

        var link = stat()
        guard lstat(expanded, &link) == 0 else {
            // Only a definite absence is absence. A parent directory this user cannot search
            // gives `EACCES`, which is not evidence that nothing is there — reporting it as
            // "missing" would invite a caller to conclude the agreement had been removed.
            let code = errno
            switch code {
            case ENOENT, ENOTDIR:
                return ContractReading(availability: .missing, selectedPath: selection, readAt: moment,
                                       note: "Nothing is at \(expanded) now. The selection is kept, so "
                                           + "restoring the file is enough to make it readable again.")
            default:
                return ContractReading(availability: .unreadable, selectedPath: selection,
                                       readAt: moment,
                                       note: "\(expanded) could not be examined (errno \(code)). "
                                           + "That is not the same as it not being there.")
            }
        }
        let resolved = BridgeHost.resolve(expanded) ?? expanded

        // Opened non-blocking, before anything else is decided. A named pipe with no writer blocks
        // for ever on `open` alone, so the descriptor is acquired in a way that cannot wait, and
        // *then* asked what it is.
        let descriptor = Darwin.open(resolved, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            let availability: ContractAvailability = (code == ENOENT || code == ENOTDIR)
                ? .missing : .unreadable
            return ContractReading(availability: availability, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   note: availability == .missing
                                       ? "Nothing is at \(resolved) now. The selection is kept."
                                       : "\(resolved) could not be opened (errno \(code)).")
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            return ContractReading(availability: .unreadable, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   note: "\(resolved) could not be inspected.")
        }
        guard (opened.st_mode & S_IFMT) == S_IFREG else {
            return ContractReading(availability: .notRegularFile, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   note: "\(resolved) is not a regular file — a directory, a pipe, "
                                       + "a socket or a device cannot be an agreement.")
        }
        if let refusal = typeRefusal(resolved, mode: opened.st_mode) {
            return ContractReading(availability: .unsupportedType, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   sizeBytes: Int(opened.st_size),
                                   modifiedAt: modified(opened), note: refusal)
        }
        let size = Int(opened.st_size)
        guard size <= maximumBytes else {
            return ContractReading(availability: .tooLarge, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment, sizeBytes: size,
                                   modifiedAt: modified(opened),
                                   note: "\(resolved) is \(size) bytes, over the \(maximumBytes)-byte "
                                       + "limit. Nothing is returned: half an agreement is worse "
                                       + "than none.")
        }

        guard let bytes = readAll(descriptor, upTo: maximumBytes + 1) else {
            return ContractReading(availability: .unreadable, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment, sizeBytes: size,
                                   modifiedAt: modified(opened),
                                   note: "\(resolved) could not be read to the end.")
        }
        afterRead?()

        // Two checks, because they catch different things.
        //
        // The **descriptor** still describing the same file rules out a truncation or an in-place
        // rewrite while we were reading. The **path** still naming that same inode rules out the
        // other half: an atomic replacement, or a symlink pointed somewhere else, leaves the open
        // descriptor perfectly intact while the selection now means a different document. Reporting
        // the first file's bytes under the second file's identity is the one error a consumer has
        // no way to detect for itself.
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            return ContractReading(availability: .unreadable, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   note: "\(resolved) could not be re-checked after reading.")
        }
        var atPath = stat()
        let pathStillMatches = stat(expanded, &atPath) == 0
            && atPath.st_dev == opened.st_dev && atPath.st_ino == opened.st_ino
        guard after.st_dev == opened.st_dev, after.st_ino == opened.st_ino,
              after.st_size == opened.st_size, sameTime(after, opened), sameChangeTime(after, opened),
              pathStillMatches, bytes.count == size else {
            return ContractReading(availability: .changedWhileReading, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment,
                                   sizeBytes: pathStillMatches ? Int(after.st_size) : nil,
                                   modifiedAt: pathStillMatches ? modified(after) : nil,
                                   note: "\(resolved) changed while it was being read — it was "
                                       + "replaced, retargeted or rewritten. Nothing is returned "
                                       + "from this attempt; ask again.")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return ContractReading(availability: .notText, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment, sizeBytes: size,
                                   modifiedAt: modified(opened),
                                   note: "\(resolved) is not valid UTF-8 text. It is left exactly "
                                       + "as it is; nothing was converted or repaired.")
        }
        // Valid UTF-8 is not the same as a document. A binary blob can decode cleanly and still be
        // full of NULs and control bytes, and handing that to something expecting an agreement is
        // not an improvement on refusing it. Tabs, newlines and every ordinary Unicode character
        // stay welcome.
        if let offending = binaryRefusal(text) {
            return ContractReading(availability: .notText, selectedPath: selection,
                                   resolvedPath: resolved, readAt: moment, sizeBytes: size,
                                   modifiedAt: modified(opened),
                                   note: "\(resolved) contains \(offending), so it reads as data "
                                       + "rather than a document. It is left exactly as it is.")
        }
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ContractReading(availability: .available, selectedPath: selection,
                               resolvedPath: resolved, readAt: moment, sizeBytes: size,
                               modifiedAt: modified(opened), revision: revision,
                               content: includeContent ? text : nil,
                               note: "Read \(size) bytes from \(resolved).")
    }

    /// What makes this data rather than a document. `nil` means it reads as text.
    static func binaryRefusal(_ text: String) -> String? {
        for scalar in text.unicodeScalars {
            if scalar.value == 0 { return "a null byte" }
            // C0 controls other than tab, newline and carriage return, plus DEL. Everything above
            // that — accents, emoji, any script — is ordinary text and is left alone.
            if scalar.value < 0x20, scalar.value != 0x09, scalar.value != 0x0A, scalar.value != 0x0D {
                return "control characters"
            }
            if scalar.value == 0x7F { return "control characters" }
        }
        return nil
    }

    /// Read a whole small file, bounded, without ever blocking on what is at the path.
    enum BoundedRead {
        case read(Data, stat)
        /// Definitely nothing there.
        case absent
        case notRegular
        case tooLarge(Int)
        case failed(Int32)
    }

    static func boundedRead(_ path: String, limit: Int) -> BoundedRead {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR) ? .absent : .failed(code)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failed(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .notRegular }
        guard Int(info.st_size) <= limit else { return .tooLarge(Int(info.st_size)) }
        guard let data = readAll(descriptor, upTo: limit + 1) else { return .failed(errno) }
        return .read(data, info)
    }

    /// Whether the selected document may be handed to an editor, and why not when it may not.
    ///
    /// Deliberately narrow. Only a reading that came back `available` can be opened, which means
    /// the file has already been proved to be a regular, non-executable, supported, UTF-8 document
    /// of a bounded size — before any application is involved. A chooser's file filter is a
    /// convenience for the person picking; it is not evidence, and it is not what this trusts.
    public enum OpenDecision: Sendable, Equatable {
        case allowed(String)
        case refused(String)
    }

    public static func openDecision(for reading: ContractReading) -> OpenDecision {
        guard let path = reading.resolvedPath else {
            return .refused("There is nothing to open — no document is selected.")
        }
        switch reading.availability {
        case .available:
            return .allowed(path)
        case .noSelection:
            return .refused("There is nothing to open — no document is selected.")
        case .missing:
            return .refused("Nothing is at that path now, so there is nothing to open.")
        case .notRegularFile:
            return .refused("That path is not a regular file, so it will not be opened.")
        case .unsupportedType:
            return .refused("That file is not a type this will open. \(reading.note)")
        case .tooLarge:
            return .refused("That file is over the size limit, so it is not opened here.")
        case .notText:
            return .refused("That file is not UTF-8 text, so it will not be opened as a document.")
        case .unreadable, .changedWhileReading, .configUnreadable:
            return .refused("That document could not be read just now, so it is not opened. "
                            + reading.note)
        }
    }

    /// The one absolute path this selection means — or why it does not name one.
    ///
    /// Everything downstream uses the string this returns, and nothing uses the raw selection
    /// again. The order matters: tidy it, expand it, and only then decide, so what is judged is
    /// exactly what will be opened.
    enum PathVerdict: Equatable {
        case path(String)
        case refused(String)
    }

    static func absolutePath(_ selection: String) -> PathVerdict {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = trimmed.range(of: "://"), trimmed.distance(from: trimmed.startIndex,
                                                                   to: scheme.lowerBound) < 10 {
            let prefix = String(trimmed[trimmed.startIndex..<scheme.lowerBound]).lowercased()
            if prefix != "file" {
                return .refused("A contract is a local file. \(prefix):// is a network location, "
                                + "and nothing here fetches one.")
            }
        }
        if trimmed.contains("\u{0}") { return .refused("That path contains a null byte.") }
        // A path is a path. Anything that reads as a command is refused rather than sanitised,
        // because sanitising an instruction is a game with no end.
        if let bad = ["|", ";", "&&", "`", "$(", ">", "<"].first(where: { trimmed.contains($0) }) {
            return .refused("That looks like a command, not a file path (it contains ‘\(bad)’). "
                            + "Nothing here runs anything.")
        }

        // Expanded *before* the decision, because `~` only means somewhere absolute if it resolves.
        // `~someone-who-does-not-exist/Agreement.md` comes back unchanged, and would then be read
        // relative to whichever directory asked.
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            let why = trimmed.hasPrefix("~")
                ? "‘\(trimmed)’ starts with ~ but does not resolve to a home directory, so it is "
                + "not an absolute path."
                : "‘\(trimmed)’ is relative, so it would mean a different file depending on which "
                + "directory asked."
            return .refused("A contract is named by an absolute path. " + why)
        }
        return .path(expanded)
    }

    /// Why this file will not be treated as a document. `nil` means it will.
    static func typeRefusal(_ path: String, mode: mode_t) -> String? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if (mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0 {
            return "\(name) is marked executable. An agreement is something to read, so this is "
                 + "refused rather than opened."
        }
        if executableExtensions.contains(ext) {
            return "\(name) is a .\(ext) file, which a machine may run. Choose a plain-text or "
                 + "Markdown document instead."
        }
        guard supportedExtensions.contains(ext) else {
            return "\(name) is a .\(ext) file. Supported: "
                 + supportedExtensions.filter { !$0.isEmpty }.sorted().map { "." + $0 }
                     .joined(separator: ", ") + ", or no extension."
        }
        return nil
    }

    /// Read to the end, bounded, restarting on interruption. Returns nil on a real error.
    private static func readAll(_ descriptor: Int32, upTo limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if read == 0 { return data }
            if read < 0 {
                if errno == EINTR { continue }
                // A non-blocking descriptor on a regular file does not return EAGAIN; on anything
                // else we have already refused. Either way this is an error, not a retry loop.
                return nil
            }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    private static func modified(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
             + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// The change time moves for a rename, a permission change or a link count change — things a
    /// modification time does not notice.
    private static func sameChangeTime(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameTime(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

/// Storing the selection, with the rollback built in rather than remembered.
///
/// The failure this exists to prevent: the window sets the new path in the live configuration,
/// the write fails, the window reports the failure — and the *in-memory* configuration keeps the
/// new value anyway. The next unrelated settings change then writes it out, and a selection the
/// user was told had failed quietly becomes the one in force.
///
/// So nothing is mutated until the write has succeeded. The caller cannot forget to roll back,
/// because there is nothing to roll back: on failure the configuration it holds was never changed.
public enum ContractSelection {
    public enum Outcome: Sendable, Equatable {
        /// Written. Use this configuration from now on.
        case saved(AttentionConfig)
        /// Not written, and nothing changed anywhere. The message is for the user.
        case failed(String)
    }

    /// `path` of `nil` clears the selection. Every other preference is carried across untouched.
    public static func store(_ path: String?, current: AttentionConfig,
                             to configuration: URL) -> Outcome {
        var candidate = current
        candidate.orchestrationContractPath = path
        do {
            try candidate.save(to: configuration)
        } catch {
            return .failed("That selection could not be saved (\(error.localizedDescription)). "
                           + "Nothing was changed on disk, and nothing was changed here either.")
        }
        return .saved(candidate.validated())
    }
}
