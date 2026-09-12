import Foundation

/// Turns Claude Code's stream into something a person can read over your shoulder.
///
/// The tab is a **transcript**, not a packet trace: prompts, replies, what tools ran, and how the
/// turn ended. Everything else — hook chatter, token estimates, tool progress — is dropped.
///
/// **Every character here came from a model.** So none of it is written to the terminal as-is. An
/// escape sequence in model output can clear the screen, retitle the window, move the cursor over
/// what was already printed, or ring the bell; a carriage return can overwrite the line above it.
/// A terminal that renders whatever arrived is a terminal something else is driving, so control
/// characters are stripped before anything reaches the tty and each line is bounded.
public struct TranscriptRenderer: Sendable {
    /// A line longer than this is cut, with a note that it was.
    public static let maximumLineLength = 2_000
    /// Lines emitted for one frame. A single assistant message is not allowed to fill the scroll
    /// back on its own.
    public static let maximumLinesPerFrame = 40

    public init() {}

    /// What the tab shows when it opens: what this is, and what it will not do.
    public static func header(sessionID: String, cwd: String, model: String?) -> [String] {
        let project = (cwd as NSString).lastPathComponent
        let shortID = String(sessionID.prefix(8))
        return [
            "",
            "  Agent Warden — session in \(safe(project))",
            "  \(safe(cwd))",
            "  session \(safe(shortID))" + (model.map { " · model \(safe($0))" } ?? ""),
            "",
            "  This session is driven by Agent Warden's local API. Typing here is not enabled",
            "  yet — your keystrokes are not sent to Claude. Send messages with:",
            "      aa-bridge send --session \(safe(sessionID)) --message-id <id> --prompt <text>",
            "",
            "  ────────────────────────────────────────────────────────────────────",
            "",
        ]
    }

    /// One line of the client's output, rendered. Empty when there is nothing worth showing.
    public func render(line: String) -> [String] {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return render(frame: object)
    }

    public func render(frame object: [String: Any]) -> [String] {
        switch object["type"] as? String {
        case "user":
            // Our own prompt coming home. Shown as what was asked, without the correlation footer
            // that exists for the protocol rather than for the reader.
            guard let message = object["message"] as? [String: Any],
                  let text = TranscriptRenderer.textBlocks(message) else { return [] }
            let asked = TranscriptRenderer.withoutCorrelation(text)
            guard !asked.isEmpty else { return [] }
            return prefixed("›", asked)

        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return [] }
            var lines: [String] = []
            if let text = TranscriptRenderer.textBlocks(message), !text.isEmpty {
                lines += prefixed(" ", text)
            }
            // Tools are summarised by **name only**. Their input is a command, a path or a patch —
            // exactly the material that must not be echoed into a terminal.
            for name in TranscriptRenderer.toolNames(message) {
                lines.append("  · ran \(TranscriptRenderer.safe(name))")
            }
            return Array(lines.prefix(TranscriptRenderer.maximumLinesPerFrame))

        case "result":
            let failed = (object["is_error"] as? Bool) ?? false
            let text = (object["result"] as? String).map(TranscriptRenderer.safe) ?? ""
            let mark = failed ? "  ✘" : "  ✔"
            guard !text.isEmpty else { return [mark + (failed ? " turn failed" : " turn complete")] }
            return prefixed(mark, text)

        case "system":
            // One system frame is worth a person's attention: a permission this bridge will not
            // answer. The rest is machinery.
            guard let subtype = object["subtype"] as? String, subtype.contains("permission") else {
                return []
            }
            return ["  ! Claude asked for a permission decision. Agent Warden does not answer those."]

        default:
            return []
        }
    }

    private func prefixed(_ mark: String, _ text: String) -> [String] {
        let cleaned = TranscriptRenderer.safe(text)
        guard !cleaned.isEmpty else { return [] }
        var lines: [String] = []
        for (index, raw) in cleaned.components(separatedBy: "\n").enumerated() {
            guard index < TranscriptRenderer.maximumLinesPerFrame else {
                lines.append("  … (truncated)")
                break
            }
            let bounded = raw.count > TranscriptRenderer.maximumLineLength
                ? String(raw.prefix(TranscriptRenderer.maximumLineLength)) + " … (truncated)"
                : raw
            lines.append(index == 0 ? "\(mark) \(bounded)" : "    \(bounded)")
        }
        return lines
    }

    /// Strip everything that could steer the terminal, keep everything a person reads.
    ///
    /// Tabs and newlines stay; every other C0 control, DEL and the C1 range go. That covers escape
    /// sequences at their first character, so a colour code or a cursor move never begins.
    public static func safe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.value < 0x20 { return false }
            if scalar.value == 0x7F { return false }
            if scalar.value >= 0x80 && scalar.value <= 0x9F { return false }
            return true
        }))
    }

    static func textBlocks(_ message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func toolNames(_ message: [String: Any]) -> [String] {
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard (block["type"] as? String) == "tool_use" else { return nil }
            return (block["name"] as? String).map { String($0.prefix(40)) }
        }
    }

    /// The correlation footer is protocol, not conversation.
    static func withoutCorrelation(_ text: String) -> String {
        guard let marker = text.range(of: "\n\n[warden-correlation:") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[text.startIndex..<marker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Everything needed to open one visible session, decided before a terminal is touched.
///
/// The surface command is run by a shell, so this is the one place where a caller-supplied string
/// could become a second command in the user's own terminal. Every component is validated as a
/// plain path or identifier and refused otherwise — there is no escaping or quoting scheme here,
/// because a quoting scheme is a thing to get subtly wrong.
public struct VisibleSessionPlan: Sendable, Equatable {
    public let sessionID: String
    public let cwd: String
    public let model: String?
    public let claudeExecutable: String
    public let relayExecutable: String
    public let inbox: String
    public let outbox: String
    public let withoutTools: Bool
    /// Continue the conversation named by `sessionID` rather than start one under it.
    public let resume: Bool

    public init?(sessionID: String, cwd: String, model: String?, claudeExecutable: String,
                 relayExecutable: String, inbox: String, outbox: String, withoutTools: Bool,
                 resume: Bool = false) {
        guard VisibleSessionPlan.isPlainIdentifier(sessionID) else { return nil }
        // A model name is optional; a *malformed* one is refused rather than dropped, so a caller
        // never gets a session quietly running on something other than what it asked for.
        if let requested = model, !requested.isEmpty,
           !VisibleSessionPlan.isPlainIdentifier(requested) { return nil }
        for path in [cwd, claudeExecutable, relayExecutable, inbox, outbox] {
            guard VisibleSessionPlan.isPlainPath(path) else { return nil }
        }
        self.sessionID = sessionID
        self.cwd = cwd
        self.model = (model?.isEmpty == false) ? model : nil
        self.claudeExecutable = claudeExecutable
        self.relayExecutable = relayExecutable
        self.inbox = inbox
        self.outbox = outbox
        self.withoutTools = withoutTools
        self.resume = resume
    }

    /// The command Ghostty runs in the new surface. Our own relay, never `claude` directly, so the
    /// rendering and the hand-off to Warden are one owned process rather than a shell pipeline.
    public var command: String {
        var parts = [relayExecutable,
                     "--session-id", sessionID,
                     "--cwd", cwd,
                     "--claude", claudeExecutable,
                     "--inbox", inbox,
                     "--outbox", outbox]
        if let model { parts += ["--model", model] }
        if withoutTools { parts.append("--no-tools") }
        if resume { parts.append("--resume") }
        return parts.joined(separator: " ")
    }

    /// What the tab is called, so it can be found among a dozen others.
    public var title: String {
        let project = (cwd as NSString).lastPathComponent
        return "Agent Warden · \(project)"
    }

    /// A path with nothing in it that a shell would treat as syntax.
    static func isPlainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= 1_024 else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            return !";&|`$()<>*?[]{}!#\"'\\ \n\t".unicodeScalars.contains(scalar)
        }
    }

    static func isPlainIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

}
