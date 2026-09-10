import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("Terminal pairing")
struct PairingTests {
    private func pairing(
        session: String = "sess-1",
        claudePID: Int32 = 100,
        claudeStart: Double = 500,
        ghosttyPID: Int32 = 900,
        ghosttyStart: Double = 1000,
        terminalID: String = "term-1"
    ) -> TerminalPairing {
        TerminalPairing(
            sessionID: session, claudePID: claudePID, claudePIDStartedAt: claudeStart, tty: "/dev/ttys004",
            terminalAppBundleID: "com.mitchellh.ghostty",
            terminalAppPID: ghosttyPID, terminalAppStartedAt: ghosttyStart,
            terminalID: terminalID, tabID: "tab-1", windowID: "win-1",
            terminalName: "task42-own-capital", workingDirectory: "/w/task42-own-capital",
            pairedAt: Fixture.origin
        )
    }

    // MARK: - Is this link still worth anything?

    @Test("A link whose two processes are unchanged and whose tab still exists is valid")
    func validLink() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 1000), terminalExists: true) == .valid)
    }

    @Test("No link is not a broken link")
    func noLink() {
        #expect(PairingValidator.validate(pairing: nil, sessionPID: 100, sessionPIDStartedAt: 500,
                                          ghostty: ProcessFingerprint(pid: 900, startedAt: 1000),
                                          terminalExists: true) == .none)
    }

    @Test("A relaunched Ghostty invalidates the link — a terminal id means nothing across runs")
    func ghosttyRelaunched() {
        let verdict = PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: ProcessFingerprint(pid: 901, startedAt: 2000), terminalExists: true)
        #expect(verdict == .terminalAppChanged)
        #expect(!verdict.isUsable)
        #expect(verdict.explanation.contains("Link the tab again"))
    }

    @Test("A recycled Ghostty pid at a different birth time is still a different Ghostty")
    func recycledGhosttyPID() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 9999), terminalExists: true) == .terminalAppChanged)
    }

    @Test("A recycled Claude pid cannot inherit another session's tab")
    func recycledClaudePID() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 8888,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 1000), terminalExists: true) == .sessionChanged)
    }

    @Test("A session with no identified process cannot be matched to a link")
    func unidentifiedSession() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: nil, sessionPIDStartedAt: nil,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 1000), terminalExists: true) == .sessionChanged)
    }

    @Test("Ghostty not running is its own answer, not a failure of the link")
    func ghosttyNotRunning() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: nil, terminalExists: nil) == .terminalAppNotRunning)
    }

    @Test("A tab that has closed invalidates the link rather than redirecting it")
    func terminalClosed() {
        #expect(PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 1000), terminalExists: false) == .terminalMissing)
    }

    @Test("Not being able to check is not permission to proceed")
    func inspectionDenied() {
        let verdict = PairingValidator.validate(
            pairing: pairing(), sessionPID: 100, sessionPIDStartedAt: 500,
            ghostty: ProcessFingerprint(pid: 900, startedAt: 1000), terminalExists: nil)
        #expect(verdict == .inspectionDenied)
        #expect(!verdict.isUsable)
    }

    @Test("A start time a second or two apart is the same process; hours apart is not")
    func fingerprintTolerance() {
        let recorded = ProcessFingerprint(pid: 900, startedAt: 1000)
        #expect(ProcessFingerprint(pid: 900, startedAt: 1001).matches(recorded))
        #expect(!ProcessFingerprint(pid: 900, startedAt: 1100).matches(recorded))
        #expect(!ProcessFingerprint(pid: 901, startedAt: 1000).matches(recorded))
    }

    // MARK: - What the plan promises

    @Test("Without a link, a Ghostty session is honestly app-only")
    func unpairedGhosttyIsAppOnly() {
        let identity = Fixture.identity(session: "sess-1", project: "alpha")
        var ghostty = identity
        ghostty.termProgram = "ghostty"
        ghostty.terminalAppPath = "/Applications/Ghostty.app"

        let plan = TerminalTarget.plan(for: ghostty)
        #expect(plan.confidence == .appOnly)
        #expect(plan.actionLabel == "Open Ghostty")
        #expect(!plan.steps.contains { if case .ghosttyFocus = $0 { return true } else { return false } })
    }

    @Test("With a confirmed link, it is exact — and says so in the label")
    func pairedGhosttyIsExact() {
        var identity = Fixture.identity(session: "sess-1", project: "alpha")
        identity.termProgram = "ghostty"
        identity.terminalAppPath = "/Applications/Ghostty.app"

        let plan = TerminalTarget.plan(for: identity, pairing: pairing())
        #expect(plan.confidence == .exactTab)
        #expect(plan.actionLabel == "Open linked tab")
        #expect(plan.steps.first == .ghosttyFocus(terminalID: "term-1"))
        #expect(plan.explanation.contains("you linked"))
    }

    @Test("A terminal id is never derived from a tty, a title or a directory")
    func nothingIsSynthesised() {
        var identity = Fixture.identity(session: "sess-1", project: "task42-own-capital")
        identity.termProgram = "ghostty"
        identity.terminalAppPath = "/Applications/Ghostty.app"
        identity.tty = "/dev/ttys004"
        identity.title = "task42-own-capital"

        // Everything a guess could be built from is present, and no link is. Still app-only.
        let plan = TerminalTarget.plan(for: identity, pairing: nil)
        #expect(plan.confidence == .appOnly)
    }

    // MARK: - The store

    @Test("Links round-trip, replace rather than accumulate, and can be removed")
    func storeRoundTrip() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)

        #expect(store.pairing(for: "sess-1") == nil)
        try store.put(pairing())
        #expect(store.pairing(for: "sess-1")?.terminalID == "term-1")

        // Linking a different tab replaces the link; there is one tab per session.
        try store.put(pairing(terminalID: "term-9"))
        #expect(store.load().count == 1)
        #expect(store.pairing(for: "sess-1")?.terminalID == "term-9")

        try store.remove(sessionID: "sess-1")
        #expect(store.pairing(for: "sess-1") == nil)
    }

    /// The tab-title reader changes several links at once, every few seconds, on its own thread,
    /// while the auto-linker adds new ones on another. Both go through `update` for this reason.
    @Test("Changing several links at once is one indivisible step")
    func updateIsAtomic() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)
        try store.put(pairing(session: "sess-1", terminalID: "term-1"))
        try store.put(pairing(session: "sess-2", terminalID: "term-2"))

        try store.update { all in
            all["sess-1"]?.terminalName = "groom red tickets"
            all["sess-1"]?.tabIndex = 3
            all["sess-2"]?.tabIndex = 6
        }
        #expect(store.pairing(for: "sess-1")?.terminalName == "groom red tickets")
        #expect(store.pairing(for: "sess-1")?.tabIndex == 3)
        #expect(store.pairing(for: "sess-2")?.tabIndex == 6)
    }

    /// Reading the tab bar every few seconds nearly always finds everything as it left it. That
    /// must cost nothing — a write every few seconds, for ever, to say nothing new is not free.
    @Test("A change that changes nothing does not touch the file")
    func aNoOpUpdateWritesNothing() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)
        try store.put(pairing())

        let before = try FileManager.default
            .attributesOfItem(atPath: paths.pairingsFile.path)[.modificationDate] as? Date
        try store.update { all in
            let unchanged = all["sess-1"]
            all["sess-1"] = unchanged
        }
        try store.put(pairing())      // the identical link again
        let after = try FileManager.default
            .attributesOfItem(atPath: paths.pairingsFile.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    /// A link made while a refresh was in flight used to be erased by it: the refresh had loaded the
    /// file before the link existed and wrote that version back.
    @Test("A link made during another thread's change is not erased by it")
    func concurrentWritersDoNotLoseLinks() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)

        DispatchQueue.concurrentPerform(iterations: 24) { index in
            _ = try? store.put(pairing(session: "sess-\(index)", terminalID: "term-\(index)"))
        }
        #expect(store.load().count == 24)
    }

    @Test("The file is private to this user")
    func storeIsPrivate() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)
        try store.put(pairing())

        let mode = (try FileManager.default.attributesOfItem(atPath: paths.pairingsFile.path))[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test("It holds identifiers and timestamps, and nothing else")
    func storeHoldsNoContent() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)
        try store.put(pairing())

        let text = try String(contentsOf: paths.pairingsFile, encoding: .utf8)
        #expect(text.contains("term-1"))
        #expect(text.contains("\"schema\""))
        #expect(text.contains("userConfirmed"), "the provenance is recorded: a person said so")
        for forbidden in ["messagingSocketPath", ".key", "transcript", "prompt", "content"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test("A file from another schema is ignored rather than half-read")
    func unknownSchemaIgnored() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data(#"{"schema":99,"pairings":[]}"#.utf8).write(to: paths.pairingsFile)
        #expect(PairingStore(url: paths.pairingsFile).load().isEmpty)
    }

    @Test("An unreadable file is no links, not a crash")
    func corruptFileIsEmpty() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data("{ not json".utf8).write(to: paths.pairingsFile)
        #expect(PairingStore(url: paths.pairingsFile).load().isEmpty)
    }

    @Test("Links for sessions that have ended are retired; live ones are kept")
    func retireEndedSessions() throws {
        let paths = try Fixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PairingStore(url: paths.pairingsFile)
        try store.put(pairing(session: "sess-1"))
        try store.put(pairing(session: "sess-2"))

        #expect(try store.retire(keeping: ["sess-1"]) == 1)
        #expect(store.pairing(for: "sess-1") != nil)
        #expect(store.pairing(for: "sess-2") == nil)
        #expect(try store.retire(keeping: ["sess-1"]) == 0, "nothing to do the second time")
    }

    // MARK: - Reading and confirming, against the mock

    @Test("Reading the selected tab returns what Ghostty says, and nothing derived")
    func readsSelected() throws {
        let ghostty = MockGhostty()
        let snapshot = try ghostty.readSelectedTerminal().get()
        #expect(snapshot.terminalID == "term-1")
        #expect(snapshot.tabID == "tab-1")
        #expect(snapshot.summary.contains("terminal term-1"))
        #expect(ghostty.focusCalls.isEmpty, "reading never focuses anything")
    }

    @Test("Every failure to read is reported as itself", arguments: [
        GhosttyFailure.notRunning, .permissionDenied, .noSelection, .timedOut,
    ])
    func readFailuresAreSpecific(failure: GhosttyFailure) {
        let ghostty = MockGhostty()
        ghostty.selected = .failure(failure)
        guard case .failure(let reported) = ghostty.readSelectedTerminal() else {
            Issue.record("expected a failure"); return
        }
        #expect(reported == failure)
        #expect(!failure.explanation.isEmpty)
    }
}
