import Foundation

/// User-tunable behaviour. Stored at `<home>/config.json`; every field has a safe default so a
/// missing, partial or hand-mangled file still starts the app, and every numeric field is clamped
/// to a range the app can actually run at — a negative sweep interval would spin a timer, a zero
/// card limit would render nothing.
public struct AttentionConfig: Codable, Sendable, Equatable {
    /// Retained so an existing `config.json` still loads. Nothing reads it: inferred inactivity was
    /// removed, and elapsed silence no longer produces anything at all.
    public var stallThresholdSeconds: TimeInterval
    /// How long a `Stop` reading of background work stays trustworthy.
    public var backgroundEvidenceTTLSeconds: TimeInterval
    /// Default snooze length offered on the card.
    public var snoozeDurationSeconds: TimeInterval
    /// Items older than this are dropped on sweep — a queue from yesterday helps nobody.
    public var maxItemAgeSeconds: TimeInterval
    /// Session records untouched for this long are dropped even if we cannot prove the process died.
    public var staleSessionSeconds: TimeInterval
    /// How often the app sweeps for snooze expiry and liveness.
    public var sweepIntervalSeconds: TimeInterval
    /// Retained so an existing `config.json` still loads. Nothing reads it: it existed to forgive
    /// the clock jump after a sleep, which only mattered while silence was treated as evidence.
    public var wakeGraceSeconds: TimeInterval
    /// The master audio switch. Off means Agent Warden makes no sound at all, whatever else is
    /// set — including speech. On restores whatever the individual preferences already said; it
    /// never announces anything that happened while it was off.
    public var soundEnabled: Bool
    /// Local macOS speech. Off unless the user turns it on, and silent whenever `soundEnabled` is.
    public var speechEnabled: Bool
    /// The short two-note chime for a genuine ask.
    ///
    /// **Off by default, including for an existing install.** Adding a feature that starts making
    /// noise on somebody's machine because they updated is not a feature. An older `config.json`
    /// has no key for this, and a missing key reads as off, so nothing changes until it is asked
    /// for. Silent whenever `soundEnabled` is off, like everything else audible.
    public var chimeEnabled: Bool
    public var speechVoiceIdentifier: String?
    /// Where the user keeps their orchestration contract — the working agreement Agent Warden and
    /// its consumers read.
    ///
    /// **Optional, and `nil` until somebody chooses one.** No default path, no assumed vault, no
    /// dependency on any particular note-taking app: a hardcoded location would be a guess about
    /// somebody else's filing. Storing it changes nothing on its own — the document is read on
    /// request and never written, never executed, never opened by itself.
    public var orchestrationContractPath: String?
    /// Cards rendered before collapsing into "+N more".
    public var maxVisibleCards: Int
    /// Raise attention when a turn ends without work left to do.
    public var notifyOnWorkComplete: Bool
    /// Raise attention when Claude Code reports the prompt idle.
    public var notifyOnIdle: Bool
    /// Retained for compatibility only. Inferred stalls no longer exist, and turning this on does
    /// nothing.
    public var stallDetectionEnabled: Bool
    /// Store the hook's own message text as the reason, instead of a static label.
    ///
    /// Off by default. The observed messages are generic ("Claude needs your permission",
    /// "Claude is waiting for your input"), but they are message bodies from a hook payload and
    /// keeping them is a choice, not a default.
    public var includeHookMessages: Bool
    /// Show the always-visible floating bubble. The menu bar item is the secondary surface and
    /// stays either way.
    public var bubbleEnabled: Bool
    /// Where the bubble sits. Remembered as a corner plus an inward offset, so it survives a
    /// display or resolution change.
    public var bubblePlacement: BubblePlacement
    /// Diameter in points.
    public var bubbleSize: Double
    /// Percent at which roam ends itself and the machine sleeps deliberately.
    ///
    /// Ten rather than the bottom of `RoamPolicy.thresholdRange`, because the guard is not
    /// instantaneous: it is consulted once per lease renewal (`PowerLease.renewInterval`, 10
    /// seconds), and what follows the decision is a lease release the daemon has to confirm and
    /// a system sleep the machine has to carry out. A threshold at the floor would leave no
    /// margin for the check that noticed a moment late, and none for reopening the lid
    /// afterwards.
    ///
    /// A value outside `RoamPolicy.thresholdRange` falls back to this default in `validated()`,
    /// and deliberately **not** to the nearest bound: clamping 200 to 50 would sleep an
    /// unattended Mac at half charge, turning a typo into the most aggressive guard available.
    public var roamBatteryThreshold: Int
    /// The network you expect to be on while roaming. Best-effort: a warning, never a block.
    ///
    /// `nil` until somebody names one — there is no sensible guess, and an invented SSID would
    /// produce a warning about a network the user never chose. Best-effort because `RoamNetwork`
    /// classifies on the gateway address rather than the name: SSID access is privacy-gated on
    /// modern macOS, so an unreadable name makes the warning vaguer and never wrong.
    public var roamHotspotSSID: String?
    /// The "you seem to be at the desk — still need roam?" prompt.
    ///
    /// On by default, which is safe because `NudgePolicy` requires three signals at once — lid
    /// open, recent typing, and roam settled — before it asks anything. A prompt that rarely
    /// fires is one people read; one that fires on a single signal is one they learn to dismiss.
    public var roamNudgeEnabled: Bool
    /// How long a dismissed nudge stays quiet.
    ///
    /// Fifteen minutes: long enough that answering "no, keep roaming" is not asked again during
    /// the same errand, short enough that a roam session left on for an afternoon is asked more
    /// than once. Clamped in `validated()` to stay a snooze rather than an off switch, which
    /// `roamNudgeEnabled` already is.
    public var roamNudgeSnoozeMinutes: Int

    /// How long a dismissed roam nudge may stay quiet. The floor is 1 because 0 minutes would
    /// make dismissing the prompt a no-op — `NudgePolicy.shouldNudge` compares `now` against the
    /// snooze deadline, so a zero-length one has expired by the time it is next consulted. The ceiling is
    /// a day because anything longer outlives any plausible roam session, at which point it is
    /// not a snooze but a way of turning the prompt off without saying so.
    public static let roamNudgeSnoozeRange = 1...1440

    public static let `default` = AttentionConfig(
        stallThresholdSeconds: 300,
        snoozeDurationSeconds: 600,
        maxItemAgeSeconds: 8 * 3600,
        staleSessionSeconds: 12 * 3600,
        sweepIntervalSeconds: 15,
        wakeGraceSeconds: 90,
        soundEnabled: true,
        speechEnabled: false,
        chimeEnabled: false,
        speechVoiceIdentifier: nil,
        orchestrationContractPath: nil,
        maxVisibleCards: 4,
        notifyOnWorkComplete: true,
        notifyOnIdle: true,
        stallDetectionEnabled: false,
        includeHookMessages: false,
        backgroundEvidenceTTLSeconds: 30 * 60,
        bubbleEnabled: true,
        bubblePlacement: .default,
        bubbleSize: 56,
        roamBatteryThreshold: 10,
        roamHotspotSSID: nil,
        roamNudgeEnabled: true,
        roamNudgeSnoozeMinutes: 15
    )

    public init(
        stallThresholdSeconds: TimeInterval,
        snoozeDurationSeconds: TimeInterval,
        maxItemAgeSeconds: TimeInterval,
        staleSessionSeconds: TimeInterval,
        sweepIntervalSeconds: TimeInterval,
        wakeGraceSeconds: TimeInterval,
        soundEnabled: Bool,
        speechEnabled: Bool,
        chimeEnabled: Bool = false,
        speechVoiceIdentifier: String?,
        orchestrationContractPath: String? = nil,
        maxVisibleCards: Int,
        notifyOnWorkComplete: Bool,
        notifyOnIdle: Bool,
        stallDetectionEnabled: Bool,
        includeHookMessages: Bool,
        backgroundEvidenceTTLSeconds: TimeInterval,
        bubbleEnabled: Bool,
        bubblePlacement: BubblePlacement,
        bubbleSize: Double,
        // Defaulted, like `chimeEnabled` and `orchestrationContractPath` before them, so every
        // existing call site still compiles without naming a roam setting it knows nothing about.
        roamBatteryThreshold: Int = 10,
        roamHotspotSSID: String? = nil,
        roamNudgeEnabled: Bool = true,
        roamNudgeSnoozeMinutes: Int = 15
    ) {
        self.stallThresholdSeconds = stallThresholdSeconds
        self.snoozeDurationSeconds = snoozeDurationSeconds
        self.maxItemAgeSeconds = maxItemAgeSeconds
        self.staleSessionSeconds = staleSessionSeconds
        self.sweepIntervalSeconds = sweepIntervalSeconds
        self.wakeGraceSeconds = wakeGraceSeconds
        self.soundEnabled = soundEnabled
        self.speechEnabled = speechEnabled
        self.chimeEnabled = chimeEnabled
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.orchestrationContractPath = orchestrationContractPath
        self.maxVisibleCards = maxVisibleCards
        self.notifyOnWorkComplete = notifyOnWorkComplete
        self.notifyOnIdle = notifyOnIdle
        self.stallDetectionEnabled = stallDetectionEnabled
        self.includeHookMessages = includeHookMessages
        self.backgroundEvidenceTTLSeconds = backgroundEvidenceTTLSeconds
        self.bubbleEnabled = bubbleEnabled
        self.bubblePlacement = bubblePlacement
        self.bubbleSize = bubbleSize
        self.roamBatteryThreshold = roamBatteryThreshold
        self.roamHotspotSSID = roamHotspotSSID
        self.roamNudgeEnabled = roamNudgeEnabled
        self.roamNudgeSnoozeMinutes = roamNudgeSnoozeMinutes
    }

    /// Bounds every value to something the app can run at. Applied on load, on every config
    /// change and inside the engine's initialiser, so no code path can be handed a value that
    /// spins a timer or renders an empty panel.
    public func validated() -> AttentionConfig {
        func clamp(_ value: TimeInterval, _ low: TimeInterval, _ high: TimeInterval, _ fallback: TimeInterval) -> TimeInterval {
            guard value.isFinite else { return fallback }
            return Swift.min(Swift.max(value, low), high)
        }
        var copy = self
        let d = AttentionConfig.default
        copy.stallThresholdSeconds = clamp(stallThresholdSeconds, 30, 24 * 3600, d.stallThresholdSeconds)
        copy.snoozeDurationSeconds = clamp(snoozeDurationSeconds, 10, 24 * 3600, d.snoozeDurationSeconds)
        copy.maxItemAgeSeconds = clamp(maxItemAgeSeconds, 60, 7 * 24 * 3600, d.maxItemAgeSeconds)
        copy.staleSessionSeconds = clamp(staleSessionSeconds, 60, 30 * 24 * 3600, d.staleSessionSeconds)
        copy.sweepIntervalSeconds = clamp(sweepIntervalSeconds, 1, 3600, d.sweepIntervalSeconds)
        copy.wakeGraceSeconds = clamp(wakeGraceSeconds, 0, 3600, d.wakeGraceSeconds)
        copy.maxVisibleCards = Swift.min(Swift.max(maxVisibleCards, 1), 20)
        copy.backgroundEvidenceTTLSeconds = clamp(backgroundEvidenceTTLSeconds, 60, 24 * 3600, d.backgroundEvidenceTTLSeconds)
        copy.bubbleSize = clamp(bubbleSize, 40, 96, d.bubbleSize)
        // An offset larger than any plausible screen would put the bubble off the edge; the
        // geometry clamps too, but a sane stored value keeps the menu and the config honest.
        copy.bubblePlacement.offsetX = clamp(bubblePlacement.offsetX, 0, 8000, d.bubblePlacement.offsetX)
        copy.bubblePlacement.offsetY = clamp(bubblePlacement.offsetY, 0, 8000, d.bubblePlacement.offsetY)
        // Clamped to the policy's own declared range, so the file and the policy cannot disagree
        // **Fallback, not a clamp, and the difference is the whole point.** A threshold outside
        // `RoamPolicy.thresholdRange` is a typo, and the two ends fail in opposite directions:
        // `RoamPolicy` answers `.none` to a hand-edited 0, leaving a roaming Mac with no battery
        // guard at all — silently, and only at the moment it was needed — while clamping a
        // hand-edited 200 to the ceiling would sleep an unattended Mac at 50%, turning the same
        // typo into the most aggressive guard available. Neither bound is a safe reading of a
        // number the user cannot have meant. The shipped default is, so both ends land there:
        // a working, conservative guard either way, and `AttentionConfig.save` then writes that
        // rather than a value the policy would refuse. The policy's own range check stays exactly
        // as it is, for any caller that never passes through here.
        copy.roamBatteryThreshold = RoamPolicy.thresholdRange.contains(roamBatteryThreshold)
            ? roamBatteryThreshold
            : d.roamBatteryThreshold
        // Clamped to the nearest bound rather than defaulted, because neither end inverts
        // anything: too small makes a dismissal last a minute instead of none, too large makes a
        // prompt quiet for a day. A nudge that fires late or not at all costs a sentence — this
        // is the one roam setting that cannot put a machine to sleep.
        copy.roamNudgeSnoozeMinutes = Swift.min(Swift.max(roamNudgeSnoozeMinutes,
                                                          AttentionConfig.roamNudgeSnoozeRange.lowerBound),
                                                AttentionConfig.roamNudgeSnoozeRange.upperBound)
        if let voice = copy.speechVoiceIdentifier, voice.isEmpty { copy.speechVoiceIdentifier = nil }
        // An empty SSID is not a choice of network, for the same reason an empty voice identifier
        // is not a choice of voice: stored as absent, so "none named" has one representation.
        if let ssid = copy.roamHotspotSSID,
           ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.roamHotspotSSID = nil
        }
        // An empty string is not a selection. Stored as absent, so "nothing chosen" has one
        // representation rather than two that behave differently.
        if let contract = copy.orchestrationContractPath,
           contract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.orchestrationContractPath = nil
        }
        return copy
    }

    // Decode leniently: unknown keys ignored, missing keys fall back to the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AttentionConfig.default
        func num(_ key: CodingKeys, _ fallback: TimeInterval) -> TimeInterval {
            ((try? c.decodeIfPresent(TimeInterval.self, forKey: key)) ?? nil) ?? fallback
        }
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }
        stallThresholdSeconds = num(.stallThresholdSeconds, d.stallThresholdSeconds)
        snoozeDurationSeconds = num(.snoozeDurationSeconds, d.snoozeDurationSeconds)
        maxItemAgeSeconds = num(.maxItemAgeSeconds, d.maxItemAgeSeconds)
        staleSessionSeconds = num(.staleSessionSeconds, d.staleSessionSeconds)
        sweepIntervalSeconds = num(.sweepIntervalSeconds, d.sweepIntervalSeconds)
        wakeGraceSeconds = num(.wakeGraceSeconds, d.wakeGraceSeconds)
        soundEnabled = flag(.soundEnabled, d.soundEnabled)
        speechEnabled = flag(.speechEnabled, d.speechEnabled)
        chimeEnabled = flag(.chimeEnabled, d.chimeEnabled)
        speechVoiceIdentifier = (try? c.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier)) ?? nil
        orchestrationContractPath =
            (try? c.decodeIfPresent(String.self, forKey: .orchestrationContractPath)) ?? nil
        maxVisibleCards = ((try? c.decodeIfPresent(Int.self, forKey: .maxVisibleCards)) ?? nil) ?? d.maxVisibleCards
        notifyOnWorkComplete = flag(.notifyOnWorkComplete, d.notifyOnWorkComplete)
        notifyOnIdle = flag(.notifyOnIdle, d.notifyOnIdle)
        stallDetectionEnabled = flag(.stallDetectionEnabled, d.stallDetectionEnabled)
        includeHookMessages = flag(.includeHookMessages, d.includeHookMessages)
        backgroundEvidenceTTLSeconds = num(.backgroundEvidenceTTLSeconds, d.backgroundEvidenceTTLSeconds)
        bubbleEnabled = flag(.bubbleEnabled, d.bubbleEnabled)
        bubblePlacement = ((try? c.decodeIfPresent(BubblePlacement.self, forKey: .bubblePlacement)) ?? nil) ?? d.bubblePlacement
        bubbleSize = num(.bubbleSize, d.bubbleSize)
        // Every config.json written before roam existed is missing all four of these keys, and
        // reads here as the defaults — the same rule every field above follows.
        roamBatteryThreshold =
            ((try? c.decodeIfPresent(Int.self, forKey: .roamBatteryThreshold)) ?? nil) ?? d.roamBatteryThreshold
        roamHotspotSSID = (try? c.decodeIfPresent(String.self, forKey: .roamHotspotSSID)) ?? nil
        roamNudgeEnabled = flag(.roamNudgeEnabled, d.roamNudgeEnabled)
        roamNudgeSnoozeMinutes =
            ((try? c.decodeIfPresent(Int.self, forKey: .roamNudgeSnoozeMinutes)) ?? nil) ?? d.roamNudgeSnoozeMinutes
    }
}

extension AttentionConfig {
    /// Is Agent Warden allowed to speak right now?
    ///
    /// Two switches, and both have to be on. Muting is a master control — it silences speech
    /// without forgetting that speech was wanted, so unmuting restores exactly what was set rather
    /// than turning something on the user never asked for.
    public var speechIsAudible: Bool { soundEnabled && speechEnabled }

    /// Is the chime allowed to sound right now? Same two-switch rule, for the same reason.
    public var chimeIsAudible: Bool { soundEnabled && chimeEnabled }

    /// Sound is on, but nothing is actually set to make a noise.
    ///
    /// Worth stating out loud in the settings, because a master switch reading "Sound" strongly
    /// implies there is a sound — and until this feature existed there genuinely was not one.
    public var soundIsOnButSilent: Bool { soundEnabled && !speechEnabled && !chimeEnabled }

    /// Always returns a usable configuration, whatever is on disk.
    public static func load(from url: URL) -> AttentionConfig {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return ((try? JSONCoding.decoder.decode(AttentionConfig.self, from: data)) ?? .default).validated()
    }

    public func save(to url: URL) throws {
        let encoder = JSONCoding.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(validated()), to: url)
    }
}
