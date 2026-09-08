import Foundation
import Testing
@testable import AgentAttentionCore

/// A Ghostty stand-in. Mirrors the real answers: the scripting API hands back a window id, a tab id
/// and a terminal id, and later tells you whether that terminal still exists.
private final class FakeSurfaces: GhosttySurfaceCreating, @unchecked Sendable {
    var created: [VisibleSessionPlan] = []
    var nextResult: Result<GhosttySurface, GhosttySurfaceFailure> = .success(
        GhosttySurface(windowID: "tab-group-1", tabID: "tab-1", terminalID: "TERM-1"))
    var living: Set<String> = ["TERM-1"]
    var focused: [String] = []
    var closed: [String] = []
    var hasWindow = true
    var closeFails = false

    func createSurface(_ plan: VisibleSessionPlan, inNewWindow: Bool)
        -> Result<GhosttySurface, GhosttySurfaceFailure> {
        created.append(plan)
        return nextResult
    }
    func surfaceExists(terminalID: String) -> Result<Bool, GhosttySurfaceFailure> {
        .success(living.contains(terminalID))
    }
    func focus(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        guard living.contains(terminalID) else { return .failure(.surfaceGone) }
        focused.append(terminalID)
        return .success(())
    }
    func close(terminalID: String) -> Result<Void, GhosttySurfaceFailure> {
        closed.append(terminalID)
        guard !closeFails else { return .failure(.scriptingFailed) }
        living.remove(terminalID)
        return .success(())
    }
    func hasOpenWindow() -> Bool { hasWindow }
}

@Suite("Visible session launcher")
struct VisibleLauncherTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-visible-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    private func launcher(_ surfaces: FakeSurfaces, root: URL) -> VisibleClaudeLauncher {
        VisibleClaudeLauncher(surfaces: surfaces, root: root, claudeExecutable: "/usr/bin/true",
                             relayExecutable: "/usr/bin/true")
    }

    @Test("Launching creates a surface and records the exact ids it was given")
    func identityIsRecorded() throws {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })

        #expect(surfaces.created.count == 1)
        let visible = try #require(handle as? VisibleClaudeHandle)
        #expect(visible.surface.terminalID == "TERM-1")
        #expect(visible.surface.tabID == "tab-1")
        #expect(visible.surface.windowID == "tab-group-1")
        handle.terminate()
    }

    @Test("The channel files are private to this user, in a private directory")
    func channelsArePrivate() throws {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })
        defer { handle.terminate() }

        // Production mutation this catches: creating the relay channel world-readable, which would
        // let any local process read a session's prompts and replies.
        let plan = try #require(surfaces.created.first)
        for path in [plan.inbox, plan.outbox] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            #expect(mode & 0o077 == 0, "\(path) is readable or writable by somebody else")
            #expect((attributes[.type] as? FileAttributeType) == .typeCharacterSpecial
                    || FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("A surface that could not be created is a launch failure, not a silent success",
          arguments: [GhosttySurfaceFailure.notInstalled, .permissionDenied, .scriptingFailed,
                      .surfaceGone])
    func surfaceFailuresAreReported(_ failure: GhosttySurfaceFailure) throws {
        let surfaces = FakeSurfaces()
        surfaces.nextResult = .failure(failure)
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            _ = try launcher(surfaces, root: root)
                .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in },
                        onExit: { _ in })
        }
        // And nothing is left behind for a session that never started.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.allSatisfy { !$0.contains("S-1") },
                "a failed launch leaves no channel files")
    }

    @Test("A cwd that is not a plain path never reaches the terminal")
    func hostilePathsAreRefusedBeforeAnySurface() {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            _ = try launcher(surfaces, root: root)
                .launch(sessionID: "S-1", cwd: "/tmp/x; rm -rf ~", model: nil, onLine: { _ in },
                        onExit: { _ in })
        }
        #expect(surfaces.created.isEmpty, "no surface is created for a command we would not run")
    }

    @Test("Liveness is the surface's, not our own intent")
    func livenessFollowsTheSurface() throws {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })
        #expect(handle.isRunning)

        surfaces.living.remove("TERM-1")            // the user closed the tab
        #expect(!handle.isRunning, "a closed tab is a session that has gone")
        handle.terminate()
    }

    @Test("Stopping closes the surface this launcher created, and only that one")
    func stopClosesOnlyOwnSurface() throws {
        let surfaces = FakeSurfaces()
        surfaces.living.insert("SOMEONE-ELSE")
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })

        handle.terminate()

        #expect(surfaces.closed == ["TERM-1"])
        #expect(surfaces.living.contains("SOMEONE-ELSE"),
                "a tab this app did not create is never touched")
    }

    @Test("Stopping removes the channel files it made")
    func stopCleansUpChannels() throws {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })
        let plan = try #require(surfaces.created.first)

        handle.terminate()
        var waited = 0
        while FileManager.default.fileExists(atPath: plan.inbox) && waited < 200 {
            usleep(10_000); waited += 1
        }
        #expect(!FileManager.default.fileExists(atPath: plan.inbox))
        #expect(!FileManager.default.fileExists(atPath: plan.outbox))
    }

    @Test("Focus asks for the exact terminal that was created")
    func focusUsesTheRecordedIdentity() throws {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })
        defer { handle.terminate() }

        let visible = try #require(handle as? VisibleClaudeHandle)
        #expect(visible.focus())
        #expect(surfaces.focused == ["TERM-1"], "no searching, no guessing, no pairing step")
    }

    @Test("With no Ghostty window open, the surface is created in a new window")
    func aNewWindowIsUsedWhenThereIsNone() throws {
        let surfaces = FakeSurfaces()
        surfaces.hasWindow = false
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let handle = try launcher(surfaces, root: root)
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in }, onExit: { _ in })
        defer { handle.terminate() }
        #expect(surfaces.created.count == 1)
    }
}

/// A launcher that records what it was asked for and hands back a fake visible handle.
private final class RecordingVisibleLauncher: BridgeClientLaunching, @unchecked Sendable {
    let surfaces = FakeSurfaces()
    private(set) var launches = 0
    var failure: Error?

    func launch(sessionID: String, cwd: String, model: String?,
                onLine: @escaping (String) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> BridgeClientHandle {
        launches += 1
        if let failure { throw failure }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-visible-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try VisibleClaudeLauncher(surfaces: surfaces, root: root,
                                         claudeExecutable: "/usr/bin/true",
                                         relayExecutable: "/usr/bin/true")
            .launch(sessionID: sessionID, cwd: cwd, model: model, onLine: onLine, onExit: onExit)
    }
}

/// The API surface: opt-in, default-unchanged, and honest refusals.
@Suite("Visible sessions through the bridge")
struct VisibleBridgeTests {
    private let scratch = FileManager.default.temporaryDirectory.path

    private func host(visible: BridgeClientLaunching? = nil)
        -> (BridgeHost, FakeLauncher, RecordingVisibleLauncher?) {
        let background = FakeLauncher()
        let recording = visible as? RecordingVisibleLauncher
        return (BridgeHost(launcher: background, approvedRoots: [scratch],
                           visibleLauncher: visible), background, recording)
    }

    @Test("Without --terminal, a session is exactly the background one it always was")
    func theDefaultIsUnchanged() {
        // Production mutation this catches: making the visible launcher the default, which would
        // open a terminal for every existing caller that never asked for one.
        let visible = RecordingVisibleLauncher()
        let (bridge, background, _) = host(visible: visible)
        let response = bridge.handle(.start(.init(requestID: "r1", cwd: scratch)))

        #expect(response.ok)
        #expect(background.launched.count == 1)
        #expect(visible.launches == 0)
        #expect(response.session?.surface == nil, "no terminal was asked for, so none is reported")
    }

    @Test("With --terminal ghostty, the session opens in a surface and reports its identity")
    func theOptInOpensASurface() {
        let visible = RecordingVisibleLauncher()
        let (bridge, background, _) = host(visible: visible)
        let response = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                  terminal: "ghostty")))

        #expect(response.ok)
        #expect(visible.launches == 1)
        #expect(background.launched.isEmpty, "the background client is not started as well")
        let surface = response.session?.surface
        #expect(surface?.terminal == "ghostty")
        #expect(surface?.terminalID == "TERM-1")
        #expect(surface?.tabID == "tab-1")
        #expect(surface?.open == true)
        #expect(surface?.acceptsTyping == false, "and the answer says so, rather than implying it")
        #expect(surface?.note.lowercased().contains("typing") == true)
        _ = bridge.handle(.stop(sessionID: response.session!.sessionID))
    }

    @Test("A terminal nobody supports is refused, not quietly downgraded", arguments: [
        "iterm", "Terminal", "tmux", "kitty", "anything",
    ])
    func unknownTerminalsAreRefused(_ terminal: String) {
        let visible = RecordingVisibleLauncher()
        let (bridge, background, _) = host(visible: visible)
        let response = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                  terminal: terminal)))

        #expect(!response.ok)
        #expect(visible.launches == 0)
        #expect(background.launched.isEmpty,
                "a caller that asked to see its session must not get a hidden one instead")
    }

    @Test("A host with no visible launcher refuses rather than starting a hidden session")
    func withoutSupportItRefuses() {
        let (bridge, background, _) = host(visible: nil)
        let response = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                  terminal: "ghostty")))
        #expect(!response.ok)
        #expect(response.error?.code == .clientUnavailable)
        #expect(background.launched.isEmpty)
    }

    @Test("A surface that cannot be created is a failed start, with nothing left running")
    func surfaceFailureIsAFailedStart() {
        let visible = RecordingVisibleLauncher()
        visible.failure = VisibleSessionError.surface(.permissionDenied)
        let (bridge, _, _) = host(visible: visible)

        let response = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                  terminal: "ghostty")))
        #expect(!response.ok)
        #expect(response.error?.code == .clientUnavailable)
        #expect(response.session?.phase == .failed)
        #expect(!bridge.hasRunningClients, "nothing is left behind by a start that failed")
    }

    @Test("The same request id asking for a different surface is a conflict, not a retry")
    func surfaceIsPartOfTheIntent() {
        let visible = RecordingVisibleLauncher()
        let (bridge, _, _) = host(visible: visible)
        let first = bridge.handle(.start(.init(requestID: "r1", cwd: scratch)))
        #expect(first.ok)

        let second = bridge.handle(.start(.init(requestID: "r1", cwd: scratch, terminal: "ghostty")))
        #expect(second.error?.code == .idempotencyConflict,
                "‘the same request’ has to mean the same session, in the same place")
    }

    @Test("Focus asks for the exact created terminal, and only for a visible session")
    func focusIsExactAndScoped() {
        let visible = RecordingVisibleLauncher()
        let (bridge, _, _) = host(visible: visible)
        let started = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                 terminal: "ghostty"))).session!

        #expect(bridge.handle(.focus(sessionID: started.sessionID)).ok)
        #expect(visible.surfaces.focused == ["TERM-1"])

        let background = bridge.handle(.start(.init(requestID: "r2", cwd: scratch))).session!
        let refused = bridge.handle(.focus(sessionID: background.sessionID))
        #expect(!refused.ok, "a background session has no terminal of its own to bring forward")
        #expect(visible.surfaces.focused == ["TERM-1"])
        _ = bridge.handle(.stop(sessionID: started.sessionID))
    }

    @Test("Focusing a session this host did not start is refused")
    func focusIsOwnedOnly() {
        let (bridge, _, _) = host(visible: RecordingVisibleLauncher())
        #expect(bridge.handle(.focus(sessionID: UUID().uuidString)).error?.code == .notOwned)
    }

    @Test("Closing the tab is reported as the session having gone")
    func aClosedTabEndsTheSession() {
        let visible = RecordingVisibleLauncher()
        let (bridge, _, _) = host(visible: visible)
        let started = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                 terminal: "ghostty"))).session!
        #expect(bridge.hasRunningClients)

        visible.surfaces.living.remove("TERM-1")        // the user closed it

        #expect(!bridge.hasRunningClients, "a closed tab is not a running session")
        #expect(bridge.handle(.status(sessionID: started.sessionID)).session?.surface?.open == false)
    }

    @Test("Stopping closes the created surface and leaves every other one alone")
    func stopIsScopedToTheOwnedSurface() {
        let visible = RecordingVisibleLauncher()
        visible.surfaces.living.insert("USERS-OWN-TAB")
        let (bridge, _, _) = host(visible: visible)
        let started = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                 terminal: "ghostty"))).session!

        _ = bridge.handle(.stop(sessionID: started.sessionID))

        #expect(visible.surfaces.closed == ["TERM-1"])
        #expect(visible.surfaces.living.contains("USERS-OWN-TAB"))
    }

    @Test("A visible session takes prompts and correlates them exactly like a background one")
    func correlationIsUnchanged() throws {
        let visible = RecordingVisibleLauncher()
        let (bridge, _, _) = host(visible: visible)
        let started = bridge.handle(.start(.init(requestID: "r1", cwd: scratch,
                                                 terminal: "ghostty"))).session!

        // A relay would be reading the inbox; here the test is that relay, so the write has a
        // reader and must genuinely succeed. Accepting a failure as "fine" would have let a
        // completely broken send path pass.
        //
        // The reader is opened **non-blocking, and first**. A FIFO opened for reading the ordinary
        // way waits for a writer, and this session's writer only opens inside the send below — so
        // the blocking shape waits for a peer that cannot arrive until the wait ends. That is a
        // deadlock in the test, not in the code under test, and the fix belongs here.
        let plan = try #require(visible.surfaces.created.first)
        let descriptor = open(plan.inbox, O_RDONLY | O_NONBLOCK)
        #expect(descriptor >= 0, "the inbox this session was given can be opened for reading")
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor) }

        let sent = bridge.handle(.send(.init(sessionID: started.sessionID, messageID: "m1",
                                             prompt: "hello")))
        #expect(sent.ok, "the prompt reached the session's own pipe")
        #expect(sent.session?.messages.first?.messageID == "m1")

        // And what arrived is the documented frame, carrying the join key correlation depends on.
        // Read with a bound: a non-blocking descriptor returns nothing until the bytes land, so
        // this polls briefly rather than waiting on a pipe with no deadline.
        var arrived = Data()
        let deadline = Date().addingTimeInterval(5)
        while !arrived.contains(0x0A), Date() < deadline {
            arrived.append(reader.availableData)
            if !arrived.contains(0x0A) { usleep(20_000) }
        }
        let firstLine = try #require(arrived.firstIndex(of: 0x0A).map { arrived[..<$0] })
        let frame = try #require(try JSONSerialization.jsonObject(
            with: Data(firstLine)) as? [String: Any])
        #expect((frame["type"] as? String) == "user")
        #expect(UUID(uuidString: frame["uuid"] as? String ?? "") != nil)
        #expect((frame["session_id"] as? String) == started.sessionID)

        _ = bridge.handle(.stop(sessionID: started.sessionID))
    }
}

/// The gaps a review found in the visible launcher: a session that ends on its own, and a relay
/// that never starts.
@Suite("Visible session lifecycle")
struct VisibleLifecycleTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("warden-visible-life-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test("A session that ends on its own reports its exit exactly once")
    func naturalExitIsReported() throws {
        // Production mutation this catches: the reader thread reaching EOF and returning without
        // calling `onExit`. The background launcher fires it from the process's own termination
        // handler; without the same here, a closed tab leaves the session with no exit status, its
        // phase never settled and its in-flight turn never released — so the next send is refused
        // as busy for ever.
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let exits = Box<Int>()
        exits.value = 0
        let reported = DispatchSemaphore(value: 0)

        let handle = try VisibleClaudeLauncher(surfaces: surfaces, root: root,
                                               claudeExecutable: "/usr/bin/true",
                                               relayExecutable: "/usr/bin/true")
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in },
                    onExit: { _ in
                        exits.value = (exits.value ?? 0) + 1
                        reported.signal()
                    })

        // Stand in for the relay: open the outbox, then close it, exactly as the relay does when
        // Claude finishes or the tab is closed.
        let plan = try #require(surfaces.created.first)
        let writer = try #require(FileHandle(forWritingAtPath: plan.outbox))
        try writer.close()

        #expect(reported.wait(timeout: .now() + 5) == .success,
                "the session ending must reach the host")
        #expect(exits.value == 1)

        handle.terminate()
        usleep(200_000)
        #expect(exits.value == 1, "and stopping afterwards does not report a second exit")
    }

    @Test("A missing relay is refused before any terminal is opened")
    func aMissingRelayIsRefused() {
        // Production mutation this catches: validating the relay path's *shape* but never checking
        // it is there. Ghostty would open a tab whose command fails instantly, the relay would
        // never open its end of the pipe, and the reader thread would block on that open for ever
        // while the channel files stayed on disk.
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            _ = try VisibleClaudeLauncher(surfaces: surfaces, root: root,
                                          claudeExecutable: "/usr/bin/true",
                                          relayExecutable: "/usr/bin/no-such-relay-binary")
                .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in },
                        onExit: { _ in })
        }
        #expect(surfaces.created.isEmpty, "no tab is opened for a command that cannot run")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("visible").path)) ?? []
        #expect(leftovers.isEmpty, "and no channel files are left behind")
    }

    @Test("A missing Claude executable is refused the same way")
    func aMissingClaudeIsRefused() {
        let surfaces = FakeSurfaces()
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            _ = try VisibleClaudeLauncher(surfaces: surfaces, root: root,
                                          claudeExecutable: "/usr/bin/no-such-claude",
                                          relayExecutable: "/usr/bin/true")
                .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in },
                        onExit: { _ in })
        }
        #expect(surfaces.created.isEmpty)
    }

    @Test("A surface that will not close is reported, not called a clean stop")
    func aFailedCloseIsHonest() throws {
        let surfaces = FakeSurfaces()
        surfaces.closeFails = true
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let statuses = Box<Int32>()
        let handle = try VisibleClaudeLauncher(surfaces: surfaces, root: root,
                                               claudeExecutable: "/usr/bin/true",
                                               relayExecutable: "/usr/bin/true")
            .launch(sessionID: "S-1", cwd: root.path, model: nil, onLine: { _ in },
                    onExit: { statuses.value = $0 })

        handle.terminate()
        #expect(statuses.value != 0,
                "a terminal that would not close is not a session that stopped cleanly")
    }

    @Test("The transcript header cannot be steered by a directory or model name")
    func theHeaderIsSanitisedToo() {
        let header = TranscriptRenderer.header(
            sessionID: "S-1",
            cwd: "/Users/me/\u{1B}[2Jwiped",
            model: "opus\u{07}\u{1B}]0;stolen\u{07}")
        let text = header.joined()
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\u{07}"))
    }
}

/// The script that actually reaches Ghostty. Checked because a missing parameter here does not
/// come back as an error — it comes back as a request that never returns.
@Suite("Ghostty surface script")
struct GhosttySurfaceScriptTests {
    /// Captures the source instead of running it.
    private final class CapturingExecutor: ScriptExecuting, @unchecked Sendable {
        var sources: [String] = []
        var answer = "TERM-1\ntab-1"
        func execute(_ source: String) -> Result<String, GhosttyFailure> {
            sources.append(source)
            if source.contains("count of windows") { return .success("1") }
            if source.contains("id of front window") { return .success("win-1") }
            return .success(answer)
        }
    }

    private func plan() -> VisibleSessionPlan {
        VisibleSessionPlan(sessionID: "S-1", cwd: "/private/tmp", model: nil,
                           claudeExecutable: "/usr/bin/true", relayExecutable: "/usr/bin/true",
                           inbox: "/private/tmp/in", outbox: "/private/tmp/out",
                           withoutTools: false)!
    }

    @Test("Creating a tab names the window to put it in")
    func aTabNamesItsWindow() {
        // Production mutation this catches: `new tab with configuration` without `in front window`.
        // Ghostty answers -1708, and through NSAppleScript that arrives as no answer at all — the
        // call hangs until its budget expires, which is how a launch turned into a 30-second
        // timeout with no tab and no error.
        let executor = CapturingExecutor()
        _ = GhosttySurfaceAdapter(executor: executor).createSurface(plan(), inNewWindow: false)

        let creation = executor.sources.first { $0.contains("new tab") }
        #expect(creation != nil)
        #expect(creation?.contains("new tab in front window with configuration") == true)
    }

    @Test("Creating a window asks for its selected tab, not the window itself")
    func aWindowResolvesToItsTab() {
        let executor = CapturingExecutor()
        _ = GhosttySurfaceAdapter(executor: executor).createSurface(plan(), inNewWindow: true)

        let creation = executor.sources.first { $0.contains("new window") }
        #expect(creation?.contains("selected tab of theWindow") == true)
        #expect(creation?.contains("focused terminal of theTab") == true)
    }

    @Test("The command and working directory reach the script as written")
    func theCommandIsCarried() {
        let executor = CapturingExecutor()
        let subject = plan()
        _ = GhosttySurfaceAdapter(executor: executor).createSurface(subject, inNewWindow: false)

        let creation = executor.sources.first { $0.contains("new tab") }
        #expect(creation?.contains(subject.command) == true)
        #expect(creation?.contains("initial working directory of cfg to \"/private/tmp\"") == true)
    }
}
