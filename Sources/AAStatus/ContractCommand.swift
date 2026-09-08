import Foundation
import AgentAttentionCore

/// `aa-status --contract [--json] [--content]`
///
/// Answers one question — *what is the working agreement right now?* — and answers it from the
/// configuration and the file as they are at this instant. It does not need the app to be running,
/// does not talk to it, and holds nothing between invocations: there is no cache here to serve a
/// stale agreement out of.
///
/// Read-only in the strongest sense: it starts no window, opens the document in no application,
/// runs nothing, writes nothing, creates no session and grants no permission. Selecting a document
/// is a statement of policy by the user; this only reports what that document says and whether it
/// could be read at all.
enum ContractCommand {
    static func run(arguments: [String], paths: AppPaths) -> Int32 {
        let wantsContent = arguments.contains("--content")
        let reading = OrchestrationContract.read(configuration: paths.configFile,
                                                 includeContent: wantsContent)

        if arguments.contains("--json") {
            let encoder = JSONCoding.encoder
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(reading), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            print(summary(reading, includeContent: wantsContent))
        }
        return exitCode(reading.availability)
    }

    /// Distinct codes, because "no contract is selected" and "the contract is unreadable" ask for
    /// different behaviour from a script, and rounding either into the other loses the difference.
    static func exitCode(_ availability: ContractAvailability) -> Int32 {
        switch availability {
        case .available: return 0
        case .noSelection: return 1
        case .missing: return 3
        case .unreadable, .configUnreadable, .changedWhileReading: return 4
        case .notRegularFile, .unsupportedType, .notText: return 5
        case .tooLarge: return 6
        }
    }

    static func summary(_ reading: ContractReading, includeContent: Bool) -> String {
        var lines: [String] = []
        lines.append("contract: \(reading.availability.rawValue)")
        if let path = reading.selectedPath { lines.append("selected: \(path)") }
        if let resolved = reading.resolvedPath, resolved != reading.selectedPath {
            lines.append("resolved: \(resolved)")
        }
        if let size = reading.sizeBytes { lines.append("size:     \(size) bytes") }
        if let modified = reading.modifiedAt {
            lines.append("modified: \(ISO8601DateFormatter().string(from: modified))")
        }
        if let revision = reading.revision { lines.append("revision: \(revision)") }
        lines.append("readAt:   \(ISO8601DateFormatter().string(from: reading.readAt))")
        lines.append(reading.note)
        // The body is printed only when it was asked for. A metadata query that dumped an
        // agreement into a log every time it was polled would be a poor way to keep one.
        if includeContent, let content = reading.content {
            lines.append("")
            lines.append(content)
        }
        return lines.joined(separator: "\n")
    }
}
