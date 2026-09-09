import Foundation

/// A root-owned note on disk saying "this daemon set the block".
///
/// **Why it exists at all.** It matters for exactly one moment: daemon startup. The daemon
/// holds no lease then, but `SleepDisabled` may still be `1` — either because this daemon
/// set it and then died, or because something else entirely owns it. `SleepDisabled` is a
/// single machine-wide boolean with no notion of who set it, so the setting itself cannot
/// answer that question. Clearing it unconditionally would end a stranger's session;
/// leaving it always would strand a machine that can no longer sleep. The marker is the
/// only thing that tells the two apart.
///
/// This is not hypothetical. On the machine this was developed on, `pmset -g` reported
/// `SleepDisabled 1` at a moment when this daemon had never run, because a separate tool
/// had a session going. A startup that cleared the block unconditionally would have killed
/// it.
///
/// **Why root-owned and outside every user-writable tree.** A marker a non-root user could
/// create is a way to make a root daemon clear a setting it does not own — which is the
/// one thing this whole mechanism exists to prevent. So it lives beside the binary's own
/// support directory, and `exists` does not merely ask whether a path is there: it insists
/// the file is a regular file owned by uid 0.
enum HeldMarker {
    static let directory = "/Library/Application Support/dev.agentwarden"
    static let path = "/Library/Application Support/dev.agentwarden/held"

    /// True only for a *root-owned regular file*. A path that exists but is owned by
    /// somebody else, or is a symlink pointing somewhere convenient, is not our marker and
    /// must not be read as our permission to clear the block.
    static var exists: Bool { isRootOwnedRegularFile(path) }

    /// Written only after a `setBlock` has been verified by read-back, so the marker never
    /// claims ownership of a block that was not actually established.
    ///
    /// A failure here does not fail the acquire — the running daemon still knows it holds
    /// the lease and will clear the block on release, expiry or disconnect. What is lost is
    /// crash recovery: without the marker, a daemon that dies now will find the block set,
    /// no proof it is ours, and correctly decline to touch it. That is worth a line in the
    /// log, because the symptom shows up much later and nowhere near the cause.
    static func write() {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .ownerAccountID: 0]
        )
        let written = FileManager.default.createFile(
            atPath: path,
            contents: Data(ISO8601DateFormatter().string(from: Date()).utf8),
            attributes: [.posixPermissions: 0o600, .ownerAccountID: 0]
        )
        if !written {
            PowerdLog.write("could not write the held marker — a crash now would strand the block")
        }
    }

    /// Removed *before* the block is cleared, never after.
    ///
    /// A crash in between then leaves the safe combination — no marker, block still set —
    /// where startup declines to touch a setting it can no longer prove is its own and the
    /// operator has the documented `sudo pmset -a disablesleep 0` repair. The other order
    /// would leave "marker present, block already cleared", and the next startup would
    /// clear a block that by then could belong to somebody else.
    static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// True when `path` is a regular file owned by uid 0.
///
/// `lstat`, not `stat`, and a regular-file check rather than mere existence: a symlink is
/// owned by whoever created it, so following one would let a non-root user aim a root
/// daemon's trust at any file on the system. Refusing the link outright is cheaper than
/// reasoning about where it points.
///
/// This is what makes "root-owned file" a checked property of the two inputs the daemon
/// trusts — the held marker and the allowed-uid file — rather than an assumption about how
/// the installer happened to behave.
func isRootOwnedRegularFile(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_uid == 0 && (info.st_mode & S_IFMT) == S_IFREG
}
