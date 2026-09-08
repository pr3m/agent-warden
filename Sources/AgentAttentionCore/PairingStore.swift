import Foundation

/// Where the user's confirmed session ↔ tab links live.
///
/// A file of its own, not part of `state.json`. The queue is rebuilt from hooks every few seconds
/// and is the app's own bookkeeping; these are the user's decisions, and they should not be able to
/// be lost by a sweep, a migration or a corrupt queue. Mode `0600`, written atomically, and holding
/// nothing but identifiers and timestamps — no transcript text, no tokens, no socket paths.
public final class PairingStore {
    public struct File: Codable, Sendable {
        public static let currentSchema = 1
        public var schema: Int
        public var pairings: [TerminalPairing]

        public init(schema: Int = File.currentSchema, pairings: [TerminalPairing]) {
            self.schema = schema
            self.pairings = pairings
        }
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var fileURL: URL { url }

    /// Everything on disk, keyed by session id. A file we cannot read is an empty set of links, not
    /// an error the user has to deal with — and never a reason to guess at one.
    public func load() -> [String: TerminalPairing] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONCoding.decoder.decode(File.self, from: data),
              file.schema == File.currentSchema else { return [:] }
        return Dictionary(file.pairings.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    public func pairing(for sessionID: String) -> TerminalPairing? {
        load()[sessionID]
    }

    /// Add or replace one link. Replacing is how "link a different tab" works: there is exactly one
    /// tab per session, and a second confirmation overwrites the first rather than accumulating.
    @discardableResult
    public func put(_ pairing: TerminalPairing) throws -> [String: TerminalPairing] {
        var all = load()
        all[pairing.sessionID] = pairing
        try write(all)
        return all
    }

    @discardableResult
    public func remove(sessionID: String) throws -> [String: TerminalPairing] {
        var all = load()
        all.removeValue(forKey: sessionID)
        try write(all)
        return all
    }

    /// Drop links for sessions that no longer exist.
    ///
    /// Called with the ids the app is still tracking. It touches nothing else — in particular it is
    /// not allowed anywhere near the attention queue, so retiring a link can never resolve, snooze
    /// or disturb a pending request.
    @discardableResult
    public func retire(keeping liveSessionIDs: Set<String>) throws -> Int {
        let all = load()
        let survivors = all.filter { liveSessionIDs.contains($0.key) }
        guard survivors.count != all.count else { return 0 }
        try write(survivors)
        return all.count - survivors.count
    }

    public func write(_ pairings: [String: TerminalPairing]) throws {
        let file = File(pairings: pairings.values.sorted { $0.sessionID < $1.sessionID })
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(file), to: url)
    }
}
