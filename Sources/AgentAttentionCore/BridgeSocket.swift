import Foundation

/// A Unix-domain socket, private to the user who owns it.
///
/// No network listener, at any address. The socket lives in a directory this user owns, is created
/// 0600, and reaching it means being this user on this machine. There is no token to leak because
/// there is no port to reach.
///
/// Three things this got wrong the first time, each of which is now a rule:
///
/// - **accepting and serving are different jobs.** They shared one serial queue, so the accept loop
///   held it forever and no client was ever served. Accept has its own queue; connections are
///   handled on a concurrent one, capped, so a flood cannot spawn workers without limit.
/// - **the path is not ours to delete.** Binding used to `unlink` whatever was there, which would
///   remove a caller's regular file, or the socket of a host that is still running. Now: a regular
///   file is refused outright, a live socket is refused, and only a stale socket of our own kind is
///   replaced. On the way out we unlink only if the inode is still the one we bound.
/// - **partial I/O is normal.** Writes loop until the frame is out, reads and writes have deadlines,
///   `SIGPIPE` is disabled per socket, and a response too large for one frame is paged with an
///   honest cursor rather than truncated.
public final class BridgeSocketServer: @unchecked Sendable {
    public let path: String
    private let host: BridgeHost
    /// One queue that does nothing but accept, and a pool that does nothing but serve.
    private let acceptQueue = DispatchQueue(label: "ai.wundamental.agent-warden.bridge.accept")
    private let workQueue = DispatchQueue(label: "ai.wundamental.agent-warden.bridge.work",
                                          attributes: .concurrent)
    /// How many connections may be in flight at once. Beyond this, a caller waits its turn.
    private let workers: DispatchSemaphore
    private let ioDeadline: TimeInterval

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundInode: (device: dev_t, inode: ino_t)?
    private var running = false

    public init(path: String, host: BridgeHost,
                maximumConnections: Int = 8, ioDeadline: TimeInterval = 10) {
        self.path = path
        self.host = host
        self.workers = DispatchSemaphore(value: max(1, maximumConnections))
        self.ioDeadline = ioDeadline
    }

    public func start() throws {
        // A broken pipe must never take the whole host down.
        signal(SIGPIPE, SIG_IGN)

        try prepareSocketPath()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeSocketError.cannotCreate(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = try BridgeSocketServer.address(for: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); throw BridgeSocketError.cannotBind(errno) }
        // Checked, not hoped for. An endpoint that could not be made private is not used at all —
        // there is no "well, it is probably fine" fallback here.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw BridgeSocketError.pathOccupied("could not make \(path) private (errno \(code))")
        }
        guard listen(fd, 16) == 0 else { close(fd); unlink(path); throw BridgeSocketError.cannotListen(errno) }

        var info = stat()
        let identity: (dev_t, ino_t)? = stat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil

        lock.lock()
        listener = fd
        boundInode = identity
        running = true
        lock.unlock()

        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    /// Decide whether this path may be bound at all — without destroying anything.
    ///
    /// The endpoint is only as private as the directory holding it, so both are checked: the parent
    /// must be a real directory this user owns, with no access for anyone else, and the endpoint
    /// itself must be a socket this user owns. A symlink is refused outright rather than followed.
    private func prepareSocketPath() throws {
        try BridgeSocketServer.verifyPrivateParent(of: path)

        var info = stat()
        guard lstat(path, &info) == 0 else { return }          // nothing there: free to bind

        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw BridgeSocketError.pathOccupied(
                "\(path) is a symbolic link. Refusing to bind through it.")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw BridgeSocketError.pathOccupied(
                "\(path) exists and is not a socket. Refusing to remove it — choose another path.")
        }
        guard info.st_uid == getuid() else {
            throw BridgeSocketError.pathOccupied(
                "\(path) is a socket owned by another user. Refusing to touch it.")
        }
        // Replaced **only** on a definite refusal to connect: that is the one answer that means
        // nothing is listening. A timeout, or a permission error, means we do not know — and a
        // socket we do not understand is not ours to delete.
        switch BridgeSocketServer.probe(path) {
        case .live:
            throw BridgeSocketError.pathOccupied("A bridge host is already listening on \(path).")
        case .unknown(let code):
            throw BridgeSocketError.pathOccupied(
                "\(path) exists and could not be checked (errno \(code)). Refusing to replace it.")
        case .refused:
            unlink(path)
        }
    }

    /// The directory an endpoint lives in decides who can reach it.
    static func verifyPrivateParent(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else {
            throw BridgeSocketError.pathOccupied("The directory for \(path) does not exist.")
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)

        var info = stat()
        guard stat(canonical, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw BridgeSocketError.pathOccupied("\(canonical) is not a directory.")
        }
        guard info.st_uid == getuid() else {
            throw BridgeSocketError.pathOccupied("\(canonical) is not owned by this user.")
        }
        // No access at all for group or other. A private endpoint in a shared directory is not
        // private: anyone who can traverse the directory can reach what is inside it.
        guard (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 else {
            throw BridgeSocketError.pathOccupied(
                "\(canonical) is readable or writable by others (mode "
                + String(format: "%03o", info.st_mode & 0o777)
                + "). The socket would not be private; refusing.")
        }
    }

    /// Three answers, kept apart: something is listening, nothing is, or we could not tell.
    enum Probe {
        case live
        case refused
        case unknown(Int32)
    }

    static func probe(_ path: String) -> Probe {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno) }
        defer { close(fd) }
        // Non-blocking, so a full backlog cannot hold this up.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        guard var address = try? address(for: path) else { return .unknown(EINVAL) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if connected == 0 { return .live }
        switch errno {
        case ECONNREFUSED: return .refused         // definitively nobody there
        case EINPROGRESS, EALREADY, EAGAIN: return .live   // a backlog is still a listener
        default: return .unknown(errno)
        }
    }

    /// Who is on the other end of this connection?
    static func peerIsThisUser(_ fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listener
        let identity = boundInode
        listener = -1
        boundInode = nil
        lock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)                            // unblocks a waiting accept
            close(fd)
        }
        // Only remove the socket if it is still the one we created. Another host may have taken the
        // path in the meantime, and that one is not ours to delete.
        guard let identity else { return }
        var info = stat()
        if stat(path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode {
            unlink(path)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock(); let keepGoing = running; lock.unlock()
            guard keepGoing else { return }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return                                          // listener closed, or gone
            }
            // Only this user. A Unix socket at 0600 in a 0700 directory already says so; asking
            // the kernel who is on the other end says it again, at the point it matters.
            guard BridgeSocketServer.peerIsThisUser(client) else {
                close(client)
                continue
            }
            // Bounded: a flood queues rather than spawning workers without limit.
            workers.wait()
            workQueue.async { [weak self] in
                defer { self?.workers.signal() }
                self?.serve(client)
            }
        }
    }

    /// One connection: read bounded lines, answer each, and never wait for ever.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var deadline = timeval(tv_sec: Int(ioDeadline), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        var discardingOversized = false
        let hardStop = Date().addingTimeInterval(ioDeadline * 3)

        while Date() < hardStop {
            let read = recv(client, &chunk, chunk.count, 0)
            if read == 0 { return }                             // the caller went
            if read < 0 {
                if errno == EINTR { continue }
                return                                          // timed out or failed: close
            }
            buffer.append(contentsOf: chunk[0..<read])

            while let index = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                if discardingOversized {
                    // The tail of an oversized frame is not a frame. Dropped to the newline so a
                    // suffix cannot be read as a request in its own right.
                    discardingOversized = false
                    continue
                }
                _ = respond(client, answer(to: line))
            }
            if buffer.count > BridgeProtocol.maximumFrameBytes {
                _ = respond(client, BridgeResponse(
                    ok: false,
                    error: BridgeError(code: .malformed,
                                       message: "That frame is larger than this host will read.")))
                buffer.removeAll()
                discardingOversized = true
            }
        }
    }

    func answer(to line: Data) -> BridgeResponse {
        guard !line.isEmpty else {
            return BridgeResponse(ok: false, error: BridgeError(code: .malformed, message: "Empty frame."))
        }
        guard line.count <= BridgeProtocol.maximumFrameBytes else {
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .malformed, message: "Frame too large."))
        }
        guard let request = try? JSONCoding.decoder.decode(BridgeRequest.self, from: line) else {
            return BridgeResponse(ok: false,
                                  error: BridgeError(code: .malformed,
                                                     message: "That frame is not a bridge request."))
        }
        return host.handle(request)
    }

    @discardableResult
    private func respond(_ client: Int32, _ response: BridgeResponse) -> Bool {
        guard var data = try? JSONCoding.encoder.encode(response) else { return false }
        data.append(0x0A)
        return BridgeSocketServer.writeAll(client, data)
    }

    /// Writes the whole frame, or gives up. A short write is the normal case, not an error.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                let written = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if written > 0 { sent += written; continue }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maximum else { throw BridgeSocketError.pathTooLong }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                        source, maximum)
            }
        }
        return address
    }
}

public enum BridgeSocketError: Error, LocalizedError {
    case cannotCreate(Int32)
    case cannotBind(Int32)
    case cannotListen(Int32)
    case pathTooLong
    case pathOccupied(String)
    case noAnswer

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let code): return "could not create the socket (errno \(code))"
        case .cannotBind(let code): return "could not bind the socket (errno \(code))"
        case .cannotListen(let code): return "could not listen on the socket (errno \(code))"
        case .pathTooLong: return "the socket path is too long for a Unix socket"
        case .pathOccupied(let why): return why
        case .noAnswer: return "the bridge host did not answer"
        }
    }
}

/// The client half: connect, send one request, read one answer, within one deadline.
public enum BridgeSocketClient {
    public static func send(_ request: BridgeRequest, to path: String,
                            timeout: TimeInterval = 30) throws -> BridgeResponse {
        signal(SIGPIPE, SIG_IGN)
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid() else {
            throw BridgeSocketError.pathOccupied(
                "\(path) is not a socket owned by this user; refusing to speak to it.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeSocketError.cannotCreate(errno) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = try BridgeSocketServer.address(for: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { throw BridgeSocketError.cannotBind(errno) }
        // The client checks the endpoint too: a host running as somebody else is not our host.
        guard BridgeSocketServer.peerIsThisUser(fd) else {
            throw BridgeSocketError.pathOccupied("The socket at \(path) is served by another user.")
        }

        // Per-read *and* overall. A trickle that never finishes is a hang by another name.
        var slice = timeval(tv_sec: Int(max(1, timeout / 3)), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
        let hardStop = Date().addingTimeInterval(timeout)

        var payload = try JSONCoding.encoder.encode(request)
        payload.append(0x0A)
        guard BridgeSocketServer.writeAll(fd, payload) else { throw BridgeSocketError.noAnswer }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while Date() < hardStop {
            let read = recv(fd, &chunk, chunk.count, 0)
            if read == 0 { break }
            if read < 0 {
                if errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<read])
            if let index = buffer.firstIndex(of: 0x0A) {
                return try JSONCoding.decoder.decode(BridgeResponse.self,
                                                     from: Data(buffer[buffer.startIndex..<index]))
            }
            if buffer.count > BridgeProtocol.maximumFrameBytes { break }
        }
        // Nothing came back inside the deadline. That is not a failed request — it is not knowing
        // whether it was acted on, and saying so is the only honest answer.
        return BridgeResponse(ok: false,
                              error: BridgeError(code: .clientUnavailable,
                                                 message: "The bridge host did not answer within "
                                                        + "\(Int(timeout))s. Whether it acted on this "
                                                        + "request is unknown."))
    }
}
