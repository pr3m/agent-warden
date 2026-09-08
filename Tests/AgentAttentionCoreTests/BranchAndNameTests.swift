import Foundation
import Testing
@testable import AgentAttentionCore

/// What a session is *called*, and what branch it is *on*.
///
/// Both were wrong in a way that mattered. Six sessions in one repository were labelled `redmy-36`,
/// `redmy-0c`, `redmy-6e`, `redmy-e9` — client-generated identifiers, two characters apart. And all
/// five live sessions reported `main` while their working directories were on `cs/client-info-t1`,
/// `cs/red645-own-capital`, `cs/sensitivity-train`, `cs/red658-plan-vs-ledger` and
/// `cs/exec-cashflow-truth`, because the transcript stamps `gitBranch` once at session start.
@Suite("Names and branches")
struct BranchAndNameTests {

    private func identity(
        cwd: String,
        title: String? = nil,
        titleSource: String? = nil,
        gitBranch: String? = nil,
        branch: BranchFact? = nil
    ) -> SessionIdentity {
        SessionIdentity(sessionID: "s1", cwd: cwd, title: title, titleSource: titleSource,
                        gitBranch: gitBranch, branch: branch)
    }

    // MARK: - Naming

    @Test("A client-generated label never becomes the session's name", arguments: [
        ("redmy-36", "derived"), ("redmy-e9", "derived"), ("client-info-foundation", "auto"),
    ])
    func generatedLabelsDoNotWin(name: String, source: String) {
        let id = identity(cwd: "/Users/dev/redmy/redmy-core/.worktrees/red645-own-capital",
                          title: name, titleSource: source)
        #expect(id.displayName == "red645-own-capital", "the worktree is what a person calls it")
        #expect(id.generatedLabel == name, "and the generated one is kept, for Details")
        #expect(!id.titleIsHumanChosen)
    }

    @Test("A name a person chose does win", arguments: ["user", "custom", "explicit", "MANUAL"])
    func humanNamesWin(source: String) {
        let id = identity(cwd: "/Users/dev/redmy", title: "Cashflow rewrite", titleSource: source)
        #expect(id.displayName == "Cashflow rewrite")
        #expect(id.titleIsHumanChosen)
        #expect(id.generatedLabel == nil, "it is already on screen; Details need not repeat it")
    }

    @Test("A name with no source at all is not assumed to be meaningful")
    func unknownSourceIsNotTrusted() {
        // Nothing demonstrates a person chose it, so it does not get to be the label.
        let id = identity(cwd: "/Users/dev/redmy/worktrees/alpha", title: "redmy-7f", titleSource: nil)
        #expect(id.displayName == "alpha")
        #expect(id.generatedLabel == "redmy-7f")
    }

    @Test("With no name at all, the worktree stands alone")
    func fallsBackToFolder() {
        #expect(identity(cwd: "/Users/dev/redmy/.worktrees/sensitivity-train").displayName == "sensitivity-train")
    }

    // MARK: - Which branch is believed

    @Test("A branch read from the directory beats the one stamped at launch")
    func gitBeatsTranscript() {
        let now = Date()
        let id = identity(cwd: "/w/red645-own-capital",
                          gitBranch: "main",
                          branch: .git(.branch("cs/red645-own-capital"), path: "/w/red645-own-capital", at: now))
        let fact = id.branchFact
        #expect(fact?.branch == "cs/red645-own-capital")
        #expect(fact?.source == "git")
        #expect(fact?.summary == "cs/red645-own-capital")
    }

    @Test("With no reading of our own, there is no current branch — only a launch one")
    func transcriptIsNeverCurrent() {
        // The rule changed deliberately. The launch value was observed saying `main` for five
        // sessions that were each on their own `cs/…` branch, so standing in for the current branch
        // is exactly what it must not do. It is kept, labelled, somewhere else.
        let id = identity(cwd: "/w/alpha", gitBranch: "main")
        #expect(id.branchFact == nil, "a launch stamp is not a reading")
        #expect(id.branchAvailability == "pending")
        #expect(id.launchBranch?.source == "transcript")
        #expect(id.launchBranch?.summary == "main (at launch)")
    }

    @Test("Every non-branch outcome is shown as itself, never as a name", arguments: [
        (BranchReading.detached, "detached HEAD"),
        (.notARepository, "not a git repository"),
        (.denied, "branch unreadable (permission)"),
        (.timedOut, "branch unreadable (git did not answer)"),
    ])
    func outcomesAreSpelledOut(reading: BranchReading, expected: String) {
        let fact = BranchFact.git(reading, path: "/w/alpha", at: Date())
        #expect(fact.summary == expected)
        #expect(fact.branch == nil)
        #expect(!fact.isResolved)
    }

    // MARK: - Classifying what git said

    @Test("A branch name on stdout with exit 0 is a branch")
    func classifyBranch() {
        let reading = GitBranchProbe.classify(status: 0, stdout: Data("cs/red658-plan-vs-ledger\n".utf8), stderr: Data())
        #expect(reading == .branch("cs/red658-plan-vs-ledger"))
    }

    @Test("Exit 0 with nothing printed is a detached HEAD, not an empty branch")
    func classifyDetached() {
        #expect(GitBranchProbe.classify(status: 0, stdout: Data(), stderr: Data()) == .detached)
        #expect(GitBranchProbe.classify(status: 0, stdout: Data("\n".utf8), stderr: Data()) == .detached)
    }

    @Test("A directory that is not a repository says so")
    func classifyNotARepo() {
        let reading = GitBranchProbe.classify(
            status: 128, stdout: Data(),
            stderr: Data("fatal: not a git repository (or any of the parent directories): .git\n".utf8))
        #expect(reading == .notARepository)
    }

    @Test("A directory we cannot enter is denied, not empty", arguments: [
        "fatal: cannot change to '/w/gone': No such file or directory\n",
        "error: Permission denied\n",
    ])
    func classifyDenied(stderr: String) {
        #expect(GitBranchProbe.classify(status: 128, stdout: Data(), stderr: Data(stderr.utf8)) == .denied)
    }

    @Test("A branch name with anything odd in it is not shown", arguments: [
        "line one\nline two", "", String(repeating: "x", count: 500), "bad;rm -rf /", "$(whoami)",
    ])
    func rejectsOddNames(raw: String) {
        #expect(GitBranchProbe.validBranchName(raw) == nil)
    }

    @Test("Ordinary ref characters are fine", arguments: [
        "main", "cs/red645-own-capital", "feature/JIRA-123_thing", "release/1.2.3", "user@host",
    ])
    func acceptsRealNames(raw: String) {
        #expect(GitBranchProbe.validBranchName(raw) == raw)
    }

    // MARK: - Against real directories

    @Test("A path with spaces and quotes is just a path")
    func awkwardPathIsNotAShellProblem() throws {
        // Arguments go to `git` as an argument vector, never through a shell. The proof that this
        // matters: the same string as a shell command would be a disaster.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent warden 'test' $(echo no) \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Not a repository, and that is exactly the answer we want — reached without a shell.
        let fact = GitBranchProbe.read(directory: base.path, timeout: 5)
        #expect(fact.state == "notARepository" || fact.state == "unavailable")
        #expect(fact.path == base.path)
        #expect(fact.branch == nil)
        #expect(FileManager.default.fileExists(atPath: base.path), "and nothing was changed")
    }

    @Test("A directory that does not exist is denied")
    func missingDirectory() {
        let fact = GitBranchProbe.read(directory: "/nonexistent-\(UUID().uuidString)")
        #expect(fact.state == "denied")
    }

    @Test("An empty path is not looked up at all")
    func emptyPath() {
        #expect(GitBranchProbe.read(directory: "").state == "unavailable")
    }

    // MARK: - How the engine takes a reading

    @Test("A reading updates the branch and nothing else")
    func applyingChangesOnlyTheBranch() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .approval,
                                    detail: "Permission needed: Bash", at: clock.now,
                                    identity: Fixture.identity(session: "s1", project: "alpha")))
        let before = engine.session("s1")

        let cwd = try! #require(before?.identity.cwd)
        #expect(engine.apply(branch: .git(.branch("cs/alpha"), path: cwd, at: clock.now), sessionID: "s1"))

        let after = engine.session("s1")
        #expect(after?.identity.branch?.branch == "cs/alpha")
        #expect(after?.identity.cwd == before?.identity.cwd, "a hook's directory is never overwritten")
        #expect(after?.activity == before?.activity)
        #expect(engine.pendingCount == 1, "and the ask is untouched")
        #expect(engine.visibleItems().first?.kind == .approval)
    }

    @Test("A hook-covered session still gets its branch corrected")
    func hookCoveredSessionsAreCorrectedToo() {
        // The transcript said `main`; the directory says otherwise. Hook coverage does not make the
        // stale value right — it was never read from the directory in the first place.
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        var id = Fixture.identity(session: "s1", project: "red645-own-capital")
        id.gitBranch = "main"
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse", identity: id))
        #expect(engine.session("s1")?.identity.branchFact == nil, "the launch stamp is not current")
        #expect(engine.session("s1")?.identity.launchBranch?.branch == "main", "but it is kept")

        engine.apply(branch: .git(.branch("cs/red645-own-capital"), path: id.cwd, at: clock.now), sessionID: "s1")
        #expect(engine.session("s1")?.identity.branchFact?.branch == "cs/red645-own-capital")
        #expect(engine.session("s1")?.identity.branchFact?.source == "git")
        #expect(engine.session("s1")?.activity == .working, "and its state is untouched")
    }

    @Test("A reading for a directory the session has left is discarded")
    func readingForTheWrongDirectoryIsDropped() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))

        #expect(!engine.apply(branch: .git(.branch("cs/somewhere-else"), path: "/other/place", at: clock.now),
                              sessionID: "s1"),
                "a probe that finished after the session moved must not label the new directory")
        #expect(engine.session("s1")?.identity.branch == nil)
    }

    @Test("A branch that changed is picked up; an older reading that arrives late is not")
    func newestReadingWins() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        let cwd = engine.session("s1")!.identity.cwd

        engine.apply(branch: .git(.branch("cs/first"), path: cwd, at: clock.now), sessionID: "s1")
        clock.advance(120)
        engine.apply(branch: .git(.branch("cs/second"), path: cwd, at: clock.now), sessionID: "s1")
        #expect(engine.session("s1")?.identity.branch?.branch == "cs/second", "the branch changed")

        engine.apply(branch: .git(.branch("cs/first"), path: cwd, at: Fixture.origin), sessionID: "s1")
        #expect(engine.session("s1")?.identity.branch?.branch == "cs/second", "a late older probe loses")
    }

    @Test("Sessions are re-read when their reading ages, or when they move")
    func staleReadingsAreQueuedAgain() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        let cwd = engine.session("s1")!.identity.cwd

        #expect(engine.sessionsNeedingBranchRead(at: clock.now, staleAfter: 60).count == 1, "never read")
        engine.apply(branch: .git(.branch("cs/alpha"), path: cwd, at: clock.now), sessionID: "s1")
        #expect(engine.sessionsNeedingBranchRead(at: clock.now, staleAfter: 60).isEmpty)

        clock.advance(120)
        #expect(engine.sessionsNeedingBranchRead(at: clock.now, staleAfter: 60).count == 1, "gone stale")
    }

    @Test("A failed reading is recorded rather than left blank")
    func failuresAreRecorded() {
        let clock = TestClock(Fixture.origin)
        let engine = AttentionEngine(config: .default, clock: clock, liveness: StubLiveness(), restoring: nil)
        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: "PostToolUse"))
        let cwd = engine.session("s1")!.identity.cwd

        engine.apply(branch: .git(.timedOut, path: cwd, at: clock.now), sessionID: "s1")
        // The reading is kept — a failure that leaves no trace is one nobody can act on — but it is
        // not a *fact about the branch*, so it is reported through availability rather than as one.
        #expect(engine.session("s1")?.identity.branch?.state == "timedOut")
        #expect(engine.session("s1")?.identity.branchFact == nil, "no name is invented to fill the gap")
        #expect(engine.session("s1")?.identity.branchAvailability == "timedOut")
    }
}

/// Where a name and a branch come from, and what may overwrite them.
///
/// Two bugs sat here at once, both invisible until five live rows disagreed with each other: a
/// title learned from a hook could never acquire its provenance, so a client-generated identifier
/// was indistinguishable from a name a person chose; and a branch stamped at launch, or read in a
/// directory the session has since left, could stand in for the current one.
@Suite("Provenance and freshness")
struct ProvenanceTests {
    private func registryScan(session: String, title: String, source: String,
                              pid: Int32? = 4242, started: Double? = 1_759_000_000,
                              cwd: String = "/w/launched-here") -> SessionIdentity {
        var scan = Fixture.identity(session: session, pid: pid, startedAt: started)
        scan.cwd = cwd
        scan.title = title
        scan.titleSource = source
        return scan
    }

    @Test("A name we already had can still learn where it came from")
    func provenanceFillsForAKnownTitle() {
        var held = Fixture.identity(session: "s1")
        held.title = "redmy-e9"                 // learned from a hook, with no source
        held.titleSource = nil

        held.fillGaps(from: registryScan(session: "s1", title: "redmy-e9", source: "derived"))

        #expect(held.titleSource == "derived", "the gap was the source, not the title")
        #expect(!held.titleIsHumanChosen, "and knowing that is what keeps it out of the label")
    }

    @Test("A source is only ever attached to the name it describes")
    func provenanceIsNotTransplanted() {
        var held = Fixture.identity(session: "s1")
        held.title = "something the user typed"
        held.titleSource = nil

        held.fillGaps(from: registryScan(session: "s1", title: "redmy-e9", source: "derived"))

        #expect(held.titleSource == nil, "a different name's provenance says nothing about this one")
        #expect(held.title == "something the user typed")
    }

    @Test("A rename is taken, for the same session on the same process, from a newer scan")
    func renameIsTaken() {
        var held = Fixture.identity(session: "s1")
        held.title = "old name"
        held.titleSource = "derived"
        held.cwd = "/w/worktree"

        let took = held.refreshTitle(from: registryScan(session: "s1", title: "new name", source: "user"),
                                     scannedAt: Fixture.origin, holdingSince: Fixture.origin.addingTimeInterval(-60))

        #expect(took)
        #expect(held.title == "new name")
        #expect(held.titleIsHumanChosen, "and a name a person chose now wins the label")
        #expect(held.cwd == "/w/worktree", "the registry's launch directory never replaces where it is now")
    }

    @Test("A rename is refused when it cannot be attributed", arguments: [
        "different process", "recycled pid", "older scan", "no source",
    ])
    func renameIsGuarded(_ situation: String) {
        var held = Fixture.identity(session: "s1")
        held.title = "old name"
        held.titleSource = "derived"

        var scan = registryScan(session: "s1", title: "new name", source: "user")
        var scannedAt = Fixture.origin
        var holdingSince = Fixture.origin.addingTimeInterval(-60)
        switch situation {
        case "different process": scan.claudePID = 9999
        case "recycled pid": scan.claudePIDStartedAt = 1_759_000_000 + 7200
        case "older scan": scannedAt = Fixture.origin.addingTimeInterval(-120)
        default: scan.titleSource = nil
        }
        _ = holdingSince

        let took = held.refreshTitle(from: scan, scannedAt: scannedAt, holdingSince: holdingSince)
        #expect(!took)
        #expect(held.title == "old name")
    }

    @Test("A branch read in another directory is never adopted as this one's")
    func branchIsNotTransplanted() {
        var held = Fixture.identity(session: "s1")
        held.cwd = "/w/worktree"
        var older = Fixture.identity(session: "s1")
        older.cwd = "/w/project-root"
        older.branch = .git(.branch("main"), path: "/w/project-root", at: Fixture.origin)

        held.fillGaps(from: older)

        #expect(held.branch == nil, "that reading is about a directory this session has left")
        #expect(held.branchFact == nil)
        #expect(held.branchAvailability == "pending", "pending is honest; `main` would not be")
    }

    @Test("A session that moved to the project root is not dragged back to its old worktree")
    func movingIsAllowed() {
        var held = Fixture.identity(session: "s1")
        held.cwd = "/w/project-root"
        held.branch = .git(.branch("main"), path: "/w/project-root", at: Fixture.origin)
        var older = Fixture.identity(session: "s1")
        older.cwd = "/w/worktree"
        older.branch = .git(.branch("cs/topic"), path: "/w/worktree", at: Fixture.origin)

        held.fillGaps(from: older)

        #expect(held.cwd == "/w/project-root")
        #expect(held.branchFact?.branch == "main", "the reading for where it is now stands")
    }

    @Test("The launch stamp is kept, labelled, and never called current")
    func launchStampIsSeparate() {
        var held = Fixture.identity(session: "s1")
        held.cwd = "/w/worktree"
        held.gitBranch = "main"

        #expect(held.branchFact == nil)
        #expect(held.branchAvailability == "pending")
        #expect(held.launchBranch?.branch == "main")
        #expect(held.launchBranch?.summary.contains("at launch") == true)
    }

    @Test("A reading that failed is reported as itself, not as pending")
    func failedReadingIsItsOwnAnswer() {
        var held = Fixture.identity(session: "s1")
        held.cwd = "/w/worktree"
        held.branch = BranchFact(source: "git", state: "denied", branch: nil,
                                 readAt: Fixture.origin, path: "/w/worktree")

        #expect(held.branchFact == nil, "no branch was read")
        #expect(held.branchAvailability == "denied", "and the reason is not hidden behind `pending`")
    }
}
