import Foundation
import Testing
@testable import AgentAttentionCore

/// A transcript line as Claude Code writes one: a JSON object per line, the prompt inside it.
private func userLine(_ content: String) -> String {
    let payload: [String: Any] = ["type": "user", "message": ["content": content]]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return String(decoding: data, as: UTF8.self)
}

private func assistantLine(_ content: String) -> String {
    let payload: [String: Any] = ["type": "assistant", "message": ["content": content]]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return String(decoding: data, as: UTF8.self)
}

private func invocation(_ command: String, _ args: String) -> String {
    "<command-message>\(command)</command-message>\n<command-name>/\(command)</command-name>\n<command-args>\(args)</command-args>"
}

@Suite("Naming a session from the command it was given")
struct SessionNamingCommandTests {
    @Test("A sprint slug in a slash command becomes the label")
    func slugBecomesLabel() {
        let transcript = userLine(invocation("orbit-sprint-start", "checkout-trust-back-half"))
        #expect(SessionNaming.labelFromCommands(in: transcript) == "checkout trust back half")
    }

    @Test("The newest slug wins, because a session moves on from where it started")
    func newestSlugWins() {
        let transcript = [
            userLine(invocation("orbit-sprint-start", "payments-groom")),
            assistantLine("working on it"),
            userLine(invocation("orbit-sprint-start", "checkout-trust-back-half")),
        ].joined(separator: "\n")
        #expect(SessionNaming.labelFromCommands(in: transcript) == "checkout trust back half")
    }

    @Test("A ticket key is already a good label")
    func ticketKeyIsALabel() {
        let transcript = userLine(invocation("orbit-work", "task42-portal"))
        #expect(SessionNaming.labelFromCommands(in: transcript) == "task42 portal")
    }

    @Test("Prose arguments are not a label, so nothing is proposed")
    func proseIsNotASlug() {
        let transcript = userLine(invocation("orbit-sprint-plan",
                                             "Assemble ONE sprint for the checkout trust back half"))
        #expect(SessionNaming.labelFromCommands(in: transcript) == nil)
    }

    @Test("A single unhyphenated argument is not a slug")
    func singleWordIsNotASlug() {
        #expect(SessionNaming.labelFromCommands(in: userLine(invocation("loop", "5m"))) == nil)
    }

    @Test("A slug past the cap is refused rather than cut mid-word")
    func overlongSlugIsRefused() {
        let long = String(repeating: "very-long-", count: 8) + "tail"
        #expect(SessionNaming.labelFromCommands(in: userLine(invocation("orbit-work", long))) == nil)
    }

    @Test("An assistant quoting a command does not name the session")
    func onlyUserMessagesCount() {
        let transcript = assistantLine(invocation("orbit-sprint-start", "checkout-trust-back-half"))
        #expect(SessionNaming.labelFromCommands(in: transcript) == nil)
    }

    @Test("A transcript with no commands proposes nothing")
    func noCommandsNoLabel() {
        let transcript = userLine("time to prep next release")
        #expect(SessionNaming.labelFromCommands(in: transcript) == nil)
    }

    @Test("A half-written line at the window edge is skipped, not parsed")
    func fragmentIsSkipped() {
        let transcript = "ent-args>broken-fragment</command-args>\"}}\n"
            + userLine(invocation("orbit-sprint-start", "checkout-trust-back-half"))
        #expect(SessionNaming.labelFromCommands(in: transcript) == "checkout trust back half")
    }
}

@Suite("Taking a model at its word, but not on trust")
struct SessionNamingModelTests {
    @Test("A three word answer is accepted")
    func plainAnswer() {
        #expect(SessionNaming.sanitize("checkout trust sprint") == "checkout trust sprint")
    }

    @Test("Surrounding quotes and a trailing period come off")
    func decorationComesOff() {
        #expect(SessionNaming.sanitize("\"release prep\".") == "release prep")
    }

    @Test("Only the first line is read, because a model likes to explain itself")
    func firstLineOnly() {
        #expect(SessionNaming.sanitize("release prep\n\nThis names the session because…") == "release prep")
    }

    @Test("An answer that is a sentence is refused rather than shown")
    func sentenceIsRefused() {
        let sentence = "This session is preparing the next release of the checkout service"
        #expect(SessionNaming.sanitize(sentence) == nil)
    }

    @Test("An empty answer is refused")
    func emptyIsRefused() {
        #expect(SessionNaming.sanitize("   \n  ") == nil)
        #expect(SessionNaming.sanitize("") == nil)
    }

    @Test("Control characters never reach the tab")
    func controlCharactersStripped() {
        #expect(SessionNaming.sanitize("release\u{1B}[31m prep") == "release[31m prep")
    }

    @Test("Whitespace is collapsed so the tab does not show a gap")
    func whitespaceCollapsed() {
        #expect(SessionNaming.sanitize("  release    prep  ") == "release prep")
    }
}

@Suite("Deciding which tabs to touch at all")
struct SessionNamingEligibilityTests {
    @Test("A tab showing its folder name is eligible")
    func folderNameIsEligible() {
        #expect(SessionNaming.needsName(current: "atlas", folder: "atlas"))
    }

    @Test("A name somebody chose is never overwritten")
    func chosenNameIsLeftAlone() {
        #expect(!SessionNaming.needsName(current: "release prep", folder: "atlas"))
    }

    @Test("A tab with no name at all is eligible")
    func missingNameIsEligible() {
        #expect(SessionNaming.needsName(current: nil, folder: "atlas"))
    }

    @Test("The comparison ignores case and spacing, which a terminal may change")
    func comparisonIsForgiving() {
        #expect(SessionNaming.needsName(current: " Atlas ", folder: "atlas"))
    }
}

@Suite("Naming a fleet of tabs on request")
struct SessionNamerTests {
    private let transcript = URL(fileURLWithPath: "/tmp/does-not-matter.jsonl")

    private func candidate(_ id: String, current: String? = "atlas",
                           folder: String = "atlas") -> SessionNamer.Candidate {
        SessionNamer.Candidate(sessionID: id, currentName: current, folder: folder,
                               transcript: transcript)
    }

    private func namer(command: String? = nil, model: String? = nil,
                       excerpt: String? = "some session text",
                       written: Written = Written()) -> SessionNamer {
        SessionNamer(commandScan: { _ in command },
                     askModel: { _ in model },
                     excerpt: { _ in excerpt },
                     write: { id, name in written.record(id, name); return true })
    }

    final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var pairs: [(String, String)] = []
        func record(_ id: String, _ name: String) {
            lock.lock(); defer { lock.unlock() }
            pairs.append((id, name))
        }
    }

    @Test("The command rule answers without asking a model at all")
    func commandWins() {
        var modelWasAsked = false
        let namer = SessionNamer(commandScan: { _ in "release prep" },
                                 askModel: { _ in modelWasAsked = true; return "something else" },
                                 excerpt: { _ in "text" },
                                 write: { _, _ in true })
        let outcome = namer.run([candidate("s1")])
        #expect(outcome.named == [.init(sessionID: "s1", name: "release prep", source: "command")])
        #expect(!modelWasAsked)
    }

    @Test("A session with no command falls through to the model")
    func modelFallback() {
        let outcome = namer(command: nil, model: "v0.20.0 release").run([candidate("s1")])
        #expect(outcome.named == [.init(sessionID: "s1", name: "v0.20.0 release", source: "model")])
    }

    @Test("A name somebody already chose is never overwritten, and no model is asked about it")
    func namedTabsAreLeftAlone() {
        var modelWasAsked = false
        let namer = SessionNamer(commandScan: { _ in "release prep" },
                                 askModel: { _ in modelWasAsked = true; return nil },
                                 excerpt: { _ in "text" },
                                 write: { _, _ in true })
        let outcome = namer.run([candidate("s1", current: "my own name")])
        #expect(outcome.named.isEmpty)
        #expect(outcome.skipped == 1)
        #expect(!modelWasAsked)
    }

    @Test("A model that answers with the folder name is refused, because that is not a name")
    func modelEchoingTheFolderIsRefused() {
        let outcome = namer(command: nil, model: "atlas").run([candidate("s1")])
        #expect(outcome.named.isEmpty)
        #expect(outcome.unnamed == 1)
    }

    @Test("No model available leaves the tab exactly as it was")
    func noModelIsNotAnError() {
        let outcome = namer(command: nil, model: nil).run([candidate("s1")])
        #expect(outcome.named.isEmpty)
        #expect(outcome.unnamed == 1)
    }

    @Test("A model answering with a sentence names nothing")
    func modelProseIsRefused() {
        let answer = "This session appears to be preparing the next release of the service"
        let outcome = namer(command: nil, model: answer).run([candidate("s1")])
        #expect(outcome.unnamed == 1)
    }

    @Test("A session with no transcript is counted, not crashed on")
    func missingTranscript() {
        let outcome = namer(command: "release prep").run([
            SessionNamer.Candidate(sessionID: "s1", currentName: "atlas", folder: "atlas",
                                   transcript: nil)
        ])
        #expect(outcome.unnamed == 1)
        #expect(outcome.named.isEmpty)
    }

    @Test("A write that does not stick is reported as unnamed rather than claimed")
    func failedWriteIsHonest() {
        let namer = SessionNamer(commandScan: { _ in "release prep" },
                                 askModel: { _ in nil },
                                 excerpt: { _ in "text" },
                                 write: { _, _ in false })
        let outcome = namer.run([candidate("s1")])
        #expect(outcome.named.isEmpty)
        #expect(outcome.unnamed == 1)
    }

    @Test("A mixed fleet is answered by whichever route fits each session")
    func mixedFleet() {
        let written = Written()
        let namer = SessionNamer(
            commandScan: { _ in nil },
            askModel: { prompt in prompt.contains("orbit") ? "orbit tickets" : nil },
            excerpt: { _ in "orbit" },
            write: { id, name in written.record(id, name); return true })
        let outcome = namer.run([
            candidate("s1"),
            candidate("s2", current: "already named"),
        ])
        #expect(outcome.named.count == 1)
        #expect(outcome.skipped == 1)
        #expect(written.pairs.map(\.0) == ["s1"])
    }
}

@Suite("Writing a name where warden reads it")
struct WardenLabelFileTests {
    private func sandbox() -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aw-label-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/warden/sessions"),
            withIntermediateDirectories: true)
        return root.path
    }

    @Test("The filename matches warden's own rule, or warden never reads it")
    func filenameRule() {
        let url = WardenLabelFile.path(forTTY: "/dev/ttys003", home: "/home/alex")
        #expect(url.path == "/home/alex/.claude/warden/sessions/_dev_ttys003.label")
    }

    @Test("A name is written as one line warden can read back")
    func writesOneLine() {
        let home = sandbox()
        #expect(WardenLabelFile.write("release prep", forTTY: "/dev/ttys003", home: home))
        let written = try? String(contentsOf: WardenLabelFile.path(forTTY: "/dev/ttys003", home: home),
                                  encoding: .utf8)
        #expect(written == "release prep\n")
    }

    @Test("Writing again replaces the name rather than appending to it")
    func replacesNotAppends() {
        let home = sandbox()
        WardenLabelFile.write("first name", forTTY: "/dev/ttys003", home: home)
        WardenLabelFile.write("second name", forTTY: "/dev/ttys003", home: home)
        let written = try? String(contentsOf: WardenLabelFile.path(forTTY: "/dev/ttys003", home: home),
                                  encoding: .utf8)
        #expect(written == "second name\n")
    }

    @Test("No warden installed writes nothing and says so, rather than creating half of it")
    func noWardenNoWrite() {
        let bare = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aw-bare-\(UUID().uuidString)").path
        #expect(!WardenLabelFile.write("release prep", forTTY: "/dev/ttys003", home: bare))
        #expect(!FileManager.default.fileExists(atPath: bare + "/.claude"))
    }

    @Test("A pipe would corrupt warden's status bus, so it never reaches the file")
    func pipeIsStripped() {
        #expect(WardenLabelFile.strip("release | prep") == "release  prep")
    }

    @Test("Control characters and extra lines are dropped, as warden's own reader does")
    func controlAndLinesDropped() {
        #expect(WardenLabelFile.strip("release prep\nand more") == "release prep")
        #expect(WardenLabelFile.strip("release\u{1B}[31m prep") == "release[31m prep")
    }

    @Test("An empty name is refused rather than blanking a tab")
    func emptyRefused() {
        let home = sandbox()
        #expect(!WardenLabelFile.write("   ", forTTY: "/dev/ttys003", home: home))
    }
}
