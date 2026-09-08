import Foundation
import Testing
@testable import AgentAttentionCore

/// Telling "here is what I need from you" apart from "nothing is needed".
///
/// The live defect: a turn ended with a dedicated `I need from you:` footer *and* a shell still
/// running. The background rule correctly suppressed the generic completion — and took the request
/// with it. The turn before that one, which had background work and genuinely asked for nothing,
/// was correctly silent and must stay that way.
@Suite("Final handoff")
struct FinalHandoffTests {
    @Test("A dedicated footer asking for something is a request")
    func explicitFooterAsks() {
        let reading = FinalHandoff.read("""
        Done — the panel renders.

        **In short:** two colours changed.

        **I need from you:** re-run the panel step, and say whether the grid should be full width.
        """)

        #expect(reading.asksForSomething)
        #expect(reading.reason == .asked)
        #expect(reading.excerpt?.hasPrefix("re-run the panel step") == true)
    }

    @Test("The footer's usual ways of saying nothing stay silent", arguments: [
        "**I need from you:** nothing, carry on.",
        "**I need from you:** nothing — Codex reviews next.",
        "I need from you: none.",
        "I need from you: no action.",
        "**I need from you:** Nothing.",
        "_I need from you:_ n/a",
    ])
    func nothingFootersAreQuiet(_ footer: String) {
        // These end most replies. Alerting on them would make the app cry wolf on nearly every
        // turn — worse than the bug this feature fixes.
        let reading = FinalHandoff.read("Some work happened.\n\n\(footer)")
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .explicitlyNothing)
    }

    @Test("A word that merely starts like 'nothing' is still a request")
    func nothingNeedsAWordBoundary() {
        let reading = FinalHandoff.read("**I need from you:** none of these options work — pick one.")
        #expect(reading.asksForSomething, "‘none of these options’ is a question, not a dismissal")
    }

    @Test("Prose, questions and suggestions are not handoffs", arguments: [
        "Should I also update the docs?",
        "You may want to re-run the panel step.",
        "Let me know if the grid should be full width.",
        "I need from you to be patient while this runs.",
        "The report says what I need from you is nothing at all.",
    ])
    func narrativeIsQuiet(_ message: String) {
        // Only a dedicated line counts. Inferring intent from prose is exactly the general-purpose
        // guessing this feature is not.
        #expect(!FinalHandoff.read(message).asksForSomething)
    }

    @Test("A marker inside a code fence or a quote is an example, not a request", arguments: [
        "Here is the convention:\n\n```\n**I need from you:** a decision\n```\n\nNothing to do.",
        "You wrote:\n\n> **I need from you:** a decision\n\nAnd I have done it.",
        "Indented sample:\n\n    **I need from you:** a decision\n\nAll done.",
    ])
    func quotedMarkersAreQuiet(_ message: String) {
        let reading = FinalHandoff.read(message)
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .insideCodeOrQuote)
    }

    @Test("Oversized or empty text is treated conservatively")
    func boundsAreRespected() {
        let huge = String(repeating: "x", count: FinalHandoff.maximumBytes + 1)
            + "\n**I need from you:** a decision"
        #expect(FinalHandoff.read(huge).reason == .tooLarge)
        #expect(!FinalHandoff.read(huge).asksForSomething)
        #expect(FinalHandoff.read(nil).reason == .empty)
        #expect(FinalHandoff.read("").reason == .empty)
    }

    @Test("An excerpt is bounded, single-purpose, and only ever the request itself")
    func excerptIsBounded() {
        let long = String(repeating: "decide this thing ", count: 40)
        let reading = FinalHandoff.read("**I need from you:** \(long)")
        #expect(reading.excerpt?.count ?? 0 <= FinalHandoff.maximumExcerpt)
    }
}

/// The same rules where they actually take effect: through the translator, the engine, and the
/// interaction with background work.
@Suite("Handoff through the pipeline")
struct HandoffPipelineTests {
    private func stop(_ message: String?, running: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "s1",
            "background_tasks": running > 0 ? [["status": "running", "type": "shell"]] : [],
            "session_crons": [],
        ]
        if let message { payload["last_assistant_message"] = message }
        return payload
    }

    @Test("A Stop that hands something back is a request, not a completion")
    func stopWithHandoffIsAnAsk() {
        let classification = HookTranslator.classify(stop("**I need from you:** a decision", running: 1))
        #expect(classification.attentionKind == .handoff)
        #expect(classification.signal == .attention)
        #expect(!AttentionKind.handoff.isGeneric, "so background work cannot silence it")
    }

    @Test("A Stop that asks for nothing is still just a completion")
    func stopWithoutHandoffIsUnchanged() {
        #expect(HookTranslator.classify(stop("**I need from you:** nothing, carry on.", running: 1))
            .attentionKind == .workComplete)
        #expect(HookTranslator.classify(stop(nil, running: 0)).attentionKind == .workComplete)
    }

    @Test("By default the request's own words are never persisted")
    func defaultKeepsNoText() {
        let classification = HookTranslator.classify(
            stop("**I need from you:** the SECRET-PLAN decision", running: 1))
        let stored = classification.resolvedDetail(includeMessages: false)

        #expect(stored == AttentionKind.handoff.staticDetail)
        #expect(stored?.contains("SECRET-PLAN") == false)
    }

    @Test("With message text switched on, a bounded excerpt may be kept")
    func optInKeepsAnExcerpt() {
        let classification = HookTranslator.classify(stop("**I need from you:** pick a colour", running: 1))
        let stored = classification.resolvedDetail(includeMessages: true)
        #expect(stored?.contains("pick a colour") == true)
        #expect((stored?.count ?? 0) <= 140)
    }

    @Test("A request survives background work; a bare completion still does not")
    func askOutlivesBackgroundWork() {
        let (engine, clock, _) = makeEngine()
        let running = BackgroundEvidence(availability: .reported, running: 1,
                                         types: ["shell"], observedAt: clock.now)

        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    detail: AttentionKind.handoff.staticDetail, at: clock.now,
                                    hookEvent: "Stop", background: running))
        #expect(engine.visibleItems(at: clock.now).count == 1, "the request is shown")
        #expect(engine.visibleItems(at: clock.now).first?.kind == .handoff)

        let (quiet, quietClock, _) = makeEngine()
        quiet.ingest(Fixture.event(session: "s2", signal: .attention, kind: .workComplete,
                                   at: quietClock.now, hookEvent: "Stop", background: running))
        #expect(quiet.visibleItems(at: quietClock.now).isEmpty,
                "background work with nothing asked stays quiet, exactly as before")
    }

    @Test("A subagent finishing does not close the parent's request")
    func childStopKeepsTheParentWaiting() {
        let (engine, clock, _) = makeEngine()
        let running = BackgroundEvidence(availability: .reported, running: 1,
                                         types: ["shell"], observedAt: clock.now)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    at: clock.now, hookEvent: "Stop", background: running))
        _ = clock.advance(5)

        engine.ingest(Fixture.event(session: "s1", signal: .housekeeping, at: clock.now,
                                    hookEvent: "SubagentStop"))

        #expect(engine.visibleItems(at: clock.now).count == 1, "the parent is still waiting for you")
        #expect(engine.session("s1")?.activity != .working, "a child stopping is not the parent working")
        #expect(engine.session("s1")?.background?.isWaitingOnBackgroundWork == true,
                "and the parent's own background reading is untouched")
    }

    @Test("The parent genuinely resuming does close it")
    func realWorkResolvesTheRequest() {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    at: clock.now, hookEvent: "Stop"))
        _ = clock.advance(5)

        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now,
                                    hookEvent: "PostToolUse"))

        #expect(engine.visibleItems(at: clock.now).isEmpty)
        #expect(engine.session("s1")?.activity == .working)
    }

    @Test("A subagent's own closing message is never read as the parent asking")
    func subagentMessageIsIgnored() {
        var payload: [String: Any] = [
            "hook_event_name": "SubagentStop",
            "session_id": "s1",
            "last_assistant_message": "**I need from you:** a decision",
        ]
        payload["background_tasks"] = []

        let classification = HookTranslator.classify(payload)
        #expect(classification.signal == .housekeeping)
        #expect(classification.attentionKind == nil)
    }

    @Test("Errors and structured asks are unchanged")
    func structuredSignalsAreUntouched() {
        #expect(HookTranslator.classify(["hook_event_name": "PreToolUse",
                                         "tool_name": "AskUserQuestion"]).attentionKind == .question)
        #expect(HookTranslator.classify(["hook_event_name": "PreToolUse",
                                         "tool_name": "ExitPlanMode"]).attentionKind == .stageDecision)
        #expect(HookTranslator.classify(["hook_event_name": "PermissionRequest",
                                         "tool_name": "Bash"]).attentionKind == .approval)
        #expect(HookTranslator.classify(["hook_event_name": "StopFailure",
                                         "error_type": "overloaded"]).attentionKind == .error)
    }

    @Test("An explicit command-line override still wins over anything read from the payload")
    func explicitOverrideStillWins() throws {
        // The installed hooks pass `--kind`/`--signal`. Those must keep deciding, so an existing
        // installation behaves the same whatever the final message happened to say.
        let outcome = HookIngestion.process(
            payload: stop("**I need from you:** a decision", running: 0),
            identity: Fixture.identity(session: "s1"),
            now: Fixture.origin,
            config: .default,
            override: HookIngestion.Override(kind: .approval)
        )

        #expect(outcome.event?.attentionKind == .approval, "the override decides, as it always did")

        // And with no override, the same payload produces the handoff — so an installation that
        // passes neither flag still benefits.
        let unforced = HookIngestion.process(
            payload: stop("**I need from you:** a decision", running: 0),
            identity: Fixture.identity(session: "s1"),
            now: Fixture.origin)
        #expect(unforced.event?.attentionKind == .handoff)
    }

    @Test("The arguments the installed hooks actually pass produce the corrected behaviour")
    func installedHookArgumentsWork() {
        // These are exactly the entries in `Scripts/manage-hooks.py`. The point of this test is
        // that an existing installation needs no `settings.json` rewrite.
        let stopHandoff = HookIngestion.process(
            payload: stop("**I need from you:** a decision", running: 1),
            identity: Fixture.identity(session: "s1"), now: Fixture.origin,
            override: HookIngestion.Override(kind: .workComplete))     // Stop --kind workComplete
        #expect(stopHandoff.event?.attentionKind == .handoff,
                "a generic override yields to a real request read from the same payload")

        let stopQuiet = HookIngestion.process(
            payload: stop("**I need from you:** nothing, carry on.", running: 1),
            identity: Fixture.identity(session: "s1"), now: Fixture.origin,
            override: HookIngestion.Override(kind: .workComplete))
        #expect(stopQuiet.event?.attentionKind == .workComplete, "and otherwise decides as before")

        let subagent = HookIngestion.process(
            payload: ["hook_event_name": "SubagentStop", "session_id": "s1"],
            identity: Fixture.identity(session: "s1"), now: Fixture.origin,
            override: HookIngestion.Override(signal: .activity))       // SubagentStop --signal activity
        #expect(subagent.heartbeat.lastSignal == .housekeeping,
                "the installed `--signal activity` no longer makes a child's stop look like the parent working")
        #expect(subagent.event == nil, "and it still spools nothing")

        let realWork = HookIngestion.process(
            payload: ["hook_event_name": "PostToolUse", "session_id": "s1"],
            identity: Fixture.identity(session: "s1"), now: Fixture.origin,
            override: HookIngestion.Override(signal: .activity))
        #expect(realWork.heartbeat.lastSignal == .activity, "genuine work is untouched")

        let approval = HookIngestion.process(
            payload: ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash"],
            identity: Fixture.identity(session: "s1"), now: Fixture.origin,
            override: HookIngestion.Override(kind: .approval))
        #expect(approval.event?.attentionKind == .approval, "a specific override is never second-guessed")
    }

    @Test("An old record carrying the previous classification still loads")
    func oldRecordsStillDecode() throws {
        // A spool file written before this change says `activity` for a SubagentStop. It must keep
        // working — it simply behaves as it did then.
        let before = EmittedEvent(hookEvent: "SubagentStop", signal: .activity, occurredAt: Fixture.origin,
                                  identity: Fixture.identity(session: "s1"))
        let encoded = try JSONCoding.encoder.encode(before)
        let event = try JSONCoding.decoder.decode(EmittedEvent.self, from: encoded)

        #expect(event.signal == .activity, "records written before this change still load and behave as they did")
        #expect(String(decoding: encoded, as: UTF8.self).contains("activity"))
    }
}

/// The four defects an independent review found in the first cut, each with the behaviour that
/// proves it rather than an assertion adjusted to match the code.
@Suite("Handoff review corrections")
struct HandoffCorrectionTests {
    private func stop(_ message: String) -> [String: Any] {
        [
            "hook_event_name": "Stop",
            "session_id": "s1",
            "background_tasks": [["status": "running", "type": "shell"]],
            "session_crons": [],
            "last_assistant_message": message,
        ]
    }

    /// The installed hook's exact arguments, because that is where it has to be right.
    private func throughInstalledStopHook(_ message: String) -> AttentionKind? {
        HookIngestion.process(payload: stop(message),
                              identity: Fixture.identity(session: "s1"),
                              now: Fixture.origin,
                              override: HookIngestion.Override(kind: .workComplete)).event?.attentionKind
    }

    @Test("A label with nothing after it is a heading, not a request")
    func bareLabelIsNotARequest() {
        let reading = FinalHandoff.read("All done.\n\n**I need from you:**")
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .emptyRequest)
        #expect(throughInstalledStopHook("All done.\n\n**I need from you:**") == .workComplete)
    }

    @Test("A request written on the next line is still a request")
    func continuationCarriesTheRequest() {
        let reading = FinalHandoff.read("**I need from you:**\nchoose a colour for the heatmap.")
        #expect(reading.asksForSomething)
        #expect(reading.excerpt?.hasPrefix("choose a colour") == true)
        #expect(throughInstalledStopHook("**I need from you:**\nchoose a colour for the heatmap.") == .handoff)
    }

    @Test("A continuation that says nothing is still nothing", arguments: [
        "**I need from you:**\nNothing — all checks passed.",
        "**I need from you:**\n\nnone.",
        "**I need from you:**\nno action.",
    ])
    func continuationCanDecline(_ message: String) {
        let reading = FinalHandoff.read(message)
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .explicitlyNothing)
        #expect(throughInstalledStopHook(message) == .workComplete)
    }

    @Test("A shape this parser will not interpret stays quiet rather than guessing", arguments: [
        "**I need from you:**\n```\nsomething\n```",
        "**I need from you:**\n> quoted continuation",
        "**I need from you:**\n\n\n\nfar below, unconnected",
    ])
    func unsupportedContinuationIsQuiet(_ message: String) {
        #expect(!FinalHandoff.read(message).asksForSomething)
        #expect(throughInstalledStopHook(message) == .workComplete)
    }

    @Test("A fence is closed only by its own kind, so nested fences stay code", arguments: [
        "````text\n~~~\nI need from you: choose a colour.\n````",
        "```\n``\nI need from you: choose a colour.\n```",
        "~~~\n```\nI need from you: choose a colour.\n~~~",
    ])
    func nestedFencesAreStillCode(_ message: String) {
        // The old rule toggled on any fence, so an inner one opened the content early and a code
        // sample became an alert.
        let reading = FinalHandoff.read(message)
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .insideCodeOrQuote)
        #expect(throughInstalledStopHook(message) == .workComplete)
    }

    @Test("An unclosed fence leaves the rest of the message opaque")
    func unclosedFenceIsConservative() {
        let reading = FinalHandoff.read("```\nsample\n\nI need from you: choose a colour.")
        #expect(!reading.asksForSomething, "no closing fence means we do not know where code ended")
    }

    @Test("A handoff wrapped in inline backticks is a quotation of the convention")
    func inlineCodeIsNotARequest() {
        let reading = FinalHandoff.read("The convention is `I need from you: a decision`. Nothing to do.")
        #expect(!reading.asksForSomething)
    }

    @Test("Parsing is bounded by lines as well as bytes")
    func lineCountIsBounded() {
        let padding = String(repeating: "filler\n", count: FinalHandoff.maximumLines + 50)
        #expect(!FinalHandoff.read(padding + "**I need from you:** a decision").asksForSomething,
                "beyond the line bound we stop looking rather than scan without limit")
    }
}

/// A subagent's proof of life arrives only through the heartbeat, because housekeeping spools
/// nothing. It has to be ingested — and it still may not disturb the parent.
@Suite("Housekeeping heartbeats")
struct HousekeepingHeartbeatTests {
    private func heartbeat(_ session: String, at moment: Date,
                           event: String = "SubagentStop",
                           signal: SignalClass = .housekeeping) -> SessionHeartbeat {
        SessionHeartbeat(identity: Fixture.identity(session: session),
                         lastEventAt: moment, lastHookEvent: event, lastSignal: signal)
    }

    @Test("A session first heard of through a child's heartbeat is not dropped")
    func firstContactCanBeAChild() {
        let (engine, clock, _) = makeEngine()

        engine.applyHeartbeats([heartbeat("s1", at: clock.now)])

        #expect(engine.session("s1") != nil, "the session exists")
        #expect(engine.session("s1")?.lastEventAt == clock.now, "and its last-seen actually advanced")
        #expect(engine.session("s1")?.activity == .unknown, "without claiming it is working")
        #expect(engine.visibleItems(at: clock.now).isEmpty)
    }

    @Test("Repeated delivery of the same heartbeat changes nothing")
    func repeatedDeliveryIsANoOp() {
        let (engine, clock, _) = makeEngine()
        let beat = heartbeat("s1", at: clock.now)

        engine.applyHeartbeats([beat])
        let after = engine.session("s1")
        _ = clock.advance(30)
        engine.applyHeartbeats([beat, beat])

        #expect(engine.session("s1")?.lastEventAt == after?.lastEventAt)
        #expect(engine.session("s1")?.episodeID == after?.episodeID, "and no episode was closed")
    }

    @Test("A child's heartbeat leaves a request, a pause and a dismissal exactly as they were")
    func housekeepingPreservesEverything() {
        let (engine, clock, _) = makeEngine()
        let running = BackgroundEvidence(availability: .reported, running: 1,
                                         types: ["shell"], observedAt: clock.now)
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    at: clock.now, hookEvent: "Stop", background: running))
        let before = engine.session("s1")
        _ = clock.advance(10)

        engine.applyHeartbeats([heartbeat("s1", at: clock.now)])
        let after = engine.session("s1")

        #expect(engine.visibleItems(at: clock.now).count == 1, "the request stands")
        #expect(after?.currentItemID == before?.currentItemID)
        #expect(after?.activity == before?.activity)
        #expect(after?.lastActivityAt == before?.lastActivityAt, "a child is not the parent working")
        #expect(after?.background == before?.background)
        #expect(after?.episodeDismissed == before?.episodeDismissed)
        #expect((after?.lastEventAt ?? .distantPast) > (before?.lastEventAt ?? .distantPast),
                "but the session was heard from, and says so")
    }

    @Test("A record written before this change is read for what it means, not what it says",
          arguments: ["SubagentStop", "SubagentStart"])
    func legacyChildRecordsAreReinterpreted(_ event: String) {
        // Both paths: a spool event and a heartbeat, each labelled `activity` as earlier builds and
        // the installed hooks wrote them.
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    at: clock.now, hookEvent: "Stop"))
        _ = clock.advance(5)

        engine.ingest(Fixture.event(session: "s1", signal: .activity, at: clock.now, hookEvent: event))
        #expect(engine.visibleItems(at: clock.now).count == 1, "a replayed child event closes nothing")
        #expect(engine.session("s1")?.activity != .working)

        _ = clock.advance(5)
        engine.applyHeartbeats([heartbeat("s1", at: clock.now, event: event, signal: .activity)])
        #expect(engine.visibleItems(at: clock.now).count == 1, "and neither does a legacy heartbeat")
        #expect(engine.session("s1")?.activity != .working)
    }

    @Test("Genuine parent work is untouched by the reinterpretation", arguments: [
        "PostToolUse", "UserPromptSubmit", "PostToolBatch",
    ])
    func parentWorkStillResumes(_ event: String) {
        let (engine, clock, _) = makeEngine()
        engine.ingest(Fixture.event(session: "s1", signal: .attention, kind: .handoff,
                                    at: clock.now, hookEvent: "Stop"))
        _ = clock.advance(5)

        engine.applyHeartbeats([heartbeat("s1", at: clock.now, event: event, signal: .activity)])

        #expect(engine.visibleItems(at: clock.now).isEmpty, "the parent carried on, so the ask is done")
        #expect(engine.session("s1")?.activity == .working)
    }
}

/// The last two false positives an independent pass found, and the boundaries around them.
@Suite("Handoff phrase and fence boundaries")
struct HandoffBoundaryTests {
    private func throughInstalledStopHook(_ message: String) -> AttentionKind? {
        HookIngestion.process(
            payload: [
                "hook_event_name": "Stop",
                "session_id": "s1",
                "background_tasks": [["status": "running", "type": "shell"]],
                "session_crons": [],
                "last_assistant_message": message,
            ],
            identity: Fixture.identity(session: "s1"),
            now: Fixture.origin,
            override: HookIngestion.Override(kind: .workComplete)).event?.attentionKind
    }

    @Test("A complete no-request phrase is silent, however it is finished", arguments: [
        "I need from you: no action needed.",
        "I need from you: nothing required.",
        "**I need from you:** nothing needed at all.",
        "**I need from you:** none required",
        "I need from you: no action needed for now.",
        "_I need from you:_ nothing further.",
        "**I need from you:** nothing else — Codex installs next.",
    ])
    func completeDismissalsAreQuiet(_ message: String) {
        let reading = FinalHandoff.read(message)
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .explicitlyNothing)
        #expect(throughInstalledStopHook(message) == .workComplete)
    }

    @Test("An ordinary word after the phrase is still a request", arguments: [
        "**I need from you:** none of these options work, please choose.",
        "**I need from you:** nothing you have sent so far answers this — pick one.",
        "**I need from you:** no action on the panel, but decide the colour.",
    ])
    func aSentenceAfterThePhraseStillAsks(_ message: String) {
        // The qualifier list is closed on purpose. A word outside it means the sentence carried on,
        // and a sentence that carries on is where a request lives.
        #expect(FinalHandoff.read(message).asksForSomething)
        #expect(throughInstalledStopHook(message) == .handoff)
    }

    @Test("A fence with an info string does not close an open block", arguments: [
        "```text\n```python\nI need from you: choose a colour.\n```",
        "````\n```swift\nI need from you: choose a colour.\n````",
        "~~~\n~~~ruby\nI need from you: choose a colour.\n~~~",
    ])
    func infoStringDoesNotCloseAFence(_ message: String) {
        // ```python inside a block opens a nested example; it does not end the outer one. Without
        // the "nothing after the delimiter" rule, the block ended early and code became an alert.
        let reading = FinalHandoff.read(message)
        #expect(!reading.asksForSomething)
        #expect(reading.reason == .insideCodeOrQuote)
        #expect(throughInstalledStopHook(message) == .workComplete)
    }

    @Test("A genuine footer after a properly closed block is still read")
    func footerAfterClosedFenceStillAsks() {
        let message = """
        Here is the config:

        ```json
        {"panel": true}
        ```

        **I need from you:** confirm the panel setting.
        """
        let reading = FinalHandoff.read(message)
        #expect(reading.asksForSomething, "closing the block properly hands the message back to prose")
        #expect(reading.excerpt?.hasPrefix("confirm the panel setting") == true)
        #expect(throughInstalledStopHook(message) == .handoff)
    }

    @Test("A closing delimiter with trailing whitespace still closes")
    func trailingWhitespaceStillCloses() {
        let message = "```\nsample\n```   \n\n**I need from you:** confirm it."
        #expect(FinalHandoff.read(message).asksForSomething)
    }
}
