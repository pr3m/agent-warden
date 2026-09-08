import Foundation
import AgentAttentionCore

/// `aa-status --session <full-session-id> --context [--json]`
///
/// A thin shell around `SessionContextQuery`. The rules — identity before contents, the shared trust
/// model for attention, the separation of "the queue says" from "the transcript says" — all live in
/// the query, so the command line and the app cannot drift into two different ideas of what is
/// known. This file formats and picks an exit code.
enum SessionContextCommand {
    /// 0 read · 2 usage · 3 no transcript · 4 unreadable · 5 not tracked · 6 identity unverified.
    static func run(arguments: [String], paths: AppPaths, store: EventStore, config: AttentionConfig) -> Int32 {
        let wantsJSON = arguments.contains("--json")

        guard let sessionID = value(after: "--session", in: arguments), !sessionID.isEmpty else {
            FileHandle.standardError.write(Data("""
            aa-status: --context needs a session id.

              aa-status --session <full-session-id> --context [--json]

            The full id, not the short one shown on a card: short ids collide, and a collision here
            would show you another session's conversation. `aa-status --json` lists the full ids.

            """.utf8))
            return 2
        }
        guard SessionContextReader.isPlausibleSessionID(sessionID) else {
            FileHandle.standardError.write(Data(
                "aa-status: '\(sessionID)' is not a session id.\n".utf8))
            return 2
        }

        let answer = SessionContextQuery.run(
            sessionID: sessionID,
            store: store,
            config: config,
            claudeHome: SessionRegistry.defaultRoot()
        )

        print(wantsJSON ? json(answer) : text(answer))

        if answer.identity == .notTracked {
            FileHandle.standardError.write(Data("""
            aa-status: \(sessionID) is not a session Agent Warden is tracking, so no transcript was read.
            Nothing is known about what it wants, and a file with that name would not be its conversation.

            """.utf8))
            return 5
        }
        if answer.identity == .processGone || answer.identity == .unverified {
            FileHandle.standardError.write(Data("""
            aa-status: \(sessionID) could not be verified as a live session, so no transcript was read.
            \(identityLine(answer.identity))

            """.utf8))
            return 6
        }
        switch answer.context?.availability {
        case .read: return 0
        case .noTranscript, .unknownSession, .none:
            FileHandle.standardError.write(Data(
                "aa-status: no transcript for session \(sessionID).\n".utf8))
            return 3
        case .denied, .rejectedPath:
            FileHandle.standardError.write(Data(
                "aa-status: the transcript for session \(sessionID) could not be read.\n".utf8))
            return 4
        }
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        let candidate = arguments[next]
        return candidate.hasPrefix("--") ? nil : candidate
    }

    // MARK: - Rendering

    static func text(_ answer: SessionContextAnswer) -> String {
        var lines: [String] = []
        lines.append("Session: \(answer.displayName ?? answer.sessionID)  (\(answer.sessionID))")
        lines.append("  identity: \(identityLine(answer.identity))")
        if let cwd = answer.cwd { lines.append("  folder  : \(cwd)") }
        if let state = answer.branchState {
            let name = answer.branch ?? state
            lines.append("  branch  : \(name)  [\(answer.branchSource ?? "-")]")
        }
        if let generated = answer.generatedLabel {
            lines.append("  label   : \(generated)  (client-generated, not a chosen name)")
        }
        lines.append("  process : \(answer.process)")

        lines.append("")
        lines.append("Attention state — from hooks, and authoritative:")
        let attention = answer.attention
        if let kind = attention.kind {
            lines.append("  \(kind): \(attention.reason ?? "-")")
            lines.append("  waiting \(attention.waitingSeconds ?? 0)s, seen \(attention.occurrences ?? 1)x"
                         + (attention.snoozed == true ? ", snoozed" : ""))
        } else if attention.known {
            lines.append("  nothing is being asked of you by this session right now")
        } else {
            lines.append("  unknown — \(attention.certainty)")
        }
        lines.append("  known: \(attention.known)  ·  certainty: \(attention.certainty)"
                     + "  ·  queue fresh: \(attention.queueIsFresh)"
                     + "  ·  app running: \(attention.appIsRunning.map(String.init) ?? "unknown")")
        if attention.unprocessedEvents > 0 {
            lines.append("  \(attention.unprocessedEvents) hook event(s) not yet folded into the queue")
        }

        lines.append("")
        lines.append("Recent conversation — context only, never an alert:")
        guard let context = answer.context else {
            lines.append("  not read: " + identityLine(answer.identity))
            for caveat in attention.caveats { lines.append("  ! \(caveat)") }
            return lines.joined(separator: "\n")
        }
        guard context.availability == .read else {
            lines.append("  " + (context.notes.first ?? "not available"))
            for caveat in attention.caveats { lines.append("  ! \(caveat)") }
            return lines.joined(separator: "\n")
        }
        if context.messages.isEmpty {
            lines.append("  no user or assistant text in the part of the transcript read")
        }
        for message in context.messages {
            let stamp = message.at.map { JSONCoding.dateFormatter.string(from: $0) } ?? "—"
            lines.append("  [\(message.role)] \(stamp)")
            for line in message.excerpt.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
        }

        if !context.questions.isEmpty {
            lines.append("")
            lines.append("Questions found in the transcript:")
            for question in context.questions {
                lines.append("  \(question.question)  [\(question.answered)]")
                for option in question.options { lines.append("    - \(option)") }
                if question.answered == "notObserved" {
                    lines.append("    (no result seen in what was read — not evidence that one is owed)")
                }
                if question.answered == "cancelled" {
                    lines.append("    (the question was cancelled or refused — not answered)")
                }
            }
        }

        lines.append("")
        lines.append("Read \(context.bytesRead) bytes at \(JSONCoding.dateFormatter.string(from: context.readAt))"
                     + (context.tailTruncated ? " (tail only)" : " (whole file)"))
        if let newest = context.messages.last?.at {
            let age = max(0, Int(context.readAt.timeIntervalSince(newest)))
            lines.append("Newest message is \(age)s old — conversation freshness, not queue freshness.")
        }
        for note in context.notes { lines.append("  ! \(note)") }
        for caveat in attention.caveats { lines.append("  ! \(caveat)") }
        return lines.joined(separator: "\n")
    }

    static func identityLine(_ identity: SessionContextAnswer.Identity) -> String {
        switch identity {
        case .verifiedLive: return "tracked, process alive at the recorded start time"
        case .processGone: return "tracked, but its process is gone or is not the one recorded — NOTHING was read"
        case .unverified: return "tracked, but its process could not be pinned down — NOTHING was read"
        case .notTracked: return "NOT tracked by Agent Warden — no transcript was read"
        }
    }

    static func json(_ answer: SessionContextAnswer) -> String {
        struct Payload: Encodable {
            var schema = 2
            var sessionID: String
            var generatedAt: Date
            var identity: String
            var identityNote: String
            var displayName: String?
            var cwd: String?
            var branch: String?
            var branchState: String?
            var branchSource: String?
            var branchReadAt: Date?
            var generatedLabel: String?
            var process: String
            var attention: SessionContextAnswer.Attention
            var context: SessionContext?
            var contextNote: String
        }
        let payload = Payload(
            sessionID: answer.sessionID,
            generatedAt: answer.generatedAt,
            identity: answer.identity.rawValue,
            identityNote: identityLine(answer.identity),
            displayName: answer.displayName,
            cwd: answer.cwd,
            branch: answer.branch,
            branchState: answer.branchState,
            branchSource: answer.branchSource,
            branchReadAt: answer.branchReadAt,
            generatedLabel: answer.generatedLabel,
            process: answer.process,
            attention: answer.attention,
            context: answer.context,
            contextNote: "Excerpts from the transcript. Context only: it never raises an attention "
                       + "item and never clears one. `attention` above is the authoritative state."
        )
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not encode session context\"}"
        }
        return text
    }
}
