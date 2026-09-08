import AVFoundation
import AgentAttentionCore

/// Optional, local, off by default.
///
/// Uses the on-device macOS speech synthesiser — no network, no account, no audio recording.
/// Only brand new items are spoken, and never more than once every few seconds, so a burst of
/// sessions finishing does not turn into a monologue.
final class SpeechAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenAt: Date = .distantPast
    private let minimumGap: TimeInterval = 4

    var isEnabled: Bool = false
    var voiceIdentifier: String?

    func announce(_ item: AttentionItem) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSpokenAt) >= minimumGap else { return }
        lastSpokenAt = now

        let utterance = AVSpeechUtterance(string: phrase(for: item))
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Short and specific: which project, and what it wants.
    private func phrase(for item: AttentionItem) -> String {
        let project = item.identity.projectName
        switch item.kind {
        case .approval: return "\(project) needs approval"
        case .question: return "\(project) asked you a question"
        case .handoff: return "\(project) is waiting for you"
        case .stageDecision: return "\(project) needs a decision"
        case .workComplete: return "\(project) finished"
        case .idle: return "\(project) is waiting"
        case .error: return "\(project) hit an error"
        case .suspectedStall: return "\(project) may be stalled"
        }
    }
}
