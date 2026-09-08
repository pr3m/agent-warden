import AppKit
import AgentAttentionCore

/// Plays the generated chime through the platform's simplest player.
///
/// `NSSound` over an in-memory WAV, and nothing else: no audio session, no hardware
/// configuration, no permission prompt, no recording of any kind. The bytes are produced by
/// `AttentionChime` in this process and never leave it.
final class SystemChimePlayer: NSObject, ChimeSounding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NSSound?

    func play(_ sound: ChimeSound) {
        guard let next = NSSound(data: AttentionChime.wav(sound)) else { return }
        lock.lock()
        current?.stop()
        current = next
        lock.unlock()
        next.play()
    }

    /// Immediate. A master mute that finishes the current sound first is not a mute.
    func stop() {
        lock.lock()
        let sounding = current
        current = nil
        lock.unlock()
        sounding?.stop()
    }
}
