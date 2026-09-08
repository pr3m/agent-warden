import Foundation
import Testing
@testable import AgentAttentionCore

/// Real macOS process inspection. These exercise the platform, but only read-only, and only about
/// this test process and its own ancestors.
@Suite("Process probing")
struct ProcessProbeTests {

    @Test("We can snapshot ourselves")
    func snapshotOfSelf() throws {
        let snapshot = try #require(ProcessProbe.snapshot(pid: getpid()))
        #expect(snapshot.pid == getpid())
        #expect(snapshot.ppid == getppid())
        #expect(snapshot.startedAt > 1_000_000_000)
        #expect(!snapshot.command.isEmpty)
    }

    @Test("Ancestry starts with us and climbs without looping")
    func ancestryWalk() {
        let chain = ProcessProbe.ancestry(of: getpid())
        #expect(chain.count >= 2)
        #expect(chain.first?.pid == getpid())
        #expect(Set(chain.map(\.pid)).count == chain.count)
        #expect(ProcessProbe.ancestry(of: getpid(), limit: 3).count <= 3)
    }

    @Test("An executable path resolves for ourselves")
    func executablePath() throws {
        #expect(try #require(ProcessProbe.executablePath(pid: getpid())).hasPrefix("/"))
    }

    @Test("An unknown pid yields nothing")
    func unknownPid() {
        #expect(ProcessProbe.snapshot(pid: 999_999) == nil)
        #expect(ProcessProbe.isAlive(pid: 999_999) == false)
    }

    @Test("Liveness accepts us and rejects a wrong start time")
    func livenessStartTimeGuard() throws {
        let probe = SystemLiveness()
        let actual = try #require(ProcessProbe.snapshot(pid: getpid())?.startedAt)

        #expect(probe.isAlive(pid: getpid(), startedAt: nil))
        #expect(probe.isAlive(pid: getpid(), startedAt: actual))
        #expect(probe.isAlive(pid: getpid(), startedAt: actual - 86_400) == false,
                "a recycled pid with a different start time is not the session we recorded")
    }

    @Test("Liveness rejects a process that has exited")
    func livenessAfterExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, SystemLiveness().isAlive(pid: pid, startedAt: nil) {
            usleep(50_000)
        }
        #expect(SystemLiveness().isAlive(pid: pid, startedAt: nil) == false)
    }

    @Test("Claude is recognised by path, not just by name")
    func claudeDetection() {
        // A released CLI lives at ~/.local/share/claude/versions/<version>, so p_comm reads as the
        // version number. This is exactly what defeats a name-only heuristic.
        #expect(ProcessProbe.looksLikeClaude(command: "2.1.261", executablePath: "/Users/dev/.local/share/claude/versions/2.1.261"))
        #expect(ProcessProbe.looksLikeClaude(command: "claude", executablePath: nil))
        #expect(ProcessProbe.looksLikeClaude(command: "node", executablePath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"))
        #expect(ProcessProbe.looksLikeClaude(command: "node", executablePath: "/opt/homebrew/bin/claude"))
    }

    @Test("Anything we have not positively identified is not called Claude", arguments: [
        ("zsh", "/bin/zsh"),
        ("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ("codex", "/Applications/ChatGPT.app/Contents/Resources/codex"),
        // The trap the old heuristic fell into: a plain shell that merely mentions the word.
        ("zsh", "/Users/dev/projects/claude-notes/bin/zsh"),
        ("node", "/Users/dev/src/my-claude-experiment/server.js"),
    ])
    func nonClaudeProcesses(command: String, path: String) {
        #expect(ProcessProbe.looksLikeClaude(command: command, executablePath: path) == false)
    }

    @Test("An unidentifiable ancestry yields no process, never a guess")
    func noFallbackToAnyTtyOwner() {
        // Previously the first ancestor owning a tty was accepted. That is either the transient
        // shell the hook ran in, or an unrelated long-lived login shell — and everything
        // downstream treats it as the session's own process.
        let identity = SessionIdentityBuilder.build(
            payload: ["session_id": "s1", "cwd": "/Users/dev/code/alpha"],
            environment: [:],
            pid: getpid(),
            locate: { _ in (nil, "/Applications/Ghostty.app") }
        )
        #expect(identity.claudePID == nil)
        #expect(identity.claudePIDStartedAt == nil)
    }

    @Test("Identity is built from the payload, the environment and the process tree")
    func identityBuilder() {
        let identity = SessionIdentityBuilder.build(
            payload: ["session_id": "sess-1", "cwd": "/Users/dev/code/alpha"],
            environment: [
                "TERM_PROGRAM": "iTerm.app",
                "ITERM_SESSION_ID": "w0t2p0:ABCD-EF",
                "TMUX": "/private/tmp/tmux-501/default,1234,0",
                "TMUX_PANE": "%3",
            ],
            pid: getpid(),
            locate: { _ in (ProcSnapshot(pid: 4242, ppid: 1, startedAt: 111, command: "claude", tty: "/dev/ttys009"), "/Applications/iTerm.app") }
        )

        #expect(identity.sessionID == "sess-1")
        #expect(identity.projectName == "alpha")
        #expect(identity.claudePID == 4242)
        #expect(identity.claudePIDStartedAt == 111)
        #expect(identity.tty == "/dev/ttys009")
        #expect(identity.itermSessionID == "w0t2p0:ABCD-EF")
        #expect(identity.tmuxPane == "%3")
        #expect(identity.tmuxSocket == "/private/tmp/tmux-501/default")
        #expect(TerminalTarget.plan(for: identity).confidence == .exactTab)
    }

    @Test("Identity building copes with an empty payload")
    func identityBuilderEmptyPayload() {
        let identity = SessionIdentityBuilder.build(payload: [:], environment: [:], pid: getpid(), locate: { _ in (nil, nil) })
        #expect(identity.sessionID == "unknown")
        #expect(!identity.cwd.isEmpty)
        #expect(identity.claudePID == nil)
        #expect(TerminalTarget.plan(for: identity).confidence == .none)
    }

    @Test("Hook ingestion produces a heartbeat for every event and a spool record only when needed")
    func ingestionOutcomes() {
        let identity = Fixture.identity(session: "s1")

        let work = HookIngestion.process(
            payload: ["hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Read"],
            identity: identity, now: Fixture.origin, config: .default
        )
        #expect(work.event == nil)
        #expect(work.heartbeat.lastSignal == .activity)
        #expect(work.heartbeat.lastHookEvent == "PostToolUse")

        let ask = HookIngestion.process(
            payload: ["hook_event_name": "Notification", "session_id": "s1", "notification_type": "permission_prompt"],
            identity: identity, now: Fixture.origin, config: .default
        )
        #expect(ask.event?.attentionKind == .approval)
        #expect(ask.heartbeat.lastSignal == .attention)
    }
}
