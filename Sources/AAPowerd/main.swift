import Foundation
// `launch_activate_socket` lives in <launch.h>, which the macOS SDK exposes as the
// `launch` module. It is not in `Darwin` and not in `ServiceManagement`; `import XPC`
// re-exports it too, but the declaring module is the honest import.
import launch
import AgentAttentionCore

/// `aa-powerd` — the one privileged component of roam mode.
///
/// It runs as root under launchd for a single reason: `SleepDisabled`, the machine-global
/// setting that keeps a Mac awake with the lid shut, can only be written by root. Nothing
/// else in Agent Warden needs privilege, so nothing else lives here. This binary reads five
/// argument-free verbs off a Unix socket, answers them from a pure lease state machine, and
/// applies at most one of two fixed `pmset` argument vectors.

// A broken pipe must never take a root daemon down. A client that closes between our read
// and our reply would otherwise deliver SIGPIPE, whose default disposition is death — and
// this process dying with a lease outstanding is how a Mac ends up awake in a bag. Same
// rule, same reason, as `BridgeSocketServer.start()`.
signal(SIGPIPE, SIG_IGN)

// The uid permitted to talk to this daemon, written by the installer into a root-owned
// file. Read from there and nowhere else: a user-writable source would let anyone nominate
// themselves as the peer a root daemon obeys.
let allowedUIDPath = "/Library/Application Support/dev.agentwarden/allowed-uid"

// Existence is not enough — the file must be a regular file owned by root. Refusing to
// start is the safe direction: a daemon that cannot establish who it serves has no business
// serving anyone.
guard isRootOwnedRegularFile(allowedUIDPath) else {
    PowerdLog.write("allowed-uid file missing or not root-owned — refusing to start")
    exit(1)
}
guard let allowedUIDText = try? String(contentsOfFile: allowedUIDPath, encoding: .utf8),
      let allowedUID = uid_t(allowedUIDText.trimmingCharacters(in: .whitespacesAndNewlines))
else {
    PowerdLog.write("allowed-uid file is unreadable or not a uid — refusing to start")
    exit(1)
}

let daemon = PowerDaemon(allowedUID: allowedUID)
// Reconcile before the socket is served, so no client can acquire a lease against a machine
// state that has not been settled yet.
daemon.reconcile()
daemon.startExpiryTimer()
daemon.log("started, serving uid \(allowedUID)")

// The listening socket comes from launchd (`Sockets` → `PowerdSocket` in the plist), which
// created it with the owner and mode the plist declares before this process was even
// started. We never bind, never unlink, and so can never race a stale inode or delete
// somebody else's file.
//
// The SDK annotates the `fds` out-parameter as non-null, so Swift wants a pointer to a
// *non-optional* pointer. The storage is declared optional anyway — that is what a failed
// call leaves behind — and rebound for the call; the two have identical layout, because
// Swift represents a nil pointer as the null address.
var socketFDs: UnsafeMutablePointer<Int32>?
var socketCount: size_t = 0
let activation = withUnsafeMutablePointer(to: &socketFDs) { slot in
    slot.withMemoryRebound(to: UnsafeMutablePointer<Int32>.self, capacity: 1) { rebound in
        launch_activate_socket("PowerdSocket", rebound, &socketCount)
    }
}
guard activation == 0, let socketFDs, socketCount > 0 else {
    daemon.log("launchd did not hand over a socket (error \(activation)) — refusing to start")
    exit(1)
}
let listener = socketFDs[0]
free(socketFDs)

// Accept loop. One thread per connection: connections are few — the app, plus the occasional
// `aa-roam status` — and each is long-lived, so a thread each is simpler than multiplexing
// and, crucially, cannot starve the expiry timer, which runs on the state queue instead.
while true {
    let client = accept(listener, nil, nil)
    guard client >= 0 else {
        // Transient: try again. Anything else means the listener itself is no longer usable,
        // and spinning on it as root would burn a core forever. Exiting hands the problem to
        // launchd, which restarts us into `reconcile()` — the path built for exactly this.
        if errno == EINTR || errno == ECONNABORTED { continue }
        daemon.log("accept failed (errno \(errno)) — exiting so launchd can restart us")
        exit(1)
    }

    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == daemon.allowedUID else {
        // This authenticates a *user*, not this application. Any process running as that
        // user can hold the lease; without stable code signing on both ends that cannot be
        // tightened, and pretending otherwise would be worse than saying so.
        daemon.log("refused a connection from uid \(peerUID)")
        close(client)
        continue
    }

    let connectionID = daemon.claimConnectionID()
    Thread.detachNewThread {
        // Whatever ends this thread — EOF, a write failure, a client that never sends a
        // newline — the lease must not outlive it.
        defer {
            daemon.connectionClosed(connectionID)
            close(client)
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        var pending = Data()
        while true {
            let count = read(client, &buffer, buffer.count)
            // A signal interrupting the read is not the client going away. Dropping the
            // lease over one would end a session for no reason.
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                let reply: PowerReply = PowerRequest.parse(line)
                    .map { daemon.handle($0, connection: connectionID) } ?? .error(.unknown)
                let out = Data((reply.wire + "\n").utf8)
                let written = out.withUnsafeBytes { write(client, $0.baseAddress, out.count) }
                guard written == out.count else { return }
            }

            // Bounded after draining, not before: the residue here is by definition an
            // unfinished line, and every verb in this protocol is under a dozen bytes. A
            // peer that has sent 4 KB without a newline is not speaking it, and a root
            // daemon must not grow a buffer on its say-so.
            guard pending.count < 4096 else { return }
        }
    }
}
