import Foundation
import AgentAttentionCore

/// Keeps each linked session's tab name and tab number current, off the main thread.
///
/// A link records what the tab was called at the moment it was made, and nothing ever revisited it.
/// That is fine for a second and wrong for the rest of the day: a person renames a tab, `/warden:label`
/// writes a new one, tabs get dragged and closed. So the panel showed `Claude Code` and
/// `claude --resume 7ccdb3ff…` — the titles those tabs had at launch — for sessions whose tabs plainly
/// said `groom red tickets` and `planned backlog review`.
///
/// Same rules as every other reader here:
///
/// - **One script, read-only.** `windows → tabs → terminals`. Nothing is typed, opened or closed.
/// - **One at a time, and rate-limited.** The script gate is process-wide and shared with the tab
///   handshake; a second read can never queue behind a first. At most one read every ten seconds,
///   whatever the sweep does.
/// - **Matched on the terminal id, never on a name.** Matching a tab by what it is called is the
///   guess the whole pairing design exists to avoid.
/// - **Written only when something actually changed.** What is stored is the *readable* name, with
///   the spinner glyph and the context percentage taken off — those change several times a second,
///   and storing them would mean a disk write several times a second for no new information.
/// - **A tab that answers with nothing keeps what it had.** A title that is only decoration is not a
///   name, and overwriting a good name with an empty one is a regression, not a refresh.
final class TabTitleService {
    /// Called on the main thread when at least one row's name or number changed.
    var onChange: (() -> Void)?

    /// How long a reading stays current before Ghostty is asked again.
    let staleAfter: TimeInterval = 10

    private let queue = DispatchQueue(label: "ai.wundamental.agent-warden.tabtitle", qos: .utility)
    private let ghostty: GhosttyControlling
    private let pairings: PairingStore
    private let log: (String) -> Void

    private let lock = NSLock()
    private var running = false
    private var lastReadAt: Date?

    init(ghostty: GhosttyControlling, pairings: PairingStore, log: @escaping (String) -> Void = { _ in }) {
        self.ghostty = ghostty
        self.pairings = pairings
        self.log = log
    }

    /// Ask for a reading if one is due. Returns immediately.
    ///
    /// `force` is for the moment the panel is about to be shown: a list somebody is opening is worth
    /// one script even if the last read was recent.
    func refresh(now: Date = Date(), force: Bool = false) {
        lock.lock()
        if running { lock.unlock(); return }
        if !force, let last = lastReadAt, now.timeIntervalSince(last) < staleAfter {
            lock.unlock(); return
        }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let changed = self.readAndApply()
            self.lock.lock()
            self.running = false
            self.lastReadAt = Date()
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async { self.onChange?() }
            }
        }
    }

    /// One reading, folded into the saved links. Returns whether anything moved.
    ///
    /// Not private so a check can drive it directly against a stub Ghostty.
    @discardableResult
    func readAndApply() -> Bool {
        guard case .success(let placements) = ghostty.readTabLayout() else { return false }
        var byTerminal: [String: TabPlacement] = [:]
        for placement in placements { byTerminal[placement.terminalID] = placement }

        // Read, apply and write as one step, against whatever is in the file at that moment. A
        // load-then-write here would race the auto-linker: a reading that began before a handshake
        // landed would write back the version without it, and a session just linked to its tab
        // would lose it again. It is also one write for the whole reading, not one per row.
        var changedAny = false
        do {
            try pairings.update { all in
                let updated = TabLayout.applying(placements: byTerminal, to: all)
                guard !updated.isEmpty else { return }
                for (sessionID, pairing) in updated { all[sessionID] = pairing }
                changedAny = true
            }
        } catch {
            log("could not save refreshed tab names: \(error)")
            return false
        }
        return changedAny
    }
}
