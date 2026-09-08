import Foundation
import AgentAttentionCore

// aa-status — read-only query interface for Agent Warden.
//
// The point is that something other than a pair of eyes can ask "which sessions need me?" without
// a screenshot and without starting anything. It reads saved state and never writes, so asking is
// always safe: it cannot drain the spool, lose an alert, or change what the app does next.
//
// Foundation only — no AppKit, no window server — so it runs over SSH. It does need to be able to
// inspect processes: under a sandbox that refuses `sysctl`, it reports the app's state as unknown
// rather than guessing that it is dead.

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = AppPaths.resolved()
let store = EventStore(paths: paths)

if arguments.contains("--version") {
    print("aa-status \(AgentAttentionVersion.string)")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    aa-status \(AgentAttentionVersion.string) — read-only view of the \(AgentAttentionVersion.displayName) queue

      aa-status              one-line-per-item summary for a human
      aa-status --json       the same information as JSON (schema \(StatusReport.currentSchema))
      aa-status --waiting    exit status only, see below
      aa-status --session <full-session-id> --context [--json]
                             recent conversation for ONE session, read on demand
      aa-status --contract [--json] [--content]
                             the orchestration contract the user selected, read fresh
      aa-status --version

    Reads only. Never starts the app, never modifies the queue.

    --waiting exit codes:
      0  something is waiting for you
      1  nothing is waiting, and the answer can be trusted (app running, state fresh and readable)
      2  cannot tell — the app is not running, its state is stale or unreadable, or process
         inspection is unavailable here. Never treat this as "all quiet".

    JSON shape:
      .app.running            true / false / null. null means process inspection was refused, not
                              that the app is gone.
      .app.livenessVerified   false when we could not check at all
      .app.stateReadable      false when the saved queue exists but will not parse
      .app.fresh              running AND readable AND written recently
      .app.stateAgeSeconds    how old the saved queue is
      .app.unprocessedEvents  hook events written but not yet folded in
      .counts                 pending / snoozed / sessionsTracked / sessionsWorking /
                              sessionsWaitingOnBackground / sessionsUncertain /
                              sessionsAwaitingFirstHook
      .pending[]              kind, source, project, sessionID (full, stable),
                              displayID (short, display only), reason, waitingSeconds, occurrences,
                              clickTarget, openLabel, process (alive|dead|unknown|unidentified)
      .sessions[]             every tracked session. `hookCoverage` says whether a hook has ever
                              reported for it; `attention` says what we can claim about it *now*:
                                waiting            — it asked for something, and the ask is open
                                none               — positively not asking: working, paused on its
                                                     own background work, or already dealt with
                                uncertain          — its turn ended and nothing confirmed how
                                awaitingFirstHook  — found running, never reported
                              The last two are NOT "quiet". Having heard from a session once does
                              not make its current state known, so they are reported apart.
      .sessions[].link        a Ghostty tab the user confirmed for this session: terminalID,
                              provenance ("userConfirmed" — a person said so; nothing is derived
                              from tty, title or working directory), pairedAt, and a `verdict`
                              checked at the moment of asking against this Ghostty process and this
                              Claude process. `usable: false` means do not expect exact navigation.
                              Absent means no link, and then `clickTarget` is `appOnly` at best.
      .sessions[].background  what the last Stop hook said the turn left running: availability
                              (reported|none|unknown), running / failed / crons counts, task types,
                              and waiting / confirmedComplete. Counts only — never a task's
                              description, command or prompt. "unknown" means the evidence was
                              missing or unreadable, which is neither busy nor finished.

    A session waiting on its own background work is NOT in .pending — nothing is being asked of
    you — so --waiting stays quiet for it. It is counted in .counts.sessionsWaitingOnBackground.

    Elapsed silence never produces an item. A session that has been quiet for six hours is
    reported exactly as one that has been quiet for six seconds.
      .discovery              when the registry was last scanned, and how many sessions are
                              awaiting a first hook versus covered by one
      .warnings[]             plain sentences about anything that makes the above misleading

    --session … --context:
      Reads the tail of that one session's transcript and prints what was recently said, attributed
      and timestamped. It is the only mode that reads message content, and it does so only when you
      ask: nothing is cached, persisted, logged, or folded into the queue.

      The id must be the FULL session id. Short ids collide, and a collision here would show you
      another session's conversation. Every record read is checked to carry that same id.

      What is excluded: thinking blocks, tool inputs, tool result payloads, attachments, sidechains.
      What is bounded: a 1 MiB tail, at most \(SessionContextReader.maximumMessages) messages,
      \(SessionContextReader.maximumExcerptCharacters) characters each and
      \(SessionContextReader.maximumTotalCharacters) in total.

      A transcript excerpt is NOT an attention signal. It never raises an item and never clears one.
      The session's real attention state is reported separately, from the queue, and says so.

      **Identity is checked before anything is read.** A session id Agent Warden is not tracking
      gets no contents at all, whatever file happens to carry that name — presenting a conversation
      the app cannot vouch for would be worse than answering nothing.

      `attention.known` is true only when the state is one we positively know AND the queue can be
      trusted (app running, state fresh and readable). A saved request from an app that is no longer
      running is still reported — it is a real record — but it is not called live certainty.
      `identity` says `verifiedLive`, `processGone`, `unverified` or `notTracked`; queue freshness,
      app presence, unprocessed hook events and the age of the newest message are all reported
      separately, because they are separate questions.

      Questions found in the transcript are `answered`, `cancelled` (an error result — an interrupted
      or refused question is not an answer) or `notObserved`. Never "unanswered": not seeing a result
      is not evidence that one is owed, and only a hook can say a session is waiting.

      Exit codes:
        0  the transcript was read
        2  usage error — no session id given, or it is not a plausible id
        3  no transcript exists for that session id
        4  a transcript exists but could not be read (permission, or the path is not a transcript)
        5  that id is not a session Agent Warden tracks; nothing was read
        6  the session is tracked, but its Claude process is gone or could not be pinned to the
           one recorded; nothing was read, because a recycled pid may belong to something else

      Errors go to stderr; the report goes to stdout. With --json, stdout is a single JSON object
      whether or not the transcript could be read; `availability` says which.

    --contract:
      What working agreement is in force, read from the current configuration and the current file
      on every invocation. Never cached, so it cannot serve a stale agreement; it does not need the
      app or the bridge to be running.

      Reports `availability` (available, noSelection, missing, notRegularFile, unsupportedType,
      tooLarge, notText, unreadable, changedWhileReading, configUnreadable), the selected and
      resolved paths, `readAt`, size, modification time and `revision` — a SHA-256 of the exact
      bytes, which is how a consumer detects an edit that kept the same size and second.

      `--content` adds the body, UTF-8, whole or not at all, bounded at
      \(OrchestrationContract.maximumBytes) bytes. Without it, no body is printed at all.

      Reads only: it never opens the document in an application, never runs it, never edits it or
      the configuration, starts no session and grants no permission. A selection is the user's own
      statement of policy — it is not an authorisation, and it does not make any assistant load or
      follow anything.

      How to use it: ask for the contract, look at `availability` and `revision`, read the content
      if you need it, act within what you are actually allowed to do, and ask again when the work
      changes or the revision does.

      Exit codes:
        0  read
        1  nothing is selected
        3  selected, but nothing is at that path
        4  unreadable, changed mid-read, or the configuration could not be read
        5  not a regular file, an unsupported type, or not UTF-8 text
        6  larger than the limit; no partial body is ever returned

    Storage root: \(paths.root.path)   (override with AGENT_ATTENTION_HOME)
    """)
    exit(0)
}

// aa-status --contract [--json] [--content]
//
// Deliberately answered before anything else is loaded: this mode reads the configuration and the
// chosen document itself, and depends on nothing the monitor has saved. It works whether or not the
// app or the bridge is running.
if arguments.contains("--contract") {
    exit(ContractCommand.run(arguments: arguments, paths: paths))
}

let config = AttentionConfig.load(from: paths.configFile)

// aa-status --session <full-session-id> --context [--json]
//
// A separate mode, and the only one that reads message content. Everything the ordinary modes
// promise still holds: it opens the transcript for reading, and writes nothing anywhere — no spool
// draining, no state file, no log, no app launch, no network, no model call.
if arguments.contains("--context") || arguments.contains("--session") {
    exit(SessionContextCommand.run(arguments: arguments, paths: paths, store: store, config: config))
}

// Links are read from their own file. `aa-status` has no window server, so it does not ask Ghostty
// anything: the verdict it reports is "we could not check", which is the honest answer from here
// and is never rounded up to "valid".
let report = StatusReport.build(store: store, config: config,
                                pairings: PairingStore(url: paths.pairingsFile).load())

if arguments.contains("--waiting") {
    // Three outcomes, not two. "Nothing waiting" and "I could not find out" must not share an
    // exit code, or a script will treat a stopped monitor as a quiet one.
    if report.counts.pending > 0 { exit(0) }
    exit(report.answerIsTrustworthy ? 1 : 2)
}

if arguments.contains("--json") {
    print(report.jsonString())
} else {
    print(report.textSummary())
}
exit(0)
