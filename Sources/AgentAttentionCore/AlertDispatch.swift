import Foundation

/// The last question asked before a sound is made: *is this still true?*
///
/// An alert is decided when a signal arrives and played a moment later. In between, the session can
/// answer its own question, resume work, or open a whole new episode — and an alert that fires
/// after that is asking about something that is over. So the queue is rechecked against the
/// session's **current** episode at dispatch, not at decision.
///
/// The distinction that matters, and the reason this is not simply "cancel anything old":
///
/// - **A generic milestone** — "the turn finished" — is a statement about a moment. Once the
///   session has carried on working, it is no longer true, and announcing it would send someone to
///   look at a session that is busy.
/// - **A genuine ask** — an approval, a question, an error, a handoff, a stage decision — is a
///   request put to a person. A background job making progress does not answer it, and neither
///   does the parent doing something else. Only resolving it, or the episode being replaced,
///   closes it.
///
/// Cancelling the second kind because something unrelated moved is how a monitor that runs all day
/// silently swallows every question a session asks.
public enum AlertDispatch {
    /// May this queued alert still be announced?
    public static func shouldDispatch(_ item: AttentionItem, session: SessionState?,
                                      at moment: Date) -> Bool {
        // A session that is gone cannot still be asking for anything.
        guard let session else { return false }
        // The episode is the identity of one wait. A new one means this alert belongs to a wait
        // that has already ended.
        guard session.episodeID == item.episodeID else { return false }
        guard !session.episodeDismissed else { return false }

        if AlertDispatch.isGenericMilestone(item.kind) {
            // True when it was raised, not true now.
            return session.activity != .working
        }
        return true
    }

    /// A statement about a moment, rather than a request put to a person.
    static func isGenericMilestone(_ kind: AttentionKind) -> Bool {
        switch kind {
        case .workComplete, .idle, .suspectedStall:
            return true
        case .approval, .question, .error, .handoff, .stageDecision:
            return false
        }
    }
}
