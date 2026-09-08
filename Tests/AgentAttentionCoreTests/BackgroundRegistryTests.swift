import Foundation
import Testing
@testable import AgentAttentionCore

private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func frame(_ type: String, session: String = "S", task: String = "T1",
                   event: String = UUID().uuidString, status: String? = nil,
                   taskType: String? = nil, toolUse: String? = nil) -> BackgroundLifecycleFrame? {
    var object: [String: Any] = ["type": type == "tool_progress" ? "tool_progress" : "system",
                                 "subtype": type, "session_id": session, "task_id": task,
                                 "uuid": event]
    if let status { object["status"] = status }
    if let taskType { object["task_type"] = taskType }
    if let toolUse { object["tool_use_id"] = toolUse }
    return BackgroundLifecycleFrame(object)
}

/// One job at a time, named by the session **and** the task.
@Suite("Background job registry")
struct BackgroundRegistryTests {
    @Test("A started task is recorded against the session that owns it")
    func aStartedTaskIsRecorded() {
        var registry = BackgroundRegistry()
        #expect(registry.apply(frame("task_started")!, ownedBy: "S", at: at(0)) == .recorded)

        #expect(registry.jobs.count == 1)
        let job = registry.jobs[0]
        #expect(job.identity == BackgroundJob.Identity(sessionID: "S", taskID: "T1"))
        #expect(job.state == .running)
        #expect(job.source == .lifecycleStream)
        #expect(job.observedAt == at(0))
    }

    @Test("A frame naming another session is refused outright")
    func aForeignFrameIsRefused() {
        var registry = BackgroundRegistry()
        #expect(registry.apply(frame("task_started", session: "OTHER")!, ownedBy: "S", at: at(0))
                == .wrongSession)
        #expect(registry.jobs.isEmpty, "an id we cannot vouch for creates nothing")
    }

    @Test("A frame with no task id creates nothing")
    func anUnidentifiedFrameIsRefused() {
        var registry = BackgroundRegistry()
        let object: [String: Any] = ["type": "system", "subtype": "task_started", "session_id": "S", "uuid": "e1"]
        #expect(BackgroundLifecycleFrame(object) == nil)
        #expect(registry.jobs.isEmpty)
    }

    @Test("The same task id in two sessions is two different jobs")
    func taskIdentityIncludesTheSession() {
        var first = BackgroundRegistry()
        var second = BackgroundRegistry()
        _ = first.apply(frame("task_started", session: "A", task: "shared")!, ownedBy: "A", at: at(0))
        _ = second.apply(frame("task_started", session: "B", task: "shared")!, ownedBy: "B", at: at(0))

        #expect(first.jobs[0].identity.sessionID == "A")
        #expect(second.jobs[0].identity.sessionID == "B")
        #expect(first.jobs[0].identity != second.jobs[0].identity,
                "a task id alone is not an identity; two sessions can each have a T1")
    }

    @Test("An event that arrives twice is applied once")
    func duplicateEventsAreIgnored() {
        var registry = BackgroundRegistry()
        let started = frame("task_started", event: "e-1")!
        #expect(registry.apply(started, ownedBy: "S", at: at(0)) == .recorded)
        #expect(registry.apply(started, ownedBy: "S", at: at(30)) == .duplicate)

        #expect(registry.jobs.count == 1)
        #expect(registry.jobs[0].observedAt == at(0), "a replay does not move the clock forward")
    }

    @Test("Progress after a terminal outcome does not bring a job back to life")
    func terminalStatesAreSticky() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1")!, ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_notification", event: "e2", status: "completed")!,
                           ownedBy: "S", at: at(10))
        #expect(registry.jobs[0].state == .completed)

        let late = registry.apply(frame("task_progress", event: "e3")!, ownedBy: "S", at: at(20))
        #expect(late == .outOfOrder)
        #expect(registry.jobs[0].state == .completed, "an out-of-order frame is not a resurrection")
    }

    @Test("A start that arrives after the outcome does not reopen the job")
    func startAfterTerminalIsIgnored() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_notification", event: "e1", status: "failed")!,
                           ownedBy: "S", at: at(10))
        #expect(registry.apply(frame("task_started", event: "e2")!, ownedBy: "S", at: at(5))
                == .outOfOrder)
        #expect(registry.jobs[0].state == .failed)
    }

    @Test("Stopped and failed are different outcomes", arguments: [
        ("stopped", BackgroundJob.State.stopped), ("failed", .failed), ("completed", .completed),
    ])
    func outcomesAreDistinct(_ testCase: (String, BackgroundJob.State)) {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1")!, ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_notification", event: "e2", status: testCase.0)!,
                           ownedBy: "S", at: at(5))
        #expect(registry.jobs[0].state == testCase.1)
    }

    @Test("A status nobody taught it is unknown, never running and never done")
    func unknownStatusStaysUnknown() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1")!, ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_notification", event: "e2", status: "quiescent")!,
                           ownedBy: "S", at: at(5))
        #expect(registry.jobs[0].state == .unknown)
        #expect(registry.coverage != .complete)
    }

    @Test("local_bash alone cannot say whether it is a shell or a monitor")
    func localBashIsNotADiscriminant() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1", taskType: "local_bash")!,
                           ownedBy: "S", at: at(0))
        #expect(registry.jobs[0].kind == .unknown,
                "the same type covers a one-shot shell and a long-lived monitor")
        #expect(registry.jobs[0].typeLabel == "local_bash", "the vocabulary is still reported")
    }

    @Test("A type that names watching behaviour is believed", arguments: [
        "monitor", "watch", "watcher",
    ])
    func watchingTypesAreRead(_ type: String) {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1", taskType: type)!,
                           ownedBy: "S", at: at(0))
        #expect(registry.jobs[0].kind == .monitor)
    }

    @Test("A feature name is not a promise about lifespan", arguments: [
        "shell", "bash", "local_bash", "subagent", "local_agent", "task", "mcp_task",
    ])
    func featureTypesDoNotImplyAFiniteLife(_ type: String) {
        // `shell` covers `ls` and `tail -f`; `subagent` covers a two-second answer and a loop that
        // runs all afternoon. Reading either as finite would put "1 background job" beside a
        // session whose watcher never ends, and then take it away when it did not finish.
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1", taskType: type)!,
                           ownedBy: "S", at: at(0))
        #expect(registry.jobs[0].kind == .unknown, "how long it lives is not evidenced by its type")
        #expect(registry.jobs[0].typeLabel == type, "and the word it used is still reported")
    }

    @Test("A wakeup that fires once is not a recurring monitor")
    func oneShotWakeupsAreNotMonitors() {
        #expect(BackgroundJob.kind(fromType: "cron", recurring: true) == .recurringWakeup)
        #expect(BackgroundJob.kind(fromType: "cron", recurring: false) == .finite,
                "one alarm is not a monitor running all day")
    }

    @Test("A task and a cron with the same id are two different jobs")
    func identityNamespacesDoNotCollide() {
        let task = BackgroundJob.Identity(sessionID: "S", taskID: "1", namespace: .task)
        let cron = BackgroundJob.Identity(sessionID: "S", taskID: "1", namespace: .cron)
        #expect(task != cron, "two numbering systems, two jobs — a cron must not close a shell")
    }

    @Test("A tool-use correlation is kept when it is offered, and is not required")
    func correlationIsOptional() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", event: "e1", toolUse: "tool-42")!,
                           ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_started", task: "T2", event: "e2")!, ownedBy: "S", at: at(1))
        #expect(registry.jobs[0].toolUseID == "tool-42")
        #expect(registry.jobs[1].toolUseID == nil)
        #expect(registry.jobs[1].state == .running, "a missing correlation is not a missing job")
    }

    @Test("The registry is bounded, and says what it dropped")
    func evictionIsBoundedAndReported() {
        var registry = BackgroundRegistry()
        for index in 0...(BackgroundRegistry.maximumJobs + 9) {
            _ = registry.apply(frame("task_started", task: "T\(index)", event: "e\(index)")!,
                               ownedBy: "S", at: at(Double(index)))
        }
        #expect(registry.jobs.count == BackgroundRegistry.maximumJobs)
        #expect(registry.evicted == 10)
        #expect(registry.coverage == .partial, "having dropped records, it cannot claim to be whole")
        #expect(registry.jobs.first?.identity.taskID == "T10", "the oldest went first")
    }

    @Test("An empty registry is not evidence that the work is done")
    func emptinessProvesNothing() {
        let registry = BackgroundRegistry()
        #expect(registry.jobs.isEmpty)
        #expect(registry.coverage == .unknown)
        #expect(!registry.provesNothingIsRunning,
                "never having heard about a job is not the same as there being none")

        var heard = BackgroundRegistry()
        _ = heard.apply(frame("task_started", event: "e1")!, ownedBy: "S", at: at(0))
        _ = heard.apply(frame("task_notification", event: "e2", status: "completed")!,
                        ownedBy: "S", at: at(5))
        #expect(!heard.provesNothingIsRunning,
                "a stream we know is partial cannot establish that nothing else is running")
    }

    @Test("Counts are derived from the jobs, not carried alongside them")
    func countsAreDerived() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", task: "A", event: "1")!, ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_started", task: "B", event: "2")!, ownedBy: "S", at: at(1))
        _ = registry.apply(frame("task_notification", task: "B", event: "3", status: "failed")!,
                           ownedBy: "S", at: at(2))
        _ = registry.apply(frame("task_started", task: "C", event: "4")!, ownedBy: "S", at: at(3))
        _ = registry.apply(frame("task_notification", task: "C", event: "5", status: "stopped")!,
                           ownedBy: "S", at: at(4))

        #expect(registry.running == 1)
        #expect(registry.failed == 1)
        #expect(registry.stopped == 1)
        #expect(registry.completed == 0)
    }

    @Test("Freshness is a property of each job, not of the registry")
    func freshnessIsPerJob() {
        var registry = BackgroundRegistry()
        _ = registry.apply(frame("task_started", task: "old", event: "1")!, ownedBy: "S", at: at(0))
        _ = registry.apply(frame("task_started", task: "new", event: "2")!, ownedBy: "S", at: at(3_000))

        let jobs = registry.jobs
        #expect(jobs[0].isStale(at: at(3_100), after: 1_800))
        #expect(!jobs[1].isStale(at: at(3_100), after: 1_800))
    }
}

/// The `Stop` snapshot, enriched — identifiers and vocabulary, never content.
@Suite("Background snapshot records")
struct BackgroundSnapshotTests {
    private func payload(tasks: [[String: Any]], crons: [[String: Any]]) -> [String: Any] {
        ["background_tasks": tasks, "session_crons": crons]
    }

    @Test("Identifiers, types and statuses are kept; commands and prompts are not")
    func recordsCarryOnlyVocabulary() {
        let evidence = BackgroundEvidence.read(from: payload(tasks: [
            ["id": "task-1", "type": "shell", "status": "running",
             "command": "rm -rf /", "description": "secret plan", "prompt": "do the thing"],
        ], crons: []), now: at(0))

        #expect(evidence.records.count == 1)
        let record = evidence.records[0]
        #expect(record.id == "task-1")
        #expect(record.type == "shell")
        #expect(record.state == .running)
        let encoded = String(data: try! JSONEncoder().encode(evidence), encoding: .utf8)!
        #expect(!encoded.contains("rm -rf"))
        #expect(!encoded.contains("secret plan"))
        #expect(!encoded.contains("do the thing"))
    }

    @Test("A scheduled wakeup keeps its id and whether it recurs")
    func cronsCarryRecurrence() {
        let evidence = BackgroundEvidence.read(from: payload(tasks: [], crons: [
            ["id": "cron-1", "recurring": true, "prompt": "check the deploy"],
        ]), now: at(0))

        let cron = evidence.records.first { $0.kind == .recurringWakeup }
        #expect(cron?.id == "cron-1")
        #expect(cron?.recurring == true)
        #expect(evidence.availability == .reported, "a scheduled wakeup is pending work")
    }

    @Test("Two records with the same id make the reading uncertain")
    func duplicateRecordsAreNotCompleteCoverage() {
        let evidence = BackgroundEvidence.read(from: payload(tasks: [
            ["id": "task-1", "type": "shell", "status": "completed"],
            ["id": "task-1", "type": "shell", "status": "completed"],
        ], crons: []), now: at(0))

        #expect(evidence.availability == .unknown,
                "a list that repeats itself is not a list we can call complete")
        #expect(!evidence.isConfirmedComplete)
    }

    @Test("A record with no id is still counted, and still makes coverage partial")
    func anonymousRecordsAreNotDropped() {
        let evidence = BackgroundEvidence.read(from: payload(tasks: [
            ["type": "shell", "status": "running"],
        ], crons: []), now: at(0))

        #expect(evidence.running == 1)
        #expect(evidence.recordCoverage == .partial,
                "one entry we could not name means the list is not fully described")
    }

    @Test("An older snapshot with no records at all still decodes")
    func olderSnapshotsDecode() throws {
        let old = #"{"availability":"reported","running":1,"completed":0,"failed":0,"unrecognised":0,"crons":0,"types":["shell"],"observedAt":760000000}"#
        let evidence = try JSONDecoder().decode(BackgroundEvidence.self, from: Data(old.utf8))
        #expect(evidence.running == 1)
        #expect(evidence.records.isEmpty)
        #expect(evidence.recordCoverage == .unknown, "no records is not an empty list of jobs")
    }

    @Test("The bounded list is capped, and says it was capped")
    func recordsAreBounded() {
        let many = (0..<(BackgroundEvidence.maximumRecords + 5)).map { index in
            ["id": "task-\(index)", "type": "shell", "status": "running"] as [String: Any]
        }
        let evidence = BackgroundEvidence.read(from: payload(tasks: many, crons: []), now: at(0))
        #expect(evidence.records.count == BackgroundEvidence.maximumRecords)
        #expect(evidence.running == BackgroundEvidence.maximumRecords + 5, "counts are not capped")
        #expect(evidence.recordCoverage == .partial)
    }
}

/// The wire, as documented — and what happens when it does not arrive.
@Suite("Background lifecycle frames")
struct BackgroundLifecycleFrameTests {
    @Test("The documented system shape parses", arguments: [
        "task_started", "task_progress", "task_notification", "task_updated",
    ])
    func systemSubtypesParse(_ subtype: String) {
        let object: [String: Any] = ["type": "system", "subtype": subtype, "task_id": "T1",
                                     "uuid": "e1", "session_id": "S"]
        let frame = BackgroundLifecycleFrame(object)
        #expect(frame?.kind.rawValue == subtype)
        #expect(frame?.taskID == "T1")
        #expect(frame?.sessionID == "S")
    }

    @Test("A flattened shape no client sends is not accepted")
    func theFlatShapeIsRejected() {
        // The shape an earlier cut of this parsed. Accepting it would let the tests stay green
        // while every real frame fell through to a note.
        #expect(BackgroundLifecycleFrame(["type": "task_started", "task_id": "T1",
                                          "session_id": "S", "uuid": "e"]) == nil)
    }

    @Test("tool_progress keeps its name at the top level, and needs a task id")
    func toolProgressIsTopLevel() {
        let withTask: [String: Any] = ["type": "tool_progress", "tool_use_id": "toolu_1",
                                       "tool_name": "Bash", "parent_tool_use_id": NSNull(),
                                       "elapsed_time_seconds": 3, "task_id": "T1",
                                       "uuid": "e1", "session_id": "S"]
        #expect(BackgroundLifecycleFrame(withTask)?.kind == .toolProgress)
        #expect(BackgroundLifecycleFrame(withTask)?.toolUseID == "toolu_1")

        var withoutTask = withTask
        withoutTask["task_id"] = nil
        #expect(BackgroundLifecycleFrame(withoutTask) == nil,
                "a tool progress frame that names no task tracks nothing")
    }

    @Test("task_updated is read through its patch")
    func patchStatusIsRead() {
        let frame = BackgroundLifecycleFrame(["type": "system", "subtype": "task_updated",
                                              "task_id": "T1", "uuid": "e1", "session_id": "S",
                                              "patch": ["status": "killed",
                                                        "error": "something private"]])
        #expect(frame?.status == "killed")
        var registry = BackgroundRegistry()
        _ = registry.apply(frame!, ownedBy: "S", at: Date())
        #expect(registry.jobs[0].state == .stopped, "killed is stopped, and stopped is not failed")
    }

    @Test("Content fields are never read", arguments: ["description", "prompt", "summary", "error"])
    func contentIsNotRead(_ field: String) {
        let object: [String: Any] = ["type": "system", "subtype": "task_started", "task_id": "T1",
                                     "uuid": "e1", "session_id": "S", field: "SECRET-TEXT",
                                     "task_type": "local_bash"]
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(object)!, ownedBy: "S", at: Date())
        let encoded = String(data: try! JSONEncoder().encode(registry), encoding: .utf8)!
        #expect(!encoded.contains("SECRET-TEXT"))
    }

    @Test("Housekeeping the CLI hides is kept but not counted as the session's work")
    func ambientTasksAreNotShown() {
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                     "task_id": "amb", "uuid": "e1",
                                                     "session_id": "S", "ambient": true])!,
                           ownedBy: "S", at: Date())
        #expect(registry.jobs.count == 1)
        #expect(registry.running == 0, "an auto-started watcher is not the session's work")
        #expect(registry.visible.isEmpty)
    }

    @Test("Every untrusted string is bounded", arguments: [
        String(repeating: "x", count: 200), "with\u{0}null", "", "line\nbreak",
    ])
    func identifiersAreBounded(_ bad: String) {
        #expect(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                          "task_id": bad, "uuid": "e", "session_id": "S"]) == nil)
        #expect(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                          "task_id": "T1", "uuid": "e", "session_id": bad]) == nil)
        // A bad event id is not fatal — it simply cannot be deduplicated, and coverage says so.
        var registry = BackgroundRegistry()
        let frame = BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                              "task_id": "T1", "uuid": bad, "session_id": "S"])
        #expect(frame?.eventID == nil)
        _ = registry.apply(frame!, ownedBy: "S", at: Date())
        #expect(registry.coverage == .partial)
    }
}

/// The level signal, and what a job going quiet is allowed to mean.
@Suite("Background membership")
struct BackgroundMembershipTests {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func started(_ registry: inout BackgroundRegistry, _ id: String, at moment: Date) {
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                     "task_id": id, "uuid": "u-\(id)",
                                                     "session_id": "S"])!,
                           ownedBy: "S", at: moment)
    }

    @Test("A job missing from the live set stops being running — and is not called finished")
    func absentIsItsOwnAnswer() {
        var registry = BackgroundRegistry()
        started(&registry, "A", at: t0)
        started(&registry, "B", at: t0)

        registry.applyMembership(taskIDs: ["A"], ownedBy: "S", at: t0.addingTimeInterval(30))

        #expect(registry.jobs.first { $0.identity.taskID == "A" }?.state == .running)
        let gone = registry.jobs.first { $0.identity.taskID == "B" }
        #expect(gone?.state == .absent, "the payload carries ids; it does not say how B ended")
        #expect(registry.completed == 0, "and absence is never read as completion")
        #expect(registry.running == 1, "nor left showing as freshly running for ever")
    }

    @Test("A settled outcome is not overwritten by the level signal")
    func terminalOutcomesSurviveMembership() {
        var registry = BackgroundRegistry()
        started(&registry, "A", at: t0)
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system",
                                                     "subtype": "task_notification",
                                                     "task_id": "A", "uuid": "n1",
                                                     "session_id": "S", "status": "failed"])!,
                           ownedBy: "S", at: t0.addingTimeInterval(5))

        registry.applyMembership(taskIDs: [], ownedBy: "S", at: t0.addingTimeInterval(10))
        #expect(registry.jobs[0].state == .failed, "it failed; it did not merely go away")
    }

    @Test("A task we never saw start is picked up from the live set")
    func membershipCanIntroduceAJob() {
        var registry = BackgroundRegistry()
        registry.applyMembership(taskIDs: ["new"], ownedBy: "S", at: t0)
        #expect(registry.jobs.count == 1)
        #expect(registry.jobs[0].state == .running)
    }

    @Test("A client restart clears what we thought was live")
    func aRestartResetsTheSet() {
        var registry = BackgroundRegistry()
        started(&registry, "A", at: t0)
        registry.processRestarted(at: t0.addingTimeInterval(60))

        #expect(registry.jobs[0].state == .absent,
                "the level signal is per-process and emits nothing at startup")
        #expect(registry.coverage == .partial)
        #expect(registry.running == 0)
    }
}

/// Snapshot against stream: whichever is newer wins, and a contradiction is said out loud.
@Suite("Background snapshot conflicts")
struct BackgroundConflictTests {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(_ state: String, at moment: Date) -> BackgroundEvidence {
        BackgroundEvidence.read(from: ["background_tasks": [["id": "A", "type": "shell",
                                                             "status": state]],
                                       "session_crons": []], now: moment)
    }

    @Test("An older snapshot does not overwrite what we heard more recently")
    func staleSnapshotsDoNotWin() {
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_progress",
                                                     "task_id": "A", "uuid": "p1",
                                                     "session_id": "S"])!,
                           ownedBy: "S", at: t0.addingTimeInterval(60))

        registry.apply(snapshot: snapshot("running", at: t0), ownedBy: "S")     // taken a minute earlier
        #expect(registry.jobs[0].observedAt == t0.addingTimeInterval(60),
                "a photograph from before does not become the newest thing we know")
        #expect(registry.coverage == .partial, "and the disagreement is on the record")
    }

    @Test("A snapshot that contradicts a settled outcome is recorded, not obeyed")
    func contradictionIsExplicit() {
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system",
                                                     "subtype": "task_notification",
                                                     "task_id": "A", "uuid": "n1",
                                                     "session_id": "S", "status": "completed"])!,
                           ownedBy: "S", at: t0)

        registry.apply(snapshot: snapshot("running", at: t0.addingTimeInterval(30)), ownedBy: "S")
        #expect(registry.jobs[0].state == .completed)
        #expect(registry.coverage == .partial, "the two sources disagree, and that is reported")
    }

    @Test("A newer snapshot does update a job we have not heard from")
    func newerSnapshotsAreApplied() {
        var registry = BackgroundRegistry()
        _ = registry.apply(BackgroundLifecycleFrame(["type": "system", "subtype": "task_started",
                                                     "task_id": "A", "uuid": "s1",
                                                     "session_id": "S"])!,
                           ownedBy: "S", at: t0)
        registry.apply(snapshot: snapshot("completed", at: t0.addingTimeInterval(60)), ownedBy: "S")

        #expect(registry.jobs[0].state == .completed)
        #expect(registry.jobs[0].source == .stopSnapshot, "and where it came from is updated too")
    }

    @Test("A persisted registry is validated on the way in, not trusted")
    func decodingValidates() throws {
        let hostile = #"""
        {"jobs":[
          {"identity":{"sessionID":"S","taskID":"A"},"kind":"unknown","state":"running","source":"lifecycleStream","firstSeenAt":0,"observedAt":0},
          {"identity":{"sessionID":"S","taskID":"A"},"kind":"unknown","state":"running","source":"lifecycleStream","firstSeenAt":0,"observedAt":0},
          {"identity":{"sessionID":"","taskID":"B"},"kind":"unknown","state":"running","source":"lifecycleStream","firstSeenAt":0,"observedAt":0}
        ],"evicted":0,"coverage":"observed","seenEvents":["e1"]}
        """#
        let registry = try JSONDecoder().decode(BackgroundRegistry.self, from: Data(hostile.utf8))
        #expect(registry.jobs.count == 1, "a duplicate identity and an unnamed session are dropped")
        #expect(registry.evicted == 2)
        #expect(registry.coverage == .partial)
    }
}
