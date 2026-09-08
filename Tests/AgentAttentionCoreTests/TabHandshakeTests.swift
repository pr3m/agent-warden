import Foundation
import Testing
@testable import AgentAttentionCore

/// A stand-in for Ghostty plus a set of tabs, where writing a title to a tty changes the name of
/// exactly the terminal that owns it — which is the real behaviour the handshake depends on.
private final class FakeTerminals: TerminalTitleWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]          // terminalID → name
    private let ttys: [String: String]           // tty → terminalID
    private var failReads: Int
    private var refuseWrite: Bool
    private(set) var writes: [(tty: String, title: String)] = []

    init(names: [String: String], ttys: [String: String],
         failReads: Int = 0, refuseWrite: Bool = false) {
        self.names = names
        self.ttys = ttys
        self.failReads = failReads
        self.refuseWrite = refuseWrite
    }

    func setTitle(_ title: String, onTTY tty: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if refuseWrite { return false }
        writes.append((tty, title))
        // Only the terminal that owns this tty can be renamed by writing to it. That is the whole
        // basis of the handshake, so the fake models it exactly.
        guard let terminalID = ttys[tty] else { return true }
        names[terminalID] = title
        return true
    }

    func readAll() -> Result<[TerminalSnapshot], GhosttyFailure> {
        lock.lock(); defer { lock.unlock() }
        if failReads > 0 { failReads -= 1; return .failure(.busy) }
        return .success(names.map { TerminalSnapshot(terminalID: $0.key, tabID: "tab-\($0.key)",
                                                     windowID: "win-1", name: $0.value,
                                                     workingDirectory: "/tmp/project") }
            .sorted { $0.terminalID < $1.terminalID })
    }

    var currentNames: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }
}

private func handshake(_ fake: FakeTerminals, attempts: Int = 5) -> TabHandshake {
    TabHandshake(titles: fake, readAll: { fake.readAll() },
                 attempts: attempts, interval: 0, pause: { _ in })
}

@Suite("Linking a session to its tab without asking")
struct TabHandshakeTests {

    /// The case that made linking manual: four tabs, one repository, identical working directories
    /// and interchangeable titles. Nothing about a name or a directory can tell them apart — only
    /// the tty can, and this is how the tty is turned into an answer.
    @Test("The terminal that owns the session's tty identifies itself, even among identical tabs")
    func theRightTabAnswers() throws {
        let fake = FakeTerminals(
            names: ["T-1": "redmy", "T-2": "redmy", "T-3": "redmy", "T-4": "redmy"],
            ttys: ["/dev/ttys003": "T-3"])

        let found = try handshake(fake).identifyTerminal(onTTY: "/dev/ttys003").get()

        #expect(found.terminalID == "T-3", "the tab that owns the tty, not one that looks like it")
    }

    @Test("The tab is left with the name it had before, not the token")
    func theTitleIsPutBack() throws {
        let fake = FakeTerminals(names: ["T-1": "velocity analysis"], ttys: ["/dev/ttys001": "T-1"])

        _ = try handshake(fake).identifyTerminal(onTTY: "/dev/ttys001").get()

        #expect(fake.currentNames["T-1"] == "velocity analysis",
                "a link that renames somebody's tab is not a link they asked for")
    }

    @Test("What is reported is the tab's own name, so the user recognises it")
    func theSnapshotCarriesTheRealName() throws {
        let fake = FakeTerminals(names: ["T-9": "release prep"], ttys: ["/dev/ttys009": "T-9"])

        let found = try handshake(fake).identifyTerminal(onTTY: "/dev/ttys009").get()

        #expect(found.name == "release prep")
        #expect(found.terminalID == "T-9")
    }

    @Test("A session in no Ghostty tab links to nothing at all")
    func aSessionElsewhereIsNotLinked() {
        // The tty belongs to no terminal Ghostty knows: tmux, another terminal, a detached process.
        let fake = FakeTerminals(names: ["T-1": "redmy", "T-2": "wunda"], ttys: [:])

        let outcome = handshake(fake).identifyTerminal(onTTY: "/dev/ttys099")

        #expect(outcome == .failure(.noTerminalAnswered),
                "no answer means no link — never the closest-looking tab")
    }

    @Test("A session with no terminal device is refused before anything is written")
    func noTTYMeansNoHandshake() {
        let fake = FakeTerminals(names: ["T-1": "redmy"], ttys: ["/dev/ttys001": "T-1"])

        for tty in [nil, "", "-"] {
            #expect(handshake(fake).identifyTerminal(onTTY: tty) == .failure(.noTTY))
        }
        #expect(fake.writes.isEmpty, "nothing is written to a device we were not given")
    }

    @Test("A token left over from a previous attempt is refused, not matched")
    func aStaleTokenIsRefused() {
        let fake = FakeTerminals(names: ["T-1": "⟦agent-warden:old⟧", "T-2": "redmy"],
                                 ttys: ["/dev/ttys002": "T-2"])

        #expect(handshake(fake).identifyTerminal(onTTY: "/dev/ttys002") == .failure(.ambiguous))
        #expect(fake.writes.isEmpty, "and nothing is written while the screen is in that state")
    }

    @Test("A tty that cannot be written to is a failure, not a guess")
    func anUnwritableTTYFails() {
        let fake = FakeTerminals(names: ["T-1": "redmy"], ttys: ["/dev/ttys001": "T-1"],
                                 refuseWrite: true)

        #expect(handshake(fake).identifyTerminal(onTTY: "/dev/ttys001") == .failure(.couldNotWrite))
    }

    @Test("Ghostty being busy for a moment does not lose the answer")
    func aTransientRefusalIsRetried() throws {
        // The first read fails outright, so the pre-read cannot even start; the handshake reports it.
        let blocked = FakeTerminals(names: ["T-1": "redmy"], ttys: ["/dev/ttys001": "T-1"], failReads: 1)
        #expect(handshake(blocked).identifyTerminal(onTTY: "/dev/ttys001") == .failure(.ghostty(.busy)))

        // A refusal *during* polling is transient, and the next attempt still finds the tab.
        let flaky = FakeTerminals(names: ["T-1": "redmy"], ttys: ["/dev/ttys001": "T-1"])
        let subject = TabHandshake(titles: flaky,
                                   readAll: { flaky.readAll() },
                                   attempts: 5, interval: 0, pause: { _ in })
        #expect(try subject.identifyTerminal(onTTY: "/dev/ttys001").get().terminalID == "T-1")
    }

    @Test("Every attempt uses a token of its own")
    func tokensDoNotRepeat() {
        let one = TabHandshake.makeToken()
        let two = TabHandshake.makeToken()
        #expect(one != two, "a reused token could be answered by a stale title")
        #expect(one.hasPrefix("⟦agent-warden:") && one.hasSuffix("⟧"))
    }

    /// The token is addressed to the terminal emulator, not to the program in the tab.
    @Test("The handshake writes a title and nothing else — it never types into a session")
    func nothingIsTypedIntoTheSession() throws {
        let fake = FakeTerminals(names: ["T-1": "agent-warden"], ttys: ["/dev/ttys004": "T-1"])

        _ = try handshake(fake).identifyTerminal(onTTY: "/dev/ttys004").get()

        #expect(fake.writes.count == 2, "one token, one restore, and no third thing")
        #expect(fake.writes.allSatisfy { $0.tty == "/dev/ttys004" },
                "and only ever to the session's own device")
    }
}
